import SwiftUI

/// Recent processing events, newest first, for diagnosing failed jobs.
struct ProcessingLogView: View {
    private var log = DiagnosticsLog.shared

    var body: some View {
        List {
            if log.entries.isEmpty {
                ContentUnavailableView("No Events Yet", systemImage: "list.bullet.rectangle", description: Text("Events appear here when NoteFlash makes or updates flashcards."))
            } else {
                ForEach(Array(log.entries.enumerated().reversed()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Processing Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = log.entries.joined(separator: "\n")
                }
                .disabled(log.entries.isEmpty)
                Button("Clear", systemImage: "trash", role: .destructive) {
                    log.clear()
                }
                .disabled(log.entries.isEmpty)
            }
        }
    }
}
