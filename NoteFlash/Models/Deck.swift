import Foundation
import SwiftData

@Model
final class Deck {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    // Where the notes came from.
    var sourceKindRaw: String = SourceKind.text.rawValue
    var sourceName: String?
    /// The notes text the current cards were generated from.
    var sourceText: String = ""
    @Attribute(.externalStorage) var sourcePDF: Data?
    var densityRaw: String = CardDensity.balanced.rawValue

    // Google Drive sync state. (Named for Docs, which were the first linked files.)
    /// The linked Drive file's ID.
    var googleDocID: String?
    /// A link that opens the file in Docs, Slides, or Drive.
    var googleDocURL: String?
    var sourceHash: String?
    /// The Drive version (or content hash) the notes were read from.
    var sourceVersion: String?
    var autoSync: Bool = true
    var lastCheckedAt: Date?
    var lastChangedAt: Date?
    var lastSyncSummary: String?
    var lastSyncError: String?

    var bestMatchTime: Double?

    @Relationship(deleteRule: .cascade, inverse: \Flashcard.deck)
    var cards: [Flashcard] = []

    init(title: String, sourceKind: SourceKind, sourceName: String? = nil, sourceText: String, density: CardDensity) {
        self.title = title
        self.sourceKindRaw = sourceKind.rawValue
        self.sourceName = sourceName
        self.sourceText = sourceText
        self.densityRaw = density.rawValue
    }

    var sourceKind: SourceKind {
        get { SourceKind(rawValue: sourceKindRaw) ?? .text }
        set { sourceKindRaw = newValue.rawValue }
    }

    var density: CardDensity {
        get { CardDensity(rawValue: densityRaw) ?? .balanced }
        set { densityRaw = newValue.rawValue }
    }

    var isLinkedToDrive: Bool { googleDocID != nil }

    var driveReference: DriveFileReference? {
        googleDocID.map { DriveFileReference(id: $0, kind: sourceKind.driveFileKind, name: sourceName) }
    }

    /// "Open in Google Slides", for linked decks.
    var openLinkLabel: String {
        sourceKind.driveFileKind?.openLabel ?? "Open in Google Drive"
    }

    var sortedCards: [Flashcard] {
        cards.sorted { $0.order < $1.order }
    }

    var nextCardOrder: Int {
        (cards.map(\.order).max() ?? -1) + 1
    }

    var masteredCount: Int {
        cards.filter { $0.masteryLevel >= Flashcard.masteredLevel }.count
    }

    var masteryFraction: Double {
        cards.isEmpty ? 0 : Double(masteredCount) / Double(cards.count)
    }

    var recentlyChangedCount: Int {
        cards.filter { $0.activeSyncBadge != nil }.count
    }

    func addCard(front: String, back: String, badge: SyncBadge? = nil) {
        let card = Flashcard(front: front, back: back, order: nextCardOrder)
        card.setBadge(badge)
        modelContext?.insert(card)
        cards.append(card)
    }
}
