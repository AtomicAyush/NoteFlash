import BackgroundTasks
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers
import UserNotifications

/// Reads what another app shared, copies it into the shared inbox, and lets NoteFlash know.
@Observable
final class ShareModel {
    enum State: Equatable {
        case loading
        case ready
        case saving
        case saved(notified: Bool)
        case failed(String)
    }

    /// A file copied into the draft.
    struct SharedFile: Identifiable {
        enum Kind {
            case pdf
            case powerPoint
            case image
        }

        let name: String
        let kind: Kind
        var id: String { name }
    }

    enum Payload {
        case text(String)
        case files([SharedFile])
        case link(URL)
    }

    static let densities = [("essentials", "Essentials"), ("balanced", "Balanced"), ("thorough", "Thorough")]
    private static let powerPointType = UTType("org.openxmlformats.presentationml.presentation") ?? .presentation
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    private(set) var state: State = .loading
    private(set) var payload: Payload?
    var title = ""
    var density = "balanced"

    private let context: NSExtensionContext?
    private var draft: SharedInbox.Draft?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    // MARK: Summary

    /// "PDF · 12 pages", "3 images", …
    var summaryTitle: String {
        switch payload {
        case .text: "Text"
        case .link(let url): Self.linkLabel(url)
        case .files(let files):
            if files.count == 1, let file = files.first {
                switch file.kind {
                case .pdf: "PDF"
                case .powerPoint: "PowerPoint"
                case .image: "Image"
                }
            } else if files.allSatisfy({ $0.kind == .image }) {
                "\(files.count) images"
            } else {
                "\(files.count) files"
            }
        case nil: ""
        }
    }

    var summaryDetail: String {
        switch payload {
        case .text(let text):
            "\(text.count.formatted()) characters"
        case .link(let url):
            url.absoluteString
        case .files(let files):
            if files.count == 1, let file = files.first, file.kind == .pdf, let draft,
               let pages = PDFDocument(url: draft.fileURL(file.name))?.pageCount {
                "\(file.name) · \(pages == 1 ? "1 page" : "\(pages) pages")"
            } else if files.allSatisfy({ $0.kind == .image }) {
                files.count == 1 ? files[0].name : "Made into one deck, a page per image"
            } else {
                files.map(\.name).joined(separator: ", ")
            }
        case nil:
            ""
        }
    }

    var systemImage: String {
        switch payload {
        case .text: "text.alignleft"
        case .link: "link"
        case .files(let files):
            files.allSatisfy { $0.kind == .image } ? "photo.on.rectangle"
                : files.first?.kind == .powerPoint ? "rectangle.on.rectangle" : "doc.richtext"
        case nil: "doc"
        }
    }

    /// Several PDFs or PowerPoint files each become their own deck, named after the file.
    var makesSeveralDecks: Bool {
        guard case .files(let files) = payload else { return false }
        let documents = files.filter { $0.kind != .image }.count
        let imageDecks = files.contains { $0.kind == .image } ? 1 : 0
        return documents + imageDecks > 1
    }

    // MARK: Loading

    func load() async {
        SharedInbox.removeAbandonedDrafts()
        do {
            let draft = try SharedInbox.makeDraft()
            self.draft = draft
            let found = try await Self.readAttachments(from: context, into: draft)
            guard let chosen = found.payload else {
                draft.discard()
                state = .failed(found.problem ?? "NoteFlash can't make flashcards from this. Try sharing text, a PDF, images, or a PowerPoint file.")
                return
            }
            payload = chosen
            title = found.suggestedTitle ?? ""
            state = .ready
        } catch {
            draft?.discard()
            state = .failed(error.localizedDescription)
        }
    }

    private struct Found {
        var payload: Payload?
        var suggestedTitle: String?
        var problem: String?
    }

