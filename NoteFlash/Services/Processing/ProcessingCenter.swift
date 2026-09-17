import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// One deck being written, rewritten, or updated by the AI engine.
@Observable
final class ProcessingJob: Identifiable {
    enum Kind {
        case newDeck(NewDeckSource, CardDensity)
        case regenerate(deckID: UUID)
        case updateNotes(deckID: UUID, text: String)
        case syncDoc(deckID: UUID, content: DriveFileContent)
    }

    enum State: Equatable {
        case running
        case finished(deckID: UUID, summary: String)
        /// Stopped because iOS ended background time; resumes when the app is opened.
        case paused
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    fileprivate(set) var state: State = .running
    fileprivate(set) var phase = "Getting ready"
    fileprivate(set) var reportedFraction = 0.0
    fileprivate(set) var estimator: ProcessingEstimator?
    fileprivate(set) var errorDetail: String?
    /// True while iOS is letting the job keep running after the user leaves the app.
    fileprivate(set) var continuesInBackground = false

    fileprivate var task: Task<Void, Never>?
    fileprivate var systemTask: BGContinuedProcessingTask?
    fileprivate var systemUnits: Int64 = 0
    fileprivate var appBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    fileprivate var pausing = false
    fileprivate var lastSystemSubtitle = ""
    fileprivate let startedAt = Date.now

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    var isRunning: Bool { state == .running }

    /// The deck this job is about, once known.
    var deckID: UUID? {
        switch (kind, state) {
        case (_, .finished(let deckID, _)): deckID
        case (.regenerate(let deckID), _), (.updateNotes(let deckID, _), _), (.syncDoc(let deckID, _), _): deckID
        case (.newDeck, _): nil
        }
    }

    /// Section title for this kind of work.
    var activityLabel: String {
        switch kind {
        case .newDeck: "Making Flashcards"
        case .regenerate: "Rewriting Cards"
        case .updateNotes, .syncDoc: "Updating Cards"
        }
    }

    /// Progress to show, or nil while the job is still preparing (fetching, reading a PDF).
    func fraction(at date: Date = .now) -> Double? {
        estimator?.displayFraction(reported: reportedFraction, now: date)
    }

    func remaining(at date: Date = .now) -> TimeInterval? {
        estimator?.remaining(fraction: reportedFraction, now: date)
    }

    /// "About 40 sec left · Section 2 of 5"
    func statusLine(at date: Date = .now) -> String {
        guard let remaining = remaining(at: date) else { return phase }
        return "\(ETAText.remaining(remaining)) · \(phase)"
    }
}

/// Runs deck-writing jobs so the user can keep using the app (or leave it) while they finish.
///
/// Each job asks iOS for a continued-processing task, which keeps it running after the user
/// leaves the app and shows a system Live Activity (Dynamic Island and Lock Screen). If iOS
/// declines or later withdraws that time, the job keeps running while the app is open; if the
/// app is in the background then, the job pauses and resumes when the app is opened again.
@Observable
final class ProcessingCenter {
    private(set) var jobs: [ProcessingJob] = []

    private let container: ModelContainer
    private let sync: DocSyncService
    private let log = DiagnosticsLog.shared
    private var ticker: Task<Void, Never>?
    private var askedForNotifications = false

    private static let taskIdentifierPrefix = "com.ayushkansal.NoteFlash.processing."
    private static let systemUnitCount: Int64 = 10_000

    init(container: ModelContainer, sync: DocSyncService) {
        self.container = container
        self.sync = sync
        sync.onDocChanged = { [weak self] deck, content in
            self?.updateFromFile(deck, content: content)
        }
    }

    /// A running job for this deck, if any.
    func runningJob(forDeck deckID: UUID) -> ProcessingJob? {
        jobs.first { $0.isRunning && $0.deckID == deckID }
    }

    /// The newest job for this deck that is still running or needs attention.
    func unfinishedJob(forDeck deckID: UUID) -> ProcessingJob? {
        jobs.first { job in
            if case .finished = job.state { return false }
            return job.deckID == deckID
        }
    }

    // MARK: Starting and stopping

    func startNewDeck(from source: NewDeckSource, density: CardDensity, title: String) {
        launch(ProcessingJob(kind: .newDeck(source, density), title: title))
    }

    func regenerate(_ deck: Deck) {
        guard runningJob(forDeck: deck.id) == nil else { return }
        launch(ProcessingJob(kind: .regenerate(deckID: deck.id), title: deck.title))
    }

