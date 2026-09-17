import Observation
import SwiftUI

enum DriveLayout: String {
    case list
    case grid
}

/// Folders and files at one Drive location (or search results), in a list or grid.
struct DriveListingView: View {
    let content: DriveListingModel.Content
    let title: String?
    let context: DrivePickerContext

    @Environment(GoogleAuth.self) private var googleAuth
    @AppStorage("driveSort") private var sortRaw = DriveSort.modified.rawValue
    @AppStorage("driveSortAscending") private var ascending = false
    @AppStorage("driveLayout") private var layoutRaw = DriveLayout.list.rawValue
    @State private var model: DriveListingModel

    init(content: DriveListingModel.Content, title: String?, context: DrivePickerContext) {
        self.content = content
        self.title = title
        self.context = context
        _model = State(initialValue: DriveListingModel(content: content))
    }

    private var sort: DriveSort { DriveSort(rawValue: sortRaw) ?? .modified }
    private var layout: DriveLayout { DriveLayout(rawValue: layoutRaw) ?? .list }
    private var isRecent: Bool { content == .location(.recent) }
    /// Recent is always ordered by when you opened each doc.
    private var effectiveSort: DriveSort { isRecent ? .opened : sort }
    private var effectiveAscending: Bool { isRecent ? false : ascending }

    /// Where a doc lives is worth showing when the list isn't a single folder.
    private var showsLocation: Bool {
        switch content {
        case .search, .location(.starred), .location(.recent): true
        case .location(.folder), .location(.sharedWithMe): false
        }
    }

