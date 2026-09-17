import SwiftData
import SwiftUI

/// Adds a card, or edits one. Edited cards are locked against future syncs.
struct CardEditorView: View {
    let deck: Deck
    let card: Flashcard?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var front: String
    @State private var back: String
    @State private var isStarred: Bool

    init(deck: Deck, card: Flashcard?) {
        self.deck = deck
        self.card = card
        _front = State(initialValue: card?.front ?? "")
        _back = State(initialValue: card?.back ?? "")
        _isStarred = State(initialValue: card?.isStarred ?? false)
    }

    private var trimmedFront: String { front.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBack: String { back.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Term or question") {
                    TextField("Front", text: $front, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Definition or answer") {
                    TextField("Back", text: $back, axis: .vertical)
                        .lineLimit(2...10)
                }
                Section {
                    Toggle("Starred", systemImage: "star", isOn: $isStarred)
                } footer: {
                    if deck.isLinkedToDrive || deck.sourceKind == .text {
                        Text("Cards you write or edit are never changed when the notes update.")
                    }
                }
                if let card {
                    Section {
                        Button("Delete Card", role: .destructive) {
                            deck.cards.removeAll { $0.id == card.id }
                            modelContext.delete(card)
                            deck.markModifiedByMe()
                            try? modelContext.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(card == nil ? "New Card" : "Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedFront.isEmpty || trimmedBack.isEmpty)
                }
            }
        }
    }

    private func save() {
        var edited = true
        if let card {
            if card.front != trimmedFront || card.back != trimmedBack {
                card.front = trimmedFront
                card.back = trimmedBack
                card.isUserEdited = true
                card.updatedAt = .now
                card.setBadge(nil)
            } else {
                // Starring alone doesn't count as editing the deck.
                edited = false
            }
            card.isStarred = isStarred
        } else {
            let newCard = Flashcard(front: trimmedFront, back: trimmedBack, order: deck.nextCardOrder, isUserEdited: true)
            newCard.isStarred = isStarred
            modelContext.insert(newCard)
            deck.cards.append(newCard)
        }
        if edited { deck.markModifiedByMe() }
        try? modelContext.save()
        dismiss()
    }
}
