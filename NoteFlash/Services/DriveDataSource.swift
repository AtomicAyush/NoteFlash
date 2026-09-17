import Foundation
import UIKit

/// Where the doc picker gets its Drive data: the Drive and Docs APIs, or sample data in UI tests.
protocol DriveDataSource {
    func requiresSignIn(_ auth: GoogleAuth) -> Bool
    func requiresListPermission(_ auth: GoogleAuth) -> Bool
    func listing(in location: DriveLocation, sort: DriveSort, ascending: Bool, auth: GoogleAuth) async throws -> DriveListing
    func moreDocs(in location: DriveLocation, sort: DriveSort, ascending: Bool, pageToken: String, auth: GoogleAuth) async throws -> DrivePage
    func search(_ term: String, pageToken: String?, auth: GoogleAuth) async throws -> DrivePage
    func folderName(id: String, auth: GoogleAuth) async throws -> String
    func document(id: String, auth: GoogleAuth) async throws -> GoogleDocContent
    func thumbnail(for item: DriveItem, auth: GoogleAuth) async -> UIImage?
}

enum DriveDataSources {
    static var current: any DriveDataSource {
        #if DEBUG
        if UITestSupport.isEnabled { return SampleDriveDataSource() }
        #endif
        return LiveDriveDataSource()
    }
}

struct LiveDriveDataSource: DriveDataSource {
    private static let thumbnails = NSCache<NSString, UIImage>()

    func requiresSignIn(_ auth: GoogleAuth) -> Bool { !auth.isSignedIn }

    func requiresListPermission(_ auth: GoogleAuth) -> Bool { !auth.canListDocs }

    func listing(in location: DriveLocation, sort: DriveSort, ascending: Bool, auth: GoogleAuth) async throws -> DriveListing {
        let orderBy = Self.orderBy(for: location, sort: sort, ascending: ascending)
        return try await authorized(auth) { token in
            async let folders = Self.folders(in: location, orderBy: orderBy, token: token)
            async let docs = GoogleDriveClient.listFiles(
                accessToken: token,
                query: DriveQuery.items(in: location, mimeType: DriveMimeType.document),
                orderBy: orderBy,
                pageSize: 50,
                pageToken: nil
            )
            return try await DriveListing(folders: folders, docs: docs)
        }
    }

    func moreDocs(in location: DriveLocation, sort: DriveSort, ascending: Bool, pageToken: String, auth: GoogleAuth) async throws -> DrivePage {
        let orderBy = Self.orderBy(for: location, sort: sort, ascending: ascending)
        return try await authorized(auth) { token in
            try await GoogleDriveClient.listFiles(
                accessToken: token,
                query: DriveQuery.items(in: location, mimeType: DriveMimeType.document),
                orderBy: orderBy,
                pageSize: 50,
                pageToken: pageToken
            )
        }
    }

    func search(_ term: String, pageToken: String?, auth: GoogleAuth) async throws -> DrivePage {
        try await authorized(auth) { token in
            // Drive can't order full-text searches; results are sorted on the device.
            try await GoogleDriveClient.listFiles(
                accessToken: token, query: DriveQuery.search(term), orderBy: nil, pageSize: 50, pageToken: pageToken
            )
        }
    }

    func folderName(id: String, auth: GoogleAuth) async throws -> String {
        try await authorized(auth) { token in
            try await GoogleDriveClient.fileName(accessToken: token, id: id)
        }
    }

    func document(id: String, auth: GoogleAuth) async throws -> GoogleDocContent {
        try await authorized(auth) { token in
            try await GoogleDocsClient.fetchViaAPI(documentID: id, accessToken: token)
        }
    }

    func thumbnail(for item: DriveItem, auth: GoogleAuth) async -> UIImage? {
        guard let link = item.thumbnailLink else { return nil }
        let key = "\(item.id)-\(item.modifiedTime?.timeIntervalSince1970 ?? 0)" as NSString
        if let cached = Self.thumbnails.object(forKey: key) { return cached }
        guard let token = try? await auth.validAccessToken(),
              let data = try? await GoogleDriveClient.thumbnailData(accessToken: token, link: link),
              let image = UIImage(data: data) else { return nil }
        Self.thumbnails.setObject(image, forKey: key)
        return image
    }

    // MARK: Helpers

    private static func orderBy(for location: DriveLocation, sort: DriveSort, ascending: Bool) -> String {
        // Recent is always most recently opened first, as in Drive.
        location == .recent ? DriveSort.opened.orderBy(ascending: false) : sort.orderBy(ascending: ascending)
    }

    nonisolated private static func folders(in location: DriveLocation, orderBy: String, token: String) async throws -> [DriveItem] {
        guard location != .recent else { return [] }
        return try await GoogleDriveClient.allFiles(
            accessToken: token,
            query: DriveQuery.items(in: location, mimeType: DriveMimeType.folder),
            orderBy: orderBy
        )
    }

    /// Runs a Google API call with a fresh token, retrying once if the token was rejected.
    private func authorized<T>(_ auth: GoogleAuth, _ operation: (String) async throws -> T) async throws -> T {
        do {
            return try await operation(try await auth.validAccessToken())
        } catch let error where Self.isUnauthorized(error) {
            auth.invalidateAccessToken()
            return try await operation(try await auth.validAccessToken())
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if let error = error as? GoogleDriveClient.DriveError { return error == .unauthorized }
        if case .unauthorized? = error as? GoogleDocsClient.DocsError { return true }
        return false
    }
}
