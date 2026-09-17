import Foundation

nonisolated enum DriveMimeType {
    static let document = "application/vnd.google-apps.document"
    static let folder = "application/vnd.google-apps.folder"
}

/// A Google Doc or folder from the user's Drive.
nonisolated struct DriveItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    var modifiedTime: Date?
    var modifiedByMeTime: Date?
    var viewedByMeTime: Date?
    var ownedByMe = false
    var ownerName: String?
    var lastModifierName: String?
    var lastModifiedByMe = false
    var parentID: String?
    var starred = false
    var shared = false
    var thumbnailLink: String?

    var isFolder: Bool { mimeType == DriveMimeType.folder }
    var editURL: String { "https://docs.google.com/document/d/\(id)/edit" }
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
    case modified
    case modifiedByMe
    case opened

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .modified: "Last modified"
        case .modifiedByMe: "Last modified by me"
        case .opened: "Last opened by me"
        }
    }

    var ascendingByDefault: Bool { self == .name }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name: ascending ? "A to Z" : "Z to A"
        default: ascending ? "Oldest first" : "Newest first"
        }
    }

    func orderBy(ascending: Bool) -> String {
        let key = switch self {
        case .name: "name_natural"
        case .modified: "modifiedTime"
        case .modifiedByMe: "modifiedByMeTime"
        case .opened: "viewedByMeTime"
        }
        return ascending ? key : "\(key) desc"
    }

    func date(of item: DriveItem) -> Date? {
        switch self {
        case .name, .modified: item.modifiedTime
        case .modifiedByMe: item.modifiedByMeTime
        case .opened: item.viewedByMeTime
        }
    }

    /// Sorts in memory, e.g. search results (Drive can't order full-text searches).
    /// Items without the date sort last either way.
    func sorted(_ items: [DriveItem], ascending: Bool) -> [DriveItem] {
        items.sorted { a, b in
            if self == .name {
                let order = a.name.localizedStandardCompare(b.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            switch (date(of: a), date(of: b)) {
            case let (dateA?, dateB?) where dateA != dateB:
                return ascending ? dateA < dateB : dateA > dateB
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// Drive search queries (https://developers.google.com/workspace/drive/api/guides/search-files).
nonisolated enum DriveQuery {
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func items(in location: DriveLocation, mimeType: String) -> String {
        let scope = switch location {
        case .folder(let id): "'\(escape(id))' in parents"
        case .sharedWithMe: "sharedWithMe = true"
        case .starred: "starred = true"
        case .recent: "viewedByMeTime > '1970-01-01T00:00:00'"
        }
        return "\(scope) and mimeType = '\(mimeType)' and trashed = false"
    }

    /// Docs and folders whose name or text contains `term`.
    static func search(_ term: String) -> String {
        let value = escape(term.trimmingCharacters(in: .whitespacesAndNewlines))
        return "(name contains '\(value)' or fullText contains '\(value)')"
            + " and (mimeType = '\(DriveMimeType.document)' or mimeType = '\(DriveMimeType.folder)')"
            + " and trashed = false"
    }
}

/// Reads Drive metadata for the doc picker (read-only).
nonisolated enum GoogleDriveClient {
    enum DriveError: LocalizedError, Equatable {
        case unauthorized
        case missingPermission
        case apiDisabled
        case notFound
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                "Google sign-in expired. Sign in again in Settings."
            case .missingPermission:
                "NoteFlash doesn't have permission to list your Google Docs yet."
            case .apiDisabled:
                "The Google Drive API isn't turned on for NoteFlash's Google Cloud project. Enable it under APIs & Services → Library → Google Drive API."
            case .notFound:
                "That item isn't available in Google Drive."
            case .http(let status):
                "Google Drive returned an error (\(status))."
            }
        }
    }

    static let fileFields = "id,name,mimeType,modifiedTime,modifiedByMeTime,viewedByMeTime,ownedByMe,"
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
