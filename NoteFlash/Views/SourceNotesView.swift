import PDFKit
import SwiftUI

struct SourceNotesView: View {
    let deck: Deck
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if deck.sourceKind == .pdf || deck.sourceKind == .drivePDF, let data = deck.sourcePDF {
                    PDFKitView(data: data)
                        .ignoresSafeArea(edges: .bottom)
                } else if deck.sourceText.isEmpty {
                    ContentUnavailableView("No Notes", systemImage: "doc.text")
                } else if deck.sourceKind.hasEditableNotes {
                    ScrollView {
                        Text(deck.sourceText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    ScrollView {
                        DocTextView(text: deck.sourceText)
                            .padding()
                    }
                }
            }
            .navigationTitle(deck.sourceName ?? "Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if let link = deck.googleDocURL.flatMap(URL.init(string:)) {
                    ToolbarItem(placement: .topBarLeading) {
                        Link(destination: link) {
                            Label(deck.openLinkLabel, systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
        }
    }
}

private struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
