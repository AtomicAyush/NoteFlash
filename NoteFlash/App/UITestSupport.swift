#if DEBUG
import Foundation
import SwiftData
import UIKit

/// Launch-argument hooks for UI tests: `-uiTesting` uses an in-memory store seeded with a sample deck.
enum UITestSupport {
    nonisolated static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTesting")
    }

    /// `-catchUpNow` runs a short background catch-up at launch, to check that saved work is
    /// picked up and that stopping at the deadline keeps everything.
    nonisolated static var runsCatchUpAtLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("-catchUpNow")
    }

    static func seed(_ context: ModelContext) {
        let deck = Deck(
            title: "Sample: Cell Biology",
            sourceKind: .text,
            sourceText: """
                # Cell Biology
                Mitochondria make most of the cell's ATP through cellular respiration.
                Ribosomes build proteins by translating messenger RNA.
                The nucleus stores the cell's DNA and controls gene expression.
                The Golgi apparatus packages and ships proteins.
                The cell membrane is a phospholipid bilayer that controls what enters and leaves the cell.
                Lysosomes contain enzymes that break down waste.
                """,
            density: .balanced
        )
        context.insert(deck)
        let cards = [
            ("Which organelle makes most of the cell's ATP?", "Mitochondria"),
            ("What do ribosomes build?", "Proteins"),
            ("Where is DNA stored in a eukaryotic cell?", "The nucleus"),
            ("What organelle packages proteins for export?", "Golgi apparatus"),
            ("What structure controls what enters the cell?", "Cell membrane"),
            ("Which organelle breaks down waste?", "Lysosome"),
        ]
        for (front, back) in cards {
            deck.addCard(front: front, back: back)
        }
        deck.cards.first?.setBadge(.new)

        // Older decks with different dates, for checking the deck list's sort options.
        let history = Deck(title: "American Revolution", sourceKind: .googleDoc, sourceName: "American Revolution Notes",
                           sourceText: "The Treaty of Paris ended the war in 1783.", density: .balanced)
        history.createdAt = .now.addingTimeInterval(-86_400 * 30)
        history.updatedAt = .now.addingTimeInterval(-3_600)
        history.modifiedByMeAt = .now.addingTimeInterval(-86_400 * 20)
        history.lastOpenedAt = .now.addingTimeInterval(-86_400 * 2)
        history.googleDocID = "d-revolution"
        history.autoSync = false
        context.insert(history)
        history.addCard(front: "What treaty ended the Revolutionary War?", back: "The Treaty of Paris (1783)")

        let math = Deck(title: "Algebra Formulas", sourceKind: .text, sourceText: "The quadratic formula solves ax^2 + bx + c = 0.", density: .balanced)
        math.createdAt = .now.addingTimeInterval(-86_400 * 10)
        math.updatedAt = .now.addingTimeInterval(-86_400 * 10)
        math.modifiedByMeAt = .now.addingTimeInterval(-86_400 * 10)
        math.lastOpenedAt = nil
        context.insert(math)
        math.addCard(front: "What does the quadratic formula solve?", back: "ax^2 + bx + c = 0")
        try? context.save()
    }
}

/// Writes placeholder cards slowly, so processing progress can be checked in the Simulator
/// (where Apple's on-device model can't run).
nonisolated struct SampleFlashcardEngine: FlashcardEngine {
    func generateDeck(from source: NoteSource, density: CardDensity, progress: GenerationProgressHandler?) async throws -> GeneratedDeck {
        let lines = TextDiff.lines(of: source.text).filter { !$0.hasPrefix("#") && !CommentWeaver.isCommentLine($0) }
        let sections = max(1, min(4, lines.count / 3))
        let steps = 24
        let simulatesLimit = Self.takeSimulatedLimit()
        for step in 0..<steps {
            try await Task.sleep(for: .milliseconds(750))
            let section = min(sections, step * sections / steps + 1)
            progress?(GenerationProgress(fraction: Double(step + 1) / Double(steps), detail: "Section \(section) of \(sections)"))
            if simulatesLimit && step == 6 {
                // A short wait, then a limit too long to wait out (see `-simulateUsageLimit`).
                let until = Date.now.addingTimeInterval(6)
                progress?(GenerationProgress(fraction: 0.29, detail: AppleFlashcardEngine.waitingDetail(until: until), waitingUntil: until))
                try await Task.sleep(for: .seconds(6))
            }
            if simulatesLimit && step == 10 {
                throw AppleFlashcardEngine.EngineError.rateLimited(
                    resumeAt: Date.now.addingTimeInterval(25), detail: "Simulated usage limit (-simulateUsageLimit)"
                )
            }
        }
        let cards = lines.map { line in
            GeneratedCard(front: "What do the notes say about “\(line.prefix(30))”?", back: line)
        }
        return GeneratedDeck(title: "Sample Deck", cards: cards)
    }

    private static let limitLock = NSLock()
    nonisolated(unsafe) private static var limitSimulated = false

    /// With `-simulateUsageLimit`, the first deck made hits a fake usage limit.
    private static func takeSimulatedLimit() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("-simulateUsageLimit") else { return false }
        return limitLock.withLock {
            defer { limitSimulated = true }
            return !limitSimulated
        }
    }

    func reviseDeck(
        existing: [ExistingCard], changes: NoteChanges, updatedNotes: String, density: CardDensity,
        progress: GenerationProgressHandler?
    ) async throws -> DeckRevision {
        let steps = 10
        for step in 0..<steps {
            try await Task.sleep(for: .milliseconds(600))
            progress?(GenerationProgress(fraction: Double(step + 1) / Double(steps), detail: "Updating cards"))
        }
        let added = changes.hunks.flatMap(\.added).map { line in
            GeneratedCard(front: "What do the notes say about “\(line.prefix(30))”?", back: line)
        }
        return DeckRevision(updated: [], removed: [], added: added)
    }
}

