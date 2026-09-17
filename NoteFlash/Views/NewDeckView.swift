import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct NewDeckView: View {
    /// Where the notes for a new deck come from.
    enum Source: String, CaseIterable, Identifiable {
        case text
        case file
        case drive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .text: "Text"
            case .file: "File"
            case .drive: "Google Drive"
            }
        }

        var systemImage: String {
            switch self {
            case .text: "text.alignleft"
            case .file: "doc"
            case .drive: "externaldrive"
            }
        }
    }

    /// A PDF or PowerPoint file, or photos of notes, picked for a new deck.
    nonisolated private struct PickedFile: Sendable {
        enum Kind: Sendable {
            case pdf
            case presentation
            /// One or more photos or scanned pages, made into one deck.
            case images
        }

        let name: String
        /// The file, or each image.
        let items: [Data]
        let kind: Kind
        /// "12 pages", "8 slides", or "3 photos"
        let summary: String
        /// Approximate notes length, for the time estimate.
        let characters: Int
    }

    private static let powerPointType = UTType("org.openxmlformats.presentationml.presentation") ?? .presentation

    @Environment(\.dismiss) private var dismiss
    @Environment(ProcessingCenter.self) private var processing
    @Environment(GoogleAuth.self) private var googleAuth
    @AppStorage(AIEngineKind.storageKey) private var engine: AIEngineKind = .apple
    @Query private var decks: [Deck]

    @State private var source: Source = .text
    @State private var title = ""
    @State private var notes = ""
    @State private var pickedFile: PickedFile?
    @State private var isReadingFile = false
    @State private var isImportingFile = false
    @State private var isScanning = false
    @State private var isChoosingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var driveLink = ""
    @State private var selectedFile: DriveItem?
    @State private var isPickingFile = false
    @State private var autoSync = true
    @State private var density: CardDensity = .balanced
    @State private var errorMessage: String?
    private let incoming: IncomingNotes?

    /// `incoming` fills in notes another app opened in NoteFlash.
    init(incoming: IncomingNotes? = nil) {
        self.incoming = incoming
        switch incoming?.content {
        case .text(let title, let notes):
            _title = State(initialValue: title)
            _notes = State(initialValue: notes)
        case .file:
            _source = State(initialValue: .file)
        case nil:
            break
        }
    }

    private var canGenerate: Bool {
        switch source {
        case .text: !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file: pickedFile != nil
        case .drive: chosenReference != nil
        }
    }

    private var chosenReference: DriveFileReference? {
        selectedFile?.reference ?? DriveFileReference(link: driveLink)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source", selection: $source) {
                        ForEach(Source.allCases) { source in
                            Label(source.label, systemImage: source.systemImage).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch source {
                case .text: textSection
                case .file: fileSection
                case .drive: driveSections
                }

                Section {
                    Picker("Detail", selection: $density) {
                        ForEach(CardDensity.allCases) { density in
                            Text(density.label).tag(density)
                        }
                    }
                } header: {
                    Text("Cards")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(density.promptGuidance)
                        if let estimate = estimatedSeconds {
                            Label("Estimated time: \(ETAText.estimate(estimate))", systemImage: "clock")
                                .foregroundStyle(.primary)
                        }
                        Text("Cards are written by \(engine.label). Processing keeps going if you leave NoteFlash, and you can follow it in the Dynamic Island.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate", systemImage: "sparkles") {
                        generate()
                    }
                    .disabled(!canGenerate || isReadingFile)
                }
            }
            .fileImporter(
                isPresented: $isImportingFile,
                allowedContentTypes: [.pdf, Self.powerPointType, .image],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .photosPicker(
                isPresented: $isChoosingPhotos,
                selection: $photoSelection,
                maxSelectionCount: 30,
                selectionBehavior: .ordered,
                matching: .images
            )
            .onChange(of: photoSelection) {
                guard !photoSelection.isEmpty else { return }
                let items = photoSelection
                photoSelection = []
                Task { await loadPhotos(items) }
            }
            .fullScreenCover(isPresented: $isScanning) {
                DocumentScannerView { pages in
                    isScanning = false
                    guard !pages.isEmpty else { return }
                    pickImages(pages, name: "Scanned notes", summary: Self.pageCount(pages.count, noun: "page"))
                }
                .ignoresSafeArea()
            }
            .task {
                if case .file(let name, let data) = incoming?.content, pickedFile == nil {
                    await pick([(name, data)])
                }
            }
            .sheet(isPresented: $isPickingFile) {
                GoogleDocPickerView(linkedDocIDs: Set(decks.compactMap(\.googleDocID))) { item in
                    selectedFile = item
                    driveLink = ""
                }
            }
        }
    }

    // MARK: Sections

    private var textSection: some View {
        Section {
            TextField("Title (optional)", text: $title)
            TextEditor(text: $notes)
                .frame(minHeight: 240)
                .accessibilityIdentifier("notes-editor")
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Type or paste your notes…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                notes = notes.isEmpty ? text : notes + "\n" + text
            }
        } header: {
            Text("Notes")
        }
    }

    private var fileSection: some View {
        Section {
            if let pickedFile {
                LabeledContent {
                    Text(pickedFile.summary)
                } label: {
                    Label(pickedFile.name, systemImage: Self.systemImage(for: pickedFile.kind))
                        .lineLimit(2)
                }
                if pickedFile.kind == .images {
                    ImageThumbnailStrip(images: pickedFile.items)
                }
                chooseMenu(title: "Choose Something Else", systemImage: "arrow.triangle.2.circlepath")
            } else if isReadingFile {
                HStack {
                    Text("Reading…")
                    Spacer()
                    ProgressView()
                }
            } else {
                chooseMenu(title: "Choose Notes…", systemImage: "doc.badge.plus")
            }
        } header: {
            Text("Photos, PDF, or PowerPoint")
        } footer: {
            fileFooter
        }
    }

    @ViewBuilder
    private var driveSections: some View {
        Section {
            if googleAuth.isConfigured {
                if let selectedFile {
                    selectedFileRow(selectedFile)
                } else {
                    Button {
                        isPickingFile = true
                    } label: {
                        Label("Choose from Google Drive", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            if selectedFile == nil {
                TextField(
                    googleAuth.isConfigured ? "Or paste a link" : "https://docs.google.com/…",
                    text: $driveLink,
                    axis: .vertical
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                PasteButton(payloadType: String.self) { strings in
                    driveLink = strings.first ?? driveLink
                }
            }
            Toggle("Keep cards in sync with the file", isOn: $autoSync)
        } header: {
            Text("Google Drive")
        } footer: {
            Text("Works with Google Docs, Google Slides, PDFs, and PowerPoint files. When the file changes, NoteFlash updates the affected cards and adds cards for new material. Cards you edit by hand are never overwritten.")
        }

        if selectedFile == nil {
            Section {
                DisclosureGroup("How to share a file by link") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Open the file in Google Docs, Slides, or Drive and tap **Share**.", systemImage: "1.circle")
                        Label("Under **General access**, choose **Anyone with the link** (Viewer is enough).", systemImage: "2.circle")
                        Label("Tap **Copy link**, then tap **Paste** above.", systemImage: "3.circle")
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)
                }
            } footer: {
                Text(googleAuth.isConfigured
                    ? "Links work for files shared as “Anyone with the link”, even without signing in. To use a private file, choose it from Google Drive instead."
                    : "NoteFlash reads files shared as “Anyone with the link can view”. Anyone with the link can read the file, so avoid sharing private information this way.")
            }
        }
    }

    private func selectedFileRow(_ file: DriveItem) -> some View {
        HStack(spacing: 12) {
            Button {
                isPickingFile = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: file.kind?.systemImage ?? "doc.fill")
                        .font(.title2)
                        .foregroundStyle(Color.driveKind(file.kind))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(DriveText.modified(file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Tap to choose a different file")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                selectedFile = nil
                driveLink = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove file")
        }
    }

    // MARK: Actions

    /// Take photos, pick from the photo library, or pick files.
    private func chooseMenu(title: String, systemImage: String) -> some View {
        Menu {
            if DocumentScannerView.isAvailable {
                Button("Take Photos", systemImage: "camera") { isScanning = true }
            }
            Button("Choose from Photos", systemImage: "photo.on.rectangle") { isChoosingPhotos = true }
            Button("Choose from Files", systemImage: "folder") { isImportingFile = true }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var files: [(name: String, data: Data)] = []
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    files.append((url.lastPathComponent, try Data(contentsOf: url)))
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
            }
            guard !files.isEmpty else { return }
            Task { await pick(files) }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        errorMessage = nil
        isReadingFile = true
        defer { isReadingFile = false }
        var images: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                images.append(data)
            }
        }
        guard !images.isEmpty else {
            errorMessage = "Those photos couldn't be loaded. If they're in iCloud, make sure the iPhone is online."
            return
        }
        pickImages(images, name: "Photos of your notes", summary: Self.pageCount(images.count, noun: "photo"))
    }

    private func pickImages(_ images: [Data], name: String, summary: String) {
        errorMessage = nil
        pickedFile = PickedFile(
            name: name, items: images, kind: .images, summary: summary,
            characters: ProcessingEstimator.estimatedCharacters(pdfPages: images.count)
        )
    }

    /// Several images become one deck; otherwise pick a single PDF or PowerPoint file.
    private func pick(_ files: [(name: String, data: Data)]) async {
        errorMessage = nil
        pickedFile = nil
        isReadingFile = true
        defer { isReadingFile = false }
        do {
            if files.count == 1, let file = files.first {
                pickedFile = try await Self.inspect(file.data, name: file.name)
            } else if await Self.allImages(files.map(\.data)) {
                pickImages(files.map(\.data), name: "Images from Files", summary: Self.pageCount(files.count, noun: "image"))
            } else {
                errorMessage = "Choose one PDF or PowerPoint file at a time, or several images."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @concurrent
    private static func allImages(_ items: [Data]) async -> Bool {
        items.allSatisfy(ImageNotes.isImage)
    }

    private static func pageCount(_ count: Int, noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    private var fileFooter: Text {
        switch pickedFile?.kind {
        case .presentation:
            Text("Slide titles, text, tables, and speaker notes become your notes. Pictures and charts aren't read.")
        case .pdf, .images:
            engine == .claude
                ? Text("Claude reads the whole page, including handwriting, tables, and diagrams.")
                : Text("Text is read on this iPhone. Handwriting and scanned pages go through on-device text recognition.")
        case nil:
            Text("Take photos of paper notes, choose them from your photo library, or pick a PDF or PowerPoint (.pptx) file. From GoodNotes and similar apps, export as PDF and tap NoteFlash in the share sheet. For files in Google Drive, use the Google Drive tab so the deck stays in sync.")
        }
    }

    private static func systemImage(for kind: PickedFile.Kind) -> String {
        switch kind {
        case .pdf: "doc.richtext.fill"
        case .presentation: "rectangle.on.rectangle.fill"
        case .images: "photo.on.rectangle.angled"
        }
    }

    /// Checks that a file can be read, and measures it for the time estimate.
    @concurrent
    private static func inspect(_ data: Data, name: String) async throws -> PickedFile {
        if PowerPointTextExtractor.isPresentation(data) {
            let slides = try PowerPointTextExtractor.extract(from: data)
            guard !slides.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DriveFileReader.ReadError.empty
            }
            let summary = slides.slideCount == 1 ? "1 slide" : "\(slides.slideCount) slides"
            return PickedFile(name: name, items: [data], kind: .presentation, summary: summary, characters: slides.text.count)
        }
        if ImageNotes.isImage(data) {
            return PickedFile(
                name: name, items: [data], kind: .images, summary: "1 image",
                characters: ProcessingEstimator.estimatedCharacters(pdfPages: 1)
            )
        }
        guard let pages = PDFTextExtractor.pageCount(of: data) else {
            throw DeckCreator.CreationError.unsupportedFile
        }
        let summary = pages == 1 ? "1 page" : "\(pages) pages"
        return PickedFile(
            name: name, items: [data], kind: .pdf, summary: summary,
            characters: ProcessingEstimator.estimatedCharacters(pdfPages: pages)
        )
    }

    /// Rough processing time for typed notes or a file (a Drive file's length isn't known yet).
    private var estimatedSeconds: TimeInterval? {
        let characters: Int
        switch source {
        case .text:
            characters = notes.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard characters > 0 else { return nil }
        case .file:
            guard let pickedFile else { return nil }
            characters = pickedFile.characters
        case .drive:
            return nil
        }
        return ProcessingEstimator.expectedDuration(engine: engine, characters: characters)
    }

    private func generate() {
        errorMessage = nil
        if let problem = engine.setupProblem {
            errorMessage = problem
            return
        }

        let deckSource: NewDeckSource
        let jobTitle: String
        switch source {
        case .text:
            let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
            deckSource = .text(title: trimmedTitle, notes: notes)
            let firstLine = TextDiff.lines(of: notes).first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            jobTitle = trimmedTitle.isEmpty ? String((firstLine ?? "Your notes").prefix(40)) : trimmedTitle
        case .file:
            guard let pickedFile else { return }
            if pickedFile.kind == .images {
                deckSource = .images(name: pickedFile.name, data: pickedFile.items)
                jobTitle = pickedFile.name
            } else if let data = pickedFile.items.first {
                deckSource = .file(fileName: pickedFile.name, data: data)
                jobTitle = DriveFileReader.stripExtension(pickedFile.name)
            } else {
                return
            }
        case .drive:
            guard let reference = chosenReference else {
                errorMessage = DriveFileReader.ReadError.invalidLink.localizedDescription
                return
            }
            deckSource = .drive(reference, autoSync: autoSync)
            jobTitle = selectedFile.map { DriveFileReader.stripExtension($0.name) } ?? reference.kind?.label ?? "Google Drive file"
        }

        processing.startNewDeck(from: deckSource, density: density, title: jobTitle)
        dismiss()
    }
}
