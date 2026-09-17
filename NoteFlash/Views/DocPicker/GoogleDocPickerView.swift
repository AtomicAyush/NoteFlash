import Observation
import SwiftUI

/// Browse Google Drive like the Drive app (folders, shared, starred, recent, search),
/// preview a doc, and choose it for a new deck.
struct GoogleDocPickerView: View {
    /// Docs that already have a deck, marked in the lists.
    let linkedDocIDs: Set<String>
    let onSelect: (DriveItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(GoogleAuth.self) private var googleAuth
    @State private var path: [DriveRoute] = []
    @State private var scope: DriveScope = .myDrive
    @State private var searchText = ""
    @State private var activeSearch = ""
    @State private var folderNames = DriveFolderNameCache()
    private let source = DriveDataSources.current

    private var context: DrivePickerContext {
        DrivePickerContext(
            source: source,
            linkedDocIDs: linkedDocIDs,
            folderNames: folderNames,
            select: { item in
                onSelect(item)
                dismiss()
            }
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationTitle(activeSearch.isEmpty ? scope.title : "Search Results")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search in Drive"
                )
                .task(id: searchText) {
                    let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !term.isEmpty {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                    }
                    activeSearch = term
                }
                .navigationDestination(for: DriveRoute.self) { route in
                    switch route {
                    case .folder(let folder):
                        DriveListingView(
                            content: .location(.folder(id: folder.id)),
                            title: folder.name,
                            context: context
                        )
                    case .preview(let doc):
                        GoogleDocPreviewView(item: doc, context: context)
                    }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        if source.requiresSignIn(googleAuth) {
            ContentUnavailableView {
                Label("Sign In to See Your Docs", systemImage: "person.crop.circle")
            } description: {
                Text("Sign in with Google to browse your Drive and pick a doc.")
            } actions: {
                GoogleSignInButton(prominent: true)
            }
        } else if source.requiresListPermission(googleAuth) {
            DrivePermissionView()
        } else if !activeSearch.isEmpty {
            DriveListingView(content: .search(activeSearch), title: nil, context: context)
                .id("search-\(activeSearch)")
        } else {
            VStack(spacing: 0) {
                Picker("Location", selection: $scope) {
                    ForEach(DriveScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                DriveListingView(content: .location(scope.location), title: nil, context: context)
                    .id(scope)
            }
        }
    }
}

struct DrivePermissionView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Allow Access to Your Docs List", systemImage: "list.bullet.rectangle")
        } description: {
            Text("NoteFlash needs read-only access to the names of your Drive files to show your Docs here. It never changes your files.")
        } actions: {
            GoogleSignInButton(title: "Allow Access", systemImage: "checkmark.shield", prominent: true)
        }
    }
}

enum DriveScope: String, CaseIterable, Identifiable {
    case myDrive
    case shared
    case starred
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myDrive: "My Drive"
        case .shared: "Shared"
        case .starred: "Starred"
        case .recent: "Recent"
        }
    }

    var location: DriveLocation {
        switch self {
        case .myDrive: .folder(id: "root")
        case .shared: .sharedWithMe
        case .starred: .starred
        case .recent: .recent
        }
    }
}

enum DriveRoute: Hashable {
    case folder(DriveItem)
    case preview(DriveItem)
}

/// What every screen in the picker needs.
struct DrivePickerContext {
    let source: any DriveDataSource
    let linkedDocIDs: Set<String>
    let folderNames: DriveFolderNameCache
    let select: (DriveItem) -> Void
}

/// Looks up folder names so docs outside their folder (search, starred, recent) can show where they live.
@Observable
final class DriveFolderNameCache {
    private(set) var names: [String: String] = ["root": "My Drive"]
    private var requested: Set<String> = []

    func name(for id: String?) -> String? {
        guard let id, let name = names[id], !name.isEmpty else { return nil }
        return name
    }

    func resolve(_ id: String?, source: any DriveDataSource, auth: GoogleAuth) async {
        guard let id, names[id] == nil, requested.insert(id).inserted else { return }
        // Folders the user can't open (common for shared files) stay unnamed.
        names[id] = (try? await source.folderName(id: id, auth: auth)) ?? ""
    }
}