/// An offline Drive with folders and docs, so the doc picker can be exercised in UI tests.
struct SampleDriveDataSource: DriveDataSource {
    private static func ago(_ hours: Double) -> Date { Date.now.addingTimeInterval(-hours * 3600) }

    private static let items: [DriveItem] = [
        folder("f-school", "School", parent: "root", modified: ago(2)),
        folder("f-personal", "Personal", parent: "root", modified: ago(300)),
        doc("d-reading", "Reading List", parent: "root", modified: ago(30), opened: ago(20)),
        doc("d-untitled", "Untitled document", parent: "root", modified: ago(900)),
        folder("f-bio", "Biology", parent: "f-school", modified: ago(1)),
        folder("f-history", "History", parent: "f-school", modified: ago(50)),
        doc("d-schedule", "Class Schedule", parent: "f-school", modified: ago(200), opened: ago(3)),
        doc("d-cells", "Cell Biology Notes", parent: "f-bio", modified: ago(0.5), opened: ago(0.4), starred: true),
        doc("d-photo", "Photosynthesis Review", parent: "f-bio", modified: ago(26), opened: ago(25)),
        doc("s-mitosis", "Mitosis Lecture", parent: "f-bio", modified: ago(4), opened: ago(3), mimeType: DriveMimeType.presentation),
        doc("p-enzymes", "Enzymes Handout.pdf", parent: "f-bio", modified: ago(60), mimeType: DriveMimeType.pdf),
        doc("x-ecology", "Ecology Review.pptx", parent: "f-bio", modified: ago(120), mimeType: DriveMimeType.powerPoint),
        doc("d-genetics", "Genetics Unit 4", parent: "f-bio", modified: ago(80), modifier: "Priya Shah"),
        doc("d-lab", "Lab Report Draft", parent: "f-bio", modified: ago(500)),
        doc("d-revolution", "American Revolution Notes", parent: "f-history", modified: ago(10), opened: ago(9), starred: true),
        doc("d-civil", "Civil War Timeline", parent: "f-history", modified: ago(2000)),
        doc("d-journal", "Journal", parent: "f-personal", modified: ago(5)),
        {
            var item = folder("f-group", "Study Group", parent: nil, modified: ago(40))
            item.ownedByMe = false
            item.ownerName = "Jordan Lee"
            item.shared = true
            item.sharedWithMeTime = ago(70)
            return item
        }(),
        {
            var item = doc("d-guide", "AP Bio Study Guide", parent: nil, modified: ago(6), opened: ago(4), modifier: "Ms. Rivera")
            item.ownedByMe = false
            item.ownerName = "Ms. Rivera"
            item.shared = true
            item.sharedWithMeTime = ago(30)
            item.size = 48_000
            return item
        }(),
        {
            var item = doc("d-group", "Group Notes", parent: "f-group", modified: ago(12), modifier: "Jordan Lee")
            item.ownedByMe = false
            item.ownerName = "Jordan Lee"
            item.shared = true
            return item
        }(),
    ]

    private static func folder(_ id: String, _ name: String, parent: String?, modified: Date) -> DriveItem {
        DriveItem(id: id, name: name, mimeType: DriveMimeType.folder, modifiedTime: modified,
                  modifiedByMeTime: modified, ownedByMe: true, ownerName: "You", lastModifiedByMe: true, parentID: parent)
    }

