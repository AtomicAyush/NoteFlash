import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct NewDeckView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ProcessingCenter.self) private var processing
    @Environment(GoogleAuth.self) private var googleAuth
    @AppStorage(AIEngineKind.storageKey) private var engine: AIEngineKind = .apple
    @Query private var decks: [Deck]

    @State private var kind: SourceKind = .text
    @State private var title = ""
    @State private var notes = ""
    @State private var pdfData: Data?
    @State private var pdfName: String?
    @State private var pdfPageCount = 0
    @State private var docLink = ""
    @State private var selectedDoc: DriveItem?
    @State private var isPickingDoc = false
    @State private var autoSync = true
    @State private var density: CardDensity = .balanced
    @State private var isImportingPDF = false
    @State private var errorMessage: String?

    private var canGenerate: Bool {
        switch kind {
        case .text: !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pdf: pdfData != nil
        case .googleDoc: chosenDocumentID != nil
        }
    }

    private var chosenDocumentID: String? {
        selectedDoc?.id ?? GoogleDocsClient.documentID(from: docLink)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Source", selection: $kind) {
                        ForEach(SourceKind.allCases) { kind in
                            Label(kind.label, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                switch kind {
                case .text: textSection
                case .pdf: pdfSection
                case .googleDoc: googleDocSections
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
                    .disabled(!canGenerate)
                }
            }
            .fileImporter(isPresented: $isImportingPDF, allowedContentTypes: [.pdf], onCompletion: importPDF)
            .sheet(isPresented: $isPickingDoc) {
                GoogleDocPickerView(linkedDocIDs: Set(decks.compactMap(\.googleDocID))) { doc in
                    selectedDoc = doc
                    docLink = doc.editURL
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

    private var pdfSection: some View {
        Section {
            if let pdfName {
                LabeledContent {
                    Text("^[\(pdfPageCount) page](inflect: true)")
                } label: {
                    Label(pdfName, systemImage: "doc.richtext.fill")
                        .lineLimit(2)
                }
                Button("Choose a Different PDF") { isImportingPDF = true }
            } else {
                Button {
                    isImportingPDF = true
                } label: {
                    Label("Choose PDF…", systemImage: "doc.badge.plus")
                }
            }
        } header: {
            Text("PDF")
        } footer: {
            switch engine {
            case .apple:
                Text("Text is read from the PDF on this iPhone. Scanned pages go through on-device text recognition.")
            case .claude:
                Text("Claude reads the whole PDF, including scanned pages, tables, and diagrams.")
            }
        }
    }

    @ViewBuilder
    private var googleDocSections: some View {
        Section {
            if googleAuth.isConfigured {
                if let selectedDoc {
                    selectedDocRow(selectedDoc)
                } else {
                    Button {
                        isPickingDoc = true
                    } label: {
                        Label("Choose from Google Drive", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
            if selectedDoc == nil {
                TextField(
                    googleAuth.isConfigured ? "Or paste a doc link" : "https://docs.google.com/document/d/…",
                    text: $docLink,
                    axis: .vertical
                )
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                PasteButton(payloadType: String.self) { strings in
                    docLink = strings.first ?? docLink
                }
            }
            Toggle("Keep cards in sync with the doc", isOn: $autoSync)
        } header: {
            Text("Google Doc")
        } footer: {
            Text("When the doc changes, NoteFlash updates the affected cards and adds cards for new material. Cards you edit by hand are never overwritten.")
        }

        if selectedDoc == nil {
            Section {
                DisclosureGroup("How to share a doc by link") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Open the doc in Google Docs and tap **Share**.", systemImage: "1.circle")
                        Label("Under **General access**, choose **Anyone with the link** (Viewer is enough).", systemImage: "2.circle")
                        Label("Tap **Copy link**, then tap **Paste** above.", systemImage: "3.circle")
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)
                }
            } footer: {
                Text(googleAuth.isConfigured
                    ? "Links work for docs shared as “Anyone with the link”, even without signing in. To use a private doc, choose it from Google Drive instead."
                    : "NoteFlash reads docs shared as “Anyone with the link can view”. Anyone with the link can read the doc, so avoid sharing private information this way.")
            }
        }
    }

    private func selectedDocRow(_ doc: DriveItem) -> some View {
        HStack(spacing: 12) {
            Button {
                isPickingDoc = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.fill")
                        .font(.title2)
                        .foregroundStyle(Color.docBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.name)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(DriveText.modified(doc))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Tap to choose a different doc")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                selectedDoc = nil
                docLink = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove doc")
        }
    }

    // MARK: Actions

    private func importPDF(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let pageCount = PDFTextExtractor.pageCount(of: data) else {
                    errorMessage = DeckCreator.CreationError.unreadablePDF.localizedDescription
                    return
                }
                pdfData = data
                pdfName = url.lastPathComponent
                pdfPageCount = pageCount
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Rough processing time for typed notes or a PDF (a Google Doc's length isn't known yet).
    private var estimatedSeconds: TimeInterval? {
        let characters: Int
        switch kind {
        case .text:
            characters = notes.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard characters > 0 else { return nil }
        case .pdf:
            guard pdfData != nil else { return nil }
            characters = ProcessingEstimator.estimatedCharacters(pdfPages: pdfPageCount)
        case .googleDoc:
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

        let source: NewDeckSource
        let jobTitle: String
        switch kind {
        case .text:
            let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
            source = .text(title: trimmedTitle, notes: notes)
            let firstLine = TextDiff.lines(of: notes).first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            jobTitle = trimmedTitle.isEmpty ? String((firstLine ?? "Your notes").prefix(40)) : trimmedTitle
        case .pdf:
            guard let pdfData else { return }
            let name = pdfName ?? "Document.pdf"
            source = .pdf(fileName: name, data: pdfData)
            jobTitle = (name as NSString).deletingPathExtension
        case .googleDoc:
            guard let documentID = chosenDocumentID else {
                errorMessage = GoogleDocsClient.DocsError.invalidLink.localizedDescription
                return
            }
            source = .googleDoc(documentID: documentID, autoSync: autoSync)
            jobTitle = selectedDoc?.name ?? "Google Doc"
        }

        processing.startNewDeck(from: source, density: density, title: jobTitle)
        dismiss()
    }
}
