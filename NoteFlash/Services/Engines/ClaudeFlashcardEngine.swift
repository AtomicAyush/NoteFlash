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

    func generateDeck(from source: NoteSource, density: CardDensity) async throws -> GeneratedDeck {
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
        case .pdf(let data, let text):
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
        let deck = try await client.structuredResponse(
            system: system, content: content, schema: schema, as: GeneratedDeck.self
        )
        return GeneratedDeck(title: deck.title, cards: CardWriting.cleaned(deck.cards))
    }

    func reviseDeck(
        existing: [ExistingCard],
        changes: NoteChanges,
        updatedNotes: String,
        density: CardDensity
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
        let response = try await client.structuredResponse(
            system: system, content: [.text(prompt)], schema: schema, as: RevisionResponse.self
        )
        let removedIDs = Set(response.removed)
        let existingFronts = Set(existing.filter { !removedIDs.contains($0.id) }.map { CardWriting.normalizedKey($0.front) })
        return DeckRevision(
            updated: response.updated,
            removed: response.removed,
            added: CardWriting.cleaned(response.added, excludingFronts: existingFronts)
        )
    }
}
