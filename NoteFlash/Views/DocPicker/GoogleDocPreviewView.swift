import SwiftUI

/// Shows a file's details and the notes read from it, so the user can confirm it before making a deck.
struct GoogleDocPreviewView: View {
    let item: DriveItem
    let context: DrivePickerContext

    @Environment(GoogleAuth.self) private var googleAuth
    @State private var document: DriveFileContent?
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
                    Label("You already have a deck from this file. Using it again makes a second deck.",
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
                    Text("This file has no text, so there's nothing to make cards from.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button {
                    context.select(item)
                } label: {
                    Label("Use This File", systemImage: "checkmark")
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
            if let url = item.openURL {
                ToolbarItem(placement: .primaryAction) {
                    Link(destination: url) {
                        Label(item.kind?.openLabel ?? "Open in Google Drive", systemImage: "arrow.up.right.square")
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
                if let kind = item.kind {
                    Label(kind.label, systemImage: kind.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.driveKind(kind))
                }
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
                    if let pages = document.pageCount {
                        let unit = document.kind == .pdf ? "page" : "slide"
                        detail(pages == 1 ? "1 \(unit)" : "\(pages) \(unit)s", systemImage: "square.stack")
                    }
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
    private func content(for document: DriveFileContent?) -> some View {
        if let document {
            if isEmptyDoc {
                ContentUnavailableView("No Text", systemImage: "doc", description: Text(emptyDescription))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if document.kind != .document {
                        Text(document.kind == .pdf ? "Text read from the PDF:" : "Text read from the slides:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    DocTextView(text: document.text)
                }
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
            ProgressView(item.kind == .pdf ? "Reading the PDF…" : "Loading preview…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            document = try await context.source.content(of: item, auth: googleAuth)
        } catch is CancellationError {
            // Left the screen.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var emptyDescription: String {
        switch item.kind {
        case .pdf: "This PDF has no readable text."
        case .presentation, .powerPoint: "These slides have no text."
        default: "This doc has no text yet."
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
            /// A comment left on the notes; `priority` when it says the point is on the exam.
            case comment(priority: Bool)
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

            if CommentWeaver.isCommentLine(trimmed) {
                let body = String(trimmed.dropFirst(CommentWeaver.commentPrefix.count))
                let isPriority = body.hasPrefix(CommentWeaver.priorityLabel)
                let shown = isPriority
                    ? String(body.dropFirst(CommentWeaver.priorityLabel.count)).trimmingCharacters(in: CharacterSet(charactersIn: " —"))
                    : body
                return Line(id: index, kind: .comment(priority: isPriority), text: shown.prefix(1).uppercased() + shown.dropFirst())
            }
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
                case .comment(let priority):
                    VStack(alignment: .leading, spacing: 3) {
                        if priority {
                            Label("On the exam", systemImage: "flag.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                        Label {
                            Text(line.text)
                        } icon: {
                            Image(systemName: "text.bubble")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (priority ? Color.orange.opacity(0.12) : Color(uiColor: .secondarySystemBackground)),
                        in: .rect(cornerRadius: 8)
                    )
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
