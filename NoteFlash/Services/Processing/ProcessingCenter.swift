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

    fileprivate(set) var id = UUID()
    let kind: Kind
    let title: String
    fileprivate(set) var state: State = .running
    fileprivate(set) var phase = "Getting ready"
    fileprivate(set) var reportedFraction = 0.0
    fileprivate(set) var estimator: ProcessingEstimator?
    fileprivate(set) var errorDetail: String?
    /// True while iOS is letting the job keep running after the user leaves the app.
    fileprivate(set) var continuesInBackground = false
    /// For a job paused by Apple Intelligence's usage limit: when it continues on its own.
    fileprivate(set) var resumeAt: Date?
    /// Set while the engine waits out a usage limit.
    fileprivate(set) var waitingUntil: Date?
    fileprivate var waitStartedAt: Date?
    fileprivate var waitedSeconds: TimeInterval = 0

    fileprivate var task: Task<Void, Never>?
    fileprivate var systemTask: BGContinuedProcessingTask?
    fileprivate var systemUnits: Int64 = 0
    fileprivate var appBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    fileprivate var pausing = false
    fileprivate var lastSystemSubtitle = ""
    fileprivate let startedAt = Date.now
    /// How many times this job has been started, across app launches.
    fileprivate var attempts = 0
    /// What was written down for this job, so its files are only stored once.
    fileprivate var savedWork: JobStore.Record.Work?

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    /// Rebuilds a job that was written down before the app stopped.
    convenience init?(_ record: JobStore.Record) {
        guard let kind = ProcessingCenter.kind(of: record) else { return nil }
        self.init(kind: kind, title: record.title)
        id = record.id
        savedWork = record.work
        attempts = record.attempts
        resumeAt = record.resumeAt
        errorDetail = record.lastError
        state = .paused
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
        // A time estimate means little while waiting out a usage limit.
        guard waitingUntil == nil, let remaining = remaining(at: date) else { return phase }
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
        clearPausedNotification(for: job)
        jobs.removeAll { $0.id == job.id }
        JobStore.remove(job.id)
    }

    func retry(_ job: ProcessingJob) {
        jobs.removeAll { $0.id == job.id }
        clearPausedNotification(for: job)
        // Sections that already finished are reused, so this picks up where the job stopped.
        job.attempts = 0
        job.errorDetail = nil
        launch(job)
    }

    /// Resumes jobs that paused while the app was in the background (or whose usage-limit wait
    /// is over), and starts decks for notes shared from other apps.
    func appDidBecomeActive() {
        restoreSavedJobs()
        updateIdleTimer()
    }

    /// The app went to the background: the screen is the system's business again.
    func appDidEnterBackground() {
        updateIdleTimer()
        scheduleCatchUp()
    }

    /// Keeps the screen awake while the app is open and cards are being written, so a job the
    /// user is watching isn't cut short by the screen locking. Waiting out a usage limit doesn't
    /// count: that can take minutes with nothing to see.
    private func updateIdleTimer() {
        let working = UIApplication.shared.applicationState == .active
            && jobs.contains { $0.isRunning && $0.waitingUntil == nil }
        guard UIApplication.shared.isIdleTimerDisabled != working else { return }
        UIApplication.shared.isIdleTimerDisabled = working
        log.record(working ? "Keeping the screen on while cards are written" : "The screen can sleep again")
    }

    private func resumeReadyJobs() {
        // In the background without a task holding time for us, a job gets about half a minute —
        // less than a section takes — so it would be cut off and lose that work. Better to wait
        // for real background time, or for the app to be opened.
        guard UIApplication.shared.applicationState == .active || isCatchingUp else {
            if jobs.contains(where: { $0.state == .paused }) { scheduleCatchUp() }
            return
        }
        for job in jobs where job.state == .paused && (job.resumeAt ?? .distantPast) <= .now {
            guard job.attempts < Self.maxAttempts else {
                log.record("Not resuming \(job.title) on its own after \(job.attempts) failed tries")
                continue
            }
            log.record("Resuming: \(job.title)")
            resume(job)
        }
    }

    /// Starts a job again, keeping its place in the list and its saved record.
    private func resume(_ job: ProcessingJob) {
        jobs.removeAll { $0.id == job.id }
        launch(job)
    }

    private func launch(_ job: ProcessingJob) {
        jobs.insert(job, at: 0)
        job.state = .running
        job.resumeAt = nil
        write(job)
        log.record("Started \(job.activityLabel.lowercased()): \(job.title)")
        requestNotificationPermissionIfNeeded()
        clearPausedNotification(for: job)
        updateIdleTimer()
        // iOS only grants continued-processing time to an app the user is looking at. In the
        // background the job runs on whatever time the background task already holds.
        if UIApplication.shared.applicationState == .active, submitSystemTask(for: job) {
            // Waiting for iOS to start the task.
        } else {
            runInApp(job)
        }
        startTicker()
    }

    // MARK: Work that outlives the app

    /// How many times a job may fail on its own before it waits for the user to tap Retry.
    /// Being stopped by iOS doesn't count: no work was lost, and nothing went wrong.
    private static let maxAttempts = 4

    /// Picks up jobs written down before the app was closed or stopped by iOS, and starts the
    /// ones that are ready. Safe to call whenever the app runs, including a background launch.
    func restoreSavedJobs() {
        JobStore.removeAbandoned()
        SharedNotesImporter.importPending(into: self)
        for record in JobStore.records() where !jobs.contains(where: { $0.id == record.id }) {
            guard let job = ProcessingJob(record) else {
                log.record("Dropped a saved job that can't be read")
                JobStore.remove(record.id)
                continue
            }
            log.record("Found unfinished work: \(job.title)")
            jobs.append(job)
        }
        resumeReadyJobs()
    }

    /// Work waiting to be done, whether or not it's running right now.
    var hasUnfinishedWork: Bool {
        jobs.contains { $0.isRunning || $0.state == .paused } || !JobStore.records().isEmpty
    }

    /// Saves the job so it can be picked up again if the app stops. Sync jobs aren't saved:
    /// they're worked out from the linked file again anyway.
    private func write(_ job: ProcessingJob) {
        guard let work = job.savedWork ?? Self.work(of: job) else { return }
        job.savedWork = work
        JobStore.save(
            JobStore.Record(
                id: job.id,
                title: job.title,
                work: work,
                resumeAt: job.resumeAt,
                attempts: job.attempts,
                lastError: job.errorDetail
            )
        )
    }

    private static func work(of job: ProcessingJob) -> JobStore.Record.Work? {
        switch job.kind {
        case .newDeck(let source, let density):
            switch source {
            case .text(let title, let notes):
                return .newDeckText(title: title, notes: notes, density: density.rawValue)
            case .file(let fileName, let data, let title):
                guard let file = JobStore.addFile(data, named: fileName, for: job.id) else { return nil }
                return .newDeckFile(fileName: fileName, file: file, title: title, density: density.rawValue)
            case .images(let name, let data, let title):
                let files = data.enumerated().compactMap {
                    JobStore.addFile($1, named: "Page \($0 + 1).jpg", for: job.id)
                }
                guard files.count == data.count else { return nil }
                return .newDeckImages(name: name, files: files, title: title, density: density.rawValue)
            case .drive(let reference, let autoSync):
                return .newDeckDrive(
                    id: reference.id, kind: reference.kind?.rawValue, name: reference.name,
                    autoSync: autoSync, density: density.rawValue
                )
            }
        case .regenerate(let deckID):
            return .regenerate(deckID: deckID)
        case .updateNotes(let deckID, let text):
            return .updateNotes(deckID: deckID, text: text)
        case .syncDoc:
            return nil
        }
    }

    /// Whether starting this job again later could work. Notes the app can't use, and anything
    /// waiting on the user, won't get better on their own.
    private static func isWorthRetrying(_ error: Error) -> Bool {
        switch error {
        case is DeckCreator.CreationError, is DocSyncService.SyncError:
            false
        case let error as AppleFlashcardEngine.EngineError:
            switch error {
            case .blockedBySafetyFilter, .unsupportedLanguage, .noText, .unavailable: false
            default: true
            }
        case let error as GoogleDriveClient.DriveError:
            ![.unauthorized, .missingPermission, .apiDisabled, .notFound].contains(error)
        default:
            true
        }
    }

    fileprivate static func kind(of record: JobStore.Record) -> ProcessingJob.Kind? {
        func density(_ raw: String) -> CardDensity { CardDensity(rawValue: raw) ?? .balanced }
        switch record.work {
        case .newDeckText(let title, let notes, let raw):
            return .newDeck(.text(title: title, notes: notes), density(raw))
        case .newDeckFile(let fileName, let file, let title, let raw):
            guard let data = JobStore.file(file, for: record.id) else { return nil }
            return .newDeck(.file(fileName: fileName, data: data, title: title), density(raw))
        case .newDeckImages(let name, let files, let title, let raw):
            let data = files.compactMap { JobStore.file($0, for: record.id) }
            guard data.count == files.count, !data.isEmpty else { return nil }
            return .newDeck(.images(name: name, data: data, title: title), density(raw))
        case .newDeckDrive(let id, let kind, let name, let autoSync, let raw):
            let reference = DriveFileReference(id: id, kind: kind.flatMap(DriveFileKind.init(rawValue:)), name: name)
            return .newDeck(.drive(reference, autoSync: autoSync), density(raw))
        case .regenerate(let deckID):
            return .regenerate(deckID: deckID)
        case .updateNotes(let deckID, let text):
            return .updateNotes(deckID: deckID, text: text)
        }
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
        // If the short grace period isn't enough, the job pauses; this gets it going again
        // without the user having to open NoteFlash.
        scheduleCatchUp()
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

    // MARK: Catching up in the background

    /// Longest a catch-up run keeps going before handing the time back.
    private static let catchUpLimit: TimeInterval = 25 * 60
    private var catchUp: Task<Void, Never>?
    private var lastCatchUpRequest = Date.distantPast
    /// True while iOS is letting the app work through the queue in the background.
    private var isCatchingUp = false

    /// Asks iOS to start NoteFlash in the background later to finish what's left. iOS runs these
    /// when the device is idle, and not at all if the app was force-quit from the app switcher.
    func scheduleCatchUp(after date: Date? = nil) {
        guard hasUnfinishedWork else { return }
        // Several jobs stopping at once shouldn't each ask for the same time.
        guard date != nil || Date.now.timeIntervalSince(lastCatchUpRequest) > 60 else { return }
        lastCatchUpRequest = .now
        let request = BGProcessingTaskRequest(identifier: BackgroundWork.catchUpTaskID)
        request.earliestBeginDate = date ?? Date(timeIntervalSinceNow: 30)
        request.requiresExternalPower = false
        // Only linked Google Drive files need the network.
        request.requiresNetworkConnectivity = JobStore.records().contains { record in
            if case .newDeckDrive = record.work { return true }
            return false
        }
        // Only one request per identifier is kept, so replace any earlier one.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundWork.catchUpTaskID)
        log.record("Asking iOS for background time to finish the queue")
        submit(request, describing: "Background time")
    }

    /// Submits a request and logs anything iOS says about it. `submit(_:)` can't report some
    /// refusals, so iOS 27's reporting version is used where it exists.
    private func submit(_ request: BGTaskRequest, describing what: String) {
        if #available(iOS 27.0, *) {
            BGTaskScheduler.shared.submitTaskRequest(request) { error in
                guard let error else { return }
                Task { @MainActor in
                    DiagnosticsLog.shared.record("\(what) refused: \(DiagnosticsLog.describe(error))")
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                log.record("\(what) refused: \(DiagnosticsLog.describe(error))")
            }
        }
    }

    /// Runs the saved jobs iOS gave us time for. Returns when the work is done, the deadline
    /// passes, or iOS takes the time back.
    func catchUp(until deadline: Date) async {
        isCatchingUp = true
        defer { isCatchingUp = false }
        restoreSavedJobs()
        guard jobs.contains(where: \.isRunning) else { return }
        log.record("Working in the background (app \(Self.appStateName))")
        while jobs.contains(where: \.isRunning), Date.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        if jobs.contains(where: \.isRunning) {
            log.record("Out of background time; saving progress")
            stopForNow()
        }
    }

    /// iOS is taking the time back. Jobs stop where they are; finished sections are already
    /// saved, so the next run picks up from there instead of starting over.
    func stopForNow() {
        for job in jobs where job.isRunning {
            job.pausing = true
            job.state = .paused
            write(job)
            job.task?.cancel()
        }
        catchUp?.cancel()
        scheduleCatchUp()
    }

    /// Handles the background task iOS started for unfinished work.
    func handle(_ task: BGProcessingTask) {
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.stopForNow() }
        }
        catchUp = Task { @MainActor [weak self] in
            await self?.catchUp(until: .now.addingTimeInterval(Self.catchUpLimit))
            task.setTaskCompleted(success: true)
        }
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
            if let until = progress.waitingUntil {
                if job.waitStartedAt == nil { job.waitStartedAt = .now }
                job.waitingUntil = until
            } else if let started = job.waitStartedAt {
                job.waitedSeconds += Date.now.timeIntervalSince(started)
                job.waitStartedAt = nil
                job.waitingUntil = nil
            }
        }
        pushSystemProgress(for: job)
    }

    private func complete(_ job: ProcessingJob, deckID: UUID, summary: String) {
        let waiting = job.waitStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        job.estimator?.recordCompletion(excluding: job.waitedSeconds + waiting)
        job.reportedFraction = 1
        job.state = .finished(deckID: deckID, summary: summary)
        JobStore.remove(job.id)
        clearPausedNotification(for: job)
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
            job.pausing = false
            write(job)
            scheduleCatchUp()
            notifyPaused(job)
            return
        }
        if case .rateLimited(let resumeAt, let detail)? = error as? AppleFlashcardEngine.EngineError {
            pauseForUsageLimit(job, until: resumeAt ?? Date.now.addingTimeInterval(5 * 60), detail: detail)
            return
        }
        if wasCancelled {
            log.record("Cancelled: \(job.title)")
            jobs.removeAll { $0.id == job.id }
            JobStore.remove(job.id)
            return
        }
        let detail = DiagnosticsLog.describe(error)
        log.record("Failed: \(job.title) — \(detail)")
        job.errorDetail = detail
        job.state = .failed(error.localizedDescription)
        // Kept so it can be tried again later, unless it's a job that can't succeed on a retry.
        job.attempts += 1
        if Self.isWorthRetrying(error) && job.attempts < Self.maxAttempts {
            job.state = .paused
            write(job)
            scheduleCatchUp()
        } else {
            JobStore.remove(job.id)
        }
        notifyIfInBackground(title: "Couldn't finish “\(job.title)”", body: error.localizedDescription, deckID: nil)
    }

    /// Apple Intelligence's usage limit was reached: pause, and continue when it resets.
    private func pauseForUsageLimit(_ job: ProcessingJob, until resumeAt: Date, detail: String?) {
        let time = resumeAt.formatted(date: .omitted, time: .shortened)
        log.record("Paused for Apple Intelligence's usage limit until \(time): \(job.title)" + (detail.map { " — \($0)" } ?? ""))
        job.state = .paused
        job.resumeAt = resumeAt
        job.waitingUntil = nil
        job.errorDetail = detail
        write(job)
        scheduleCatchUp(after: resumeAt)
        startTicker()

        // A reminder to open NoteFlash when the job can continue.
        let content = UNMutableNotificationContent()
        content.title = "Ready to finish “\(job.title)”"
        content.body = "Apple Intelligence can continue now. Open NoteFlash to finish the cards."
        content.sound = .default
        let delay = max(1, resumeAt.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: Self.resumeNotificationID(job),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func resumeNotificationID(_ job: ProcessingJob) -> String {
        "resume-\(job.id.uuidString)"
    }

    private static func pausedNotificationID(_ job: ProcessingJob) -> String {
        "paused-\(job.id.uuidString)"
    }

    /// iOS stopped the work, and it needs either background time or the user. Everything written
    /// so far is saved, so this is an invitation rather than a warning.
    private func notifyPaused(_ job: ProcessingJob) {
        guard UIApplication.shared.applicationState != .active else { return }
        let done = Int(((job.fraction() ?? 0) * 100).rounded())
        let content = UNMutableNotificationContent()
        content.title = "“\(job.title)” is paused"
        content.body = done >= 10
            ? "\(done)% done and saved. It continues when iOS lets NoteFlash work in the background, or open NoteFlash to finish it now."
            : "What's written is saved. It continues when iOS lets NoteFlash work in the background, or open NoteFlash to finish it now."
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.pausedNotificationID(job), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func clearPausedNotification(for job: ProcessingJob) {
        let ids = [Self.pausedNotificationID(job), Self.resumeNotificationID(job)]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func endBackgroundWork(for job: ProcessingJob, success: Bool) {
        if let task = job.systemTask {
            task.expirationHandler = nil
            if job.pausing {
                // The Dynamic Island and Lock Screen show this as the task ends.
                task.updateTitle(job.activityLabel.capitalizedFirstWordOnly, subtitle: "\(job.title) · paused, open NoteFlash to finish")
            }
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

    /// Updates the system Live Activity every couple of seconds so progress never looks stalled,
    /// and resumes paused jobs once their usage-limit wait is over (while NoteFlash is open).
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while let self, self.jobs.contains(where: { $0.isRunning || $0.resumeAt != nil && $0.state == .paused }) {
                for job in self.jobs where job.isRunning {
                    self.pushSystemProgress(for: job)
                }
                self.updateIdleTimer()
                if UIApplication.shared.applicationState == .active {
                    self.resumeReadyJobs()
                }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.updateIdleTimer()
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
    /// Decks other NoteFlash users shared, waiting for the user to confirm adding them.
    var incomingDecks: [IncomingSharedDeck] = []

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
        if DeckShare.isPage(name: name) {
            receivePage(data, named: stem)
        } else if ["txt", "text", "md", "markdown"].contains(url.pathExtension.lowercased()),
           let text = String(data: data, encoding: .utf8) {
            incomingNotes = IncomingNotes(content: .text(title: stem, notes: text))
        } else {
            incomingNotes = IncomingNotes(content: .file(name: name, data: data))
        }
    }

    /// A shared deck if the page holds one, and otherwise the page's text as notes.
    func receivePage(_ data: Data, named name: String) {
        if let shared = DeckShare.deck(inPage: data) {
            incomingDecks.append(IncomingSharedDeck(deck: shared))
        } else if let text = DeckShare.plainText(ofPage: data), !text.isEmpty {
            incomingNotes = IncomingNotes(content: .text(title: name, notes: text))
        } else {
            DiagnosticsLog.shared.record("Nothing to read in shared page: \(name)")
        }
    }
}

/// A deck another NoteFlash user shared, shown for the user to confirm adding.
struct IncomingSharedDeck: Identifiable {
    let id = UUID()
    let deck: SharedDeck
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
        // Registered at launch, so iOS can start NoteFlash in the background to finish work the
        // app didn't get through — including notes shared while it was closed.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundWork.catchUpTaskID, using: .main) { task in
            MainActor.assumeIsolated {
                DiagnosticsLog.shared.record("iOS started NoteFlash to finish unfinished work")
                guard let task = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                AppServices.shared.processing.handle(task)
            }
        }
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
