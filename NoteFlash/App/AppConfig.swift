import Foundation

nonisolated enum AppConfig {
    /// iOS OAuth client ID from Google Cloud Console, e.g.
    /// "1234567890-abc123.apps.googleusercontent.com". See README.md → "Google Docs setup".
    /// Leave empty to only support Google Docs shared as "Anyone with the link".
    static let googleClientID = ""

    /// Claude model used when "Claude" is the selected AI engine in Settings.
    static let claudeModel = "claude-opus-5"

    /// On iOS 27, send notes too long for one on-device request to Apple's larger
    /// Private Cloud Compute model. Requires the Private Cloud Compute managed entitlement
    /// from Apple (see README); leave off until your App ID has it.
    static let usePrivateCloudCompute = false

    /// Must match BGTaskSchedulerPermittedIdentifiers in NoteFlash-Info.plist.
    static let backgroundRefreshTaskID = "com.ayushkansal.NoteFlash.docsync"

    /// How often linked Google Docs are checked while the app is open.
    static let foregroundSyncInterval: Duration = .seconds(120)

    /// Earliest time iOS may wake the app to check linked Google Docs in the background.
    static let backgroundRefreshInterval: TimeInterval = 15 * 60
}
