import Foundation

nonisolated enum DriveMimeType {
    static let document = "application/vnd.google-apps.document"
    static let presentation = "application/vnd.google-apps.presentation"
    static let pdf = "application/pdf"
    static let powerPoint = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    static let folder = "application/vnd.google-apps.folder"
    static let plainText = "text/plain"

    /// Files NoteFlash can make decks from.
    static let readable = [document, presentation, pdf, powerPoint]
}

/// The kinds of Drive files NoteFlash can read.
nonisolated enum DriveFileKind: String, Sendable, Hashable {
    case document
    case presentation
    case pdf
    case powerPoint

    init?(mimeType: String) {
        switch mimeType {
        case DriveMimeType.document: self = .document
        case DriveMimeType.presentation: self = .presentation
        case DriveMimeType.pdf: self = .pdf
        case DriveMimeType.powerPoint: self = .powerPoint
        default: return nil
        }
    }

    var mimeType: String {
        switch self {
        case .document: DriveMimeType.document
        case .presentation: DriveMimeType.presentation
        case .pdf: DriveMimeType.pdf
        case .powerPoint: DriveMimeType.powerPoint
        }
    }

    var label: String {
        switch self {
        case .document: "Google Doc"
        case .presentation: "Google Slides"
        case .pdf: "PDF"
        case .powerPoint: "PowerPoint"
        }
    }

    var systemImage: String {
        switch self {
        case .document: "doc.text.fill"
        case .presentation: "rectangle.on.rectangle.angled.fill"
        case .pdf: "doc.richtext.fill"
        case .powerPoint: "rectangle.on.rectangle.fill"
        }
    }

    /// The app a link opens in.
    var openLabel: String {
        switch self {
        case .document: "Open in Google Docs"
        case .presentation: "Open in Google Slides"
        case .pdf, .powerPoint: "Open in Google Drive"
        }
    }

    func openURL(for id: String) -> URL? {
        switch self {
        case .document: URL(string: "https://docs.google.com/document/d/\(id)/edit")
        case .presentation: URL(string: "https://docs.google.com/presentation/d/\(id)/edit")
        case .pdf, .powerPoint: URL(string: "https://drive.google.com/file/d/\(id)/view")
        }
    }

    var sourceKind: SourceKind {
        switch self {
        case .document: .googleDoc
        case .presentation: .googleSlides
        case .pdf: .drivePDF
        case .powerPoint: .drivePowerPoint
        }
    }
}

/// A Drive file, folder, or other item from the user's Drive.
nonisolated struct DriveItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    var modifiedTime: Date?
    var modifiedByMeTime: Date?
    var viewedByMeTime: Date?
    var sharedWithMeTime: Date?
    /// Bytes the file counts against the owner's storage.
    var size: Int64?
    var ownedByMe = false
    var ownerName: String?
    var lastModifierName: String?
    var lastModifiedByMe = false
    var parentID: String?
    var starred = false
    var shared = false
    var thumbnailLink: String?

    var isFolder: Bool { mimeType == DriveMimeType.folder }
    var kind: DriveFileKind? { DriveFileKind(mimeType: mimeType) }
    var openURL: URL? { (kind ?? .document).openURL(for: id) }
    var reference: DriveFileReference { DriveFileReference(id: id, kind: kind, name: name) }
}

/// Metadata used to read a file and to tell whether it changed.
nonisolated struct DriveFileMetadata: Sendable {
    let id: String
    let name: String
    let mimeType: String
    let version: String?
    let size: Int?
    let canDownload: Bool
}

nonisolated struct DrivePage: Sendable {
    let items: [DriveItem]
    let nextPageToken: String?
}

/// The folders and first page of docs at one Drive location.
nonisolated struct DriveListing: Sendable {
    let folders: [DriveItem]
    let docs: DrivePage
}

/// Where a Drive list comes from.
nonisolated enum DriveLocation: Hashable, Sendable {
    /// A folder; "root" is My Drive.
    case folder(id: String)
    case sharedWithMe
    case starred
    case recent
}

