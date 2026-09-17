import Foundation

// MARK: - Shared types

nonisolated struct GeneratedCard: Codable, Sendable {
    let front: String
    let back: String
}

nonisolated struct GeneratedDeck: Decodable, Sendable {
    let title: String
    let cards: [GeneratedCard]
}

nonisolated struct CardRevision: Decodable, Sendable {
    let id: String
    let front: String
    let back: String
}

/// Changes an engine proposes after the source notes are edited.
nonisolated struct DeckRevision: Sendable {
    var updated: [CardRevision]
    var removed: [String]
    var added: [GeneratedCard]
    /// Edited sections the engine declined to process (e.g. blocked by a safety filter).
    var skippedSections = 0

    var isEmpty: Bool { updated.isEmpty && removed.isEmpty && added.isEmpty }
}

/// A card as shown to the model during revision. `id` is a short local key, not the card's UUID.
nonisolated struct ExistingCard: Encodable, Sendable {
    let id: String
    let front: String
    let back: String
    let locked: Bool
}

nonisolated enum NoteSource: Sendable {
    case text(String)
    /// A PDF along with its extracted (and OCR'd) text.
    case pdf(data: Data, text: String)

    var text: String {
        switch self {
        case .text(let text): text
        case .pdf(_, let text): text
        }
    }
}

/// How far along an engine is with writing a deck.
nonisolated struct GenerationProgress: Sendable {
    /// Share of the AI work that's done, from 0 to 1.
    var fraction: Double
    /// Short status, e.g. "Section 2 of 5".
    var detail: String
    /// Set while the engine waits out a usage limit, until the time it continues.
    var waitingUntil: Date? = nil
}

typealias GenerationProgressHandler = @Sendable (GenerationProgress) -> Void

// MARK: - Engine

/// Something that can write flashcards from notes and revise them when the notes change.
nonisolated protocol FlashcardEngine: Sendable {
    func generateDeck(
        from source: NoteSource,
        density: CardDensity,
        progress: GenerationProgressHandler?
    ) async throws -> GeneratedDeck

    func reviseDeck(
        existing: [ExistingCard],
        changes: NoteChanges,
        updatedNotes: String,
        density: CardDensity,
        progress: GenerationProgressHandler?
    ) async throws -> DeckRevision
}

nonisolated enum AIEngineKind: String, CaseIterable, Identifiable, Sendable {
    case apple
    case claude

    static let storageKey = "aiEngine"

    /// The engine chosen in Settings (Apple Intelligence unless changed).
    static var selected: AIEngineKind {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AIEngineKind.init(rawValue:)) ?? .apple
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: "Apple Intelligence"
        case .claude: "Claude"
        }
    }

    /// Why this engine can't run right now, or nil when it's ready.
    var setupProblem: String? {
        switch self {
        case .apple:
            AppleFlashcardEngine.unavailableReason
        case .claude:
            KeychainStore.string(for: .anthropicAPIKey) == nil
                ? "Add your Claude API key in Settings, or switch to Apple Intelligence."
                : nil
        }
    }

    func makeEngine() throws -> any FlashcardEngine {
        #if DEBUG
        if UITestSupport.isEnabled { return SampleFlashcardEngine() }
        #endif
        switch self {
        case .apple: return try AppleFlashcardEngine()
        case .claude: return ClaudeFlashcardEngine(client: try AnthropicClient.fromKeychain())
        }
    }
}

// MARK: - Card writing guidance shared by both engines

nonisolated enum CardWriting {
    static let styleGuide = """
        How to write good cards:
        - Each card tests one fact, definition, concept, date, formula, or relationship from the notes. Favor what a teacher would put on a quiz.
        - The front is a term or a short, specific question. The back is the answer, short enough to recall from memory (usually under 25 words).
        - Stay faithful to the notes. Don't add facts the notes don't contain, though you may fix obvious typos.
        - Avoid duplicate or overlapping cards, and avoid yes/no questions.
        - Ask about the subject itself, never about the notes or slides (what was mentioned, what a speaker emphasized). Speaker notes from slides are a source of facts, not a topic.
        - Keep the notes' own terminology. Write plain text without Markdown; write math inline (for example, x^2 + 3x).
        - Order cards the way their topics appear in the notes.
        """

    static let revisionRules = """
        - Only include cards affected by the edits; leave every other card out of your response.
        - If an edit changes a fact that a card tests, put the card in `updated` with its id and corrected front and back.
        - If the material a card tests was removed from the notes, put its id in `removed`.
        - If the edits add material worth studying, write cards for it in `added`, matching the style of the existing cards and not duplicating any of them.
        - Cards marked locked were written or edited by the student. Never update or remove them.
        - If the edits are cosmetic (formatting, typos, reordering), return empty lists.
        """

    /// Trims cards and drops empty, duplicate (same front, ignoring case and spacing),
    /// self-answering (the front already contains the answer, or the back repeats the front),
    /// and meta cards (questions about the notes or slides rather than the subject).
    static func cleaned(_ cards: [GeneratedCard], excludingFronts existing: Set<String> = []) -> [GeneratedCard] {
        var seen = existing
        var result: [GeneratedCard] = []
        for card in cards {
            let front = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
            let frontKey = normalizedKey(front)
            let backKey = normalizedKey(back)
            guard !frontKey.isEmpty, !backKey.isEmpty, !front.hasPrefix("#") else { continue }
            if frontKey == backKey { continue }
            if backKey.count >= 3, " \(frontKey) ".contains(" \(backKey) ") { continue }
            if isAboutTheNotes(frontKey) { continue }
            guard seen.insert(frontKey).inserted else { continue }
            result.append(GeneratedCard(front: front, back: back))
        }
        return result
    }

    private static let metaPhrases = [
        "speaker notes", "presenter notes", "in the notes", "the notes say", "according to the notes",
        "on the slide", "in the slides", "the speaker", "the presenter", "was mentioned", "were mentioned",
        "is mentioned", "are mentioned",
    ]

    /// True for questions about the notes themselves ("What was mentioned in the speaker notes?").
    static func isAboutTheNotes(_ normalizedFront: String) -> Bool {
        let padded = " \(normalizedFront) "
        return metaPhrases.contains { padded.contains(" \($0) ") }
    }

    static func normalizedKey(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
