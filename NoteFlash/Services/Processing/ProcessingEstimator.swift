import Foundation

/// Progress events from deck creation, turned into a job's status by ProcessingCenter.
nonisolated enum ProcessingUpdate: Sendable {
    case phase(String)
    case workload(characters: Int, engine: AIEngineKind)
    case generation(GenerationProgress)
}

nonisolated struct ProcessingReporter: Sendable {
    let send: @Sendable (ProcessingUpdate) -> Void

    static let silent = ProcessingReporter { _ in }

    var generationHandler: GenerationProgressHandler {
        { [send] progress in send(.generation(progress)) }
    }
}

/// Predicts how long writing a deck will take, refines the guess as progress comes in,
/// and learns each engine's pace from finished runs.
nonisolated struct ProcessingEstimator: Sendable {
    let engine: AIEngineKind
    let characters: Int
    let startedAt: Date
    let expectedDuration: TimeInterval

    init(engine: AIEngineKind, characters: Int, startedAt: Date = .now, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.characters = characters
        self.startedAt = startedAt
        self.expectedDuration = Self.expectedDuration(engine: engine, characters: characters, defaults: defaults)
    }

    /// Up-front estimate: a fixed startup cost plus a learned rate per 1,000 characters of notes.
    static func expectedDuration(engine: AIEngineKind, characters: Int, defaults: UserDefaults = .standard) -> TimeInterval {
        let tuning = Tuning(engine)
        let rate = defaults.object(forKey: tuning.rateKey) as? Double ?? tuning.secondsPerThousand
        return tuning.base + rate * Double(max(characters, 0)) / 1_000
    }

    /// Rough text length of a PDF when only its page count is known.
    static func estimatedCharacters(pdfPages: Int) -> Int {
        pdfPages * 1_800
    }

    /// Seconds left. Starts from the up-front estimate and trusts the observed pace more as
    /// progress grows. Never drops to zero while work remains, so slow devices don't read
    /// "Almost done" for minutes.
    func remaining(fraction: Double, now: Date = .now) -> TimeInterval {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let progress = min(max(fraction, 0), 1)
        guard progress < 1 else { return 0 }
        let expected = max(expectedDuration, 1)
        let prior = max(expected - elapsed, expected * (1 - progress) * 0.3)
        guard progress >= 0.05 else { return max(prior, elapsed * 0.5) }
        let observed = elapsed * (1 - progress) / progress
        let trust = min(1, progress * 1.5)
        return trust * observed + (1 - trust) * prior
    }

    /// Progress to show: what the engine reported, or the time-based share if that's further
    /// along, so the bar keeps moving between updates. Stays below 100% until the work finishes.
    func displayFraction(reported: Double, now: Date = .now) -> Double {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let left = remaining(fraction: reported, now: now)
        let timeBased = elapsed / max(elapsed + left, 1)
        return min(0.97, max(reported, timeBased))
    }

    /// Updates the learned rate with how long this run actually took.
    func recordCompletion(at end: Date = .now, defaults: UserDefaults = .standard) {
        guard characters >= 300 else { return }
        let tuning = Tuning(engine)
        let actual = end.timeIntervalSince(startedAt)
        let observedRate = max(0.3, (actual - tuning.base) / (Double(characters) / 1_000))
        let current = defaults.object(forKey: tuning.rateKey) as? Double ?? tuning.secondsPerThousand
        defaults.set(current * 0.6 + observedRate * 0.4, forKey: tuning.rateKey)
    }

    private struct Tuning {
        let base: TimeInterval
        let secondsPerThousand: Double
        let rateKey: String

        init(_ engine: AIEngineKind) {
            switch engine {
            case .apple:
                base = 4
                secondsPerThousand = 5
            case .claude:
                base = 12
                secondsPerThousand = 6
            }
            rateKey = "processingRate.\(engine.rawValue)"
        }
    }
}

nonisolated enum ETAText {
    /// "About 40 sec left", "About 3 min left", or "Almost done".
    static func remaining(_ seconds: TimeInterval) -> String {
        seconds < 4 ? "Almost done" : "About \(duration(seconds)) left"
    }

    /// "About 40 sec", for estimates shown before starting.
    static func estimate(_ seconds: TimeInterval) -> String {
        "about \(duration(seconds))"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 55 {
            return "\(max(5, Int((seconds / 5).rounded(.up)) * 5)) sec"
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes) min"
    }
}
