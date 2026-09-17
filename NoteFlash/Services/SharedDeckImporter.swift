import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Adds a deck someone shared, exactly as they wrote it: the same cards in the same order, with
/// their exam priorities. No AI pass, so it's instant and nothing is reworded.
enum SharedDeckImporter {
    /// With `linkingToSource`, a deck made from a Google Drive file the recipient can open too
    /// is linked to that file, so their copy updates when the file changes instead of going stale.
    static func addDeck(
        _ shared: SharedDeck,
        title: String? = nil,
        linkingToSource: Bool = false,
        to context: ModelContext
    ) throws -> Deck {
        let chosen = (title ?? shared.title).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = linkingToSource ? shared.source : nil
        let deck = Deck(
            title: chosen.isEmpty ? "Shared deck" : chosen,
            sourceKind: source.map { DriveFileKind(rawValue: $0.kind ?? "")?.sourceKind ?? .shared } ?? .shared,
            sourceName: source?.name,
            sourceText: shared.notes,
            density: CardDensity(rawValue: shared.density) ?? .balanced
        )
        if let source {
            deck.googleDocID = source.id
            deck.googleDocURL = source.url
            deck.sourceVersion = source.version
            deck.sourceHash = TextDiff.fingerprint(of: shared.notes)
            deck.autoSync = true
        }
        context.insert(deck)
        deck.addSharedCards(shared.cards)
        try context.save()
        return deck
    }

    /// A deck already linked to this file, so the same doc isn't added twice.
    static func deck(linkedTo source: SharedDeck.Source, in context: ModelContext) -> Deck? {
        let id = source.id
        let descriptor = FetchDescriptor<Deck>(predicate: #Predicate { $0.googleDocID == id })
        return try? context.fetch(descriptor).first
    }
}

/// A deck packed up as a file for the share sheet: a web page anyone can open, with the deck
/// inside it for NoteFlash.
struct SharedDeckFile: Transferable, Sendable {
    let fileName: String
    let html: String

    init(deck: Deck) {
        let shared = deck.sharedDeck
        fileName = DeckShare.fileName(for: shared.title)
        html = DeckShare.html(for: shared)
    }

    /// Sent as a plain file, not as HTML: HTML counts as text, and apps that take text (AirDrop
    /// to a Mac, Messages, Mail) would then be handed the page's words instead of the page,
    /// which loses the deck inside it. The name still ends in .html, so it opens as a web page.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            SentTransferredFile(try file.write())
        }
        .suggestedFileName { $0.fileName }
    }

    /// Writes the page where the share sheet can pick it up, under the name the recipient sees.
    private func write() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "SharedDecks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName)
        try Data(html.utf8).write(to: url, options: .atomic)
        return url
    }
}
