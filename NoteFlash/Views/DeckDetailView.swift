import SwiftData
import SwiftUI

struct DeckDetailView: View {
    @Bindable var deck: Deck

    @Environment(\.modelContext) private var modelContext
    @Environment(DocSyncService.self) private var sync
    @Environment(ProcessingCenter.self) private var processing

    @State private var studyMode: StudyMode?
    @State private var starredOnly = false
    @State private var editingCard: Flashcard?
    @State private var isAddingCard = false
    @State private var isEditingNotes = false
    @State private var isShowingSource = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingRegenerate = false
    @State private var isConfirmingReset = false
    @State private var errorMessage: String?

    private var cards: [Flashcard] { deck.sortedCards }
    private var starredCards: [Flashcard] { cards.filter(\.isStarred) }
    private var isBusy: Bool { sync.isBusy(deck) }
    private var regenerationJob: ProcessingJob? { processing.runningJob(forDeck: deck.id) }

    private var studyCards: [Flashcard] {
        starredOnly && !starredCards.isEmpty ? starredCards : cards
    }

    var body: some View {
        List {
            if let regenerationJob {
                Section {
                    ProcessingJobRow(job: regenerationJob)
                } header: {
                    Text("Rewriting Cards")
                }
            }

            Section {
                sourceRow
                if deck.isLinkedToGoogleDoc {
                    syncRows
                }
                masteryRow
            }

            Section {
                HStack(spacing: 10) {
                    ForEach(StudyMode.allCases) { mode in
                        StudyModeTile(mode: mode) {
                            studyMode = mode
                        }
                        .disabled(studyCards.count < (mode == .match ? 2 : 1))
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if !starredCards.isEmpty {
                    Toggle("Study only starred (\(starredCards.count))", systemImage: "star.fill", isOn: $starredOnly)
                }
            } header: {
                Text("Study")
            }

            Section {
                ForEach(cards) { card in
                    CardRow(card: card)
                        .contentShape(.rect)
                        .onTapGesture { editingCard = card }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                delete(card)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(card.isStarred ? "Unstar" : "Star", systemImage: card.isStarred ? "star.slash" : "star") {
                                card.isStarred.toggle()
                            }
                            .tint(.yellow)
                        }
                }
                Button {
                    isAddingCard = true
                } label: {
                    Label("Add Card", systemImage: "plus")
                }
            } header: {
                Text("^[\(cards.count) Card](inflect: true)")
            }
        }
        .navigationTitle(deck.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarMenu }
        .refreshable {
            if deck.isLinkedToGoogleDoc { await checkDoc() }
        }
        .overlay {
            if isBusy && regenerationJob == nil {
                WorkingOverlay(title: "Updating cards…", subtitle: "\(AIEngineKind.selected.label) is revising this deck.")
            }
        }
        .animation(.default, value: isBusy)
        .fullScreenCover(item: $studyMode) { mode in
            StudySessionView(mode: mode, deck: deck, cards: studyCards)
        }
        .sheet(item: $editingCard) { card in
            CardEditorView(deck: deck, card: card)
        }
        .sheet(isPresented: $isAddingCard) {
            CardEditorView(deck: deck, card: nil)
        }
        .sheet(isPresented: $isEditingNotes) {
            NotesEditorView(deck: deck)
        }
        .sheet(isPresented: $isShowingSource) {
            SourceNotesView(deck: deck)
        }
        .alert("Rename Deck", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { deck.title = trimmed }
            }
        }
        .confirmationDialog("Regenerate all cards?", isPresented: $isConfirmingRegenerate, titleVisibility: .visible) {
            Button("Regenerate", role: .destructive) {
                if let problem = AIEngineKind.selected.setupProblem {
                    errorMessage = problem
                } else {
                    processing.regenerate(deck)
                }
            }
        } message: {
            Text("\(AIEngineKind.selected.label) will rewrite the deck from its notes. Cards you wrote or edited are kept; study progress on the others is reset.")
        }
        .confirmationDialog("Reset study progress?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset Progress", role: .destructive) {
                deck.cards.forEach { $0.resetProgress() }
                deck.bestMatchTime = nil
            }
        }
        .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header rows

