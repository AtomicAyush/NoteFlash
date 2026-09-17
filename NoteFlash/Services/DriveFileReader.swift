import CryptoKit
import Foundation

/// A Drive file to read. The kind is unknown for some pasted links until the file is opened.
nonisolated struct DriveFileReference: Hashable, Sendable {
    let id: String
    var kind: DriveFileKind?
    var name: String?

    /// Reads a Google Docs, Slides, or Drive link (or a bare file ID).
    init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = trimmed.firstMatch(of: #/\/(document|presentation)\/(?:u\/\d+\/)?d\/([A-Za-z0-9_-]{10,})/#) {
            id = String(match.2)
            kind = match.1 == "document" ? .document : .presentation
        } else if let match = trimmed.firstMatch(of: #/\/file\/(?:u\/\d+\/)?d\/([A-Za-z0-9_-]{10,})/#) {
            id = String(match.1)
        } else if trimmed.contains("google.com"),
                  let match = trimmed.firstMatch(of: #/[?&]id=([A-Za-z0-9_-]{10,})/#) {
            id = String(match.1)
        } else if trimmed.wholeMatch(of: #/[A-Za-z0-9_-]{25,}/#) != nil {
            id = trimmed
        } else {
            return nil
        }
    }

    init(id: String, kind: DriveFileKind?, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

/// A Drive file's notes, ready for the AI engine.
nonisolated struct DriveFileContent: Sendable {
    let title: String?
    let text: String
    let kind: DriveFileKind
    /// The original PDF, kept so it can be viewed and sent to Claude.
    var pdfData: Data?
    /// Pages in a PDF or slides in a presentation.
    var pageCount: Int?
    /// Identifies this version of the file, to skip unchanged files when syncing.
    var version: String?
}

/// Reads Google Docs, Google Slides, PDFs, and PowerPoint files from Drive: through the Google
/// APIs when signed in, or through public links for files shared as "Anyone with the link".
final class DriveFileReader {
    nonisolated enum ReadError: LocalizedError, Equatable {
        case invalidLink
        case needsFileAccess
        case notShared
        case unsupported(String)
        case tooLarge
        case empty

        var errorDescription: String? {
            switch self {
            case .invalidLink:
                "That doesn't look like a Google Docs, Slides, or Drive link."
            case .needsFileAccess:
                "NoteFlash needs permission to read your Drive files. In Settings → Google Account, tap Allow Access."
            case .notShared:
                AppConfig.googleClientID.isEmpty
                    ? "This file is private. In Google Drive, tap Share, set General access to \"Anyone with the link\", and paste the link again."
                    : "This file is private. Sign in with Google in Settings, or set its General access to \"Anyone with the link\"."
            case .unsupported(let type):
                "NoteFlash can read Google Docs, Google Slides, PDFs, and PowerPoint (.pptx) files, but this file is \(type)."
            case .tooLarge:
                "This file is too large to read. Try splitting it into smaller files."
            case .empty:
                "This file doesn't have any text to make cards from."
            }
        }
    }

    /// Largest PDF or PowerPoint file NoteFlash downloads.
    nonisolated static let maxDownloadBytes = 150 * 1024 * 1024

    private let auth: GoogleAuth

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    /// Reads a file. `onPhase` reports slow steps, like reading PDF pages.
    func read(_ reference: DriveFileReference, onPhase: @escaping @Sendable (String) -> Void = { _ in }) async throws -> DriveFileContent {
        guard let content = try await read(reference, knownVersion: nil, onPhase: onPhase) else {
            throw ReadError.empty
        }
        return content
    }

    /// Reads a file, or returns nil when it's unchanged since `knownVersion`.
    func readIfChanged(_ reference: DriveFileReference, knownVersion: String?) async throws -> DriveFileContent? {
        try await read(reference, knownVersion: knownVersion, onPhase: { _ in })
    }

    private func read(
        _ reference: DriveFileReference,
        knownVersion: String?,
        onPhase: @escaping @Sendable (String) -> Void
    ) async throws -> DriveFileContent? {
        guard auth.isSignedIn else {
            return try await Self.readPublic(reference, knownVersion: knownVersion, onPhase: onPhase)
        }
        do {
            return try await readPrivate(reference, knownVersion: knownVersion, onPhase: onPhase)
        } catch let error where Self.mayBePublic(error) {
            // This account can't open the file, but it may still be shared by link.
            if let content = try? await Self.readPublic(reference, knownVersion: knownVersion, onPhase: onPhase) {
                return content
            }
            if (error as? GoogleDriveClient.DriveError) == .missingPermission {
                throw ReadError.needsFileAccess
            }
            throw error
        }
    }

    // MARK: Signed in

    private func readPrivate(
        _ reference: DriveFileReference,
        knownVersion: String?,
        onPhase: @escaping @Sendable (String) -> Void
    ) async throws -> DriveFileContent? {
        // Metadata gives the file's type, name, and version. Older sign-ins may lack the
        // permission for it; Docs can still be read without it.
        var metadata: DriveFileMetadata?
        do {
            metadata = try await authorized { try await GoogleDriveClient.metadata(accessToken: $0, id: reference.id) }
        } catch GoogleDriveClient.DriveError.missingPermission where reference.kind == .document || reference.kind == nil {
            metadata = nil
        }

        let kind: DriveFileKind
        if let metadata {
            guard let known = DriveFileKind(mimeType: metadata.mimeType) else {
                throw ReadError.unsupported(Self.describe(mimeType: metadata.mimeType, name: metadata.name))
            }
            kind = known
        } else {
            kind = reference.kind ?? .document
        }

        let version = metadata?.version.map { "v:\($0)" }
        if let version, version == knownVersion { return nil }
        let title = metadata?.name ?? reference.name

        switch kind {
        case .document:
            let document = try await authorized {
                try await GoogleDocsClient.fetchViaAPI(documentID: reference.id, accessToken: $0)
            }
            return DriveFileContent(title: document.title ?? title, text: document.text, kind: .document, version: version)

        case .presentation:
            guard auth.canReadDriveFiles else { throw GoogleDriveClient.DriveError.missingPermission }
            do {
                let data = try await authorized {
                    try await GoogleDriveClient.export(accessToken: $0, id: reference.id, mimeType: DriveMimeType.powerPoint)
                }
                let slides = try await Self.extractPowerPoint(data)
                return DriveFileContent(title: title, text: slides.text, kind: .presentation, pageCount: slides.slideCount, version: version)
            } catch GoogleDriveClient.DriveError.exportTooLarge {
                // Image-heavy decks can exceed Drive's export limit; plain text is much smaller.
                let data = try await authorized {
                    try await GoogleDriveClient.export(accessToken: $0, id: reference.id, mimeType: DriveMimeType.plainText)
                }
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{FEFF}", with: "")
                return DriveFileContent(title: title, text: text, kind: .presentation, version: version)
            }

        case .pdf, .powerPoint:
            guard auth.canReadDriveFiles else { throw GoogleDriveClient.DriveError.missingPermission }
            if let metadata {
                guard metadata.canDownload else { throw GoogleDriveClient.DriveError.notDownloadable }
                if let size = metadata.size, size > Self.maxDownloadBytes { throw ReadError.tooLarge }
            }
            onPhase(kind == .pdf ? "Downloading your PDF" : "Downloading your slides")
            let data = try await authorized { try await GoogleDriveClient.download(accessToken: $0, id: reference.id) }
            return try await Self.content(ofFile: data, title: title, version: version, onPhase: onPhase)
        }
    }

    /// Runs a Google API call with a fresh token, retrying once if the token was rejected.
    private func authorized<T>(_ operation: (String) async throws -> T) async throws -> T {
        do {
            return try await operation(try await auth.validAccessToken())
        } catch let error where Self.isUnauthorized(error) {
            auth.invalidateAccessToken()
            return try await operation(try await auth.validAccessToken())
        }
    }

    nonisolated private static func isUnauthorized(_ error: Error) -> Bool {
        if let error = error as? GoogleDriveClient.DriveError { return error == .unauthorized }
        if case .unauthorized? = error as? GoogleDocsClient.DocsError { return true }
        return false
    }

    nonisolated private static func mayBePublic(_ error: Error) -> Bool {
        switch error {
        case let error as GoogleDriveClient.DriveError:
            switch error {
            case .notFound, .missingPermission, .http(403): return true
            default: return false
            }
        case let error as GoogleDocsClient.DocsError:
            switch error {
            case .notShared, .notFound: return true
            default: return false
            }
        default:
            return false
        }
    }

    // MARK: Shared by link

    @concurrent
    private static func readPublic(
        _ reference: DriveFileReference,
        knownVersion: String?,
        onPhase: @escaping @Sendable (String) -> Void
    ) async throws -> DriveFileContent? {
        switch reference.kind {
        case .document:
            let document = try await GoogleDocsClient.fetchPublicExport(documentID: reference.id)
            return DriveFileContent(title: document.title, text: document.text, kind: .document)

        case .presentation:
            let url = URL(string: "https://docs.google.com/presentation/d/\(reference.id)/export/pptx")!
            let download = try await publicDownload(url)
            let version = fingerprint(download.data)
            if version == knownVersion { return nil }
            let slides = try await extractPowerPoint(download.data)
            return DriveFileContent(
                title: download.fileName.map(stripExtension) ?? reference.name, text: slides.text, kind: .presentation,
                pageCount: slides.slideCount, version: version
            )

        case .pdf, .powerPoint, nil:
            let url = URL(string: "https://drive.google.com/uc?export=download&id=\(reference.id)")!
            let download: PublicDownload
            do {
                download = try await publicDownload(url)
            } catch ReadError.notShared where reference.kind == nil {
                // Bare IDs and older links may be Docs, which download differently.
                let document = try await GoogleDocsClient.fetchPublicExport(documentID: reference.id)
                return DriveFileContent(title: document.title, text: document.text, kind: .document)
            }
            let version = fingerprint(download.data)
            if version == knownVersion { return nil }
            return try await content(
                ofFile: download.data, title: download.fileName ?? reference.name, version: version, onPhase: onPhase
            )
        }
    }

    nonisolated private struct PublicDownload {
        let data: Data
        let fileName: String?
    }

    nonisolated private static func publicDownload(_ url: URL) async throws -> PublicDownload {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ReadError.notShared }
        switch http.statusCode {
        case 200:
            break
        case 401, 403, 404:
            throw ReadError.notShared
        default:
            throw GoogleDriveClient.DriveError.http(http.statusCode)
        }
        guard data.count <= maxDownloadBytes else { throw ReadError.tooLarge }

        let isHTML = (http.mimeType ?? "").contains("html")
            || data.prefix(64).range(of: Data("<!DOCTYPE html".utf8)) != nil
            || data.prefix(64).range(of: Data("<html".utf8)) != nil
        guard isHTML else {
            let name = GoogleDocsClient.documentTitle(
                fromContentDisposition: http.value(forHTTPHeaderField: "Content-Disposition")
            )
            return PublicDownload(data: data, fileName: name)
        }
        // Large files show a "can't scan for viruses" page with a confirm link instead.
        let page = String(decoding: data, as: UTF8.self)
        if let uuid = page.firstMatch(of: #/name="uuid" value="([^"]+)"/#)?.1,
           let id = page.firstMatch(of: #/name="id" value="([^"]+)"/#)?.1,
           url.host() != "drive.usercontent.google.com" {
            var confirm = URLComponents(string: "https://drive.usercontent.google.com/download")!
            confirm.queryItems = [
                URLQueryItem(name: "id", value: String(id)),
                URLQueryItem(name: "export", value: "download"),
                URLQueryItem(name: "confirm", value: "t"),
                URLQueryItem(name: "uuid", value: String(uuid)),
            ]
            if let confirmURL = confirm.url {
                return try await publicDownload(confirmURL)
            }
        }
        // Otherwise it's a sign-in page: the file isn't shared by link.
        throw ReadError.notShared
    }

    // MARK: File contents

    @concurrent
    private static func content(
        ofFile data: Data,
        title: String?,
        version: String?,
        onPhase: @escaping @Sendable (String) -> Void
    ) async throws -> DriveFileContent {
        if data.starts(with: Data("%PDF".utf8)) {
            onPhase("Reading your PDF")
            let extracted = await PDFTextExtractor.extract(from: data) { page, total in
                onPhase("Reading page \(page) of \(total)")
            }
            guard let extracted else { throw DeckCreator.CreationError.unreadablePDF }
            return DriveFileContent(
                title: title.map(stripExtension), text: extracted.text, kind: .pdf,
                pdfData: data, pageCount: extracted.pageCount, version: version
            )
        }
        if PowerPointTextExtractor.isPresentation(data) {
            let slides = try PowerPointTextExtractor.extract(from: data)
            return DriveFileContent(
                title: title.map(stripExtension), text: slides.text, kind: .powerPoint,
                pageCount: slides.slideCount, version: version
            )
        }
        throw ReadError.unsupported(title.map { "“\($0)”" } ?? "another type of file")
    }

    @concurrent
    private static func extractPowerPoint(_ data: Data) async throws -> PowerPointTextExtractor.Result {
        try PowerPointTextExtractor.extract(from: data)
    }

    nonisolated private static func fingerprint(_ data: Data) -> String {
        "sha:" + SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func stripExtension(_ name: String) -> String {
        for suffix in [".pdf", ".pptx", ".txt"] where name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    nonisolated private static func describe(mimeType: String, name: String) -> String {
        switch mimeType {
        case "application/vnd.google-apps.spreadsheet": "a Google Sheet"
        case "application/vnd.ms-powerpoint": "an older PowerPoint (.ppt) file; save it as .pptx first"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "a Word document; open it in Google Docs and use that instead"
        case let type where type.hasPrefix("image/"): "an image"
        default: "“\(name)”"
        }
    }
}
