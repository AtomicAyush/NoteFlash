import SwiftUI

/// Shows a doc's details and text so the user can confirm it before making a deck.
struct GoogleDocPreviewView: View {
    let item: DriveItem
    let context: DrivePickerContext

    @Environment(GoogleAuth.self) private var googleAuth
    @State private var document: GoogleDocContent?
    @State private var errorMessage: String?

    private var isLinked: Bool { context.linkedDocIDs.contains(item.id) }
    private var isEmptyDoc: Bool {
        document?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if isLinked {
                    Label("You already have a deck from this doc. Using it again makes a second deck.",
                          systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                Divider()
                content(for: document)
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if isEmptyDoc {
                    Text("This doc is empty, so there's nothing to make cards from.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    context.select(item)
                } label: {
                    Label("Use This Doc", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isEmptyDoc)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url = URL(string: item.editURL) {
                ToolbarItem(placement: .primaryAction) {
                    Link(destination: url) {
                        Label("Open in Google Docs", systemImage: "arrow.up.right.square")
                    }
                }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            DriveThumbnailView(item: item, context: context, compact: true)
                .frame(width: 60, height: 78)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                detail(DriveText.modified(item), systemImage: "pencil")
                if let opened = item.viewedByMeTime {
                    detail("You opened \(DriveText.short(opened))", systemImage: "eye")
                }
                detail(item.ownedByMe ? "Owned by you" : "Owned by \(item.ownerName ?? "someone else")",
                       systemImage: item.ownedByMe ? "person" : "person.2")
                if let folder = context.folderNames.name(for: item.parentID) {
                    detail("In \(folder)", systemImage: "folder")
                }
                if let document, !isEmptyDoc {
                    let words = Self.wordCount(document.text)
                    detail(words == 1 ? "1 word" : "\(words.formatted()) words", systemImage: "text.alignleft")
                }
            }
        }
        .task(id: item.parentID) {
            await context.folderNames.resolve(item.parentID, source: context.source, auth: googleAuth)
        }
    }

    private func detail(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func content(for document: GoogleDocContent?) -> some View {
        if let document {
            if isEmptyDoc {
                ContentUnavailableView("Empty Doc", systemImage: "doc", description: Text("This doc has no text yet."))
            } else {
                DocTextView(text: document.text)
            }
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Preview", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
        } else {
            ProgressView("Loading preview…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            document = try await context.source.document(id: item.id, auth: googleAuth)
        } catch is CancellationError {
            // Left the screen.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Renders doc text with its headings, bullets, and table rows.
struct DocTextView: View {
    let text: String

    private struct Line: Identifiable {
        enum Kind {
            case heading(Int)
            case bullet(Int)
            case table
            case paragraph
        }
        let id: Int
        let kind: Kind
        let text: String
    }

    private var lines: [Line] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count / 2

            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                return Line(id: index, kind: .heading(level), text: title)
            }
            for marker in ["• ", "● ", "○ ", "■ ", "* ", "- "] where trimmed.hasPrefix(marker) {
                return Line(id: index, kind: .bullet(indent), text: String(trimmed.dropFirst(marker.count)))
            }
            if trimmed.contains(" | ") {
                return Line(id: index, kind: .table, text: trimmed)
            }
            return Line(id: index, kind: .paragraph, text: trimmed)
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(lines) { line in
                switch line.kind {
                case .heading(let level):
                    Text(line.text)
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 6)
                case .bullet(let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(indent == 0 ? "•" : "◦")
                            .foregroundStyle(.secondary)
                        Text(line.text)
                    }
                    .padding(.leading, CGFloat(indent) * 18)
                case .table:
                    Text(line.text.replacingOccurrences(of: " | ", with: "  ·  "))
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 6))
                case .paragraph:
                    Text(line.text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
