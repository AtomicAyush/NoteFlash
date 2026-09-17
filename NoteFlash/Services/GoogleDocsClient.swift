import Foundation

nonisolated struct GoogleDocContent: Sendable {
    let title: String?
    let text: String
}

/// Reads Google Docs as plain text, via the Docs API when signed in,
/// or via the public export link for docs shared as "Anyone with the link".
nonisolated enum GoogleDocsClient {
    enum DocsError: LocalizedError {
        case invalidLink
        case unauthorized
        case notShared
        case notFound
        case apiDisabled(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                "That doesn't look like a Google Docs link. It should contain /document/d/…"
            case .unauthorized:
                "Google sign-in expired. Sign in again in Settings."
            case .notShared:
                AppConfig.googleClientID.isEmpty
                    ? "This doc is private. In Google Docs, tap Share, set General access to \"Anyone with the link\", and paste the link again."
                    : "This doc is private. Sign in with Google in Settings, or set its General access to \"Anyone with the link\"."
            case .notFound:
                "Google Docs couldn't find that document. It may have been deleted or you may not have access."
            case .apiDisabled(let message):
                "Google Docs API error: \(message)"
            case .http(let status):
                "Google Docs returned an error (\(status))."
            }
        }
    }

    static func documentID(from link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.firstMatch(of: #/\/document\/(?:u\/\d+\/)?d\/([A-Za-z0-9_-]{10,})/#) {
            return String(match.1)
        }
        // A bare document ID.
        if trimmed.wholeMatch(of: #/[A-Za-z0-9_-]{25,}/#) != nil {
            return trimmed
        }
        return nil
    }

    static func editURL(for documentID: String) -> URL? {
        URL(string: "https://docs.google.com/document/d/\(documentID)/edit")
    }

    @concurrent
    static func fetchViaAPI(documentID: String, accessToken: String) async throws -> GoogleDocContent {
        var components = URLComponents(string: "https://docs.googleapis.com/v1/documents/\(documentID)")!
        components.queryItems = [URLQueryItem(name: "fields", value: "title,body")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            let document = try JSONDecoder().decode(DocsDocument.self, from: data)
            return GoogleDocContent(title: document.title, text: DocsRenderer.text(for: document))
        case 401:
            throw DocsError.unauthorized
        case 403:
            let message = (try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data))?.error.message ?? ""
            if message.localizedCaseInsensitiveContains("has not been used")
                || message.localizedCaseInsensitiveContains("disabled") {
                throw DocsError.apiDisabled(message)
            }
            throw DocsError.notShared
        case 404:
            throw DocsError.notFound
        default:
            throw DocsError.http(status)
        }
    }

    @concurrent
    static func fetchPublicExport(documentID: String) async throws -> GoogleDocContent {
        let url = URL(string: "https://docs.google.com/document/d/\(documentID)/export?format=txt")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw DocsError.http(0) }
        switch http.statusCode {
        case 200:
            // Private docs redirect to an HTML sign-in page instead of returning text.
            let mimeType = http.mimeType ?? ""
            guard mimeType.hasPrefix("text/plain"), let text = String(data: data, encoding: .utf8) else {
                throw DocsError.notShared
            }
            let cleaned = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            let title = documentTitle(fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"))
            return GoogleDocContent(title: title, text: cleaned)
        case 401, 403:
            throw DocsError.notShared
        case 404:
            throw DocsError.notFound
        default:
            throw DocsError.http(http.statusCode)
        }
    }
}

nonisolated extension GoogleDocsClient {
    /// The doc's name from an export's download filename, e.g.
    /// `attachment; filename="Notes.txt"; filename*=UTF-8''My%20Notes.txt` → "My Notes".
    static func documentTitle(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        var filename: String?
        for part in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.lowercased().hasPrefix("filename*="),
               let encoded = part.split(separator: "'", maxSplits: 2).last {
                filename = String(encoded).removingPercentEncoding
                break
            } else if part.lowercased().hasPrefix("filename=") {
                filename = String(part.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        guard var name = filename?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if name.lowercased().hasSuffix(".txt") { name.removeLast(4) }
        return name.isEmpty ? nil : name
    }
}

// MARK: - Docs API model

nonisolated private struct GoogleAPIErrorEnvelope: Decodable {
    struct Body: Decodable { let message: String? }
    let error: Body
}

nonisolated private struct DocsDocument: Decodable {
    let title: String?
    let body: DocsBody?
}

nonisolated private struct DocsBody: Decodable {
    let content: [DocsElement]?
}

nonisolated private struct DocsElement: Decodable {
    let paragraph: DocsParagraph?
    let table: DocsTable?
}

nonisolated private struct DocsParagraph: Decodable {
    struct Element: Decodable {
        struct TextRun: Decodable { let content: String? }
        let textRun: TextRun?
    }
    struct Style: Decodable { let namedStyleType: String? }
    struct Bullet: Decodable { let nestingLevel: Int? }

    let elements: [Element]?
    let paragraphStyle: Style?
    let bullet: Bullet?
}

nonisolated private struct DocsTable: Decodable {
    struct Row: Decodable { let tableCells: [Cell]? }
    struct Cell: Decodable { let content: [DocsElement]? }
    let tableRows: [Row]?
}

/// Flattens a Docs API document into lightly marked-up text (headings, bullets, tables).
nonisolated private enum DocsRenderer {
    static func text(for document: DocsDocument) -> String {
        lines(for: document.body?.content ?? []).joined(separator: "\n")
    }

    private static func lines(for elements: [DocsElement]) -> [String] {
        var output: [String] = []
        for element in elements {
            if let paragraph = element.paragraph {
                let line = render(paragraph)
                if !line.isEmpty { output.append(line) }
            } else if let table = element.table {
                for row in table.tableRows ?? [] {
                    let cells = (row.tableCells ?? []).map { cell in
                        lines(for: cell.content ?? []).joined(separator: " ")
                    }
                    output.append(cells.joined(separator: " | "))
                }
            }
        }
        return output
    }

    private static func render(_ paragraph: DocsParagraph) -> String {
        let text = (paragraph.elements ?? [])
            .compactMap { $0.textRun?.content }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        if let bullet = paragraph.bullet {
            let indent = String(repeating: "  ", count: bullet.nestingLevel ?? 0)
            return "\(indent)• \(text)"
        }
        switch paragraph.paragraphStyle?.namedStyleType {
        case "TITLE": return "# \(text)"
        case "SUBTITLE": return "## \(text)"
        case let style? where style.hasPrefix("HEADING_"):
            let level = Int(style.dropFirst("HEADING_".count)) ?? 1
            return "\(String(repeating: "#", count: min(level, 6))) \(text)"
        default:
            return text
        }
    }
}
