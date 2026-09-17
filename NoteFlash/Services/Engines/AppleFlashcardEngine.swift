import Foundation
import FoundationModels

// MARK: - Guided-generation types

/// Generated in field order: writing the fact first helps the small model ask a real question about it.
@Generable(description: "A study flashcard")
nonisolated struct AppleCard {
    @Guide(description: "One fact from the notes, in one short sentence")
    var fact: String
    @Guide(description: "A question that this fact answers. The question must not contain the answer.")
    var question: String
    @Guide(description: "The complete answer to the question as a short phrase from the fact, for example 'in 1989' or 'exporting more than importing'")
    var answer: String

    var card: GeneratedCard { GeneratedCard(front: question, back: answer) }
}

@Generable
nonisolated struct AppleCardSet {
    @Guide(description: "A short title, a few words long, naming the subject of the notes")
    var title: String
    @Guide(description: "One flashcard per key fact in the notes, in the order the facts appear", .maximumCount(40))
    var cards: [AppleCard]
}

@Generable
nonisolated struct AppleDeckTitle {
    @Guide(description: "A short flashcard deck title, a few words long, naming the overall subject")
    var title: String
}

@Generable
nonisolated enum AppleCardAction {
    case keep
    case update
    case remove
}

/// Generated in field order: judging correctness first keeps the model from rewriting cards that are still right.
@Generable
nonisolated struct AppleCardDecision {
    @Guide(description: "The card's id exactly as given, such as c3")
    var id: String
    @Guide(description: "Whether the card's answer is still true according to the notes after the edit")
    var stillCorrect: Bool
    @Guide(description: "keep if the card is still correct, update if the notes now give a different answer, remove if the notes no longer cover it")
    var action: AppleCardAction
    @Guide(description: "The card's question, corrected when the action is update")
    var front: String
    @Guide(description: "The card's answer, corrected when the action is update")
    var back: String
}

@Generable
nonisolated struct AppleCardReview {
    @Guide(description: "One decision for each card shown", .maximumCount(12))
    var decisions: [AppleCardDecision]
}

// MARK: - Engine