    func updateNotes(of deck: Deck, to text: String) {
        guard runningJob(forDeck: deck.id) == nil else { return }
        launch(ProcessingJob(kind: .updateNotes(deckID: deck.id, text: text), title: deck.title))
    }

    private func updateFromFile(_ deck: Deck, content: DriveFileContent) {
        guard runningJob(forDeck: deck.id) == nil else { return }
        let earlier = jobs.filter { job in
            if case .syncDoc(let deckID, _) = job.kind { return deckID == deck.id }
            return false
        }
        // Don't retry the same doc text over and over; the failed row has a Retry button.
        if earlier.contains(where: { job in
            if case .syncDoc(_, let earlier) = job.kind, case .failed = job.state { return earlier.text == content.text }
            return false
        }) {
            return
        }
        // A newer version of the doc replaces an earlier failed or paused attempt.
        let replaced = Set(earlier.map(\.id))
        jobs.removeAll { replaced.contains($0.id) }
        launch(ProcessingJob(kind: .syncDoc(deckID: deck.id, content: content), title: deck.title))
    }

    func cancel(_ job: ProcessingJob) {
        log.record("Cancel requested: \(job.title)")
        job.task?.cancel()
    }

    func dismiss(_ job: ProcessingJob) {
        guard !job.isRunning else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func retry(_ job: ProcessingJob) {
        dismiss(job)
        launch(ProcessingJob(kind: job.kind, title: job.title))
    }

    /// Resumes jobs that paused while the app was in the background, and starts decks for
    /// notes shared from other apps.
    func appDidBecomeActive() {
        SharedNotesImporter.importPending(into: self)
        for job in jobs where job.state == .paused {
            log.record("Resuming: \(job.title)")
            retry(job)
        }
    }

    private func launch(_ job: ProcessingJob) {
        jobs.insert(job, at: 0)
        log.record("Started \(job.activityLabel.lowercased()): \(job.title)")
        requestNotificationPermissionIfNeeded()
        if !submitSystemTask(for: job) {
            runInApp(job)
        }
        startTicker()
    }

    // MARK: Background time

    /// Asks iOS to run the job as a continued-processing task, which keeps it going in the
    /// background and shows the system's progress Live Activity.
    private func submitSystemTask(for job: ProcessingJob) -> Bool {
        let identifier = Self.taskIdentifierPrefix + job.id.uuidString
        // Continued-processing handlers can be registered at any time; each ID is registered once.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask,
                  let job = self.jobs.first(where: { $0.id == job.id }) else {
                task.setTaskCompleted(success: false)
                return
            }
            self.attach(task, to: job)
        }
        guard registered else {
            log.record("Background task not registered (check BGTaskSchedulerPermittedIdentifiers)")
            return false
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: job.activityLabel.capitalizedFirstWordOnly,
            subtitle: job.title
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.record("Background task refused: \(DiagnosticsLog.describe(error))")
            return false
        }
        log.record("Background task accepted")

        // If iOS accepted the request but doesn't start it promptly, run the job in the app.
        Task { [weak self, weak job] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let job, job.isRunning, job.task == nil else { return }
            self.log.record("Background task didn't start; running in the app")
            self.runInApp(job)
        }
        return true
    }

    private func attach(_ task: BGContinuedProcessingTask, to job: ProcessingJob) {
        guard job.isRunning else {
            task.setTaskCompleted(success: false)
            return
        }
        log.record("Background task started")
        job.systemTask = task
        job.continuesInBackground = true
        job.systemUnits = 0
        task.progress.totalUnitCount = Self.systemUnitCount
        task.expirationHandler = { @Sendable [self, job] in
            Task { @MainActor in
                self.systemTaskExpired(job)
            }
        }
        if job.task == nil {
            run(job)
        }
        pushSystemProgress(for: job, force: true)
    }

    /// iOS withdrew the continued-processing time. That only ends background time:
    /// the job keeps running in the app, with the usual grace period if the app isn't open.
    private func systemTaskExpired(_ job: ProcessingJob) {
        guard job.isRunning, let task = job.systemTask else { return }
        log.record("Background task expired (app \(Self.appStateName)); continuing in the app")
        task.expirationHandler = nil
        task.setTaskCompleted(success: false)
        job.systemTask = nil
        job.continuesInBackground = false
        beginAppBackgroundTask(for: job)
    }

