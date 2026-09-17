import SwiftUI

/// Edits a text deck's notes; the AI engine then updates only the affected cards.
struct NotesEditorView: View {
    let deck: Deck

    @Environment(\.dismiss) private var dismiss
    @Environment(DocSyncService.self) private var sync
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(deck: Deck) {
        self.deck = deck
        _text = State(initialValue: deck.sourceText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
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
                        Task { await save() }
                    }
                    .disabled(isSaving || text == deck.sourceText)
                }
            }
            .overlay {
                if isSaving {
                    WorkingOverlay(title: "Updating cards…", subtitle: "\(AIEngineKind.selected.label) is checking which cards your edits affect.")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await sync.updateNotes(of: deck, to: text)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
