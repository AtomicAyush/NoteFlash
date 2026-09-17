import SwiftUI

/// A deck being written: progress and time left while running, then a link or an error.
struct ProcessingJobRow: View {
    let job: ProcessingJob
    var onOpen: (UUID) -> Void = { _ in }

    @Environment(ProcessingCenter.self) private var processing

    var body: some View {
        switch job.state {
        case .running:
            running
        case .finished(let deckID, let summary):
            Button {
                processing.dismiss(job)
                onOpen(deckID)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(finishedLine(summary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .swipeActions {
                Button("Dismiss", systemImage: "xmark") { processing.dismiss(job) }
            }
        case .paused:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: job.resumeAt == nil ? "pause.circle.fill" : "hourglass.circle.fill")
                        .font(.title3)
                        .foregroundStyle(job.resumeAt == nil ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.headline)
                            .lineLimit(1)
                        pausedMessage
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                details
                actions(primary: job.resumeAt == nil ? "Resume" : "Try Now", systemImage: "play.fill")
            }
            .padding(.vertical, 2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                details
                actions(primary: "Retry", systemImage: "arrow.clockwise")
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var pausedMessage: some View {
        if let resumeAt = job.resumeAt {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let when = resumeAt <= context.date
                    ? "any moment now"
                    : "at \(resumeAt.formatted(date: .omitted, time: .shortened))"
                switch job.kind {
                case .newDeck, .regenerate:
                    Text("Apple Intelligence reached its usage limit for now. Finished sections are kept, and the rest continues \(when) while NoteFlash is open.")
                case .updateNotes, .syncDoc:
                    Text("Apple Intelligence reached its usage limit for now. The update runs again \(when) while NoteFlash is open.")
                }
            }
        } else {
            Text("Paused while NoteFlash was in the background. It picks up again when you open the app.")
        }
    }

    @ViewBuilder
    private var details: some View {
        if let detail = job.errorDetail {
            DisclosureGroup("Details") {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
    }

    private func finishedLine(_ summary: String) -> String {
        switch job.kind {
        case .newDeck, .regenerate: "Ready · \(summary)"
        case .updateNotes, .syncDoc: "Updated · \(summary)"
        }
    }

    private func actions(primary: String, systemImage: String) -> some View {
        HStack {
            Button(primary, systemImage: systemImage) { processing.retry(job) }
                .buttonStyle(.bordered)
            Button("Dismiss") { processing.dismiss(job) }
                .buttonStyle(.bordered)
                .tint(.secondary)
        }
        .controlSize(.small)
    }

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .symbolEffect(.pulse, options: .repeating)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(job.statusLine(at: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Spacer(minLength: 0)
                    Button {
                        processing.cancel(job)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel")
                }
                if let fraction = job.fraction(at: context.date) {
                    ProgressView(value: fraction)
                        .animation(.linear(duration: 1), value: fraction)
                } else {
                    ProgressView(value: 0.02)
                }
                if job.continuesInBackground {
                    Label("Keeps going if you leave NoteFlash", systemImage: "arrow.up.forward.app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
