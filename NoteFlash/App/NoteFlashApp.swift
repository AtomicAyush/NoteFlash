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
        let services = AppServices.shared
        container = services.container
        _googleAuth = State(initialValue: services.googleAuth)
        _syncService = State(initialValue: services.sync)
        _processing = State(initialValue: services.processing)
    }

    var body: some Scene {
        WindowGroup {
            DeckListView()
                .environment(googleAuth)
                .environment(syncService)
                .environment(processing)
                .onOpenURL { url in
                    AppRouter.shared.receive(url)
                }
                #if DEBUG
                .task {
                    if AppleIntelligenceCheck.isRequestedAtLaunch { await AppleIntelligenceCheck.run() }
                    if UITestSupport.runsCatchUpAtLaunch {
                        await processing.catchUp(until: .now.addingTimeInterval(8))
                    }
                }
                #endif
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
                // Ask iOS for time to finish anything still being written.
                processing.scheduleCatchUp()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(AppConfig.backgroundRefreshTaskID)) { [syncService, processing] in
            await syncService.handleBackgroundRefresh()
            // A refresh is short, but finished sections are kept, so every one makes progress.
            await processing.catchUp(until: .now.addingTimeInterval(20))
        }
    }
}
