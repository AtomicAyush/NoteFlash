import Foundation

/// Writes and revises cards with Claude over the Messages API.
nonisolated struct ClaudeFlashcardEngine: FlashcardEngine {
    let client: AnthropicClient

    private struct RevisionResponse: Decodable, Sendable {
        let updated: [CardRevision]
        let removed: [String]
        let added: [GeneratedCard]
    }

    private static let cardSchema = JSONValue.strictObject([
        "front": .stringType,
        "back": .stringType,
    ])

    func generateDeck(from source: NoteSource, density: CardDensity, progress: GenerationProgressHandler?) async throws -> GeneratedDeck {
        let system = """
            You turn a student's class notes into a flashcard deck for studying, like a well-made Quizlet set.

            \(CardWriting.styleGuide)

            Deck size: \(density.promptGuidance)

            Also give the deck a short title (under 40 characters) naming its subject.
            """

        var content: [AnthropicClient.ContentBlock] = []
        switch source {
        case .text(let notes):
            content.append(.text("<notes>\n\(notes)\n</notes>"))
        case .pdf(let data, let text, _):
            // Claude reads PDFs directly (scans, tables, diagrams) when they fit in a request.
            if data.count <= PDFTextExtractor.maxDocumentBytes {
                content.append(.pdf(base64: data.base64EncodedString()))
            } else if !text.isEmpty {
                content.append(.text("<notes>\n\(text)\n</notes>"))
            } else {
                throw DeckCreator.CreationError.pdfTooLarge
            }
        }
        content.append(.text("Make flashcards from these notes."))

        let schema = JSONValue.strictObject([
            "title": .stringType,
            "cards": .arrayOf(Self.cardSchema),
        ])

        // Claude thinks first, then streams the cards; progress follows the streamed length.
        let expectedOutput = Self.expectedOutputCharacters(for: source, density: density)
        progress?(GenerationProgress(fraction: 0.02, detail: "Claude is reading your notes"))
        let onTextProgress: (@Sendable (Int) -> Void)? = progress.map { report in
            { @Sendable streamed in
                let share = min(1, Double(streamed) / expectedOutput)
                report(GenerationProgress(fraction: 0.1 + 0.88 * share, detail: "Writing cards"))
            }
        }
        let deck = try await client.structuredResponse(
            system: system, content: content, schema: schema, as: GeneratedDeck.self,
            onTextProgress: onTextProgress
        )
        progress?(GenerationProgress(fraction: 1, detail: "Done"))
        return GeneratedDeck(title: deck.title, cards: CardWriting.cleaned(deck.cards))
    }

    /// Rough size of the JSON reply: roughly one card per 80 characters of notes at the balanced size.
    private static func expectedOutputCharacters(for source: NoteSource, density: CardDensity) -> Double {
        let input: Int
        switch source {
        case .text(let text): input = text.count
        case .pdf(let data, let text, _): input = text.isEmpty ? data.count / 20 : text.count
        }
        let ratio = switch density {
        case .essentials: 0.6
        case .balanced: 1.2
        case .thorough: 1.8
        }
        return max(400, Double(input) * ratio)
    }

    func reviseDeck(
        existing: [ExistingCard],
        changes: NoteChanges,
        updatedNotes: String,
        density: CardDensity,
        progress: GenerationProgressHandler?
    ) async throws -> DeckRevision {
        let system = """
            You maintain a flashcard deck generated from a student's notes. The notes were just edited. \
            Update the deck so it matches the notes again, while keeping as much of the existing deck \
            (and the student's study progress on it) as you can.

            \(CardWriting.revisionRules)

            \(CardWriting.styleGuide)

            Deck size for new material: \(density.promptGuidance)
            """

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let cardsJSON = String(data: try encoder.encode(existing), encoding: .utf8) ?? "[]"

        let prompt = """
            <existing_cards>
            \(cardsJSON)
            </existing_cards>

            <edits>
            Lines starting with "-" were removed, lines starting with "+" were added, and other lines are unchanged context.
            \(changes.rendered)
            </edits>

            <updated_notes>
            \(updatedNotes)
            </updated_notes>

            Update the deck for these edits.
            """

        let schema = JSONValue.strictObject([
            "updated": .arrayOf(.strictObject([
                "id": .stringType,
                "front": .stringType,
                "back": .stringType,
            ])),
            "removed": .arrayOf(.stringType),
            "added": .arrayOf(Self.cardSchema),
        ])
        // The reply lists only affected cards; assume it's around the size of the edits.
        let expectedOutput = Double(max(300, changes.rendered.count))
        progress?(GenerationProgress(fraction: 0.02, detail: "Claude is reading your changes"))
        let onTextProgress: (@Sendable (Int) -> Void)? = progress.map { report in
            { @Sendable streamed in
                let share = min(1, Double(streamed) / expectedOutput)
                report(GenerationProgress(fraction: 0.1 + 0.88 * share, detail: "Updating cards"))
            }
        }
        let response = try await client.structuredResponse(
            system: system, content: [.text(prompt)], schema: schema, as: RevisionResponse.self,
            onTextProgress: onTextProgress
        )
        progress?(GenerationProgress(fraction: 1, detail: "Done"))
        let removedIDs = Set(response.removed)
        let existingFronts = Set(existing.filter { !removedIDs.contains($0.id) }.map { CardWriting.normalizedKey($0.front) })
        return DeckRevision(
            updated: response.updated,
            removed: response.removed,
            added: CardWriting.cleaned(response.added, excludingFronts: existingFronts)
        )
    }
}
