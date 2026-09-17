#if DEBUG
import Foundation
import SwiftData

/// Launch-argument hooks for UI tests: `-uiTesting` uses an in-memory store seeded with a sample deck.
enum UITestSupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    static func seed(_ context: ModelContext) {
        let deck = Deck(
            title: "Sample: Cell Biology",
            sourceKind: .text,
            sourceText: """
                # Cell Biology
                Mitochondria make most of the cell's ATP through cellular respiration.
                Ribosomes build proteins by translating messenger RNA.
                The nucleus stores the cell's DNA and controls gene expression.
                The Golgi apparatus packages and ships proteins.
                The cell membrane is a phospholipid bilayer that controls what enters and leaves the cell.
                Lysosomes contain enzymes that break down waste.
                """,
            density: .balanced
        )
        context.insert(deck)
        let cards = [
            ("Which organelle makes most of the cell's ATP?", "Mitochondria"),
            ("What do ribosomes build?", "Proteins"),
            ("Where is DNA stored in a eukaryotic cell?", "The nucleus"),
            ("What organelle packages proteins for export?", "Golgi apparatus"),
            ("What structure controls what enters the cell?", "Cell membrane"),
            ("Which organelle breaks down waste?", "Lysosome"),
        ]
        for (front, back) in cards {
            deck.addCard(front: front, back: back)
        }
        deck.cards.first?.setBadge(.new)
        try? context.save()
    }
}
#endif