    private func runInApp(_ job: ProcessingJob) {
        beginAppBackgroundTask(for: job)
        if job.task == nil {
            run(job)
        }
    }

    /// Covers the short grace period iOS gives after the user leaves the app.
    private func beginAppBackgroundTask(for job: ProcessingJob) {
        guard job.appBackgroundTask == .invalid else { return }
        job.appBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Making flashcards") { [weak self, weak job] in
            guard let self, let job else { return }
            self.appTimeExpired(job)
        }
    }

    private func appTimeExpired(_ job: ProcessingJob) {
        let identifier = job.appBackgroundTask
        job.appBackgroundTask = .invalid
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        guard job.isRunning else { return }
        if UIApplication.shared.applicationState == .active {
            // Back in the app; nothing to stop.
            return
        }
        log.record("Background time ran out; pausing \(job.title)")
        job.pausing = true
        job.task?.cancel()
    }

    private static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "in background"
        @unknown default: "unknown"
        }
    }

    // MARK: Running

    private func run(_ job: ProcessingJob) {
        let jobID = job.id
        let reporter = ProcessingReporter { [self] update in
            Task { @MainActor in
                self.apply(update, toJobWithID: jobID)
            }
        }
        job.task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.perform(job, reporter: reporter)
                self.complete(job, deckID: result.deckID, summary: result.summary)
            } catch {
                self.fail(job, with: error)
            }
        }
    }

    private func perform(_ job: ProcessingJob, reporter: ProcessingReporter) async throws -> (deckID: UUID, summary: String) {
        switch job.kind {
        case .newDeck(let source, let density):
            let deck = try await DeckCreator.createDeck(
                from: source, density: density, sync: sync, context: container.mainContext, reporter: reporter
            )
            return (deck.id, Self.cardCountText(deck.cards.count))
        case .regenerate(let deckID):
            let deck = try fetchDeck(deckID)
            try await sync.regenerate(deck, reporter: reporter)
            return (deck.id, Self.cardCountText(deck.cards.count))
        case .updateNotes(let deckID, let text):
            let deck = try fetchDeck(deckID)
            let summary = try await sync.updateNotes(of: deck, to: text, reporter: reporter)
            return (deck.id, summary)
        case .syncDoc(let deckID, let content):
            let deck = try fetchDeck(deckID)
            try await sync.applyDocChange(to: deck, content: content, reporter: reporter)
            return (deck.id, deck.lastSyncSummary ?? "Up to date")
        }
    }

    private func fetchDeck(_ id: UUID) throws -> Deck {
        let descriptor = FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })
        guard let deck = try container.mainContext.fetch(descriptor).first else {
            throw DocSyncService.SyncError.deckRemoved
        }
        return deck
    }

    private static func cardCountText(_ count: Int) -> String {
        count == 1 ? "1 card" : "\(count) cards"
    }

    private func apply(_ update: ProcessingUpdate, toJobWithID id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.isRunning else { return }
        switch update {
        case .phase(let text):
            job.phase = text
        case .workload(let characters, let engine):
            job.estimator = ProcessingEstimator(engine: engine, characters: characters)
            job.phase = "Starting"
        case .generation(let progress):
            job.reportedFraction = max(job.reportedFraction, min(progress.fraction, 1))
            job.phase = progress.detail
        }
        pushSystemProgress(for: job)
    }

    private func complete(_ job: ProcessingJob, deckID: UUID, summary: String) {
        job.estimator?.recordCompletion()
        job.reportedFraction = 1
        job.state = .finished(deckID: deckID, summary: summary)
        log.record("Finished in \(Int(Date.now.timeIntervalSince(job.startedAt)))s: \(job.title) (\(summary))")
        endBackgroundWork(for: job, success: true)
        switch job.kind {
        case .newDeck, .regenerate:
            notifyIfInBackground(title: "“\(job.title)” is ready", body: "\(summary) ready to study.", deckID: deckID)
        case .updateNotes, .syncDoc:
            notifyIfInBackground(title: "“\(job.title)” updated", body: summary, deckID: deckID)
        }
    }

    private func fail(_ job: ProcessingJob, with error: Error) {
        let wasCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        endBackgroundWork(for: job, success: false)
        if job.pausing {
            log.record("Paused: \(job.title) (\(DiagnosticsLog.describe(error)))")
            job.state = .paused
            notifyIfInBackground(
                title: "“\(job.title)” is paused",
                body: "Open NoteFlash to finish it.",
                deckID: nil
            )
            return
        }
        if wasCancelled {
            log.record("Cancelled: \(job.title)")
            jobs.removeAll { $0.id == job.id }
            return
        }
        let detail = DiagnosticsLog.describe(error)
        log.record("Failed: \(job.title) — \(detail)")
        job.errorDetail = detail
        job.state = .failed(error.localizedDescription)
        notifyIfInBackground(title: "Couldn't finish “\(job.title)”", body: error.localizedDescription, deckID: nil)
    }

    private func endBackgroundWork(for job: ProcessingJob, success: Bool) {
        if let task = job.systemTask {
            task.expirationHandler = nil
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
            job.systemTask = nil
        }
        if job.appBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(job.appBackgroundTask)
            job.appBackgroundTask = .invalid
        }
        job.continuesInBackground = false
        job.task = nil
    }

    // MARK: System progress

    /// Updates the system Live Activity every couple of seconds so progress never looks stalled.
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while let self, self.jobs.contains(where: \.isRunning) {
                for job in self.jobs where job.isRunning {
                    self.pushSystemProgress(for: job)
                }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.ticker = nil
        }
    }

    private func pushSystemProgress(for job: ProcessingJob, force: Bool = false) {
        guard let task = job.systemTask else { return }
        // iOS may end tasks whose progress stops moving, so always advance a little, even when
        // the engine is between updates. Stays below 100% until the job finishes.
        let target = Int64((job.fraction() ?? 0) * Double(Self.systemUnitCount))
        let units = min(Self.systemUnitCount - 100, max(target, job.systemUnits + 1))
        job.systemUnits = units
        task.progress.completedUnitCount = units

        let subtitle = "\(job.title) · \(job.statusLine())"
        guard force || subtitle != job.lastSystemSubtitle else { return }
        job.lastSystemSubtitle = subtitle
        task.updateTitle(job.activityLabel.capitalizedFirstWordOnly, subtitle: subtitle)
    }

    // MARK: Notifications

    private func requestNotificationPermissionIfNeeded() {
        guard !askedForNotifications else { return }
        askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfInBackground(title: String, body: String, deckID: UUID?) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let deckID {
            content.userInfo = [AppRouter.deckIDKey: deckID.uuidString]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}

private extension String {
    /// "Making Flashcards" → "Making flashcards", for system UI.
    var capitalizedFirstWordOnly: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst().lowercased()
    }
}

