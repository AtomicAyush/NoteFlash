import Foundation

nonisolated struct DriveDoc: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let modifiedTime: Date?
    let ownedByMe: Bool
    let ownerName: String?

    var editURL: String { "https://docs.google.com/document/d/\(id)/edit" }
}

nonisolated struct DriveDocPage: Sendable {
    let docs: [DriveDoc]
    let nextPageToken: String?
}

/// Lists the signed-in user's Google Docs through the Drive API (metadata only).
nonisolated enum GoogleDriveClient {
    enum DriveError: LocalizedError, Equatable {
        case unauthorized
        case missingPermission
        case apiDisabled
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Google sign-in expired. Sign in again in Settings."
            case .missingPermission:
                "NoteFlash doesn't have permission to list your Google Docs yet."
            case .apiDisabled:
                "The Google Drive API isn't turned on for NoteFlash's Google Cloud project. Enable it under APIs & Services → Library → Google Drive API."
            case .http(let status):
                "Google Drive returned an error (\(status))."
            }
        }
    }

    static let pageSize = 50

    /// Google Docs the user can open, most recently edited first, optionally filtered by name.
    @concurrent
    static func listDocuments(accessToken: String, search: String, pageToken: String?) async throws -> DriveDocPage {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query(search: search)),
            URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime,ownedByMe,owners(displayName))"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        if let pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw error(status: status, body: data) }

        let list = try JSONDecoder().decode(FileList.self, from: data)
        let docs = (list.files ?? []).map { file in
            DriveDoc(
                id: file.id,
                name: file.name?.isEmpty == false ? file.name! : "Untitled document",
                modifiedTime: file.modifiedTime.flatMap(parseDate),
                ownedByMe: file.ownedByMe ?? false,
                ownerName: file.owners?.first?.displayName
            )
        }
        return DriveDocPage(docs: docs, nextPageToken: list.nextPageToken)
    }

    /// Drive search query for non-trashed Google Docs whose names contain `search`.
    static func query(search: String) -> String {
        var clauses = ["mimeType = 'application/vnd.google-apps.document'", "trashed = false"]
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            clauses.append("name contains '\(escaped)'")
        }
        return clauses.joined(separator: " and ")
    }

    static func error(status: Int, body: Data) -> DriveError {
        let details = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        let reasons = ((details?.errors ?? []).compactMap(\.reason) + (details?.details ?? []).compactMap(\.reason))
            .map { $0.lowercased() }
        let message = details?.message?.lowercased() ?? ""
        switch status {
        case 401:
            return .unauthorized
        case 403 where reasons.contains(where: { $0.contains("insufficient") })
            || message.contains("insufficient"):
            return .missingPermission
        case 403 where reasons.contains(where: { $0 == "accessnotconfigured" || $0 == "service_disabled" })
            || message.contains("has not been used") || message.contains("is disabled"):
            return .apiDisabled
        default:
            return .http(status)
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    private struct FileList: Decodable {
        struct File: Decodable {
            struct Owner: Decodable { let displayName: String? }
            let id: String
            let name: String?
            let modifiedTime: String?
            let ownedByMe: Bool?
            let owners: [Owner]?
        }
        let nextPageToken: String?
        let files: [File]?
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            struct Reason: Decodable { let reason: String? }
            let message: String?
            let errors: [Reason]?
            let details: [Reason]?
        }
        let error: Body
    }
}
