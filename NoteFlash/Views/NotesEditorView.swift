import SwiftUI

/// Edits a text deck's notes; the AI engine then updates only the affected cards in the background.
struct NotesEditorView: View {
    let deck: Deck

    @Environment(\.dismiss) private var dismiss
    @Environment(ProcessingCenter.self) private var processing
    @State private var text: String

    init(deck: Deck) {
        self.deck = deck
        _text = State(initialValue: deck.sourceText)
    }

    private var isDeckBusy: Bool { processing.runningJob(forDeck: deck.id) != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isDeckBusy {
                    Label("This deck is being updated. You can save once that finishes.", systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextEditor(text: $text)
                    .padding(.horizontal, 12)
            }
            .navigationTitle("Edit Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update Cards") {
                        processing.updateNotes(of: deck, to: text)
                        dismiss()
                    }
                    .disabled(isDeckBusy || text == deck.sourceText)
                }
            }
        }
    }
}
