import SwiftUI

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("NoteFlash")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Reading what you shared…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Use This", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .saved(let notified):
            ContentUnavailableView {
                Label("Sent to NoteFlash", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } description: {
                Text(notified
                    ? "Tap the notification to open NoteFlash. Your flashcards are made as soon as it opens."
                    : "Open NoteFlash to make your flashcards. They're made as soon as it opens.")
            }
        case .ready, .saving:
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: model.systemImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.summaryTitle)
                            .font(.headline)
                        Text(model.summaryDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            if model.makesSeveralDecks {
                Section {
                    Label("Each PDF or PowerPoint file becomes its own deck, and any images become one deck.", systemImage: "square.stack")
                        .font(.subheadline)
                }
            } else {
                Section("Deck Title") {
                    TextField("Title (optional)", text: $model.title)
                }
            }

            Section {
                Picker("Card Detail", selection: $model.density) {
                    ForEach(ShareModel.densities, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
            } footer: {
                Text("NoteFlash makes the cards with the AI model chosen in its Settings. Handwriting in PDFs and images is read with on-device text recognition.")
            }
        }
        .disabled(model.state == .saving)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.state {
        case .saved:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { model.finish() }
            }
        case .failed:
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { model.cancel() }
            }
        default:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Make Cards") {
                    Task { await model.save() }
                }
                .disabled(model.state != .ready)
            }
        }
    }
}
