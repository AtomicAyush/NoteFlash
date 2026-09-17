import Foundation

nonisolated enum AppConfig {
    /// iOS OAuth client ID from Google Cloud Console, e.g.
    /// "1234567890-abc123.apps.googleusercontent.com". See README.md → "Google Docs setup".
    /// Leave empty to only support Google Docs shared as "Anyone with the link".
    static let googleClientID = "437168323267-gnjetmgmkqjc12mujvi8qmc51ns6e48m.apps.googleusercontent.com"

    /// Claude model used when "Claude" is the selected AI engine in Settings.
    static let claudeModel = "claude-opus-5"

    /// On iOS 27, send notes too long for one on-device request to Apple's larger
    /// Private Cloud Compute model. Requires the Private Cloud Compute managed entitlement
    /// from Apple (see README); leave off until your App ID has it.
    static let usePrivateCloudCompute = false

    /// Must match BGTaskSchedulerPermittedIdentifiers in NoteFlash-Info.plist.
    static let backgroundRefreshTaskID = "com.ayushkansal.NoteFlash.docsync"

    /// How often linked Google Drive files are checked while the app is open.
    static let foregroundSyncInterval: Duration = .seconds(120)
    /// Shared-by-link Slides, PDFs, and PowerPoint files are downloaded in full to check them, so
    /// they're checked less often unless the user taps Check Now.
    static let publicFileSyncInterval: TimeInterval = 15 * 60

    /// Earliest time iOS may wake the app to check linked Google Docs in the background.
    static let backgroundRefreshInterval: TimeInterval = 15 * 60
}