/// Sort orders offered by Google Drive.
nonisolated enum DriveSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case shared
    case modified
    case modifiedByMe
    case opened
    case storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .shared: "Date shared"
        case .modified: "Last modified"
        case .modifiedByMe: "Last modified by me"
        case .opened: "Last opened by me"
        case .storage: "Storage used"
        }
    }

    /// The sorts Drive offers in each place. "Date shared" only applies to Shared with me.
    static func options(for location: DriveLocation?) -> [DriveSort] {
        location == .sharedWithMe
            ? [.name, .shared, .modified, .modifiedByMe, .opened, .storage]
            : [.name, .modified, .modifiedByMe, .opened, .storage]
    }

    /// This sort, or Drive's default where it isn't offered.
    func available(in location: DriveLocation?) -> DriveSort {
        Self.options(for: location).contains(self) ? self : .modified
    }

    var ascendingByDefault: Bool { self == .name }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name: ascending ? "A to Z" : "Z to A"
        case .storage: ascending ? "Smallest first" : "Largest first"
        default: ascending ? "Oldest first" : "Newest first"
        }
    }

    func orderBy(ascending: Bool) -> String {
        let key = switch self {
        case .name: "name_natural"
        case .shared: "sharedWithMeTime"
        case .modified: "modifiedTime"
        case .modifiedByMe: "modifiedByMeTime"
        case .opened: "viewedByMeTime"
        case .storage: "quotaBytesUsed"
        }
        return ascending ? key : "\(key) desc"
    }

    func date(of item: DriveItem) -> Date? {
        switch self {
        case .name, .modified, .storage: item.modifiedTime
        case .shared: item.sharedWithMeTime
        case .modifiedByMe: item.modifiedByMeTime
        case .opened: item.viewedByMeTime
        }
    }

    /// Sorts in memory, e.g. search results (Drive can't order full-text searches).
    /// Items without the date (or size) sort last either way.
    func sorted(_ items: [DriveItem], ascending: Bool) -> [DriveItem] {
        items.sorted { a, b in
            switch self {
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .storage:
                return Self.compare(a.size, b.size, ascending: ascending) ?? Self.byName(a, b)
            default:
                return Self.compare(date(of: a), date(of: b), ascending: ascending) ?? Self.byName(a, b)
            }
        }
    }

    /// Orders two optional values, with missing ones last; nil when they're equal.
    private static func compare<T: Comparable>(_ a: T?, _ b: T?, ascending: Bool) -> Bool? {
        switch (a, b) {
        case let (a?, b?) where a != b: ascending ? a < b : a > b
        case (_?, nil): true
        case (nil, _?): false
        default: nil
        }
    }

    private static func byName(_ a: DriveItem, _ b: DriveItem) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Drive search queries (https://developers.google.com/workspace/drive/api/guides/search-files).
nonisolated enum DriveQuery {
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func items(in location: DriveLocation, mimeTypes: [String]) -> String {
        let scope = switch location {
        case .folder(let id): "'\(escape(id))' in parents"
        case .sharedWithMe: "sharedWithMe = true"
        case .starred: "starred = true"
        case .recent: "viewedByMeTime > '1970-01-01T00:00:00'"
        }
        return "\(scope) and \(anyOf(mimeTypes)) and trashed = false"
    }

    /// Readable files and folders whose name or text contains `term`.
    static func search(_ term: String) -> String {
        let value = escape(term.trimmingCharacters(in: .whitespacesAndNewlines))
        return "(name contains '\(value)' or fullText contains '\(value)')"
            + " and \(anyOf(DriveMimeType.readable + [DriveMimeType.folder]))"
            + " and trashed = false"
    }

    private static func anyOf(_ mimeTypes: [String]) -> String {
        let clauses = mimeTypes.map { "mimeType = '\(escape($0))'" }
        return clauses.count == 1 ? clauses[0] : "(\(clauses.joined(separator: " or ")))"
    }
}

/// Reads Drive metadata for the doc picker (read-only).
nonisolated enum GoogleDriveClient {
    enum DriveError: LocalizedError, Equatable {
        case unauthorized
        case missingPermission
        case apiDisabled
        case notFound
        case exportTooLarge
        case notDownloadable
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Google sign-in expired. Sign in again in Settings."
            case .missingPermission:
                "NoteFlash doesn't have permission to read your Google Drive files yet. Tap Allow Access in Settings → Google Account."
            case .apiDisabled:
                "The Google Drive API isn't turned on for NoteFlash's Google Cloud project. Enable it under APIs & Services → Library → Google Drive API."
            case .notFound:
                "That item isn't available in Google Drive."
            case .exportTooLarge:
                "This file is too large for Google Drive to convert."
            case .notDownloadable:
                "The owner of this file has turned off downloading, so NoteFlash can't read it."
            case .http(let status):
                "Google Drive returned an error (\(status))."
            }
        }
    }

    static let fileFields = "id,name,mimeType,modifiedTime,modifiedByMeTime,viewedByMeTime,sharedWithMeTime,quotaBytesUsed,ownedByMe,"
        + "owners(displayName),lastModifyingUser(displayName,me),parents,starred,shared,thumbnailLink"

    @concurrent
    static func listFiles(
        accessToken: String,
        query: String,
        orderBy: String?,
        pageSize: Int,
        pageToken: String?
    ) async throws -> DrivePage {
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "fields", value: "nextPageToken,files(\(fileFields))"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        if let orderBy { items.append(URLQueryItem(name: "orderBy", value: orderBy)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }

        let data = try await get(path: "files", queryItems: items, accessToken: accessToken)
        let list = try JSONDecoder().decode(FileList.self, from: data)
        return DrivePage(items: (list.files ?? []).map(\.item), nextPageToken: list.nextPageToken)
    }

    /// Every page of a query, up to `limit` items (used for folders, which are usually few).
    @concurrent
    static func allFiles(accessToken: String, query: String, orderBy: String?, limit: Int = 1_000) async throws -> [DriveItem] {
        var results: [DriveItem] = []
        var pageToken: String?
        repeat {
            let page = try await listFiles(
                accessToken: accessToken, query: query, orderBy: orderBy, pageSize: 100, pageToken: pageToken
            )
            results += page.items
            pageToken = page.nextPageToken
        } while pageToken != nil && results.count < limit
        return results
    }

    @concurrent
    static func fileName(accessToken: String, id: String) async throws -> String {
        let data = try await get(
            path: "files/\(id)",
            queryItems: [
                URLQueryItem(name: "fields", value: "name"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ],
            accessToken: accessToken
        )
        return try JSONDecoder().decode(FileName.self, from: data).name
    }

    @concurrent
    static func metadata(accessToken: String, id: String) async throws -> DriveFileMetadata {
        let data = try await get(
            path: "files/\(id)",
            queryItems: [
                URLQueryItem(name: "fields", value: "id,name,mimeType,version,size,capabilities/canDownload"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ],
            accessToken: accessToken
        )
        let file = try JSONDecoder().decode(MetadataResponse.self, from: data)
        return DriveFileMetadata(
            id: file.id,
            name: file.name ?? "Untitled",
            mimeType: file.mimeType ?? "",
            version: file.version,
            size: file.size.flatMap(Int.init),
            canDownload: file.capabilities?.canDownload ?? true
        )
    }

    /// A file's comments and their replies, leaving out deleted ones. Needs the drive.readonly scope.
    @concurrent
    static func comments(accessToken: String, id: String) async throws -> [DriveComment] {
        var comments: [DriveComment] = []
        var pageToken: String?
        var pages = 0
        repeat {
            var items = [
                URLQueryItem(name: "fields", value: "nextPageToken,comments(content,quotedFileContent/value,deleted,modifiedTime,replies(content,deleted))"),
                URLQueryItem(name: "pageSize", value: "100"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await get(path: "files/\(id)/comments", queryItems: items, accessToken: accessToken)
            let page = try JSONDecoder().decode(CommentList.self, from: data)
            comments += (page.comments ?? []).filter { $0.deleted != true }.map { comment in
                // Google returns this text with HTML escapes still in it.
                DriveComment(
                    quote: comment.quotedFileContent?.value.map(HTMLText.decodingEntities),
                    content: HTMLText.decodingEntities(comment.content ?? ""),
                    replies: (comment.replies ?? []).filter { $0.deleted != true }
                        .compactMap(\.content).map(HTMLText.decodingEntities),
                    modified: parseDate(comment.modifiedTime)
                )
            }
            pageToken = page.nextPageToken
            pages += 1
        } while pageToken != nil && pages < 10
        return comments
    }

    /// A file's bytes (for PDFs and PowerPoint files). Needs the drive.readonly scope.
    @concurrent
    static func download(accessToken: String, id: String) async throws -> Data {
        try await get(
            path: "files/\(id)",
            queryItems: [
                URLQueryItem(name: "alt", value: "media"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
            ],
            accessToken: accessToken
        )
    }

    /// A Google Workspace file converted to `mimeType` (Drive caps exports at 10 MB).
    @concurrent
    static func export(accessToken: String, id: String, mimeType: String) async throws -> Data {
        try await get(
            path: "files/\(id)/export",
            queryItems: [URLQueryItem(name: "mimeType", value: mimeType)],
            accessToken: accessToken
        )
    }

    @concurrent
    static func thumbnailData(accessToken: String, link: String) async throws -> Data {
        guard let url = URL(string: link) else { throw DriveError.notFound }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DriveError.http(status) }
        return data
    }

    private static func get(path: String, queryItems: [URLQueryItem], accessToken: String) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/\(path)")!
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw error(status: status, body: data) }
        return data
    }

    static func error(status: Int, body: Data) -> DriveError {
        let details = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        let reasons = ((details?.errors ?? []).compactMap(\.reason) + (details?.details ?? []).compactMap(\.reason))
            .map { $0.lowercased() }
        let message = details?.message?.lowercased() ?? ""
        switch status {
        case 401:
            return .unauthorized
        case 403 where reasons.contains("exportsizelimitexceeded"):
            return .exportTooLarge
        case 403 where reasons.contains(where: { $0 == "cannotdownloadfile" || $0 == "filenotdownloadable" || $0 == "cannotexportfile" }):
            return .notDownloadable
        case 403 where reasons.contains(where: { $0.contains("insufficient") })
            || message.contains("insufficient"):
            return .missingPermission
        case 403 where reasons.contains(where: { $0 == "accessnotconfigured" || $0 == "service_disabled" })
            || message.contains("has not been used") || message.contains("is disabled"):
            return .apiDisabled
        case 404:
            return .notFound
        default:
            return .http(status)
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    private struct FileList: Decodable {
        let nextPageToken: String?
        let files: [File]?
    }

    private struct File: Decodable {
        struct Person: Decodable {
            let displayName: String?
            let me: Bool?
        }

        let id: String
        let name: String?
        let mimeType: String?
        let modifiedTime: String?
        let modifiedByMeTime: String?
        let viewedByMeTime: String?
        let sharedWithMeTime: String?
        let quotaBytesUsed: String?
        let ownedByMe: Bool?
        let owners: [Person]?
        let lastModifyingUser: Person?
        let parents: [String]?
        let starred: Bool?
        let shared: Bool?
        let thumbnailLink: String?

        var item: DriveItem {
            DriveItem(
                id: id,
                name: name?.isEmpty == false ? name! : "Untitled document",
                mimeType: mimeType ?? DriveMimeType.document,
                modifiedTime: GoogleDriveClient.parseDate(modifiedTime),
                modifiedByMeTime: GoogleDriveClient.parseDate(modifiedByMeTime),
                viewedByMeTime: GoogleDriveClient.parseDate(viewedByMeTime),
                sharedWithMeTime: GoogleDriveClient.parseDate(sharedWithMeTime),
                size: quotaBytesUsed.flatMap { Int64($0) },
                ownedByMe: ownedByMe ?? false,
                ownerName: owners?.first?.displayName,
                lastModifierName: lastModifyingUser?.displayName,
                lastModifiedByMe: lastModifyingUser?.me ?? false,
                parentID: parents?.first,
                starred: starred ?? false,
                shared: shared ?? false,
                thumbnailLink: thumbnailLink
            )
        }
    }

    private struct FileName: Decodable {
        let name: String
    }

    private struct CommentList: Decodable {
        struct Comment: Decodable {
            struct Quote: Decodable { let value: String? }
            struct Reply: Decodable {
                let content: String?
                let deleted: Bool?
            }
            let content: String?
            let quotedFileContent: Quote?
            let deleted: Bool?
            let modifiedTime: String?
            let replies: [Reply]?
        }
        let nextPageToken: String?
        let comments: [Comment]?
    }

    private struct MetadataResponse: Decodable {
        struct Capabilities: Decodable { let canDownload: Bool? }
        let id: String
        let name: String?
        let mimeType: String?
        let version: String?
        let size: String?
        let capabilities: Capabilities?
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
