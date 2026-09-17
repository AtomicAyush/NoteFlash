import CryptoKit
import Foundation
import FoundationModels

/// Waits out Apple Intelligence's usage limits. iOS limits how much on-device model work an
/// app can do in a stretch; long notes can reach that limit even while NoteFlash is open.
nonisolated enum ModelLimits {
    /// Longest single wait before the job pauses instead (it resumes on its own later).
    static let maxWait: TimeInterval = 4 * 60
    /// Longest total wait for one request.
    static let maxTotalWait: TimeInterval = 8 * 60
    /// Waits when iOS doesn't say how long the limit lasts.
    private static let backoff: [TimeInterval] = [5, 10, 20, 40, 60, 90, 120]
    /// Quick retries for "the session is busy" errors.
    private static let busyRetries = 10
    /// Fresh attempts after a response stalls.
    private static let stallRetries = 2
    /// How long to wait for a response's first output, and between outputs, before treating it
    /// as stalled. The model service occasionally stops mid-response for a minute or more.
    static let firstOutputTimeout: TimeInterval = 45
    static let outputGapTimeout: TimeInterval = 20

    /// A response stopped arriving.
    struct Stalled: LocalizedError {
        var errorDescription: String? { "Apple Intelligence stopped responding." }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastLimitDate: Date?

    /// Whether a usage limit was hit recently, so optional extra requests are skipped.
    static var wasLimitedRecently: Bool {
        lock.withLock { lastLimitDate.map { Date.now.timeIntervalSince($0) < 15 * 60 } ?? false }
    }

    /// When iOS says the limit resets (iOS 27 and later).
    static func resetDate(of error: Error) -> Date? {
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError,
           case .rateLimited(let info) = error {
            return info.resetDate
        }
        return nil
    }

    /// Runs model work, waiting out usage limits. Throws `EngineError.rateLimited` with a
    /// resume date when the wait would be too long to hold the job open. `onWait` gets the
    /// time the next attempt starts.
    static func run<T>(
        onWait: (Date) -> Void = { _ in },
        maxWait: TimeInterval = maxWait,
        maxTotalWait: TimeInterval = maxTotalWait,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        _ work: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var busyAttempts = 0
        var stallAttempts = 0
        var waited: TimeInterval = 0
        while true {
            do {
                return try await work()
            } catch let error as AppleFlashcardEngine.EngineError {
                // Already handled further down (a nested request gave up).
                throw error
            } catch {
                switch AppleModelFailure(error) {
                case .busy where busyAttempts < busyRetries:
                    busyAttempts += 1
                    try await sleep(1)
                case .stalled where stallAttempts < stallRetries:
                    stallAttempts += 1
                case .rateLimited:
                    lock.withLock { lastLimitDate = .now }
                    let delay = self.delay(for: error, attempt: attempt)
                    let detail = String(reflecting: error)
                    guard delay <= maxWait, waited + delay <= maxTotalWait else {
                        throw AppleFlashcardEngine.EngineError.rateLimited(resumeAt: Date.now.addingTimeInterval(delay), detail: detail)
                    }
                    attempt += 1
                    waited += delay
                    onWait(Date.now.addingTimeInterval(delay))
                    try await sleep(delay)
                default:
                    throw error
                }
            }
        }
    }

    /// How a watched response ended.
    enum StreamEnd {
        case finished
        /// The consumer asked to stop early (for example, a runaway response).
        case stopped
        /// No output arrived for too long; the request was cancelled.
        case stalled
    }

    /// Runs a streaming request on its own task and watches it: `onOutput` gets each new
    /// snapshot (and can stop the stream), and a response that stops producing output is
    /// cancelled rather than waited on indefinitely. Returns the last snapshot.
    static func watch<Snapshot>(
        firstOutputTimeout: TimeInterval = firstOutputTimeout,
        outputGapTimeout: TimeInterval = outputGapTimeout,
        pollInterval: Duration = .milliseconds(150),
        produce: @escaping @Sendable (StreamWatch<Snapshot>) async throws -> Void,
        onOutput: (Snapshot, _ stop: () -> Void) -> Void
    ) async throws -> (latest: Snapshot?, end: StreamEnd) {
        let box = StreamWatch<Snapshot>()
        let producer = Task {
            do {
                try await produce(box)
                box.finish(nil)
            } catch {
                box.finish(error)
            }
        }
        return try await withTaskCancellationHandler {
            var seen = 0
            while true {
                try await Task.sleep(for: pollInterval)
                let state = box.state
                if state.updates != seen, let latest = state.latest {
                    seen = state.updates
                    onOutput(latest, box.requestStop)
                }
                if state.finished {
                    if let failure = state.failure, !(failure is CancellationError && state.stopRequested) {
                        throw failure
                    }
                    return (state.latest, state.stopRequested ? .stopped : .finished)
                }
                let limit = state.updates == 0 ? firstOutputTimeout : outputGapTimeout
                if Date.now.timeIntervalSince(state.lastOutput) > limit {
                    producer.cancel()
                    return (state.latest, .stalled)
                }
            }
        } onCancel: {
            producer.cancel()
        }
    }

    /// Runs a non-streaming request, giving up if it takes longer than `timeout`.
    static func withTimeout<T>(
        _ timeout: TimeInterval = firstOutputTimeout,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let (result, end) = try await watch(
            firstOutputTimeout: timeout,
            produce: { box in
                let value = try await operation()
                box.update(value)
            },
            onOutput: { _, _ in }
        )
        guard end != .stalled, let result else { throw Stalled() }
        return result
    }

    static func delay(for error: Error, attempt: Int, now: Date = .now) -> TimeInterval {
        if let reset = resetDate(of: error) {
            // A little slack, since the limit may lift just after the stated time.
            return max(2, reset.timeIntervalSince(now) + 2)
        }
        return backoff[min(attempt, backoff.count - 1)]
    }
}

/// Cards from sections that finished, so a job that is retried, resumed, or picked up after
/// iOS stopped the app skips work already done (and doesn't spend more of the usage limit on
/// it). Kept in memory and on disk.
///
/// Sections belong to the job that wrote them: a new deck, or a deck being rewritten, asks the
/// model again rather than handing back cards written for something else.
nonisolated final class SectionCache: @unchecked Sendable {
    struct Entry: Sendable, Codable {
        let title: String?
        let cards: [GeneratedCard]
    }

    static let shared = SectionCache()
    private static let maxEntries = 400
    /// Finished sections are only useful to a job that's still in the queue.
    private static let maxAge: TimeInterval = 3 * 24 * 60 * 60

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let folder = AppGroupStore.folder(named: "FinishedSections")
    private var hasPruned = false

    /// The job whose sections may be reused, set for as long as that job runs. Without one there
    /// is nothing to resume, so nothing is kept.
    @TaskLocal static var job: UUID?

    /// The key for a section of this job's work, or nil when sections shouldn't be reused at all.
    static func key(model: String, density: CardDensity, request: String, text: String) -> String? {
        guard let job else { return nil }
        let material = [job.uuidString, model, density.rawValue, request, text].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(for key: String) -> Entry? {
        if let entry = lock.withLock({ entries[key] }) { return entry }
        guard let url = file(for: key), let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        keepInMemory(entry, for: key)
        return entry
    }

    func store(_ entry: Entry, for key: String) {
        keepInMemory(entry, for: key)
        pruneOnce()
        guard let url = file(for: key), let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func removeAll() {
        lock.withLock {
            entries = [:]
            order = []
        }
        guard let folder else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func keepInMemory(_ entry: Entry, for key: String) {
        lock.withLock {
            if entries.updateValue(entry, forKey: key) == nil {
                order.append(key)
            }
            while order.count > Self.maxEntries {
                entries[order.removeFirst()] = nil
            }
        }
    }

    private func file(for key: String) -> URL? {
        // The key is a hash, so it's already a safe file name.
        folder?.appending(path: "\(key).json")
    }

    /// Drops sections left behind by jobs that finished or were given up on long ago.
    private func pruneOnce() {
        guard !lock.withLock({ hasPruned }) else { return }
        lock.withLock { hasPruned = true }
        guard let folder else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date.now.timeIntervalSince(modified) > Self.maxAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// The latest output of a watched response, shared between the task producing it and the
/// caller watching it.
nonisolated final class StreamWatch<Snapshot>: @unchecked Sendable {
    struct State {
        var latest: Snapshot?
        var updates = 0
        var lastOutput = Date.now
        var finished = false
        var failure: Error?
        var stopRequested = false
    }

    private let lock = NSLock()
    private var current = State()

    var state: State { lock.withLock { current } }
    var isStopRequested: Bool { lock.withLock { current.stopRequested } }

    func update(_ snapshot: Snapshot) {
        lock.withLock {
            current.latest = snapshot
            current.updates += 1
            current.lastOutput = .now
        }
    }

    func requestStop() {
        lock.withLock { current.stopRequested = true }
    }

    func finish(_ failure: Error?) {
        lock.withLock {
            current.finished = true
            current.failure = failure
        }
    }
}
