import Foundation
import UserNotifications

/// Starts decks for notes shared through the share extension (see `SharedInbox`).
enum SharedNotesImporter {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]

    static func importPending(into processing: ProcessingCenter) {
        let items = SharedInbox.pendingItems()
        guard !items.isEmpty else { return }
        let log = DiagnosticsLog.shared
        for item in items {
            let density = CardDensity(rawValue: item.density) ?? .balanced
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.content {
            case .text(let text):
                let firstLine = TextDiff.lines(of: text).first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#•-* "))
                processing.startNewDeck(
                    from: .text(title: title, notes: text),
                    density: density,
                    title: title.isEmpty ? String((firstLine ?? "Shared notes").prefix(40)) : title
                )

            case .link(let link):
                if let reference = DriveFileReference(link: link) {
                    processing.startNewDeck(
                        from: .drive(reference, autoSync: true),
                        density: density,
                        title: title.isEmpty ? reference.kind?.label ?? "Google Drive file" : title
                    )
                } else {
                    log.record("Shared link skipped (not a Google link): \(link)")
                }

            case .files(let names):
                startDecks(for: names, in: item, title: title, density: density, processing: processing)
            }
            log.record("Imported shared notes: \(title.isEmpty ? "untitled" : title)")
            SharedInbox.remove(item)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [item.id.uuidString])
        }
    }

    /// Images become one deck; each PDF or PowerPoint file becomes its own.
    private static func startDecks(
        for names: [String], in item: SharedInbox.Item, title: String, density: CardDensity, processing: ProcessingCenter
    ) {
        var images: [Data] = []
        var documents: [(name: String, data: Data)] = []
        for name in names {
            guard let url = SharedInbox.fileURL(name, in: item), let data = try? Data(contentsOf: url) else {
                DiagnosticsLog.shared.record("Shared file missing: \(name)")
                continue
            }
            if imageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                images.append(data)
            } else {
                documents.append((name, data))
            }
        }
        let deckCount = documents.count + (images.isEmpty ? 0 : 1)
        let sharedTitle = deckCount == 1 && !title.isEmpty ? title : nil

        for document in documents {
            processing.startNewDeck(
                from: .file(fileName: document.name, data: document.data, title: sharedTitle),
                density: density,
                title: sharedTitle ?? DriveFileReader.stripExtension(document.name)
            )
        }
        if !images.isEmpty {
            let name = images.count == 1 ? (names.first ?? "Image") : "\(images.count) images"
            processing.startNewDeck(
                from: .images(name: name, data: images, title: sharedTitle),
                density: density,
                title: sharedTitle ?? (images.count == 1 ? "Shared image" : "Shared images")
            )
        }
    }
}