    private static func readAttachments(from context: NSExtensionContext?, into draft: SharedInbox.Draft) async throws -> Found {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        var files: [SharedFile] = []
        var texts: [String] = []
        var links: [URL] = []
        var suggestedTitle = items.lazy.compactMap { $0.attributedTitle?.string }.first { !$0.isEmpty }
        var problem: String?

        for provider in items.flatMap({ $0.attachments ?? [] }) {
            let name = provider.suggestedName
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                if let stored = try? await copyFile(provider, type: .pdf, name: name, fallbackExtension: "pdf", into: draft) {
                    files.append(SharedFile(name: stored, kind: .pdf))
                }
            } else if provider.hasItemConformingToTypeIdentifier(powerPointType.identifier) {
                if let stored = try? await copyFile(provider, type: powerPointType, name: name, fallbackExtension: "pptx", into: draft) {
                    files.append(SharedFile(name: stored, kind: .powerPoint))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let stored = try? await copyImage(provider, name: name, into: draft) {
                    files.append(SharedFile(name: stored, kind: .image))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                      let url = try? await loadItem(provider, type: .fileURL) as? URL {
                switch try copyLocalFile(url, into: draft) {
                case .file(let file): files.append(file)
                case .text(let text): texts.append(text)
                case .unsupported(let message): problem = message
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = try? await loadItem(provider, type: .url) as? URL {
                links.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await loadText(provider), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    texts.append(text)
                }
            } else if provider.registeredTypeIdentifiers.contains(where: { $0.localizedCaseInsensitiveContains("goodnotes") })
                        || (name ?? "").lowercased().hasSuffix(".goodnotes") {
                problem = "GoodNotes notebooks can't be read directly. In GoodNotes, tap Share → Export, choose PDF (or Image), then share that to NoteFlash."
            } else {
                problem = "NoteFlash can't read this kind of file. Export it as a PDF, then share that."
            }
            if suggestedTitle == nil, let name, !name.isEmpty {
                suggestedTitle = (name as NSString).deletingPathExtension
            }
        }

        var found = Found(suggestedTitle: suggestedTitle, problem: problem)
        let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let googleLink = links.first(where: isGoogleLink)
        if !files.isEmpty {
            found.payload = .files(files)
            if files.count == 1, let file = files.first {
                found.suggestedTitle = suggestedTitle ?? (file.name as NSString).deletingPathExtension
            }
        } else if let googleLink {
            found.payload = .link(googleLink)
        } else if text.count >= 20 {
            found.payload = .text(text)
            if found.suggestedTitle == nil {
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
                found.suggestedTitle = String(firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#•-* ")).prefix(60))
            }
        } else if !links.isEmpty {
            found.problem = "NoteFlash can read Google Docs, Slides, and Drive links, but not other web pages. Copy the page's text and share that instead."
        } else if found.problem == nil, !text.isEmpty {
            found.problem = "There isn't enough text here to make flashcards."
        }
        return found
    }

    private enum LocalFile {
        case file(SharedFile)
        case text(String)
        case unsupported(String)
    }

    private static func copyLocalFile(_ url: URL, into draft: SharedInbox.Draft) throws -> LocalFile {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        switch ext {
        case "pdf":
            return .file(SharedFile(name: try draft.addFile(at: url, preferredName: name), kind: .pdf))
        case "pptx":
            return .file(SharedFile(name: try draft.addFile(at: url, preferredName: name), kind: .powerPoint))
        case _ where imageExtensions.contains(ext):
            return .file(SharedFile(name: try draft.addFile(at: url, preferredName: name), kind: .image))
        case "txt", "md", "text", "markdown":
            return .text(try String(contentsOf: url, encoding: .utf8))
        case "goodnotes":
            return .unsupported("GoodNotes notebooks can't be read directly. In GoodNotes, tap Share → Export, choose PDF (or Image), then share that to NoteFlash.")
        case "ppt":
            return .unsupported("Older PowerPoint (.ppt) files aren't supported. Save the presentation as .pptx, then share it.")
        default:
            return .unsupported("NoteFlash can't read .\(ext) files. Export it as a PDF, then share that.")
        }
    }

    private static func copyFile(
        _ provider: NSItemProvider, type: UTType, name: String?, fallbackExtension: String, into draft: SharedInbox.Draft
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                // The file is only guaranteed to exist until this handler returns.
                var preferred = name ?? url.deletingPathExtension().lastPathComponent
                if (preferred as NSString).pathExtension.isEmpty {
                    preferred += ".\(url.pathExtension.isEmpty ? fallbackExtension : url.pathExtension)"
                }
                continuation.resume(with: Result { try draft.addFile(at: url, preferredName: preferred) })
            }
        }
    }

    private static func copyImage(_ provider: NSItemProvider, name: String?, into draft: SharedInbox.Draft) async throws -> String {
        if let stored = try? await copyFile(provider, type: .image, name: name, fallbackExtension: "jpg", into: draft) {
            return stored
        }
        // Screenshots and some apps only provide image data.
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        return try draft.addFile(data: data, preferredName: (name ?? "Image") + ".png")
    }

    private static func loadItem(_ provider: NSItemProvider, type: UTType) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    nonisolated(unsafe) let item = item
                    continuation.resume(returning: item)
                }
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async throws -> String? {
        switch try await loadItem(provider, type: .plainText) {
        case let text as String: text
        case let text as NSAttributedString: text.string
        case let data as Data: String(data: data, encoding: .utf8)
        case let url as URL: url.absoluteString
        default: nil
        }
    }

    private static func isGoogleLink(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "docs.google.com" || host == "drive.google.com"
    }

    private static func linkLabel(_ url: URL) -> String {
        let path = url.path()
        if path.contains("/document/") { return "Google Doc" }
        if path.contains("/presentation/") { return "Google Slides" }
        return "Google Drive file"
    }

    // MARK: Actions

    func save() async {
        guard let draft, let payload else { return }
        state = .saving
        let content: SharedInbox.Item.Content = switch payload {
        case .text(let text): .text(text)
        case .files(let files): .files(files.map(\.name))
        case .link(let url): .link(url.absoluteString)
        }
        let deckTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try draft.commit(title: makesSeveralDecks ? "" : deckTitle, content: content, density: density)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        Self.askForBackgroundTime()
        let notified = await Self.notify(title: deckTitle, several: makesSeveralDecks, itemID: draft.id)
        state = .saved(notified: notified)
        if notified {
            try? await Task.sleep(for: .seconds(1.5))
            finish()
        }
    }

    func cancel() {
        draft?.discard()
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    func finish() {
        context?.completeRequest(returningItems: nil)
    }

    /// Asks iOS to start NoteFlash in the background to make the cards, so the user doesn't have
    /// to open it. iOS decides when, and won't do it at all if NoteFlash was force-quit, so the
    /// notification below stays as the way in.
    private static func askForBackgroundTime() {
        let request = BGProcessingTaskRequest(identifier: BackgroundWork.catchUpTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundWork.catchUpTaskID)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// A notification the user can tap to open NoteFlash, which then makes the cards.
    private static func notify(title: String, several: Bool, itemID: UUID) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = "Ready to make flashcards"
        content.body = several || title.isEmpty
            ? "Tap to open NoteFlash and make your decks."
            : "Tap to open NoteFlash and make “\(title)”."
        content.userInfo = ["sharedItemID": itemID.uuidString]
        let request = UNNotificationRequest(identifier: itemID.uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}
