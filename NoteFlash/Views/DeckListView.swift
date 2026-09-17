import SwiftData
import SwiftUI

struct DeckListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DocSyncService.self) private var sync
    @Environment(ProcessingCenter.self) private var processing
    @Query private var decks: [Deck]
    @AppStorage("deckSort") private var sortRaw = DeckSort.modified.rawValue
    @AppStorage("deckSortAscending") private var ascending = false

    @State private var path: [Deck] = []
    @State private var showingNewDeck = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var hasAPIKey = KeychainStore.string(for: .anthropicAPIKey) != nil
    @State private var router = AppRouter.shared
    @State private var incomingNotes: IncomingNotes?
    @State private var importingDeck: IncomingSharedDeck?
    @AppStorage(AIEngineKind.storageKey) private var engine: AIEngineKind = .apple

    /// Why the selected AI model can't write cards yet, if anything.
    private var setupProblem: String? {
        switch engine {
        case .apple: AppleFlashcardEngine.unavailableReason
        case .claude: hasAPIKey ? nil : "NoteFlash is set to use Claude. Add your API key, or switch to Apple Intelligence."
        }
    }

    private var sort: DeckSort { DeckSort(rawValue: sortRaw) ?? .modified }

    private var filteredDecks: [Deck] {
        let matching = searchText.isEmpty
            ? decks
            : decks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return sort.sorted(matching, ascending: ascending)
    }

    var body: some View {
        NavigationStack(path: $path) {
            presentations(on: navigable(deckList))
        }
    }

    private var deckList: some View {
        List {
            if let setupProblem {
                setupSection(setupProblem)
            }

            if !processing.jobs.isEmpty {
                Section {
                    ForEach(processing.jobs) { job in
                        ProcessingJobRow(job: job, onOpen: openDeck)
                    }
                } header: {
                    Text("Processing")
                }
            }

            if !filteredDecks.isEmpty {
                Section {
                    ForEach(filteredDecks) { deck in
                        NavigationLink(value: deck) {
                            DeckRow(deck: deck, sort: sort)
                        }
                        .contextMenu {
                            ShareLink(item: SharedDeckFile(deck: deck), preview: SharePreview(deck.title)) {
                                Label("Share Deck", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .onDelete(perform: deleteDecks)
                } header: {
                    SortHeaderButton(
                        label: sort.label,
                        ascending: $ascending,
                        directionLabel: sort.directionLabel(ascending: ascending)
                    )
                }
            }
        }
        .overlay { emptyState }
    }

    private func setupSection(_ problem: String) -> some View {
        Section {
            Button {
                showingSettings = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine == .apple ? "Apple Intelligence isn't ready" : "Add your Claude API key")
                            .font(.headline)
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: engine == .apple ? "sparkles" : "key.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if decks.isEmpty && processing.jobs.isEmpty {
            ContentUnavailableView {
                Label("No Decks Yet", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("Paste notes, import a PDF or slides, link a Google Drive file, or share notes from apps like GoodNotes, and NoteFlash will turn them into flashcards.")
            } actions: {
                Button("Create a Deck") { showingNewDeck = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, setupProblem == nil ? 0 : 160)
        } else if filteredDecks.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private func navigable(_ content: some View) -> some View {
        content
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    Button("New Deck", systemImage: "plus") {
                        showingNewDeck = true
                    }
                }
            }
    }

    /// Sheets, plus requests from notifications and other apps.
    private func presentations(on content: some View) -> some View {
        content
            .sheet(isPresented: $showingNewDeck) {
                NewDeckView()
            }
            .sheet(item: $incomingNotes) { incoming in
                NewDeckView(incoming: incoming)
            }
            .sheet(item: $importingDeck, onDismiss: presentNextSharedDeck) { incoming in
                ImportSharedDeckView(shared: incoming.deck) { deck in
                    path = [deck]
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: refreshKeyState) {
                SettingsView()
            }
            .onChange(of: router.incomingNotes?.id, initial: true) {
                guard let incoming = router.incomingNotes else { return }
                router.incomingNotes = nil
                Task { await present(incoming) }
            }
            .onChange(of: router.incomingDecks.count, initial: true) {
                guard importingDeck == nil else { return }
                presentNextSharedDeck()
            }
            .onChange(of: router.deckToOpen, initial: true) { _, deckID in
                guard let deckID else { return }
                router.deckToOpen = nil
                if let job = processing.jobs.first(where: { $0.deckID == deckID && !$0.isRunning }) {
                    processing.dismiss(job)
                }
                openDeck(deckID)
            }
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort By") {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(DeckSort.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
            SortOrderPicker(ascending: $ascending, ascendingByDefault: sort.ascendingByDefault) {
                sort.directionLabel(ascending: $0)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .onChange(of: sortRaw) {
            ascending = sort.ascendingByDefault
        }
    }

    /// Shows New Deck for a file another app opened in NoteFlash, closing any open sheet first.
    private func present(_ incoming: IncomingNotes) async {
        await makeWay()
        incomingNotes = incoming
    }

    /// Asks the user about the next shared deck waiting to be added.
    private func presentNextSharedDeck() {
        guard let next = router.incomingDecks.first else { return }
        Task {
            await makeWay()
            // The sheet holds the deck from here on, so it leaves the queue now.
            router.incomingDecks.removeAll { $0.id == next.id }
            importingDeck = next
        }
    }

    /// iOS can't show two sheets at once, so any open one closes first.
    private func makeWay() async {
        if showingNewDeck || showingSettings || incomingNotes != nil || importingDeck != nil {
            showingNewDeck = false
            showingSettings = false
            incomingNotes = nil
            importingDeck = nil
            try? await Task.sleep(for: .milliseconds(600))
        }
        path = []
    }

    private func openDeck(_ id: UUID) {
        guard let deck = decks.first(where: { $0.id == id }) else { return }
        showingNewDeck = false
        showingSettings = false
        path = [deck]
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
    let sort: DeckSort

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
                    if deck.isLinkedToDrive {
                        Text("·")
                        SyncStatusLabel(deck: deck)
                            .labelStyle(.titleOnly)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if deck.priorityCount > 0 {
                    Label("^[\(deck.priorityCount) card](inflect: true) on the exam", systemImage: "flag.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(sort.activity(for: deck))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

extension DeckSort {
    func sorted(_ decks: [Deck], ascending: Bool) -> [Deck] {
        decks.sorted { a, b in
            if self == .name {
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame {
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
                return a.createdAt > b.createdAt
            }
            // Decks without the date sort last either way, as in Drive.
            switch (date(of: a), date(of: b)) {
            case let (dateA?, dateB?) where dateA != dateB:
                return ascending ? dateA < dateB : dateA > dateB
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
        }
    }

    func date(of deck: Deck) -> Date? {
        switch self {
        case .name, .modified: deck.updatedAt
        case .modifiedByMe: deck.modifiedByMeAt
        case .opened: deck.lastOpenedAt
        case .created: deck.createdAt
        }
    }

    /// The date line that matches the sort, worded like Drive's.
    func activity(for deck: Deck) -> String {
        switch self {
        case .name, .modified:
            "Modified \(DriveText.short(deck.updatedAt))"
        case .modifiedByMe:
            deck.modifiedByMeAt.map { "You modified \(DriveText.short($0))" } ?? "You haven't edited this"
        case .opened:
            deck.lastOpenedAt.map { "You opened \(DriveText.short($0))" } ?? "You haven't opened this"
        case .created:
            "Created \(DriveText.short(deck.createdAt))"
        }
    }
}
