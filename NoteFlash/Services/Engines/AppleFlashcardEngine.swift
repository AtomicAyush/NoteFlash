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
        case rateLimited
        case unsupportedLanguage
        case tooLong
        case noText
        case generationFailed

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                reason
            case .blockedBySafetyFilter:
                "Apple Intelligence's safety filter declined these notes. Try switching to Claude in Settings."
            case .rateLimited:
                "Apple Intelligence is busy. Try again in a moment."
            case .unsupportedLanguage:
                "Apple Intelligence doesn't support the language of these notes yet. Try switching to Claude in Settings."
            case .tooLong:
                "Part of these notes is too long for Apple Intelligence to read at once. Try adding line breaks or headings."
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
    private static let maxRelatedCards = 10

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
        case waiting
    }

    /// iOS limits on-device model use in the background; retry for about a minute before giving up.
    private static let rateLimitRetries = 12

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
        return try await generate(chunks: chunks, density: density, progress: progress) {
            LanguageModelSession(model: cloud, instructions: instructions)
        }
    }

    private func generate(
        chunks: [String],
        density: CardDensity,
        progress: GenerationProgressHandler?,
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
            do {
                let section = try await sectionCards(
                    for: chunk,
                    request: request,
                    density: density,
                    onEvent: { event in
                        switch event {
                        case .cards(let count):
                            report(min(0.95, Double(count) / expectedCards), label)
                        case .waiting:
                            report(0, "Waiting for Apple Intelligence")
                        }
                    },
                    makeSession: makeSession
                )
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
        onEvent: (SectionEvent) -> Void,
        makeSession: () -> LanguageModelSession
    ) async throws -> SectionCards {
        let instructions = Self.generationInstructions(density: density)
        let cap = Self.maximumCardCount(for: text, density: density)
        do {
            let sets = try await cardSets(for: text, request: request, cap: cap, onEvent: onEvent, makeSession: makeSession)
            var cards = Self.faithful(sets.flatMap(\.cards).map(\.card), to: text)
            // The model sometimes stops early; top up a thin section with a plain-text pass.
            if cards.count < Self.minimumCardCount(for: text, density: density) {
                let found = cards.count
                let extra = (try? await plainTextCards(
                    for: text, request: request, instructions: instructions, cap: cap,
                    onEvent: { event in
                        if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                    }
                )) ?? []
                cards += Self.faithful(extra, to: text)
                    .filter { new in !cards.contains { CardMatcher.isNearDuplicate(new, of: $0) } }
            }
            return SectionCards(title: sets.first?.title, cards: Array(cards.prefix(cap)))
        } catch where AppleModelFailure(error) == .guardrail {
            var cards: [GeneratedCard] = []
            for _ in 0..<2 where cards.count < Self.minimumCardCount(for: text, density: density) {
                let found = cards.count
                let extra = (try? await plainTextCards(
                    for: text, request: request, instructions: instructions, cap: cap,
                    onEvent: { event in
                        if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                    }
                )) ?? []
                cards += Self.faithful(extra, to: text)
                    .filter { new in !cards.contains { CardMatcher.isNearDuplicate(new, of: $0) } }
            }
            guard !cards.isEmpty else { throw error }
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
        attempt: Int = 0,
        onEvent: (SectionEvent) -> Void
    ) async throws -> [GeneratedCard] {
        let session = LanguageModelSession(
            model: Self.permissiveModel,
            instructions: """
                \(instructions)

                Write each card as two lines, then a blank line:
                Q: <question>
                A: <answer>
                Write nothing else.
                """
        )
        do {
            var latest = ""
            let stream = session.streamResponse(to: "\(request)\n\nNOTES:\n\(text)", options: Self.options)
            for try await snapshot in stream {
                latest = snapshot.content
                let count = Self.answerCount(in: latest)
                onEvent(.cards(count))
                if count > cap { break }
            }
            return Array(Self.parsePlainTextCards(latest).prefix(cap))
        } catch where AppleModelFailure(error) == .rateLimited && attempt < Self.rateLimitRetries {
            onEvent(.waiting)
            try await Task.sleep(for: .seconds(5))
            return try await plainTextCards(
                for: text, request: request, instructions: instructions,
                cap: cap, depth: depth, attempt: attempt + 1, onEvent: onEvent
            )
        } catch where AppleModelFailure(error) == .contextExceeded && depth < 3 {
            var cards: [GeneratedCard] = []
            for half in NoteChunker.halves(of: text) where half != text {
                let found = cards.count
                cards += try await plainTextCards(
                    for: half, request: request, instructions: instructions, cap: cap, depth: depth + 1,
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
    /// rambles even on short notes), and waits out background rate limits.
    private func cardSets(
        for text: String,
        request: String,
        cap: Int,
        depth: Int = 0,
        attempt: Int = 0,
        onEvent: (SectionEvent) -> Void,
        makeSession: () -> LanguageModelSession
    ) async throws -> [AppleCardSet] {
        let prompt = """
            \(request)

            NOTES:
            \(text)
            """
        do {
            let stream = makeSession().streamResponse(to: prompt, generating: AppleCardSet.self, options: Self.options)
            var latest: GeneratedContent?
            for try await snapshot in stream {
                latest = snapshot.rawContent
                let partialCards = snapshot.content.cards ?? []
                onEvent(.cards(partialCards.count))
                if partialCards.count > cap {
                    // Stop a runaway response and keep the cards written so far (all but the last are complete).
                    let complete = partialCards.prefix(cap).compactMap { partial -> AppleCard? in
                        guard let question = partial.question, let answer = partial.answer else { return nil }
                        return AppleCard(fact: partial.fact ?? "", question: question, answer: answer)
                    }
                    return [AppleCardSet(title: snapshot.content.title ?? "", cards: complete)]
                }
            }
            if let latest, let set = try? AppleCardSet(latest) {
                return [set]
            }
            return [try await stream.collect().content]
        } catch where AppleModelFailure(error) == .rateLimited && attempt < Self.rateLimitRetries {
            onEvent(.waiting)
            try await Task.sleep(for: .seconds(5))
            return try await cardSets(
                for: text, request: request, cap: cap, depth: depth, attempt: attempt + 1,
                onEvent: onEvent, makeSession: makeSession
            )
        } catch where AppleModelFailure(error) == .contextExceeded && depth < 3 {
            let halves = NoteChunker.halves(of: text)
            guard halves.count > 1 else { throw error }
            var sets: [AppleCardSet] = []
            for half in halves {
                let found = sets.reduce(0) { $0 + $1.cards.count }
                sets += try await cardSets(
                    for: half, request: request, cap: cap, depth: depth + 1,
                    onEvent: { event in
                        if case .cards(let count) = event { onEvent(.cards(found + count)) } else { onEvent(event) }
                    },
                    makeSession: makeSession
                )
            }
            return sets
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
        let response = try await session.respond(
            to: "Suggest a title for a flashcard deck made from notes covering:\n\(outline)",
            generating: AppleDeckTitle.self,
            options: options
        )
        let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: Revision

    func reviseDeck(
        existing: [ExistingCard],
        changes: NoteChanges,
        updatedNotes: String,
        density: CardDensity
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
            for hunk in hunks {
                try Task.checkCancellation()
                do {
                    try await review(hunk, cards: editable, noteWords: noteWords, into: &revision)
                } catch where AppleModelFailure(error) == .guardrail {
                    revision.skippedSections += 1
                }
                do {
                    try await writeCards(forAddedLinesIn: hunk, noteLines: noteLines, density: density, into: &revision)
                } catch where AppleModelFailure(error) == .guardrail {
                    revision.skippedSections += 1
                }
            }
        } catch {
            throw Self.friendlyError(error)
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
        return revision
    }

    /// Decides keep/update/remove for the cards related to the lines this hunk removed.
    private func review(
        _ hunk: TextDiff.Hunk,
        cards: [ExistingCard],
        noteWords: Set<String>,
        depth: Int = 0,
        into revision: inout DeckRevision
    ) async throws {
        guard !hunk.removed.isEmpty else { return }
        let related = CardMatcher.related(to: hunk, in: cards, limit: Self.maxRelatedCards)
            .filter { card in !revision.removed.contains(card.id) && !revision.updated.contains { $0.id == card.id } }
        guard !related.isEmpty else { return }

        let decisions: [AppleCardDecision]
        do {
            decisions = try await Self.onDeviceSession(Self.reviewInstructions).respond(
                to: Self.reviewPrompt(hunk: hunk, cards: related),
                generating: AppleCardReview.self,
                options: Self.options
            ).content.decisions
        } catch where AppleModelFailure(error) == .contextExceeded && depth < 3 {
            let pieces = hunk.split(maxCharacters: max(200, hunk.characterCount / 2))
            guard pieces.count > 1 else { throw error }
            for piece in pieces {
                try await review(piece, cards: cards, noteWords: noteWords, depth: depth + 1, into: &revision)
            }
            return
        }

        var decisionsByID: [String: AppleCardDecision] = [:]
        for decision in decisions {
            let id = Self.normalizedID(decision.id)
            if decisionsByID[id] == nil { decisionsByID[id] = decision }
        }

        // Only act on the cards we showed the model. A card whose answer no longer appears
        // anywhere in the notes is stale even if the model missed it.
        for card in related {
            let isStale = CardMatcher.isAnswerMissing(card.back, fromNoteWords: noteWords)
            guard let decision = decisionsByID[card.id], !decision.stillCorrect else {
                if isStale { revision.removed.append(card.id) }
                continue
            }
            let front = decision.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = decision.back.trimmingCharacters(in: .whitespacesAndNewlines)
            let isRealUpdate = decision.action == .update
                && !front.isEmpty && !back.isEmpty
                && (front != card.front || back != card.back)
                && !CardMatcher.isAnswerMissing(back, fromNoteWords: noteWords)
                && !Self.isBloated(back, comparedTo: card.back)
            if isRealUpdate {
                revision.updated.append(CardRevision(id: card.id, front: front, back: back))
            } else if decision.action == .remove || isStale {
                revision.removed.append(card.id)
            }
        }
    }

    /// Writes cards for the lines this hunk added, using the nearest heading as context.
    private func writeCards(
        forAddedLinesIn hunk: TextDiff.Hunk,
        noteLines: [String],
        density: CardDensity,
        into revision: inout DeckRevision
    ) async throws {
        let added = hunk.added.filter { !$0.hasPrefix("#") }
        guard !added.isEmpty else { return }

        var request = "These lines were just added to the student's notes. Write flashcards only for the facts in these lines."
        if let firstIndex = noteLines.firstIndex(of: added[0]),
           let heading = noteLines[..<firstIndex].last(where: { $0.hasPrefix("#") }) {
            let topic = heading.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            request += " They belong to the section \"\(topic)\"."
        }

        let instructions = Self.generationInstructions(density: density)
        let section = try await sectionCards(
            for: added.joined(separator: "\n"),
            request: request,
            density: density,
            onEvent: { _ in },
            makeSession: { Self.onDeviceSession(instructions) }
        )
        revision.added += section.cards
    }

    // MARK: Prompts

    private static func generationInstructions(density: CardDensity) -> String {
        """
        You write study flashcards from a student's class notes. Each card asks one question \
        about one fact in the notes. Stay faithful to the notes and don't add facts they don't \
        contain. Skip headings, and don't ask yes/no or true/false questions. Write plain text.

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
        case .rateLimited: EngineError.rateLimited
        case .unsupportedLanguage: EngineError.unsupportedLanguage
        case .contextExceeded: EngineError.tooLong
        case .other:
            // Keep the app's own errors; replace the framework's opaque ones.
            error is CancellationError || error is EngineError || error is DeckCreator.CreationError
                ? error : EngineError.generationFailed
        }
    }
}

/// Buckets Foundation Models errors across the iOS 26 and iOS 27 error types.
nonisolated enum AppleModelFailure: Equatable {
    case contextExceeded
    case guardrail
    case rateLimited
    case unsupportedLanguage
    case other

    init(_ error: Error) {
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: self = .contextExceeded
            case .guardrailViolation, .refusal: self = .guardrail
            case .rateLimited, .concurrentRequests: self = .rateLimited
            case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
            default: self = .other
            }
            return
        }
        if #available(iOS 27.0, macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded: self = .contextExceeded
            case .guardrailViolation, .refusal: self = .guardrail
            case .rateLimited: self = .rateLimited
            case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
            default: self = .other
            }
            return
        }
        self = .other
    }
}
