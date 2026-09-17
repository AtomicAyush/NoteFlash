import BackgroundTasks
import Foundation
import Observation
import SwiftData

/// Keeps decks in step with their notes: polls linked Google Docs while the app is open,
/// checks again from background app refresh, and has the AI engine revise only the affected cards.
@Observable
final class DocSyncService {
    enum SyncError: LocalizedError {
        case busy
        case deckRemoved

        var errorDescription: String? {
            switch self {
            case .busy: "This deck is already being updated."
            case .deckRemoved: "The deck was deleted while it was being updated."
            }
        }
    }

    private(set) var busyDeckIDs: Set<UUID> = []
    private let container: ModelContainer
    private let googleAuth: GoogleAuth
    private var pollTask: Task<Void, Never>?

    init(container: ModelContainer, googleAuth: GoogleAuth) {
        self.container = container
        self.googleAuth = googleAuth
    }

    private var context: ModelContext { container.mainContext }

    func isBusy(_ deck: Deck) -> Bool {
        busyDeckIDs.contains(deck.id)
    }

    // MARK: Scheduling

    func startForegroundPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await syncAllLinkedDecks()
                try? await Task.sleep(for: AppConfig.foregroundSyncInterval)
            }
        }
    }

    func stopForegroundPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppConfig.backgroundRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: AppConfig.backgroundRefreshInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackgroundRefresh() async {
        Self.scheduleBackgroundRefresh()
        await syncAllLinkedDecks()
    }

    // MARK: Google Doc sync

    func syncAllLinkedDecks() async {
        let descriptor = FetchDescriptor<Deck>(
            predicate: #Predicate { $0.autoSync == true && $0.googleDocID != nil }
        )
        guard let decks = try? context.fetch(descriptor) else { return }
        for deck in decks where !Task.isCancelled {
            _ = try? await sync(deck)
        }
    }

    /// Checks one linked doc and revises the deck if the doc changed.
    /// Returns a summary of the changes, or nil if the doc is unchanged.
    @discardableResult
    func sync(_ deck: Deck) async throws -> String? {
        guard let documentID = deck.googleDocID else { return nil }
        return try await exclusively(deck) {
            do {
                let document = try await fetchDocument(id: documentID)
                guard !deck.isGone else { throw SyncError.deckRemoved }
                deck.lastCheckedAt = .now

                let fingerprint = TextDiff.fingerprint(of: document.text)
                guard fingerprint != deck.sourceHash else {
                    deck.lastSyncError = nil
                    save()
                    return nil
                }

                let summary = try await revise(deck, toMatch: document.text)
                deck.sourceHash = fingerprint
                deck.lastSyncError = nil
                save()
                return summary
            } catch {
                if !deck.isGone {
                    deck.lastSyncError = error.localizedDescription
                    save()
                }
                throw error
            }
        }
    }

    /// Reads a doc through the Docs API when signed in, falling back to the public export link.
    func fetchDocument(id: String) async throws -> GoogleDocContent {
        #if DEBUG
        if UITestSupport.isEnabled {
            return try await SampleDriveDataSource().document(id: id, auth: googleAuth)
        }
        #endif
        guard googleAuth.isSignedIn else {
            return try await GoogleDocsClient.fetchPublicExport(documentID: id)
        }
        do {
            let token = try await googleAuth.validAccessToken()
            return try await GoogleDocsClient.fetchViaAPI(documentID: id, accessToken: token)
        } catch let error as GoogleDocsClient.DocsError {
            switch error {
            case .unauthorized:
                googleAuth.invalidateAccessToken()
                let token = try await googleAuth.validAccessToken()
                return try await GoogleDocsClient.fetchViaAPI(documentID: id, accessToken: token)
            case .notShared, .notFound:
                // This account can't open the doc, but it may still be shared by link.
                if let document = try? await GoogleDocsClient.fetchPublicExport(documentID: id) {
                    return document
                }
                throw error
            default:
                throw error
            }
        }
    }

    // MARK: Edited notes and regeneration

    /// Saves hand-edited notes for a text deck and revises the affected cards.
    @discardableResult
    func updateNotes(of deck: Deck, to newText: String) async throws -> String {
        try await exclusively(deck) {
            let summary = try await revise(deck, toMatch: newText)
            save()
            return summary
        }
    }

    /// Rebuilds a deck from its source, keeping cards the user wrote or edited by hand.
    func regenerate(_ deck: Deck, reporter: ProcessingReporter = .silent) async throws {
        try await exclusively(deck) {
            var notes = deck.sourceText
            let source: NoteSource
            switch deck.sourceKind {
            case .text:
                source = .text(notes)
            case .pdf:
                if let data = deck.sourcePDF {
                    source = .pdf(data: data, text: notes)
                } else {
                    source = .text(notes)
                }
            case .googleDoc:
                guard let documentID = deck.googleDocID else { return }
                reporter.send(.phase("Opening your Google Doc"))
                notes = try await fetchDocument(id: documentID).text
                source = .text(notes)
            }

            let engineKind = AIEngineKind.selected
            let engine = try engineKind.makeEngine()
            let characters = engineKind == .claude && deck.sourceKind == .pdf && notes.count < 200
                ? (deck.sourcePDF.flatMap { PDFTextExtractor.pageCount(of: $0) }).map(ProcessingEstimator.estimatedCharacters(pdfPages:)) ?? notes.count
                : notes.count
            reporter.send(.workload(characters: characters, engine: engineKind))
            let generated = try await engine.generateDeck(
                from: source, density: deck.density, progress: reporter.generationHandler
            )
            guard !deck.isGone else { throw SyncError.deckRemoved }
            guard !generated.cards.isEmpty else { throw DeckCreator.CreationError.noCards }

            for card in deck.cards where !card.isUserEdited {
                context.delete(card)
            }
            deck.cards.removeAll { !$0.isUserEdited }
            for card in generated.cards {
                deck.addCard(front: card.front, back: card.back)
            }
            deck.sourceText = notes
            if deck.sourceKind == .googleDoc {
                deck.sourceHash = TextDiff.fingerprint(of: notes)
                deck.lastCheckedAt = .now
                deck.lastSyncError = nil
            }
            deck.updatedAt = .now
            deck.lastSyncSummary = "Regenerated \(generated.cards.count) cards"
            save()
        }
    }

    // MARK: Internals

    private func exclusively<T>(_ deck: Deck, _ work: () async throws -> T) async throws -> T {
        guard !busyDeckIDs.contains(deck.id) else { throw SyncError.busy }
        busyDeckIDs.insert(deck.id)
        defer { busyDeckIDs.remove(deck.id) }
        return try await work()
    }

    /// Asks the AI engine which cards the note edits affect, then applies its revisions.
    private func revise(_ deck: Deck, toMatch newText: String) async throws -> String {
        guard let changes = TextDiff.changes(from: deck.sourceText, to: newText) else {
            deck.sourceText = newText
            return "No changes to the notes"
        }

        var cardsByKey: [String: Flashcard] = [:]
        var existing: [ExistingCard] = []
        for (index, card) in deck.sortedCards.enumerated() {
            let key = "c\(index + 1)"
            cardsByKey[key] = card
            existing.append(ExistingCard(id: key, front: card.front, back: card.back, locked: card.isUserEdited))
        }

        let engine = try AIEngineKind.selected.makeEngine()
        let revision = try await engine.reviseDeck(
            existing: existing,
            changes: changes,
            updatedNotes: newText,
            density: deck.density
        )
        guard !deck.isGone else { throw SyncError.deckRemoved }

        var updatedCount = 0
        for edit in revision.updated {
            // Skip cards the user deleted or edited while the engine was working.
            guard let card = cardsByKey[edit.id], !card.isGone, !card.isUserEdited else { continue }
            let front = edit.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = edit.back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty, front != card.front || back != card.back else { continue }
            card.front = front
            card.back = back
            card.updatedAt = .now
            card.masteryLevel = min(card.masteryLevel, 1)
            card.setBadge(.updated)
            updatedCount += 1
        }

        var removedCount = 0
        for key in Set(revision.removed) {
            guard let card = cardsByKey[key], !card.isGone, !card.isUserEdited else { continue }
            deck.cards.removeAll { $0.id == card.id }
            context.delete(card)
            removedCount += 1
        }

        for card in revision.added {
            deck.addCard(
                front: card.front.trimmingCharacters(in: .whitespacesAndNewlines),
                back: card.back.trimmingCharacters(in: .whitespacesAndNewlines),
                badge: .new
            )
        }

        let parts = [
            revision.added.isEmpty ? nil : "\(revision.added.count) new",
            updatedCount == 0 ? nil : "\(updatedCount) updated",
            removedCount == 0 ? nil : "\(removedCount) removed",
        ].compactMap { $0 }
        var summary = parts.isEmpty ? "Notes changed, no card changes needed" : parts.joined(separator: " · ")
        if revision.skippedSections > 0 {
            summary += " (\(revision.skippedSections) edited section(s) skipped by the safety filter)"
        }

        deck.sourceText = newText
        deck.updatedAt = .now
        deck.lastSyncSummary = summary
        if !parts.isEmpty { deck.lastChangedAt = .now }
        return summary
    }

    private func save() {
        try? context.save()
    }
}

extension PersistentModel {
    /// True once the model has been deleted from its context.
    var isGone: Bool { isDeleted || modelContext == nil }
}