    private static func doc(
        _ id: String, _ name: String, parent: String?, modified: Date, opened: Date? = nil,
        modifier: String? = nil, starred: Bool = false, mimeType: String = DriveMimeType.document
    ) -> DriveItem {
        DriveItem(id: id, name: name, mimeType: mimeType, modifiedTime: modified,
                  modifiedByMeTime: modifier == nil ? modified : nil, viewedByMeTime: opened,
                  size: Int64(name.unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 900_000 } + 2_000), ownedByMe: true,
                  ownerName: "You", lastModifierName: modifier, lastModifiedByMe: modifier == nil,
                  parentID: parent, starred: starred)
    }

    private func matches(_ item: DriveItem, _ location: DriveLocation) -> Bool {
        switch location {
        case .folder(let id): item.parentID == id
        case .sharedWithMe: item.shared && !(Self.items.first { $0.id == item.parentID }?.shared ?? false)
        case .starred: item.starred
        case .recent: item.viewedByMeTime != nil && !item.isFolder
        }
    }

    func requiresSignIn(_ auth: GoogleAuth) -> Bool { false }

    func requiresListPermission(_ auth: GoogleAuth) -> Bool { false }

    func listing(in location: DriveLocation, sort: DriveSort, ascending: Bool, foldersOnTop: Bool, auth: GoogleAuth) async throws -> DriveListing {
        try await Task.sleep(for: .milliseconds(300))
        let found = Self.items.filter { matches($0, location) }
        let order = location == .recent ? DriveSort.opened : sort.available(in: location)
        let isAscending = location == .recent ? false : ascending
        guard foldersOnTop || location == .recent else {
            return DriveListing(folders: [], docs: DrivePage(items: order.sorted(found, ascending: isAscending), nextPageToken: nil))
        }
        return DriveListing(
            folders: order.sorted(found.filter(\.isFolder), ascending: isAscending),
            docs: DrivePage(items: order.sorted(found.filter { !$0.isFolder }, ascending: isAscending), nextPageToken: nil)
        )
    }

    func moreDocs(in location: DriveLocation, sort: DriveSort, ascending: Bool, foldersOnTop: Bool, pageToken: String, auth: GoogleAuth) async throws -> DrivePage {
        DrivePage(items: [], nextPageToken: nil)
    }

    func search(_ term: String, pageToken: String?, auth: GoogleAuth) async throws -> DrivePage {
        DrivePage(items: Self.items.filter { $0.name.localizedCaseInsensitiveContains(term) }, nextPageToken: nil)
    }

    func folderName(id: String, auth: GoogleAuth) async throws -> String {
        guard let name = Self.items.first(where: { $0.id == id })?.name else {
            throw GoogleDriveClient.DriveError.notFound
        }
        return name
    }

    func content(of item: DriveItem, auth: GoogleAuth) async throws -> DriveFileContent {
        try await Task.sleep(for: .milliseconds(400))
        let known = Self.items.first { $0.id == item.id } ?? item
        let name = DriveFileReader.stripExtension(known.name)
        switch known.kind ?? .document {
        case .presentation, .powerPoint:
            return DriveFileContent(title: name, text: """
                ## \(name)
                A tour of cell division

                ## Phases of mitosis
                • Prophase: chromosomes condense
                • Metaphase: chromosomes line up at the middle
                • Anaphase: sister chromatids separate
                • Telophase: two nuclei form
                Speaker notes: Cytokinesis usually overlaps with telophase.
                """, kind: known.kind ?? .presentation, pageCount: 2)
        case .pdf:
            return DriveFileContent(title: name, text: """
                Enzymes are proteins that speed up chemical reactions.
                The active site is where the substrate binds.
                Enzymes lower the activation energy of a reaction.
                High temperatures can denature enzymes.
                """, kind: .pdf, pageCount: 1)
        case .document:
            break
        }
        let sampleComments = known.id == "d-cells" ? [
            DriveComment(quote: "Mitochondria make most of the cell's ATP.", content: "This will be on the exam — know the Krebs cycle too"),
            DriveComment(quote: "Ribosomes build proteins.", content: "Ribosomes are found free or on the rough ER", replies: ["Good catch!"]),
        ] : []
        return DriveFileContent(title: name, text: CommentWeaver.weave(sampleComments, into: """
            # \(name)
            ## Overview
            These are sample notes for previewing a Google Doc in NoteFlash.
            • Mitochondria make most of the cell's ATP.
              • They have their own DNA.
            • Ribosomes build proteins.
            ## Key terms
            Photosynthesis | Converts light energy into chemical energy
            Chlorophyll | Green pigment that absorbs light
            The Calvin cycle takes place in the stroma and uses ATP and NADPH to build sugars.
            """), kind: .document)
    }

    func thumbnail(for item: DriveItem, auth: GoogleAuth) async -> UIImage? { nil }
}
#endif
