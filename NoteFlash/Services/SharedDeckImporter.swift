import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Adds a deck someone shared, exactly as they wrote it: the same cards in the same order, with
/// their exam priorities. No AI pass, so it's instant and nothing is reworded.
enum SharedDeckImporter {
    static func addDeck(_ shared: SharedDeck, title: String? = nil, to context: ModelContext) throws -> Deck {
        let chosen = (title ?? shared.title).trimmingCharacters(in: .whitespacesAndNewlines)
        let deck = Deck(
            title: chosen.isEmpty ? "Shared deck" : chosen,
            sourceKind: .shared,
            sourceText: shared.notes,
            density: CardDensity(rawValue: shared.density) ?? .balanced
        )
        context.insert(deck)
        deck.addSharedCards(shared.cards)
        try context.save()
        return deck
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
