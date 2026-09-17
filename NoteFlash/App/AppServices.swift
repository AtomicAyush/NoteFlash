import Foundation
import SwiftData

/// The app's database and services, made once and shared by the interface and by background
/// launches. iOS can start NoteFlash in the background to finish making cards, when there's no
/// window and no one looking, so this can't live in the scene.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let container: ModelContainer
    let googleAuth: GoogleAuth
    let sync: DocSyncService
    let processing: ProcessingCenter

    private init() {
        do {
            #if DEBUG
            let inMemory = UITestSupport.isEnabled
            #else
            let inMemory = false
            #endif
            container = try ModelContainer(
                for: Deck.self, Flashcard.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
            )
        } catch {
            fatalError("Could not open the NoteFlash database: \(error)")
        }
        #if DEBUG
        if UITestSupport.isEnabled { UITestSupport.seed(container.mainContext) }
        #endif
        googleAuth = GoogleAuth()
        sync = DocSyncService(container: container, googleAuth: googleAuth)
        processing = ProcessingCenter(container: container, sync: sync)
        // At launch, not when a window appears: iOS also starts the app with no window at all,
        // and a system alert can keep the first one from becoming active.
        Task { [processing] in processing.restoreSavedJobs() }
    }
}
