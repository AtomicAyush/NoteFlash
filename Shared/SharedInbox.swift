import Foundation

/// Notes shared to NoteFlash from other apps (GoodNotes, Notes, Files, …), waiting for the app
/// to make flashcards from them. The share extension writes items into the App Group
/// container, and the app picks them up the next time it's active.
///
/// Each item is a folder holding the shared files and an `item.json` manifest. The manifest
/// is written last, so the app never sees a half-written item.
nonisolated enum SharedInbox {
    static let appGroup = "group.com.ayushkansal.NoteFlash"

    struct Item: Codable, Identifiable, Sendable {
        enum Content: Codable, Sendable {
            /// Typed or copied text.
            case text(String)
            /// A PDF, PowerPoint, image, or text file, stored in the item's folder.
            case files([String])
            /// A Google Docs, Slides, or Drive link.
            case link(String)
        }

        let id: UUID
        var createdAt: Date
        var title: String
        var content: Content
        /// A `CardDensity` raw value.
        var density: String
    }

    enum InboxError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "NoteFlash couldn't save the shared notes. Open NoteFlash once, then try sharing again."
        }
    }

    static var directory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "SharedInbox", directoryHint: .isDirectory)
    }

    // MARK: Writing (share extension)

    /// A shared item being prepared: files are copied in before the user confirms.
    struct Draft: Sendable {
        let id: UUID
        let folder: URL

        /// Copies a file into the draft and returns the name it's stored under.
        func addFile(at source: URL, preferredName: String) throws -> String {
            let name = uniqueName(for: preferredName)
            try FileManager.default.copyItem(at: source, to: folder.appending(path: name))
            return name
        }

        func addFile(data: Data, preferredName: String) throws -> String {
            let name = uniqueName(for: preferredName)
            try data.write(to: folder.appending(path: name), options: .atomic)
            return name
        }

        func fileURL(_ name: String) -> URL {
            folder.appending(path: name)
        }

        /// Saves the manifest, which makes the item visible to the app.
        func commit(title: String, content: Item.Content, density: String) throws {
            let item = Item(id: id, createdAt: .now, title: title, content: content, density: density)
            let data = try JSONEncoder().encode(item)
            try data.write(to: folder.appending(path: SharedInbox.manifestName), options: .atomic)
        }

        func discard() {
            try? FileManager.default.removeItem(at: folder)
        }

        private func uniqueName(for preferred: String) -> String {
            let cleaned = preferred
                .replacingOccurrences(of: "/", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = cleaned.isEmpty ? "Shared file" : cleaned
            var name = base
            var counter = 2
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            while FileManager.default.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) {
                name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                counter += 1
            }
            return name
        }
    }

    static func makeDraft() throws -> Draft {
        guard let directory else { throw InboxError.unavailable }
        let id = UUID()
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Draft(id: id, folder: folder)
    }

    // MARK: Reading (app)

    /// Items the user confirmed, oldest first.
    static func pendingItems() -> [Item] {
        guard let directory,
              let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        return folders
            .compactMap { folder in
                (try? Data(contentsOf: folder.appending(path: manifestName)))
                    .flatMap { try? decoder.decode(Item.self, from: $0) }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func fileURL(_ name: String, in item: Item) -> URL? {
        directory?.appending(path: item.id.uuidString).appending(path: name)
    }

    static func remove(_ item: Item) {
        guard let folder = directory?.appending(path: item.id.uuidString) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes drafts that were never confirmed (the share sheet was closed early).
    static func removeAbandonedDrafts(olderThan age: TimeInterval = 3_600) {
        guard let directory,
              let folders = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: [.creationDateKey]
              )
        else { return }
        for folder in folders {
            let hasManifest = FileManager.default.fileExists(atPath: folder.appending(path: manifestName).path(percentEncoded: false))
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if !hasManifest, Date.now.timeIntervalSince(created) > age {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private static let manifestName = "item.json"
}
