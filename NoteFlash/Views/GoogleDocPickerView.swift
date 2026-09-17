import SwiftUI

/// Lists the signed-in user's Google Docs so they can pick one without copying a link.
struct GoogleDocPickerView: View {
    /// Docs that already have a deck, marked in the list.
    let linkedDocIDs: Set<String>
    let onSelect: (DriveDoc) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(GoogleAuth.self) private var googleAuth
    @State private var model = GoogleDocPickerModel()
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Google Docs")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Search your Docs")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task(id: ReloadKey(search: searchText, canList: googleAuth.canListDocs)) {
                    // Debounce typing before searching Drive.
                    if !searchText.isEmpty {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                    }
                    await model.reload(search: searchText, auth: googleAuth)
                }
        }
    }

    private struct ReloadKey: Equatable {
        let search: String
        let canList: Bool
    }

    @ViewBuilder
    private var content: some View {
        if !googleAuth.isSignedIn {
            ContentUnavailableView {
                Label("Sign In to See Your Docs", systemImage: "person.crop.circle")
            } description: {
                Text("Sign in with Google to pick a doc from your Drive.")
            } actions: {
                GoogleSignInButton(prominent: true)
            }
        } else if model.needsPermission || !googleAuth.canListDocs {
            ContentUnavailableView {
                Label("Allow Access to Your Docs List", systemImage: "list.bullet.rectangle")
            } description: {
                Text("NoteFlash needs read-only access to the names of your Drive files to show your Docs here. It never changes your files.")
            } actions: {
                GoogleSignInButton(title: "Allow Access", systemImage: "checkmark.shield", prominent: true)
            }
        } else if model.docs.isEmpty {
            if model.isLoading {
                ProgressView("Loading your Docs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't Load Your Docs", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await model.reload(search: searchText, auth: googleAuth) }
                    }
                    .buttonStyle(.bordered)
                }
            } else if !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ContentUnavailableView(
                    "No Google Docs",
                    systemImage: "doc.text",
                    description: Text("Docs you create or that are shared with you will show up here.")
                )
            }
        } else {
            List {
                Section {
                    ForEach(model.docs) { doc in
                        Button {
                            onSelect(doc)
                            dismiss()
                        } label: {
                            DocRow(doc: doc, isLinked: linkedDocIDs.contains(doc.id))
                        }
                        .accessibilityIdentifier("drive-doc")
                    }
                    if model.nextPageToken != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task { await model.loadMore(auth: googleAuth) }
                    }
                } footer: {
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .refreshable { await model.reload(search: searchText, auth: googleAuth) }
        }
    }
}

private struct DocRow: View {
    let doc: DriveDoc
    let isLinked: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title2)
                .foregroundStyle(Color(red: 0.26, green: 0.52, blue: 0.96))
            VStack(alignment: .leading, spacing: 3) {
                Text(doc.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isLinked {
                Label("Deck", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }

    private var detail: String {
        var parts: [String] = []
        if let modified = doc.modifiedTime {
            parts.append("Edited \(modified.formatted(.relative(presentation: .named)))")
        }
        if !doc.ownedByMe, let owner = doc.ownerName {
            parts.append("Shared by \(owner)")
        }
        return parts.joined(separator: " · ")
    }
}

@Observable
final class GoogleDocPickerModel {
    private(set) var docs: [DriveDoc] = []
    private(set) var nextPageToken: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var needsPermission = false

    private var search = ""
    private var generation = 0

    func reload(search: String, auth: GoogleAuth) async {
        self.search = search
        generation += 1
        await load(pageToken: nil, auth: auth, generation: generation)
    }

    func loadMore(auth: GoogleAuth) async {
        guard let token = nextPageToken, !isLoading else { return }
        await load(pageToken: token, auth: auth, generation: generation)
    }

    private func load(pageToken: String?, auth: GoogleAuth, generation: Int) async {
        guard auth.canListDocs else {
            needsPermission = auth.isSignedIn
            return
        }
        isLoading = true
        defer { if generation == self.generation { isLoading = false } }

        do {
            let page = try await fetchPage(pageToken: pageToken, auth: auth)
            // A newer search replaced this one while it was loading.
            guard generation == self.generation else { return }
            if pageToken == nil {
                docs = page.docs
            } else {
                let known = Set(docs.map(\.id))
                docs += page.docs.filter { !known.contains($0.id) }
            }
            nextPageToken = page.nextPageToken
            errorMessage = nil
            needsPermission = false
        } catch GoogleDriveClient.DriveError.missingPermission {
            needsPermission = true
        } catch let error as URLError where error.code == .cancelled {
            // The search changed; the new request takes over.
        } catch is CancellationError {
            // Same as above.
        } catch {
            guard generation == self.generation else { return }
            if pageToken == nil { docs = [] }
            nextPageToken = nil
            errorMessage = error.localizedDescription
        }
    }

    private func fetchPage(pageToken: String?, auth: GoogleAuth) async throws -> DriveDocPage {
        do {
            let token = try await auth.validAccessToken()
            return try await GoogleDriveClient.listDocuments(accessToken: token, search: search, pageToken: pageToken)
        } catch GoogleDriveClient.DriveError.unauthorized {
            auth.invalidateAccessToken()
            let token = try await auth.validAccessToken()
            return try await GoogleDriveClient.listDocuments(accessToken: token, search: search, pageToken: pageToken)
        }
    }
}
