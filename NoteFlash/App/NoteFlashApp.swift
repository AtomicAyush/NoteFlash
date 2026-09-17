import SwiftUI
import SwiftData

@main
struct NoteFlashApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var googleAuth: GoogleAuth
    @State private var syncService: DocSyncService
    @State private var processing: ProcessingCenter
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
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
        let auth = GoogleAuth()
        let sync = DocSyncService(container: container, googleAuth: auth)
        self.container = container
        _googleAuth = State(initialValue: auth)
        _syncService = State(initialValue: sync)
        _processing = State(initialValue: ProcessingCenter(container: container, sync: sync))
    }

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environment(googleAuth)
                .environment(syncService)
                .environment(processing)
        }
        .modelContainer(container)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                processing.appDidBecomeActive()
                syncService.startForegroundPolling()
            case .background:
                syncService.stopForegroundPolling()
                DocSyncService.scheduleBackgroundRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppConfig.backgroundRefreshTaskID)) { [syncService] in
            await syncService.handleBackgroundRefresh()
        }
    }
}
