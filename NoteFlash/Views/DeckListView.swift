import SwiftData
import SwiftUI

struct DeckListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DocSyncService.self) private var sync
    @Query(sort: \Deck.updatedAt, order: .reverse) private var decks: [Deck]

    @State private var path: [Deck] = []
    @State private var showingNewDeck = false
    @State private var showingSettings = false
    @State private var createdDeck: Deck?
    @State private var searchText = ""
    @State private var hasAPIKey = KeychainStore.string(for: .anthropicAPIKey) != nil
    @AppStorage(AIEngineKind.storageKey) private var engine: AIEngineKind = .apple

    /// Why the selected AI model can't write cards yet, if anything.
    private var setupProblem: String? {
        switch engine {
        case .apple: AppleFlashcardEngine.unavailableReason
        case .claude: hasAPIKey ? nil : "NoteFlash is set to use Claude. Add your API key, or switch to Apple Intelligence."
        }
    }

    private var filteredDecks: [Deck] {
        guard !searchText.isEmpty else { return decks }
        return decks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let setupProblem {
                    Section {
                        Button {
                            showingSettings = true
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine == .apple ? "Apple Intelligence isn't ready" : "Add your Claude API key")
                                        .font(.headline)
                                    Text(setupProblem)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: engine == .apple ? "sparkles" : "key.fill")
                            }
                        }
                    }
                }

                ForEach(filteredDecks) { deck in
                    NavigationLink(value: deck) {
                        DeckRow(deck: deck)
                    }
                }
                .onDelete(perform: deleteDecks)
            }
            .overlay {
                if decks.isEmpty {
                    ContentUnavailableView {
                        Label("No Decks Yet", systemImage: "rectangle.stack.badge.plus")
                    } description: {
                        Text("Paste notes, import a PDF, or link a Google Doc, and NoteFlash will turn it into flashcards.")
                    } actions: {
                        Button("Create a Deck") { showingNewDeck = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, setupProblem == nil ? 0 : 160)
                } else if filteredDecks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("NoteFlash")
            .navigationDestination(for: Deck.self) { deck in
                DeckDetailView(deck: deck)
            }
            .searchable(text: $searchText, prompt: "Search decks")
            .refreshable {
                await sync.syncAllLinkedDecks()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Deck", systemImage: "plus") {
                        showingNewDeck = true
                    }
                }
            }
            .sheet(isPresented: $showingNewDeck, onDismiss: openCreatedDeck) {
                NewDeckView { deck in
                    createdDeck = deck
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: refreshKeyState) {
                SettingsView()
            }
        }
    }

    private func openCreatedDeck() {
        guard let deck = createdDeck else { return }
        createdDeck = nil
        path.append(deck)
    }

    private func refreshKeyState() {
        hasAPIKey = KeychainStore.string(for: .anthropicAPIKey) != nil
    }

    private func deleteDecks(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredDecks[index])
        }
        try? modelContext.save()
    }
}

private struct DeckRow: View {
    let deck: Deck

    var body: some View {
        HStack(spacing: 14) {
            ProgressRing(progress: deck.masteryFraction)
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: deck.sourceKind.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(deck.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("^[\(deck.cards.count) card](inflect: true)")
                    if deck.isLinkedToGoogleDoc {
                        Text("·")
                        SyncStatusLabel(deck: deck)
                            .labelStyle(.titleOnly)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if deck.recentlyChangedCount > 0 {
                Text("\(deck.recentlyChangedCount) changed")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(.tint)
                    .background(.tint.opacity(0.15), in: .capsule)
            }
        }
        .padding(.vertical, 4)
    }
}