    var body: some View {
        titled(states)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DriveViewOptionsMenu(
                        sortRaw: $sortRaw,
                        ascending: $ascending,
                        layoutRaw: $layoutRaw,
                        sortLocked: isRecent
                    )
                }
            }
            .task(id: "\(sortRaw)-\(ascending)-\(googleAuth.hasDriveAccess)") {
                await model.load(sort: effectiveSort, ascending: effectiveAscending, context: context, auth: googleAuth)
            }
    }

    @ViewBuilder
    private func titled(_ view: some View) -> some View {
        if let title {
            view.navigationTitle(title)
        } else {
            view
        }
    }

    @ViewBuilder
    private var states: some View {
        if model.needsPermission {
            DrivePermissionView()
        } else if !model.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isEmpty, let error = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Drive", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await reload() } }
                    .buttonStyle(.bordered)
            }
        } else if model.isEmpty {
            emptyState
        } else if layout == .grid {
            grid
        } else {
            list
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch content {
        case .search(let term):
            ContentUnavailableView.search(text: term)
        case .location(.folder):
            ContentUnavailableView("Nothing to Use Here", systemImage: "folder",
                                   description: Text("This folder has no Google Docs, Slides, PDFs, PowerPoint files, or folders."))
        case .location(.sharedWithMe):
            ContentUnavailableView("Nothing Shared", systemImage: "person.2",
                                   description: Text("Docs, Slides, PDFs, and PowerPoint files that people share with you will appear here."))
        case .location(.starred):
            ContentUnavailableView("Nothing Starred", systemImage: "star",
                                   description: Text("Star files or folders in Google Drive to find them here quickly."))
        case .location(.recent):
            ContentUnavailableView("Nothing Recent", systemImage: "clock",
                                   description: Text("Docs, Slides, PDFs, and PowerPoint files you open will appear here."))
        }
    }

    // MARK: List

    private var list: some View {
        List {
            if !model.folders.isEmpty {
                Section("Folders") {
                    ForEach(model.folders) { folder in
                        NavigationLink(value: DriveRoute.folder(folder)) {
                            DriveFolderRow(item: folder, showsLocation: showsLocation, context: context)
                        }
                        .accessibilityIdentifier("drive-folder")
                    }
                }
            }
            if !model.docs.isEmpty {
                Section {
                    ForEach(model.docs) { doc in
                        NavigationLink(value: DriveRoute.preview(doc)) {
                            DriveDocRow(item: doc, sort: effectiveSort, showsLocation: showsLocation, context: context)
                        }
                        .accessibilityIdentifier("drive-doc")
                        .swipeActions(edge: .leading) {
                            Button("Use", systemImage: "checkmark") { context.select(doc) }
                                .tint(.accentColor)
                        }
                        .contextMenu { docMenu(doc) }
                        .onAppear { loadMoreIfLast(doc) }
                    }
                    if model.nextPageToken != nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } header: {
                    sortHeader
                } footer: {
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
        }
        .refreshable { await reload() }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 12) {
                if !model.folders.isEmpty {
                    Section {
                        ForEach(model.folders) { folder in
                            NavigationLink(value: DriveRoute.folder(folder)) {
                                DriveFolderTile(item: folder)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("drive-folder")
                        }
                    } header: {
                        gridHeader { Text("Folders") }
                    }
                }
                if !model.docs.isEmpty {
                    Section {
                        ForEach(model.docs) { doc in
                            NavigationLink(value: DriveRoute.preview(doc)) {
                                DriveDocCard(item: doc, sort: effectiveSort, showsLocation: showsLocation, context: context)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("drive-doc")
                            .contextMenu { docMenu(doc) }
                            .onAppear { loadMoreIfLast(doc) }
                        }
                    } header: {
                        gridHeader { sortHeader }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            if model.nextPageToken != nil {
                ProgressView().padding()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await reload() }
    }

    private func gridHeader<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        label()
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    // MARK: Pieces

    /// "Last modified ↓" — tap to flip the order, like Drive's column header.
    @ViewBuilder
    private var sortHeader: some View {
        if isRecent {
            Text("Last opened by me")
        } else {
            Button {
                ascending.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(sort.label)
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sorted by \(sort.label), \(sort.directionLabel(ascending: ascending))")
            .accessibilityHint("Double-tap to reverse the order")
        }
    }

    @ViewBuilder
    private func docMenu(_ doc: DriveItem) -> some View {
        Button("Use This File", systemImage: "checkmark.circle") { context.select(doc) }
        NavigationLink(value: DriveRoute.preview(doc)) {
            Label("Preview", systemImage: "eye")
        }
        if let url = doc.openURL {
            Link(destination: url) {
                Label(doc.kind?.openLabel ?? "Open in Google Drive", systemImage: "arrow.up.right.square")
            }
        }
    }

    private func loadMoreIfLast(_ doc: DriveItem) {
        guard doc.id == model.docs.last?.id, model.nextPageToken != nil else { return }
        Task { await model.loadMore(context: context, auth: googleAuth) }
    }

    private func reload() async {
        await model.load(sort: effectiveSort, ascending: effectiveAscending, context: context, auth: googleAuth, force: true)
    }
}

@Observable
final class DriveListingModel {
    enum Content: Hashable {
        case location(DriveLocation)
        case search(String)
    }

    let content: Content
    private(set) var folders: [DriveItem] = []
    private(set) var docs: [DriveItem] = []
    private(set) var nextPageToken: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var needsPermission = false

    private var sort: DriveSort = .modified
    private var ascending = false
    private var generation = 0

    init(content: Content) {
        self.content = content
    }

    var isEmpty: Bool { folders.isEmpty && docs.isEmpty }

    func load(sort: DriveSort, ascending: Bool, context: DrivePickerContext, auth: GoogleAuth, force: Bool = false) async {
        let sortChanged = sort != self.sort || ascending != self.ascending
        self.sort = sort
        self.ascending = ascending

        // Search results come back unordered, so re-sorting them needs no new request.
        if case .search = content, hasLoaded, !force, errorMessage == nil {
            if sortChanged { resort() }
            return
        }

        generation += 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }

        do {
            switch content {
            case .location(let location):
                let listing = try await context.source.listing(in: location, sort: sort, ascending: ascending, auth: auth)
                guard current == generation else { return }
                folders = listing.folders
                docs = listing.docs.items
                nextPageToken = listing.docs.nextPageToken
            case .search(let term):
                let page = try await context.source.search(term, pageToken: nil, auth: auth)
                guard current == generation else { return }
                apply(searchPage: page, replacing: true)
            }
            errorMessage = nil
            needsPermission = false
        } catch {
            guard current == generation else { return }
            handle(error)
        }
        hasLoaded = true
    }

    func loadMore(context: DrivePickerContext, auth: GoogleAuth) async {
        guard let pageToken = nextPageToken, !isLoading else { return }
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }

        do {
            switch content {
            case .location(let location):
                let page = try await context.source.moreDocs(
                    in: location, sort: sort, ascending: ascending, pageToken: pageToken, auth: auth
                )
                guard current == generation else { return }
                let known = Set(docs.map(\.id))
                docs += page.items.filter { !known.contains($0.id) }
                nextPageToken = page.nextPageToken
            case .search(let term):
                let page = try await context.source.search(term, pageToken: pageToken, auth: auth)
                guard current == generation else { return }
                apply(searchPage: page, replacing: false)
            }
        } catch {
            guard current == generation else { return }
            nextPageToken = nil
            handle(error)
        }
    }

    private func apply(searchPage page: DrivePage, replacing: Bool) {
        let known = replacing ? Set<String>() : Set((folders + docs).map(\.id))
        let fresh = page.items.filter { !known.contains($0.id) }
        folders = (replacing ? [] : folders) + fresh.filter(\.isFolder)
        docs = (replacing ? [] : docs) + fresh.filter { !$0.isFolder }
        nextPageToken = page.nextPageToken
        resort()
    }

    private func resort() {
        folders = sort.sorted(folders, ascending: ascending)
        docs = sort.sorted(docs, ascending: ascending)
    }

    private func handle(_ error: Error) {
        switch error {
        case GoogleDriveClient.DriveError.missingPermission:
            needsPermission = true
        case let urlError as URLError where urlError.code == .cancelled:
            break
        case is CancellationError:
            break
        default:
            errorMessage = error.localizedDescription
        }
    }
}
