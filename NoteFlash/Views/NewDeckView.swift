import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct NewDeckView: View {
    var onCreated: (Deck) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DocSyncService.self) private var sync
    @Environment(GoogleAuth.self) private var googleAuth
    @AppStorage(AIEngineKind.storageKey) private var engine: AIEngineKind = .apple

    @State private var kind: SourceKind = .text
    @State private var title = ""
    @State private var notes = ""
    @State private var pdfData: Data?
    @State private var pdfName: String?
    @State private var pdfPageCount = 0
    @State private var docLink = ""
    @State private var autoSync = true
    @State private var density: CardDensity = .balanced
    @State private var isImportingPDF = false
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var canGenerate: Bool {
        switch kind {
        case .text: !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pdf: pdfData != nil
        case .googleDoc: GoogleDocsClient.documentID(from: docLink) != nil
        }
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
                    Text("\(density.promptGuidance)\n\nCards are written by \(engine.label). You can change this in Settings.")
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
                        Task { await generate() }
                    }
                    .disabled(!canGenerate || isGenerating)
                }
            }
            .fileImporter(isPresented: $isImportingPDF, allowedContentTypes: [.pdf], onCompletion: importPDF)
            .overlay {
                if isGenerating {
                    WorkingOverlay(
                        title: "Writing flashcards…",
                        subtitle: engine.workingDescription
                    )
                }
            }
            .animation(.default, value: isGenerating)
            .interactiveDismissDisabled(isGenerating)
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
            TextField("https://docs.google.com/document/d/…", text: $docLink, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            PasteButton(payloadType: String.self) { strings in
                docLink = strings.first ?? docLink
            }
            Toggle("Keep cards in sync with the doc", isOn: $autoSync)
        } header: {
            Text("Google Doc")
        } footer: {
            Text("When the doc changes, NoteFlash updates the affected cards and adds cards for new material. Cards you edit by hand are never overwritten.")
        }

        GoogleAccountSection()
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

    private func generate() async {
        let source: NewDeckSource
        switch kind {
        case .text:
            source = .text(title: title, notes: notes)
        case .pdf:
            guard let pdfData else { return }
            source = .pdf(fileName: pdfName ?? "Document.pdf", data: pdfData)
        case .googleDoc:
            source = .googleDoc(link: docLink, autoSync: autoSync)
        }

        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let deck = try await DeckCreator.createDeck(
                from: source,
                density: density,
                sync: sync,
                context: modelContext
            )
            onCreated(deck)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
