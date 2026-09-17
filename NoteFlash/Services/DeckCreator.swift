import Foundation
import SwiftData

enum NewDeckSource {
    case text(title: String, notes: String)
    /// A PDF, PowerPoint, or image file. `title` overrides the generated deck title.
    case file(fileName: String, data: Data, title: String? = nil)
    /// Photos or exported pages, made into one deck with a page per image.
    case images(name: String, data: [Data], title: String? = nil)
    case drive(DriveFileReference, autoSync: Bool)
}

/// Builds a new deck with the AI engine chosen in Settings.
enum DeckCreator {
    enum CreationError: LocalizedError {
        case emptyNotes
        case unreadablePDF
        case unsupportedFile
        case pdfTooLarge
        case noCards

        var errorDescription: String? {
            switch self {
            case .emptyNotes: "There aren't any notes to make cards from."
            case .unreadablePDF: "That file couldn't be opened as a PDF."
            case .unsupportedFile: "NoteFlash can read PDFs, PowerPoint (.pptx) files, and images."
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

        case .file(let fileName, let data, let title) where PowerPointTextExtractor.isPresentation(data):
            reporter.send(.phase("Reading your slides"))
            let slides = try await readPowerPoint(data)
            let notes = slides.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { throw CreationError.emptyNotes }
            reporter.send(.workload(characters: notes.count, engine: engineKind))
            let generated = try await engine.generateDeck(
                from: .text(notes), density: density, progress: reporter.generationHandler
            )
            let deck = Deck(
                title: preferred(title, over: generated.title),
                sourceKind: .powerPoint,
                sourceName: fileName,
                sourceText: notes,
                density: density
            )
            return try insert(deck, cards: generated.cards, into: context)

        case .file(let fileName, let data, let title) where ImageNotes.isImage(data):
            return try await imageDeck(
                [data], name: fileName, title: title, density: density,
                engine: engine, engineKind: engineKind, context: context, reporter: reporter
            )

        case .images(let name, let images, let title):
            return try await imageDeck(
                images, name: name, title: title, density: density,
                engine: engine, engineKind: engineKind, context: context, reporter: reporter
            )

        case .file(let fileName, let data, let title):
            guard data.starts(with: Data("%PDF".utf8)) || PDFTextExtractor.pageCount(of: data) != nil else {
                throw CreationError.unsupportedFile
            }
            return try await pdfDeck(
                data, fileName: fileName, title: title, reading: "your PDF", density: density,
                engine: engine, engineKind: engineKind, context: context, reporter: reporter
            )

        case .drive(let reference, let autoSync):
            reporter.send(.phase("Opening \(reference.kind?.label ?? "your file")"))
            let content = try await sync.fetchContent(reference, reporter: reporter)
            let notes = content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { throw CreationError.emptyNotes }

            let noteSource: NoteSource
            if let pdf = content.pdfData {
                noteSource = .pdf(
                    data: pdf, text: content.text,
                    details: content.pdfPages.map { PDFDetails(pages: $0, title: content.title) }
                )
                reporter.send(.workload(characters: workload(forPDF: pdf, pages: content.pageCount ?? 0, text: content.text, engine: engineKind), engine: engineKind))
            } else {
                noteSource = .text(notes)
                reporter.send(.workload(characters: notes.count, engine: engineKind))
            }
            let generated = try await engine.generateDeck(
                from: noteSource, density: density, progress: reporter.generationHandler
            )

            let fileTitle = content.title.flatMap { ["Untitled document", "Untitled presentation", ""].contains($0) ? nil : $0 }
            let deck = Deck(
                title: fileTitle ?? generated.title,
                sourceKind: content.kind.sourceKind,
                sourceName: content.title,
                sourceText: content.text,
                density: density
            )
            deck.googleDocID = reference.id
            deck.googleDocURL = content.kind.openURL(for: reference.id)?.absoluteString
            deck.sourceHash = TextDiff.fingerprint(of: content.text)
            deck.sourceVersion = content.version
            deck.sourcePDF = content.pdfData
            deck.autoSync = autoSync
            deck.lastCheckedAt = .now
            return try insert(deck, cards: generated.cards, into: context)
        }
    }

    private static func imageDeck(
        _ images: [Data], name: String, title: String?, density: CardDensity,
        engine: any FlashcardEngine, engineKind: AIEngineKind, context: ModelContext, reporter: ProcessingReporter
    ) async throws -> Deck {
        reporter.send(.phase(images.count == 1 ? "Preparing your image" : "Preparing \(images.count) images"))
        guard let pdf = await ImageNotes.makePDF(from: images) else { throw CreationError.unsupportedFile }
        return try await pdfDeck(
            pdf, fileName: name, title: title, titleIsFromFile: false,
            reading: images.count == 1 ? "your image" : "your images",
            density: density, engine: engine, engineKind: engineKind, context: context, reporter: reporter
        )
    }

    private static func pdfDeck(
        _ data: Data, fileName: String, title: String?, titleIsFromFile: Bool = true, reading: String, density: CardDensity,
        engine: any FlashcardEngine, engineKind: AIEngineKind, context: ModelContext, reporter: ProcessingReporter
    ) async throws -> Deck {
        reporter.send(.phase("Reading \(reading)"))
        let extracted = await PDFTextExtractor.extract(from: data) { page, total in
            reporter.send(.phase(total == 1 ? "Reading \(reading)" : "Reading page \(page) of \(total)"))
        }
        guard let extracted else { throw CreationError.unreadablePDF }
        reporter.send(.workload(characters: workload(forPDF: data, pages: extracted.pageCount, text: extracted.text, engine: engineKind), engine: engineKind))
        let generated = try await engine.generateDeck(
            from: .pdf(
                data: data,
                text: extracted.text,
                details: PDFDetails(
                    pages: extracted.pages,
                    title: title ?? (titleIsFromFile ? DriveFileReader.stripExtension(fileName) : nil)
                )
            ),
            density: density,
            progress: reporter.generationHandler
        )
        let deck = Deck(
            title: preferred(title, over: generated.title),
            sourceKind: .pdf,
            sourceName: fileName,
            sourceText: extracted.text,
            density: density
        )
        deck.sourcePDF = data
        return try insert(deck, cards: generated.cards, into: context)
    }

    private static func preferred(_ title: String?, over generated: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? generated : trimmed
    }

    /// Claude reads a PDF itself, so its workload follows the page count.
    static func workload(forPDF data: Data, pages: Int, text: String, engine: AIEngineKind) -> Int {
        engine == .claude && data.count <= PDFTextExtractor.maxDocumentBytes && pages > 0
            ? ProcessingEstimator.estimatedCharacters(pdfPages: pages)
            : text.count
    }

    @concurrent
    private static func readPowerPoint(_ data: Data) async throws -> PowerPointTextExtractor.Result {
        try PowerPointTextExtractor.extract(from: data)
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
