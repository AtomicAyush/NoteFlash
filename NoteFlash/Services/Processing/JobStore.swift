import Foundation

/// Work the app still owes the user, kept in the App Group so it survives the app being closed,
/// stopped by iOS, or relaunched in the background. Each job has a folder holding its record and
/// any files it needs (a shared PDF, photographed pages); the folder is deleted once the cards
/// are made.
nonisolated enum JobStore {
    /// A job as it can be written down and picked up again later.
    struct Record: Codable, Sendable {
        /// `density` is a `CardDensity` raw value.
        enum Work: Codable, Sendable {
            case newDeckText(title: String, notes: String, density: String)
            case newDeckFile(fileName: String, file: String, title: String?, density: String)
            case newDeckImages(name: String, files: [String], title: String?, density: String)
            case newDeckDrive(id: String, kind: String?, name: String?, autoSync: Bool, density: String)
            case regenerate(deckID: UUID)
            case updateNotes(deckID: UUID, text: String)
        }

        let id: UUID
        var createdAt = Date.now
        var title: String
        var work: Work
        /// Set while the job waits out Apple Intelligence's usage limit.
        var resumeAt: Date?
        /// Stopped so often that it's no longer worth retrying on its own.
        var attempts = 0
        var lastError: String?
    }

    /// Jobs that never finished, oldest first.
    static func records() -> [Record] {
        guard let folder = AppGroupStore.folder(named: folderName),
              let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return items
            .compactMap { item in
                (try? Data(contentsOf: item.appending(path: recordName)))
                    .flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func save(_ record: Record) {
        guard let folder = folder(for: record.id), let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: folder.appending(path: recordName), options: .atomic)
    }

    static func remove(_ id: UUID) {
        guard let folder = AppGroupStore.folder(named: folderName) else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: id.uuidString))
    }

    /// Stores a file the job needs and returns the name to put in its record.
    static func addFile(_ data: Data, named preferred: String, for id: UUID) -> String? {
        guard let folder = folder(for: id) else { return nil }
        let name = uniqueName(for: preferred, in: folder)
        do {
            try data.write(to: folder.appending(path: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    /// Moves a file already in the App Group (one the share extension wrote) into the job.
    static func moveFile(at source: URL, for id: UUID) -> String? {
        guard let folder = folder(for: id) else { return nil }
        let name = uniqueName(for: source.lastPathComponent, in: folder)
        do {
            try FileManager.default.moveItem(at: source, to: folder.appending(path: name))
            return name
        } catch {
            return (try? Data(contentsOf: source)).flatMap { addFile($0, named: source.lastPathComponent, for: id) }
        }
    }

    static func file(_ name: String, for id: UUID) -> Data? {
        guard let folder = AppGroupStore.folder(named: folderName) else { return nil }
        return try? Data(contentsOf: folder.appending(path: id.uuidString).appending(path: name))
    }

    /// Clears out jobs the app gave up on long ago, so their files don't sit there forever.
    static func removeAbandoned(olderThan age: TimeInterval = 30 * 24 * 60 * 60) {
        for record in records() where Date.now.timeIntervalSince(record.createdAt) > age {
            remove(record.id)
        }
    }

    private static let folderName = "PendingJobs"
    private static let recordName = "job.json"

    private static func folder(for id: UUID) -> URL? {
        guard let folder = AppGroupStore.folder(named: folderName) else { return nil }
        let jobFolder = folder.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: jobFolder, withIntermediateDirectories: true)
        return jobFolder
    }

    private static func uniqueName(for preferred: String, in folder: URL) -> String {
        let cleaned = preferred.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "File" : cleaned
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