/// Writes and revises cards with Apple's on-device foundation model. Long notes are
/// processed in sections that fit the model's context window, and note edits are handled
/// one changed section at a time.
nonisolated struct AppleFlashcardEngine: FlashcardEngine {
    enum EngineError: LocalizedError {
        case unavailable(String)
        case blockedBySafetyFilter
        /// iOS's usage limit for Apple Intelligence was reached; work can resume at `resumeAt`.
        case rateLimited(resumeAt: Date?, detail: String?)
        case unsupportedLanguage
        case tooLong
        case timedOut
        case modelNotReady(String?)
        case noText
        /// The framework's own description is kept for the Processing Log.
        case generationFailed(String?)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                reason
            case .blockedBySafetyFilter:
                "Apple Intelligence's safety filter declined these notes. Try switching to Claude in Settings."
            case .rateLimited(let resumeAt, _):
                if let resumeAt, resumeAt > .now {
                    "Apple Intelligence reached its usage limit for now. It can continue at \(resumeAt.formatted(date: .omitted, time: .shortened))."
                } else {
                    "Apple Intelligence reached its usage limit for now. Try again in a few minutes."
                }
            case .unsupportedLanguage:
                "Apple Intelligence doesn't support the language of these notes yet. Try switching to Claude in Settings."
            case .tooLong:
                "Part of these notes is too long for Apple Intelligence to read at once. Try adding line breaks or headings."
            case .timedOut:
                "Apple Intelligence took too long on these notes. Try again, or add headings to split them into smaller sections."
            case .modelNotReady:
                #if targetEnvironment(simulator)
                "Apple Intelligence can't load its model in this Simulator. Try a real iPhone, or switch to Claude in Settings."
                #else
                "Apple Intelligence's model isn't ready on this iPhone. It may still be downloading after an update; keep the iPhone on Wi-Fi and power, then try again later. You can also switch to Claude in Settings."
                #endif
            case .noText:
                "There's no readable text in these notes."
            case .generationFailed:
                #if targetEnvironment(simulator)
                "Apple Intelligence couldn't write cards. The on-device model often can't run in the iOS Simulator; try a real iPhone, or switch to Claude in Settings."
                #else
                "Apple Intelligence couldn't write cards right now. Try again in a moment, or switch to Claude in Settings."
                #endif
            }
        }
    }

    /// Why Apple Intelligence can't be used right now, or nil when it's ready.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device doesn't support Apple Intelligence. Switch to Claude in Settings."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in the Settings app, or switch to Claude in NoteFlash Settings."
            case .modelNotReady:
                return "Apple Intelligence is still getting ready (its model may be downloading). Try again soon."
            @unknown default:
                return "Apple Intelligence isn't available right now. Switch to Claude in Settings."
            }
        }
    }

    private static let options = GenerationOptions(temperature: 0.3)

    /// Caps a response's length, so a model that starts repeating itself stops early instead of
    /// using up the time and usage limit.
    private static func options(maxTokens: Int) -> GenerationOptions {
        GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
    }
    /// Cards reviewed per edited section, in batches small enough for the context window.
    private static let maxReviewedCards = 40
    private static let reviewBatchSize = 8

    init() throws {
        if let reason = Self.unavailableReason {
            throw EngineError.unavailable(reason)
        }
    }

    /// Characters of notes per request. Notes get ~30% of the context window (at ~3.5
    /// characters per token); the rest covers instructions and the cards, which run longer
    /// than the notes because each card also restates its fact.
    static func chunkCharacters(forContextSize tokens: Int) -> Int {
        max(1_200, Int(Double(tokens) * 0.3 * 3.5))
    }

    private static var onDeviceChunkCharacters: Int {
        chunkCharacters(forContextSize: SystemLanguageModel.default.contextSize)
    }

    private static func onDeviceSession(_ instructions: String) -> LanguageModelSession {
        LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }

    // MARK: Generation

    /// What happened while writing one section, for progress reporting.
    private enum SectionEvent {
        case cards(Int)
        /// Waiting out the usage limit until this time.
        case waiting(Date)
    }

    static func waitingDetail(until date: Date) -> String {
        "Apple Intelligence needs a break · continuing at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// Whether a section's result can be reused if the job runs again.
    private final class SectionOutcome {
        var isComplete = true
    }

    func generateDeck(from source: NoteSource, density: CardDensity, progress: GenerationProgressHandler?) async throws -> GeneratedDeck {
        let notes = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { throw EngineError.noText }
        let instructions = Self.generationInstructions(density: density)
        let chunks = NoteChunker.chunks(of: notes, maxCharacters: Self.onDeviceChunkCharacters)

        do {
            // Notes too long for one on-device request can use Apple's larger cloud model, if enabled.
            if chunks.count > 1, AppConfig.usePrivateCloudCompute {
                if #available(iOS 27.0, macOS 27.0, *),
                   let deck = try? await generateWithCloudModel(notes, density: density, progress: progress) {
                    progress?(GenerationProgress(fraction: 1, detail: "Done"))
                    return deck
                }
            }
            var deck = try await generate(chunks: chunks, density: density, progress: progress) {
                Self.onDeviceSession(instructions)
            }
            if chunks.count > 1 || deck.title.isEmpty {
                progress?(GenerationProgress(fraction: 0.98, detail: "Naming your deck"))
                if let title = try? await Self.deckTitle(for: notes) {
                    deck = GeneratedDeck(title: title, cards: deck.cards)
                }
            }
            progress?(GenerationProgress(fraction: 1, detail: "Done"))
            return deck.title.isEmpty ? GeneratedDeck(title: "My Notes", cards: deck.cards) : deck
        } catch {
            throw Self.friendlyError(error)
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    private func generateWithCloudModel(_ notes: String, density: CardDensity, progress: GenerationProgressHandler?) async throws -> GeneratedDeck? {
        let instructions = Self.generationInstructions(density: density)
        let cloud = PrivateCloudComputeLanguageModel()
        guard cloud.isAvailable else { return nil }
        let contextSize = try await cloud.contextSize
        let chunks = NoteChunker.chunks(of: notes, maxCharacters: Self.chunkCharacters(forContextSize: contextSize))
        return try await generate(chunks: chunks, density: density, progress: progress, model: "cloud") {
            LanguageModelSession(model: cloud, instructions: instructions)
        }
    }

    private func generate(
        chunks: [String],
        density: CardDensity,
        progress: GenerationProgressHandler?,
        model: String = "device",
        makeSession: () -> LanguageModelSession
    ) async throws -> GeneratedDeck {
        var title: String?
        var cards: [GeneratedCard] = []
        var blockedSections = 0

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let request = chunks.count > 1
                ? "Write flashcards for this part of the student's notes. Cover every fact in it."
                : "Write flashcards for the student's notes. Cover every fact in them."
            let label = chunks.count > 1 ? "Section \(index + 1) of \(chunks.count)" : "Writing cards"
            let expectedCards = Double(Self.estimatedCardCount(for: chunk, density: density))
            // Sections share 97% of the bar; naming the deck takes the rest.
            let report = { (withinSection: Double, detail: String) in
                let overall = (Double(index) + min(max(withinSection, 0), 1)) / Double(chunks.count)
                progress?(GenerationProgress(fraction: overall * 0.97, detail: detail))
            }
            report(0, label)
            let cacheKey = SectionCache.key(model: model, density: density, request: request, text: chunk)
            if let cached = SectionCache.shared.entry(for: cacheKey) {
                // Finished before (this job is a retry or a resumed job).
                if title == nil, let cachedTitle = cached.title, !cachedTitle.isEmpty { title = cachedTitle }
                cards += cached.cards
                report(1, label)
                continue
            }
            do {
                let outcome = SectionOutcome()
                let section = try await sectionCards(
                    for: chunk,
                    request: request,
                    density: density,
                    outcome: outcome,
                    onEvent: { event in
                        switch event {
                        case .cards(let count):
                            report(min(0.95, Double(count) / expectedCards), label)
                        case .waiting(let until):
                            let overall = Double(index) / Double(chunks.count) * 0.97
                            progress?(GenerationProgress(fraction: overall, detail: Self.waitingDetail(until: until), waitingUntil: until))
                        }
                    },
                    makeSession: makeSession
                )
                if outcome.isComplete {
                    SectionCache.shared.store(SectionCache.Entry(title: section.title, cards: section.cards), for: cacheKey)
                }
                if title == nil, let sectionTitle = section.title, !sectionTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    title = sectionTitle
                }
                cards += section.cards
            } catch where AppleModelFailure(error) == .guardrail {
                // Skip a section the safety filter rejects rather than failing the whole deck.
                blockedSections += 1
            }
            report(1, label)
        }

        let cleaned = CardWriting.cleaned(cards)
        guard !cleaned.isEmpty else {
            throw blockedSections > 0 ? EngineError.blockedBySafetyFilter : DeckCreator.CreationError.noCards
        }
        return GeneratedDeck(title: title ?? "", cards: cleaned)
    }

    private struct SectionCards {
        var title: String?
        var cards: [GeneratedCard]
    }

    /// Cards for one section of notes. Guided generation always applies Apple's default
    /// guardrails and often refuses ordinary notes about wars, disease, and the like, so a
    /// refused section is retried as plain text under the permissive guardrails.
    private func sectionCards(
        for text: String,
        request: String,
        density: CardDensity,
        outcome: SectionOutcome = SectionOutcome(),
        onEvent: (SectionEvent) -> Void,
        makeSession: () -> LanguageModelSession
    ) async throws -> SectionCards {
        let instructions = Self.generationInstructions(density: density)
        let cap = Self.maximumCardCount(for: text, density: density)
        do {
            let sets = try await cardSets(for: text, request: request, cap: cap, outcome: outcome, onEvent: onEvent, makeSession: makeSession)
            var cards = Self.faithful(sets.flatMap(\.cards).map(\.card), to: text)
            // The model sometimes stops early; top up a thin section with a plain-text pass,
            // unless the usage limit was hit recently (the extra pass is optional).
            if cards.count < Self.minimumCardCount(for: text, density: density), !ModelLimits.wasLimitedRecently {
                let found = cards.count
                let extra = (try? await plainTextCards(
                    for: text, request: request, instructions: instructions, cap: cap, outcome: outcome,
                    onEvent: { event in
                        if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                    }
                )) ?? []
                cards += Self.faithful(extra, to: text)
                    .filter { new in !cards.contains { CardMatcher.isNearDuplicate(new, of: $0) } }
            }
            return SectionCards(title: sets.first?.title, cards: Array(cards.prefix(cap)))
        } catch where AppleModelFailure(error).allowsPlainTextRetry {
            var cards: [GeneratedCard] = []
            var plainTextError: Error?
            for _ in 0..<2 where cards.count < Self.minimumCardCount(for: text, density: density) {
                try Task.checkCancellation()
                let found = cards.count
                let extra: [GeneratedCard]
                do {
                    extra = try await plainTextCards(
                        for: text, request: request, instructions: instructions, cap: cap, outcome: outcome,
                        onEvent: { event in
                            if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                        }
                    )
                } catch where AppleModelFailure(error) != .cancelled {
                    plainTextError = error
                    break
                }
                cards += Self.faithful(extra, to: text)
                    .filter { new in !cards.contains { CardMatcher.isNearDuplicate(new, of: $0) } }
            }
            // A refusal is the more useful error; otherwise report why plain text failed too.
            guard !cards.isEmpty else {
                throw AppleModelFailure(error) == .guardrail ? error : (plainTextError ?? error)
            }
            return SectionCards(title: nil, cards: Array(cards.prefix(cap)))
        }
    }

    private static func sentenceCount(in text: String) -> Int {
        TextDiff.lines(of: text)
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("(Continuing") }
            .reduce(0) { count, line in
                count + max(1, line.split(whereSeparator: { ".!?".contains($0) }).filter { $0.count > 12 }.count)
            }
    }

    /// Rough lower bound on cards for a section, below which it gets a second pass.
    private static func minimumCardCount(for text: String, density: CardDensity) -> Int {
        let share = switch density {
        case .essentials: 0.25
        case .balanced: 0.5
        case .thorough: 0.75
        }
        return Int((Double(sentenceCount(in: text)) * share).rounded(.down))
    }

    /// Typical number of cards for a section, used to report progress while it's written.
    private static func estimatedCardCount(for text: String, density: CardDensity) -> Int {
        let share = switch density {
        case .essentials: 0.4
        case .balanced: 0.9
        case .thorough: 1.2
        }
        return max(1, Int((Double(sentenceCount(in: text)) * share).rounded()))
    }

    /// Most cards worth keeping from a section. The small model sometimes loops, inventing
    /// endless variations ("How does X affect plant growth / height / roots…").
    private static func maximumCardCount(for text: String, density: CardDensity) -> Int {
        max(4, estimatedCardCount(for: text, density: density) * 2)
    }

    /// Drops cards whose answer shares no key words with the notes, which catches invented facts.
    private static func faithful(_ cards: [GeneratedCard], to notes: String) -> [GeneratedCard] {
        let noteWords = CardMatcher.keywords(in: notes)
        return cards.filter { !CardMatcher.isAnswerMissing($0.back, fromNoteWords: noteWords) }
    }

    private static let permissiveModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    private func plainTextCards(
        for text: String,
        request: String,
        instructions: String,
        cap: Int,
        depth: Int = 0,
        outcome: SectionOutcome,
        onEvent: (SectionEvent) -> Void
    ) async throws -> [GeneratedCard] {
        do {
            return try await ModelLimits.run(onWait: { onEvent(.waiting($0)) }) {
                let session = LanguageModelSession(
                    model: Self.permissiveModel,
                    instructions: """
                        \(instructions)

                        Write each card as two lines, then a blank line:
                        Q: <question>
                        A: <answer>
                        Keep each answer short: the name, date, term, or phrase that answers the question, \
                        not the whole sentence from the notes. Write nothing else.
                        """
                )
                let prompt = "\(request)\n\nNOTES:\n\(text)"
                let options = Self.options(maxTokens: min(3_000, 200 + cap * 50))
                var latest = ""
                var end = ModelLimits.StreamEnd.finished
                do {
                    (_, end) = try await ModelLimits.watch(
                        produce: { box in
                            for try await snapshot in session.streamResponse(to: prompt, options: options) {
                                box.update(snapshot.content)
                                if box.isStopRequested { break }
                            }
                        },
                        onOutput: { (content: String, stop) in
                            latest = content
                            let count = Self.answerCount(in: content)
                            onEvent(.cards(count))
                            if count > cap { stop() }
                        }
                    )
                } catch where !(error is CancellationError) && !Self.parsePlainTextCards(latest).isEmpty {
                    // Keep the cards written before the model stopped.
                    end = .stalled
                }
                let cards = Self.parsePlainTextCards(latest)
                if end == .stalled {
                    guard cards.count >= max(1, cap / 4) else { throw ModelLimits.Stalled() }
                    outcome.isComplete = false
                }
                return Array(cards.prefix(cap))
            }
        } catch where [.contextExceeded, .timeout].contains(AppleModelFailure(error)) && depth < 3 {
            var cards: [GeneratedCard] = []
            for half in NoteChunker.halves(of: text) where half != text {
                let found = cards.count
                cards += try await plainTextCards(
                    for: half, request: request, instructions: instructions, cap: cap, depth: depth + 1, outcome: outcome,
                    onEvent: { event in
                        if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                    }
                )
            }
            return cards
        }
    }

    private static func answerCount(in text: String) -> Int {
        text.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t*-•"))
            return trimmed.hasPrefix("A:") || trimmed.lowercased().hasPrefix("answer:")
        }.count
    }

    /// Parses "Q: … / A: …" pairs, tolerating list markers and bold markup.
    static func parsePlainTextCards(_ text: String) -> [GeneratedCard] {
        var cards: [GeneratedCard] = []
        var question: String?
        let markers = CharacterSet(charactersIn: " \t*-•#.)").union(.decimalDigits)
        for rawLine in text.components(separatedBy: .newlines) {
            let line = String(rawLine.unicodeScalars.drop(while: markers.contains))
                .trimmingCharacters(in: .whitespaces)
            if let value = value(of: line, labels: ["Q:", "Question:"]) {
                question = value
            } else if let value = value(of: line, labels: ["A:", "Answer:"]), let current = question {
                cards.append(GeneratedCard(front: current, back: value))
                question = nil
            }
        }
        return cards
    }

    private static func value(of line: String, labels: [String]) -> String? {
        for label in labels where line.lowercased().hasPrefix(label.lowercased()) {
            let value = line.dropFirst(label.count).trimmingCharacters(in: CharacterSet(charactersIn: " *"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Generates cards for one section, streaming so progress can be reported. Halves the
    /// section if the model runs past its context window (the small model occasionally
    /// rambles even on short notes), and waits out usage limits.
    private func cardSets(
        for text: String,
        request: String,
        cap: Int,
        depth: Int = 0,
        outcome: SectionOutcome,
        onEvent: (SectionEvent) -> Void,
        makeSession: () -> LanguageModelSession
    ) async throws -> [AppleCardSet] {
        let prompt = """
            \(request)

            NOTES:
            \(text)
            """
        do {
            return try await ModelLimits.run(onWait: { onEvent(.waiting($0)) }) {
                let session = makeSession()
                let options = Self.options(maxTokens: min(4_000, 300 + cap * 75))
                var latest: AppleCardSet.PartiallyGenerated?
                var end = ModelLimits.StreamEnd.finished
                do {
                    (_, end) = try await ModelLimits.watch(
                        produce: { box in
                            for try await snapshot in session.streamResponse(to: prompt, generating: AppleCardSet.self, options: options) {
                                box.update(snapshot.content)
                                if box.isStopRequested { break }
                            }
                        },
                        onOutput: { (content: AppleCardSet.PartiallyGenerated, stop) in
                            latest = content
                            let count = content.cards?.count ?? 0
                            onEvent(.cards(count))
                            // Stop a runaway response; the cards written so far are kept below.
                            if count > cap { stop() }
                        }
                    )
                } catch where !(error is CancellationError) && !Self.completeCards(in: latest).isEmpty {
                    // The model stopped partway (for example at its length cap); keep what it wrote.
                    end = .stalled
                }
                if end == .stalled {
                    // Keep a stalled response only if it got a good way through the section.
                    guard Self.completeCards(in: latest).count >= max(1, cap / 4) else { throw ModelLimits.Stalled() }
                    outcome.isComplete = false
                }
                guard let latest else { throw EngineError.generationFailed("The model returned no output.") }
                // Build the result from the last snapshot rather than re-parsing the raw output.
                let cards = Array(Self.completeCards(in: latest).prefix(cap))
                return [AppleCardSet(title: latest.title ?? "", cards: cards)]
            }
        } catch where [.contextExceeded, .timeout].contains(AppleModelFailure(error)) && depth < 3 {
            let halves = NoteChunker.halves(of: text)
            guard halves.count > 1 else { throw error }
            var sets: [AppleCardSet] = []
            for half in halves {
                let found = sets.reduce(0) { $0 + $1.cards.count }
                sets += try await cardSets(
                    for: half, request: request, cap: cap, depth: depth + 1, outcome: outcome,
                    onEvent: { event in
                        if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                    },
                    makeSession: makeSession
                )
            }
            return sets
        }
    }

    private static func completeCards(in snapshot: AppleCardSet.PartiallyGenerated?) -> [AppleCard] {
        (snapshot?.cards ?? []).compactMap { partial -> AppleCard? in
            guard let question = partial.question, let answer = partial.answer,
                  !question.isEmpty, !answer.isEmpty else { return nil }
            return AppleCard(fact: partial.fact ?? "", question: question, answer: answer)
        }
    }

    /// Names a multi-section deck: its top-level heading if it opens with one, otherwise a
    /// model-suggested title based on its headings (or its opening, if it has none).
    private static func deckTitle(for notes: String) async throws -> String? {
        if let first = TextDiff.lines(of: notes).first, first.hasPrefix("# ") {
            let heading = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return String(heading.prefix(80)) }
        }
        let headings = TextDiff.lines(of: notes)
            .filter { $0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .prefix(30)
        let outline = headings.isEmpty ? String(notes.prefix(600)) : headings.joined(separator: "\n")
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: "You name flashcard decks made from a student's notes."
        )
        let titleOptions = options(maxTokens: 64)
        let response = try await ModelLimits.withTimeout(20) {
            try await session.respond(
                to: "Suggest a title for a flashcard deck made from notes covering:\n\(outline)",
                generating: AppleDeckTitle.self,
                options: titleOptions
            ).content
        }
        let title = response.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: Revision

    func reviseDeck(
        existing: [ExistingCard],
        changes: NoteChanges,
        updatedNotes: String,
        density: CardDensity,
        progress: GenerationProgressHandler?
    ) async throws -> DeckRevision {
        let editable = existing.filter { !$0.locked }
        let noteLines = TextDiff.lines(of: updatedNotes)
        let noteWords = CardMatcher.keywords(in: updatedNotes)
        var revision = DeckRevision(updated: [], removed: [], added: [])
        // The small model does best with one contiguous edit at a time.
        let hunks = changes.hunks
            .flatMap(\.changeBlocks)
            .flatMap { $0.split(maxCharacters: Self.onDeviceChunkCharacters / 2) }

        do {
            for (index, hunk) in hunks.enumerated() {
                try Task.checkCancellation()
                let label = hunks.count > 1 ? "Change \(index + 1) of \(hunks.count)" : "Updating cards"
                let report = { (withinChange: Double, detail: String) in
                    let overall = (Double(index) + min(max(withinChange, 0), 1)) / Double(hunks.count)
                    progress?(GenerationProgress(fraction: overall * 0.98, detail: detail))
                }
                report(0, label)
                do {
                    try await review(hunk, cards: editable, noteWords: noteWords, into: &revision)
                } catch where AppleModelFailure(error) == .guardrail {
                    revision.skippedSections += 1
                }
                report(0.35, label)
                let expectedCards = Double(Self.estimatedCardCount(for: hunk.added.joined(separator: "\n"), density: density))
                do {
                    try await writeCards(
                        forAddedLinesIn: hunk, noteLines: noteLines, density: density,
                        onEvent: { event in
                            switch event {
                            case .cards(let count): report(0.35 + 0.6 * min(1, Double(count) / expectedCards), label)
                            case .waiting(let until):
                                let overall = (Double(index) + 0.35) / Double(hunks.count) * 0.98
                                progress?(GenerationProgress(fraction: overall, detail: Self.waitingDetail(until: until), waitingUntil: until))
                            }
                        },
                        into: &revision
                    )
                } catch where AppleModelFailure(error) == .guardrail {
                    revision.skippedSections += 1
                }
                report(1, label)
            }
        } catch {
            throw Self.friendlyError(error)
        }

        // Big deletions can touch more cards than the model reviewed. A card whose answer came
        // from deleted text and no longer appears anywhere in the notes is stale.
        let removedLines = hunks.flatMap(\.removed).filter { !$0.hasPrefix("#") }
        let removedWords = CardMatcher.keywords(in: removedLines.joined(separator: " "))
        let removedLineWords = removedLines.map(CardMatcher.keywords(in:))
        let noteLineWords = noteLines.filter { !$0.hasPrefix("#") }.map(CardMatcher.keywords(in:))
        let handled = Set(revision.removed).union(revision.updated.map(\.id))
        for card in editable where !handled.contains(card.id) {
            let answerWords = CardMatcher.keywords(in: card.back)
            let answerGone = !answerWords.isDisjoint(with: removedWords)
                && CardMatcher.isAnswerMissing(card.back, fromNoteWords: noteWords)
            if answerGone || CardMatcher.isSourcedFromRemovedText(
                card, removedLines: removedLineWords, noteLines: noteLineWords
            ) {
                revision.removed.append(card.id)
            }
        }

        // Keep only new cards that don't repeat a card staying in the deck.
        let removedIDs = Set(revision.removed)
        let updatedByID = Dictionary(revision.updated.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let remaining = existing
            .filter { !removedIDs.contains($0.id) }
            .map { card in
                let edit = updatedByID[card.id]
                return GeneratedCard(front: edit?.front ?? card.front, back: edit?.back ?? card.back)
            }
        let keptFronts = Set(remaining.map { CardWriting.normalizedKey($0.front) })
        revision.added = CardWriting.cleaned(revision.added, excludingFronts: keptFronts)
            .filter { new in !remaining.contains { CardMatcher.isNearDuplicate(new, of: $0) } }
        revision.updated = Array(updatedByID.values)
        progress?(GenerationProgress(fraction: 1, detail: "Done"))
        return revision
    }

    /// Decides keep/update/remove for the cards related to the lines this hunk removed,
    /// a few cards at a time so large edits are fully covered.
    private func review(
        _ hunk: TextDiff.Hunk,
        cards: [ExistingCard],
        noteWords: Set<String>,
        into revision: inout DeckRevision
    ) async throws {
        guard !hunk.removed.isEmpty else { return }
        let related = CardMatcher.related(to: hunk, in: cards, limit: Self.maxReviewedCards)
        for start in stride(from: 0, to: related.count, by: Self.reviewBatchSize) {
            try Task.checkCancellation()
            let batch = related[start..<min(start + Self.reviewBatchSize, related.count)]
                .filter { card in !revision.removed.contains(card.id) && !revision.updated.contains { $0.id == card.id } }
            guard !batch.isEmpty else { continue }
            try await review(hunk, batch: Array(batch), noteWords: noteWords, into: &revision)
        }
    }

    private func review(
        _ hunk: TextDiff.Hunk,
        batch related: [ExistingCard],
        noteWords: Set<String>,
        depth: Int = 0,
        into revision: inout DeckRevision
    ) async throws {
        let decisions: [ReviewDecision]
        do {
            decisions = try await Self.reviewDecisions(for: hunk, cards: related)
        } catch where [.contextExceeded, .timeout].contains(AppleModelFailure(error)) && depth < 3 {
            let pieces = hunk.split(maxCharacters: max(200, hunk.characterCount / 2))
            guard pieces.count > 1 else { throw error }
            for piece in pieces {
                try await review(piece, batch: related, noteWords: noteWords, depth: depth + 1, into: &revision)
            }
            return
        }

        var decisionsByID: [String: ReviewDecision] = [:]
        for decision in decisions {
            let id = Self.normalizedID(decision.id)
            if decisionsByID[id] == nil { decisionsByID[id] = decision }
        }

        // Only act on the cards we showed the model. A card whose answer no longer appears
        // anywhere in the notes is stale even if the model missed it.
        for card in related {
            let isStale = CardMatcher.isAnswerMissing(card.back, fromNoteWords: noteWords)
            guard let decision = decisionsByID[card.id], decision.action != .keep else {
                if isStale { revision.removed.append(card.id) }
                continue
            }
            let front = decision.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = decision.back.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRealUpdate = decision.action == .update
                && !front.isEmpty && !back.isEmpty
                && (CardWriting.normalizedKey(front) != CardWriting.normalizedKey(card.front)
                    || CardWriting.normalizedKey(back) != CardWriting.normalizedKey(card.back))
                && !CardMatcher.isAnswerMissing(back, fromNoteWords: noteWords)
                && !Self.isBloated(back, comparedTo: card.back)
            if isRealUpdate {
                revision.updated.append(CardRevision(id: card.id, front: front, back: back))
            } else if decision.action == .remove || isStale {
                revision.removed.append(card.id)
            }
        }
    }

    private struct ReviewDecision {
        var id: String
        var action: AppleCardAction
        var front: String
        var back: String
    }

    /// Asks the model what to do with each card. History and other sensitive subjects can trip
    /// the guardrails for structured output, so a refused review is retried as plain text
    /// under the permissive guardrails.
    private static func reviewDecisions(for hunk: TextDiff.Hunk, cards: [ExistingCard]) async throws -> [ReviewDecision] {
        let prompt = reviewPrompt(hunk: hunk, cards: cards)
        do {
            let reviewOptions = options(maxTokens: 400 + cards.count * 120)
            let review = try await ModelLimits.run {
                try await ModelLimits.withTimeout {
                    try await onDeviceSession(reviewInstructions).respond(
                        to: prompt, generating: AppleCardReview.self, options: reviewOptions
                    ).content
                }
            }
            return review.decisions.map { decision in
                ReviewDecision(
                    id: decision.id,
                    action: decision.stillCorrect ? .keep : decision.action,
                    front: decision.front,
                    back: decision.back
                )
            }
        } catch where AppleModelFailure(error).allowsPlainTextRetry {
            let session = LanguageModelSession(
                model: permissiveModel,
                instructions: """
                    \(reviewInstructions)
                    Answer with one line per card and nothing else, in this format:
                    c1: keep
                    c2: remove
                    c3: update | <corrected question> | <corrected answer>
                    """
            )
            let textOptions = options(maxTokens: 200 + cards.count * 60)
            let text = try await ModelLimits.run {
                try await ModelLimits.withTimeout {
                    try await session.respond(to: prompt, options: textOptions).content
                }
            }
            return parsePlainTextReviewDecisions(text)
        }
    }

    /// Parses "c3: update | question | answer" lines, tolerating list markers and brackets.
    static func parsePlainTextReview(_ text: String) -> [(id: String, action: String, front: String, back: String)] {
        parsePlainTextReviewDecisions(text).map { ($0.id, "\($0.action)", $0.front, $0.back) }
    }

    private static func parsePlainTextReviewDecisions(_ text: String) -> [ReviewDecision] {
        let pattern = #/^[\W\d_]*(c\d+)\W*?[:\-–]\s*\**\s*(keep|update|remove)\b\**(.*)$/#.ignoresCase()
        var decisions: [ReviewDecision] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(of: pattern) else { continue }
            let action: AppleCardAction = switch match.2.lowercased() {
            case "update": .update
            case "remove": .remove
            default: .keep
            }
            let parts = match.3.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            decisions.append(ReviewDecision(
                id: String(match.1).lowercased(),
                action: action,
                front: parts.count >= 2 ? parts[0] : "",
                back: parts.count >= 2 ? parts[1] : ""
            ))
        }
        return decisions
    }

    /// Writes cards for the lines this hunk added, using the nearest heading as context.
    private func writeCards(
        forAddedLinesIn hunk: TextDiff.Hunk,
        noteLines: [String],
        density: CardDensity,
        onEvent: (SectionEvent) -> Void,
        into revision: inout DeckRevision
    ) async throws {
        let added = hunk.added.filter { !$0.hasPrefix("#") }
        guard !added.isEmpty else { return }

        var request = "These lines were just added to the student's notes. Write flashcards only for the facts in these lines."
        var sourceText = added.joined(separator: " ")
        if let firstIndex = noteLines.firstIndex(of: added[0]),
           let heading = noteLines[..<firstIndex].last(where: { $0.hasPrefix("#") }) {
            let topic = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            request += " They belong to the section \"\(topic)\"."
            sourceText += " " + topic
        }

        let instructions = Self.generationInstructions(density: density)
        let section = try await sectionCards(
            for: added.joined(separator: "\n"),
            request: request,
            density: density,
            onEvent: onEvent,
            makeSession: { Self.onDeviceSession(instructions) }
        )
        // With only a few lines of context the model sometimes answers from general knowledge.
        let sourceWords = CardMatcher.keywords(in: sourceText)
        revision.added += section.cards.filter { card in
            let answerWords = CardMatcher.keywords(in: card.back)
            guard answerWords.count >= 2 else { return true }
            return answerWords.intersection(sourceWords).count * 2 >= answerWords.count
        }
    }

    // MARK: Prompts

    private static func generationInstructions(density: CardDensity) -> String {
        """
        You write study flashcards from a student's class notes. Each card asks one question \
        about one fact in the notes. Stay faithful to the notes and don't add facts they don't \
        contain. Skip headings, and don't ask yes/no or true/false questions. Ask about the \
        subject itself, never about the notes, the slides, or what a speaker said or mentioned. \
        Write plain text.

        Deck size: \(density.promptGuidance)
        """
    }

    private static let reviewInstructions = """
        You keep a student's flashcards correct after they edit their class notes. \
        For each card you are shown, first decide whether its answer is still true after the edit. \
        Extra details added to the notes don't make a card wrong. Then choose:
        - keep: the card is still correct.
        - update: the notes now give a different answer. Give the corrected question and answer, in the same style.
        - remove: the notes no longer cover what the card asks.
        """

    private static func reviewPrompt(hunk: TextDiff.Hunk, cards: [ExistingCard]) -> String {
        let removed = hunk.removed.map { "- \($0)" }.joined(separator: "\n")
        let added = hunk.added.isEmpty ? "(none; the lines were deleted)" : hunk.added.map { "- \($0)" }.joined(separator: "\n")
        let cardList = cards
            .map { "[\($0.id)] front: \($0.front) | back: \($0.back)" }
            .joined(separator: "\n")
        return """
            REMOVED LINES:
            \(removed)

            LINES ADDED IN THEIR PLACE:
            \(added)

            CARDS:
            \(cardList)

            Decide keep, update, or remove for each card.
            """
    }

    /// An updated answer that balloons past the original usually means the model merged in unrelated facts.
    private static func isBloated(_ answer: String, comparedTo original: String) -> Bool {
        let newCount = answer.split(whereSeparator: \.isWhitespace).count
        let oldCount = original.split(whereSeparator: \.isWhitespace).count
        return newCount > 12 && newCount > oldCount * 2 + 4
    }

    private static func normalizedID(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
    }

    private static func friendlyError(_ error: Error) -> Error {
        switch AppleModelFailure(error) {
        case .guardrail: EngineError.blockedBySafetyFilter
        case .rateLimited, .busy:
            error as? EngineError ?? EngineError.rateLimited(
                resumeAt: ModelLimits.resetDate(of: error) ?? Date.now.addingTimeInterval(5 * 60),
                detail: String(reflecting: error)
            )
        case .unsupportedLanguage: EngineError.unsupportedLanguage
        case .contextExceeded: EngineError.tooLong
        case .timeout, .stalled: EngineError.timedOut
        case .assetsUnavailable: EngineError.modelNotReady(String(reflecting: error))
        case .cancelled: error
        case .structuredOutput, .other:
            // Keep the app's own errors; replace the framework's opaque ones, keeping their details for the log.
            error is EngineError || error is DeckCreator.CreationError
                ? error : EngineError.generationFailed(String(reflecting: error))
        }
    }
}

/// Buckets Foundation Models errors across the iOS 26 and iOS 27 error types.
nonisolated enum AppleModelFailure: Equatable {
    case contextExceeded
    case guardrail
    case rateLimited
    /// The session is still answering an earlier request.
    case busy
    /// A response stopped arriving and was cancelled.
    case stalled
    case unsupportedLanguage
    /// The model's assets aren't on the device yet (downloading or updating).
    case assetsUnavailable
    /// The request took too long; a smaller request may finish.
    case timeout
    /// Guided generation couldn't produce or parse structured output.
    case structuredOutput
    case cancelled
    case other

    init(_ error: Error) {
        if error is CancellationError {
            self = .cancelled
            return
        }
        if case .rateLimited? = error as? AppleFlashcardEngine.EngineError {
            self = .rateLimited
            return
        }
        if error is ModelLimits.Stalled {
            self = .stalled
            return
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: self = .contextExceeded
            case .guardrailViolation, .refusal: self = .guardrail
            case .rateLimited: self = .rateLimited
            case .concurrentRequests: self = .busy
            case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
            case .assetsUnavailable: self = .assetsUnavailable
            case .decodingFailure, .unsupportedGuide: self = .structuredOutput
            default: self = .other
            }
            return
        }
        if #available(iOS 27.0, macOS 27.0, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: self = .contextExceeded
                case .guardrailViolation, .refusal: self = .guardrail
                case .rateLimited: self = .rateLimited
                case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
                case .timeout: self = .timeout
                case .unsupportedGenerationGuide: self = .structuredOutput
                default: self = .other
                }
                return
            }
            if let error = error as? LanguageModelSession.Error, error == .concurrentRequests {
                self = .busy
                return
            }
            if error is SystemLanguageModel.Error {
                self = .assetsUnavailable
                return
            }
            if error is GeneratedContent.ParsingError {
                self = .structuredOutput
                return
            }
        }
        if Self.involvesModelManager(error as NSError) {
            self = .assetsUnavailable
            return
        }
        self = .other
    }

    /// Worth retrying as a plain-text request under the permissive guardrails.
    var allowsPlainTextRetry: Bool {
        switch self {
        case .guardrail, .structuredOutput, .timeout, .stalled, .other: true
        default: false
        }
    }

    /// Errors from the system's model manager mean the model itself couldn't be loaded.
    private static func involvesModelManager(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain.contains("ModelManager") { return true }
        guard depth < 4 else { return false }
        var underlying = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? []
        if let single = error.userInfo[NSUnderlyingErrorKey] as? NSError { underlying.append(single) }
        return underlying.contains { involvesModelManager($0, depth: depth + 1) }
    }
}
