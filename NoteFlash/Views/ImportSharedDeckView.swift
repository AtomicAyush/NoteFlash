import SwiftData
import SwiftUI

/// Confirms adding a deck someone shared, so the user sees what they're getting first.
struct ImportSharedDeckView: View {
    let shared: SharedDeck
    let onAdded: (Deck) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var errorMessage: String?

    private let previewCount = 8

    init(shared: SharedDeck, onAdded: @escaping (Deck) -> Void) {
        self.shared = shared
        self.onAdded = onAdded
        _title = State(initialValue: shared.title)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $title)
                } header: {
                    Text("Deck")
                } footer: {
                    summary
                }

                Section {
                    ForEach(Array(shared.cards.prefix(previewCount).enumerated()), id: \.offset) { _, card in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.front)
                                .font(.subheadline.weight(.semibold))
                            Text(card.back)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if card.isPriority {
                                Label("On the exam", systemImage: "flag.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if shared.cards.count > previewCount {
                        Text("^[\(shared.cards.count - previewCount) more card](inflect: true)")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Cards")
                }
            }
            .navigationTitle("Add Shared Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .fontWeight(.semibold)
                }
            }
            .alert("Couldn't add the deck", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// Built from pieces, since "^[…](inflect:)" only works in a literal.
    private var summary: Text {
        let cards = Text("^[\(shared.cards.count) card](inflect: true)")
        let priorities = shared.priorityCount > 0 ? Text(" · \(shared.priorityCount) on the exam") : Text("")
        let notes = Text(shared.notes.isEmpty
            ? " · Study progress starts fresh."
            : " · The notes come too, so you can edit them or regenerate the cards.")
        return Text("\(cards)\(priorities)\(notes)")
    }

    private func add() {
        do {
            let deck = try SharedDeckImporter.addDeck(shared, title: title, to: modelContext)
            dismiss()
            onAdded(deck)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
