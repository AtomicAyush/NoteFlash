import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit
import UserNotifications

/// One deck being written (or rewritten) by the AI engine.
@Observable
final class ProcessingJob: Identifiable {
    enum Kind {
        case newDeck(NewDeckSource, CardDensity)
        case regenerate(deckID: UUID)
    }

    enum State: Equatable {
        case running
        case finished(deckID: UUID, cardCount: Int)
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    fileprivate(set) var state: State = .running
    fileprivate(set) var phase = "Getting ready"
    fileprivate(set) var reportedFraction = 0.0
    fileprivate(set) var estimator: ProcessingEstimator?
    /// True when iOS agreed to keep the job running after the user leaves the app.
    fileprivate(set) var continuesInBackground = false

    fileprivate var task: Task<Void, Never>?
    fileprivate var systemTask: BGContinuedProcessingTask?
    fileprivate var appBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    fileprivate var expired = false
    fileprivate var lastSystemSubtitle = ""

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    var isRunning: Bool { state == .running }

    /// The deck this job is about, once known.
    var deckID: UUID? {
        if case .finished(let deckID, _) = state { return deckID }
        if case .regenerate(let deckID) = kind { return deckID }
        return nil
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
/// Jobs run as iOS continued-processing tasks, which the system shows as a Live Activity in the
/// Dynamic Island and on the Lock Screen; if iOS declines, the job runs while the app is open.
@Observable
final class ProcessingCenter {
    private(set) var jobs: [ProcessingJob] = []

    private let container: ModelContainer
    private let sync: DocSyncService
    private var ticker: Task<Void, Never>?
    private var askedForNotifications = false

    private static let taskIdentifierPrefix = "com.ayushkansal.NoteFlash.processing."

    init(container: ModelContainer, sync: DocSyncService) {
        self.container = container
        self.sync = sync
    }

    /// A running job for this deck, if any.
    func runningJob(forDeck deckID: UUID) -> ProcessingJob? {
        jobs.first { $0.isRunning && $0.deckID == deckID }
    }

    // MARK: Starting and stopping

    func startNewDeck(from source: NewDeckSource, density: CardDensity, title: String) {
        launch(ProcessingJob(kind: .newDeck(source, density), title: title))
    }

    func regenerate(_ deck: Deck) {
        guard runningJob(forDeck: deck.id) == nil else { return }
        launch(ProcessingJob(kind: .regenerate(deckID: deck.id), title: deck.title))
    }

    func cancel(_ job: ProcessingJob) {
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

    private func launch(_ job: ProcessingJob) {
        jobs.insert(job, at: 0)
        requestNotificationPermissionIfNeeded()
        if !submitSystemTask(for: job) {
            runInApp(job)
        }
        startTicker()
    }

    // MARK: Background execution

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
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Making flashcards",
            subtitle: job.title
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return false
        }
        job.continuesInBackground = true

        // If iOS accepted the request but never starts it, run the job in the app instead.
        Task { [weak self, weak job] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, let job, job.isRunning, job.task == nil else { return }
            job.continuesInBackground = false
            self.runInApp(job)
        }
        return true
    }

    private func attach(_ task: BGContinuedProcessingTask, to job: ProcessingJob) {
        guard job.isRunning else {
            task.setTaskCompleted(success: false)
            return
        }
        job.systemTask = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = { @Sendable [self, job] in
            Task { @MainActor in
                self.expire(job)
            }
        }
        if job.task == nil {
            run(job)
        }
        pushSystemProgress(for: job, force: true)
    }

    /// Runs while the app is open, plus the short grace period iOS allows after leaving it.
    private func runInApp(_ job: ProcessingJob) {
        job.appBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Making flashcards") { [weak self, weak job] in
            guard let self, let job else { return }
            self.expire(job)
        }
        run(job)
    }

    private func expire(_ job: ProcessingJob) {
        guard job.isRunning else { return }
        job.expired = true
        job.task?.cancel()
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
                self.complete(job, deckID: result.deckID, cardCount: result.cardCount)
            } catch {
                self.fail(job, with: error)
            }
        }
    }

    private func perform(_ job: ProcessingJob, reporter: ProcessingReporter) async throws -> (deckID: UUID, cardCount: Int) {
        let context = container.mainContext
        switch job.kind {
        case .newDeck(let source, let density):
            let deck = try await DeckCreator.createDeck(
                from: source, density: density, sync: sync, context: context, reporter: reporter
            )
            return (deck.id, deck.cards.count)
        case .regenerate(let deckID):
            let descriptor = FetchDescriptor<Deck>(predicate: #Predicate { $0.id == deckID })
            guard let deck = try context.fetch(descriptor).first else {
                throw DocSyncService.SyncError.deckRemoved
            }
            try await sync.regenerate(deck, reporter: reporter)
            return (deck.id, deck.cards.count)
        }
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

    private func complete(_ job: ProcessingJob, deckID: UUID, cardCount: Int) {
        job.estimator?.recordCompletion()
        job.reportedFraction = 1
        job.state = .finished(deckID: deckID, cardCount: cardCount)
        endBackgroundWork(for: job, success: true)
        notifyIfInBackground(
            title: "“\(job.title)” is ready",
            body: "\(cardCount) flashcards are ready to study.",
            deckID: deckID
        )
    }

    private func fail(_ job: ProcessingJob, with error: Error) {
        let wasCancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        if wasCancelled && !job.expired {
            // The user cancelled.
            endBackgroundWork(for: job, success: false)
            jobs.removeAll { $0.id == job.id }
            return
        }
        let message = job.expired
            ? "iOS stopped processing to save resources. Tap Retry to try again."
            : error.localizedDescription
        job.state = .failed(message)
        endBackgroundWork(for: job, success: false)
        notifyIfInBackground(title: "Couldn't finish “\(job.title)”", body: message, deckID: nil)
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
        job.task = nil
    }

    // MARK: System progress

    /// Keeps the system Live Activity's progress and time estimate moving between engine updates.
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
        let fraction = job.fraction() ?? 0
        task.progress.completedUnitCount = Int64(fraction * Double(task.progress.totalUnitCount))
        let subtitle = "\(job.title) · \(job.statusLine())"
        guard force || subtitle != job.lastSystemSubtitle else { return }
        job.lastSystemSubtitle = subtitle
        task.updateTitle("Making flashcards", subtitle: subtitle)
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

/// Deck navigation requested from outside the view hierarchy (notification taps).
@Observable
final class AppRouter {
    static let shared = AppRouter()
    nonisolated static let deckIDKey = "deckID"

    var deckToOpen: UUID?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let deckID = (response.notification.request.content.userInfo[AppRouter.deckIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        await MainActor.run {
            AppRouter.shared.deckToOpen = deckID
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