    private var sourceRow: some View {
        Button {
            isShowingSource = true
        } label: {
            LabeledContent {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("View notes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: deck.sourceKind.systemImage)
                }
            }
        }
    }

    private var sourceTitle: String {
        switch deck.sourceKind {
        case .text: "Typed notes"
        case .pdf: deck.sourceName ?? "PDF"
        case .googleDoc: deck.sourceName ?? "Google Doc"
        }
    }

    @ViewBuilder
    private var syncRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SyncStatusLabel(deck: deck)
                    .font(.subheadline)
                Spacer()
                Button("Check Now") {
                    Task { await checkDoc() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isBusy)
            }
            if let summary = deck.lastSyncSummary, let changed = deck.lastChangedAt {
                Text("Last change: \(summary), \(changed, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = deck.lastSyncError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        Toggle("Auto-sync with doc", isOn: $deck.autoSync)
    }

    private var masteryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mastered")
                Spacer()
                Text("\(deck.masteredCount) of \(cards.count)")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            ProgressView(value: deck.masteryFraction)
        }
    }

    // MARK: Toolbar

    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu("Options", systemImage: "ellipsis") {
                Button("Add Card", systemImage: "plus") { isAddingCard = true }
                if deck.sourceKind == .text {
                    Button("Edit Notes", systemImage: "square.and.pencil") { isEditingNotes = true }
                }
                if deck.isLinkedToGoogleDoc,
                   let link = deck.googleDocURL.flatMap(URL.init(string:)) {
                    Link(destination: link) {
                        Label("Open in Google Docs", systemImage: "arrow.up.right.square")
                    }
                }
                Button("Rename", systemImage: "pencil") {
                    renameText = deck.title
                    isRenaming = true
                }
                Picker("Card Detail", systemImage: "slider.horizontal.3", selection: $deck.densityRaw) {
                    ForEach(CardDensity.allCases) { density in
                        Text(density.label).tag(density.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Divider()
                Button("Regenerate Cards", systemImage: "sparkles") { isConfirmingRegenerate = true }
                    .disabled(isBusy || regenerationJob != nil)
                Button("Reset Progress", systemImage: "arrow.counterclockwise") { isConfirmingReset = true }
            }
        }
    }

    // MARK: Actions

    private func checkDoc() async {
        await run { try await sync.sync(deck) }
    }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch DocSyncService.SyncError.busy {
            // Already running; the overlay shows progress.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ card: Flashcard) {
        deck.cards.removeAll { $0.id == card.id }
        modelContext.delete(card)
        try? modelContext.save()
    }
}

private struct StudyModeTile: View {
    let mode: StudyMode
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: mode.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(height: 30)
                Text(mode.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(mode.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("study-\(mode.rawValue)")
    }
}

private struct CardRow: View {
    @Bindable var card: Flashcard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(card.front)
                    .font(.body.weight(.semibold))
                Text(card.back)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if card.activeSyncBadge != nil || card.masteryLevel >= Flashcard.masteredLevel || card.isUserEdited {
                    HStack(spacing: 6) {
                        if let badge = card.activeSyncBadge {
                            SyncBadgeView(badge: badge)
                        }
                        if card.masteryLevel >= Flashcard.masteredLevel {
                            Label("Mastered", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        if card.isUserEdited {
                            Label("Edited", systemImage: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 0)
            Button {
                card.isStarred.toggle()
            } label: {
                Image(systemName: card.isStarred ? "star.fill" : "star")
                    .foregroundStyle(card.isStarred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(card.isStarred ? "Unstar" : "Star")
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("card-row")
    }
}

struct StudySessionView: View {
    let mode: StudyMode
    let deck: Deck
    let cards: [Flashcard]

    var body: some View {
        switch mode {
        case .flashcards:
            FlashcardStudyView(title: deck.title, cards: cards)
        case .learn:
            LearnView(title: deck.title, cards: cards)
        case .match:
            MatchView(deck: deck, cards: cards)
        }
    }
}
