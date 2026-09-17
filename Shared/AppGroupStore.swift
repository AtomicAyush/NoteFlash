import Foundation

/// Folders NoteFlash and its share extension both use, inside the App Group container.
nonisolated enum AppGroupStore {
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedInbox.appGroup)
            // Without the App Group (a misconfigured build, or a test), keep work in the app's
            // own storage rather than dropping it.
            ?? URL.temporaryDirectory.appending(path: "NoteFlashWork", directoryHint: .isDirectory)
    }

    /// A folder in the App Group container, created if it isn't there yet.
    static func folder(named name: String) -> URL? {
        guard let container else { return nil }
        let folder = container.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Background work NoteFlash asks iOS for. The share extension asks for it too, so iOS can start
/// the app in the background after notes are shared instead of waiting for the user to open it.
nonisolated enum BackgroundWork {
    /// Must match BGTaskSchedulerPermittedIdentifiers in NoteFlash-Info.plist.
    static let catchUpTaskID = "com.ayushkansal.NoteFlash.catchup"
}
