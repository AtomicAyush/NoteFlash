import SwiftData
import SwiftUI

/// Confirms adding a deck someone shared, so the user sees what they're getting first.
struct ImportSharedDeckView: View {
    let shared: SharedDeck
    let onAdded: (Deck) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(GoogleAuth.self) private var googleAuth
    @State private var title: String
    @State private var errorMessage: String?
    @State private var linkToSource = true
    @State private var access = SourceAccess.unchecked

    /// Whether the recipient can open the Google Drive file the cards were made from.
    private enum SourceAccess: Equatable {
        case unchecked, checking, canOpen(String?), cannotOpen(String)
    }

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

                if let source = shared.source {
                    sourceSection(source)
                }
            }
            .task {
                if let source = shared.source { await checkAccess(to: source) }
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

    /// Offers to link the new deck to the same Google Drive file, when the notes came from one.
    @ViewBuilder
    private func sourceSection(_ source: SharedDeck.Source) -> some View {
        let label = DriveFileKind(rawValue: source.kind ?? "")?.label ?? "Google Drive file"
        Section {
            switch access {
            case .unchecked, .checking:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking whether you can open \(source.name ?? label)…")
                        .foregroundStyle(.secondary)
                }
            case .canOpen(let name):
                Toggle(isOn: $linkToSource) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep in sync with the \(label)")
                            Text(name ?? source.name ?? label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            case .cannotOpen(let reason):
                Label(reason, systemImage: "link.badge.plus")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Source")
        } footer: {
            if case .canOpen = access {
                Text(existingDeck == nil
                    ? "Your copy updates when the \(label) changes, the same as the sender's."
                    : "You already have a deck linked to this \(label) (“\(existingDeck?.title ?? "")”). Adding this makes a second one.")
            }
        }
    }

    private var existingDeck: Deck? {
        shared.source.flatMap { SharedDeckImporter.deck(linkedTo: $0, in: modelContext) }
    }

    /// Looks the file up with the recipient's own account: a collaborator can open it, anyone
    /// else gets the cards without syncing.
    private func checkAccess(to source: SharedDeck.Source) async {
        guard googleAuth.isSignedIn else {
            access = .cannotOpen("These cards came from a \(DriveFileKind(rawValue: source.kind ?? "")?.label ?? "Google Drive file"). Sign in with Google in Settings to keep your copy in sync with it.")
            return
        }
        access = .checking
        do {
            let token = try await googleAuth.validAccessToken()
            let file = try await GoogleDriveClient.metadata(accessToken: token, id: source.id)
            access = .canOpen(file.name)
        } catch {
            access = .cannotOpen("You don't have access to the \(DriveFileKind(rawValue: source.kind ?? "")?.label ?? "file") these cards came from, so they're added as a copy.")
        }
    }

    private func add() {
        var linking = false
        if case .canOpen = access { linking = linkToSource }
        do {
            let deck = try SharedDeckImporter.addDeck(shared, title: title, linkingToSource: linking, to: modelContext)
            dismiss()
            onAdded(deck)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
