import Foundation
import SwiftData

enum NewDeckSource {
    case text(title: String, notes: String)
    case pdf(fileName: String, data: Data)
    case googleDoc(documentID: String, autoSync: Bool)
}

/// Builds a new deck with the AI engine chosen in Settings.
enum DeckCreator {
    enum CreationError: LocalizedError {
        case emptyNotes
        case unreadablePDF
        case pdfTooLarge
        case noCards

        var errorDescription: String? {
            switch self {
            case .emptyNotes: "There aren't any notes to make cards from."
            case .unreadablePDF: "That file couldn't be opened as a PDF."
            case .pdfTooLarge: "That PDF is too large and has no selectable text. Try splitting it into smaller files."
            case .noCards: "Couldn't find anything in these notes to make flashcards from."
            }
        }
    }

    static func createDeck(
        from source: NewDeckSource,
        density: CardDensity,
        sync: DocSyncService,
        context: ModelContext,
        reporter: ProcessingReporter = .silent
    ) async throws -> Deck {
        let engineKind = AIEngineKind.selected
        let engine = try engineKind.makeEngine()

        switch source {
        case .text(let title, let notes):
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CreationError.emptyNotes }
            reporter.send(.workload(characters: trimmed.count, engine: engineKind))
            let generated = try await engine.generateDeck(
                from: .text(trimmed), density: density, progress: reporter.generationHandler
            )
            let deckTitle = title.trimmingCharacters(in: .whitespaces)
            let deck = Deck(
                title: deckTitle.isEmpty ? generated.title : deckTitle,
                sourceKind: .text,
                sourceText: trimmed,
                density: density
            )
            return try insert(deck, cards: generated.cards, into: context)

        case .pdf(let fileName, let data):
            reporter.send(.phase("Reading your PDF"))
            let extracted = await PDFTextExtractor.extract(from: data) { page, total in
                reporter.send(.phase("Reading page \(page) of \(total)"))
            }
            guard let extracted else { throw CreationError.unreadablePDF }
            // Claude reads the PDF itself, so its workload follows the page count.
            let characters = engineKind == .claude && data.count <= PDFTextExtractor.maxDocumentBytes
                ? ProcessingEstimator.estimatedCharacters(pdfPages: extracted.pageCount)
                : extracted.text.count
            reporter.send(.workload(characters: characters, engine: engineKind))
            let generated = try await engine.generateDeck(
                from: .pdf(data: data, text: extracted.text),
                density: density,
                progress: reporter.generationHandler
            )
            let deck = Deck(
                title: generated.title,
                sourceKind: .pdf,
                sourceName: fileName,
                sourceText: extracted.text,
                density: density
            )
            deck.sourcePDF = data
            return try insert(deck, cards: generated.cards, into: context)

        case .googleDoc(let documentID, let autoSync):
            reporter.send(.phase("Opening your Google Doc"))
            let document = try await sync.fetchDocument(id: documentID)
            let notes = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { throw CreationError.emptyNotes }
            reporter.send(.workload(characters: notes.count, engine: engineKind))
            let generated = try await engine.generateDeck(
                from: .text(notes), density: density, progress: reporter.generationHandler
            )

            let docTitle = document.title.flatMap { $0 == "Untitled document" ? nil : $0 }
            let deck = Deck(
                title: docTitle ?? generated.title,
                sourceKind: .googleDoc,
                sourceName: document.title,
                sourceText: document.text,
                density: density
            )
            deck.googleDocID = documentID
            deck.googleDocURL = GoogleDocsClient.editURL(for: documentID)?.absoluteString
            deck.sourceHash = TextDiff.fingerprint(of: document.text)
            deck.autoSync = autoSync
            deck.lastCheckedAt = .now
            return try insert(deck, cards: generated.cards, into: context)
        }
    }

    private static func insert(_ deck: Deck, cards: [GeneratedCard], into context: ModelContext) throws -> Deck {
        guard !cards.isEmpty else { throw CreationError.noCards }
        context.insert(deck)
        for card in cards {
            deck.addCard(
                front: card.front.trimmingCharacters(in: .whitespacesAndNewlines),
                back: card.back.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        try context.save()
        return deck
    }
}