/// Navigation requested from outside the view hierarchy: notification taps, and files other
/// apps open in NoteFlash.
@Observable
final class AppRouter {
    static let shared = AppRouter()
    nonisolated static let deckIDKey = "deckID"

    var deckToOpen: UUID?
    var incomingNotes: IncomingNotes?

    /// A file sent with "Open in NoteFlash" (or "Copy to NoteFlash") from the share sheet.
    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            DiagnosticsLog.shared.record("Couldn't read opened file: \(url.lastPathComponent)")
            return
        }
        // Copies that iOS placed in Documents/Inbox are ours to delete.
        if url.path(percentEncoded: false).contains("/Documents/Inbox/") {
            try? FileManager.default.removeItem(at: url)
        }
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        if ["txt", "text", "md", "markdown"].contains(url.pathExtension.lowercased()),
           let text = String(data: data, encoding: .utf8) {
            incomingNotes = IncomingNotes(content: .text(title: stem, notes: text))
        } else {
            incomingNotes = IncomingNotes(content: .file(name: name, data: data))
        }
    }
}

/// Notes another app handed to NoteFlash, shown in New Deck for the user to confirm.
struct IncomingNotes: Identifiable {
    enum Content {
        case file(name: String, data: Data)
        case text(title: String, notes: String)
    }

    let id = UUID()
    let content: Content
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // UIKit requires these completion handlers to be called on the main thread; the async
    // versions of these methods finish on a background thread and crash the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let deckID = (response.notification.request.content.userInfo[AppRouter.deckIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        nonisolated(unsafe) let completionHandler = completionHandler
        Self.onMain {
            if let deckID { AppRouter.shared.deckToOpen = deckID }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        nonisolated(unsafe) let completionHandler = completionHandler
        Self.onMain {
            completionHandler([.banner, .sound])
        }
    }

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
