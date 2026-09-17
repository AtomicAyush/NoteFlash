import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit

/// Keeps decks in step with their notes: polls linked Google Drive files while the app is open,
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
    /// Called when a linked file changed while the app is open, so the update can run as a
    /// visible processing job. Without it, updates run inline.
    var onDocChanged: ((Deck, DriveFileContent) -> Void)?
    private let container: ModelContainer
    private let googleAuth: GoogleAuth
    private let reader: DriveFileReader
    private var pollTask: Task<Void, Never>?

    init(container: ModelContainer, googleAuth: GoogleAuth) {
        self.container = container
        self.googleAuth = googleAuth
        reader = DriveFileReader(auth: googleAuth)
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

    // MARK: Google Drive sync

    func syncAllLinkedDecks() async {
        let descriptor = FetchDescriptor<Deck>(
            predicate: #Predicate { $0.autoSync == true && $0.googleDocID != nil }
        )
        guard let decks = try? context.fetch(descriptor) else { return }
        for deck in decks where !Task.isCancelled {
            if deck.sourceKind != .googleDoc, !googleAuth.hasDriveAccess,
               let checked = deck.lastCheckedAt,
               Date.now.timeIntervalSince(checked) < AppConfig.publicFileSyncInterval {
                continue
            }
            _ = try? await sync(deck)
        }
    }

    /// Checks one linked file. If it changed, the update is handed to `onDocChanged` while the
    /// app is open, or applied here otherwise. Returns whether the file changed.
    @discardableResult
    func sync(_ deck: Deck) async throws -> Bool {
        guard let reference = deck.driveReference, !isBusy(deck) else { return false }
        let content: DriveFileContent?
        do {
            content = try await readIfChanged(reference, knownVersion: deck.sourceVersion)
        } catch {
            if !deck.isGone {
                deck.lastSyncError = error.localizedDescription
                save()
            }
            throw error
        }
        guard !deck.isGone else { return false }
        deck.lastCheckedAt = .now

        guard let content, TextDiff.fingerprint(of: content.text) != deck.sourceHash else {
            // Unchanged, or changed in ways that don't affect the text (like formatting).
            if let content {
                deck.sourceVersion = content.version
                if let pdf = content.pdfData { deck.sourcePDF = pdf }
            }
            deck.lastSyncError = nil
            save()
            return false
        }
        if let onDocChanged, UIApplication.shared.applicationState == .active {
            onDocChanged(deck, content)
        } else {
            try await applyDocChange(to: deck, content: content)
        }
        return true
    }

    /// Revises a linked deck to match its file's new contents.
    func applyDocChange(to deck: Deck, content: DriveFileContent, reporter: ProcessingReporter = .silent) async throws {
        try await exclusively(deck) {
            do {
                _ = try await revise(deck, toMatch: content.text, reporter: reporter)
                deck.sourceHash = TextDiff.fingerprint(of: content.text)
                deck.sourceVersion = content.version
                if let pdf = content.pdfData { deck.sourcePDF = pdf }
                deck.lastSyncError = nil
                save()
            } catch {
                if !deck.isGone {
                    deck.lastSyncError = error.localizedDescription
                    save()
                }
                throw error
            }
        }
    }

    /// Reads a linked Drive file: Docs, Slides, PDFs, or PowerPoint files.
    func fetchContent(_ reference: DriveFileReference, reporter: ProcessingReporter = .silent) async throws -> DriveFileContent {
        #if DEBUG
        if UITestSupport.isEnabled {
            let item = DriveItem(id: reference.id, name: reference.name ?? "Sample", mimeType: reference.kind.map(\.mimeType) ?? DriveMimeType.document)
            return try await SampleDriveDataSource().content(of: item, auth: googleAuth)
        }
        #endif
        return try await reader.read(reference) { phase in
            reporter.send(.phase(phase))
        }
    }

    private func readIfChanged(_ reference: DriveFileReference, knownVersion: String?) async throws -> DriveFileContent? {
        #if DEBUG
        if UITestSupport.isEnabled {
            return try await fetchContent(reference)
        }
        #endif
        return try await reader.readIfChanged(reference, knownVersion: knownVersion)
    }

    // MARK: Edited notes and regeneration

    /// Saves hand-edited notes for a text deck and revises the affected cards.
    @discardableResult
    func updateNotes(of deck: Deck, to newText: String, reporter: ProcessingReporter = .silent) async throws -> String {
        try await exclusively(deck) {
            let summary = try await revise(deck, toMatch: newText, reporter: reporter)
            deck.markModifiedByMe()
            save()
            return summary
        }
    }

    /// Rebuilds a deck from its source, keeping cards the user wrote or edited by hand.
    func regenerate(_ deck: Deck, reporter: ProcessingReporter = .silent) async throws {
        try await exclusively(deck) {
            var notes = deck.sourceText
            var latest: DriveFileContent?
            if let reference = deck.driveReference {
                reporter.send(.phase("Opening your \(deck.sourceKind.label)"))
                let content = try await fetchContent(reference, reporter: reporter)
                notes = content.text
                if let pdf = content.pdfData { deck.sourcePDF = pdf }
                latest = content
            }
            let source: NoteSource = if let pdf = deck.sourcePDF, deck.sourceKind == .pdf || deck.sourceKind == .drivePDF {
                .pdf(data: pdf, text: notes)
            } else {
                .text(notes)
            }

            let engineKind = AIEngineKind.selected
            let engine = try engineKind.makeEngine()
            let characters = if case .pdf(let data, _, _) = source {
                DeckCreator.workload(forPDF: data, pages: PDFTextExtractor.pageCount(of: data) ?? 0, text: notes, engine: engineKind)
            } else {
                notes.count
            }
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
            deck.sourceText = notes
            deck.addGeneratedCards(generated.cards)
            deck.refreshPriorities()
            if let latest {
                deck.sourceHash = TextDiff.fingerprint(of: notes)
                deck.sourceVersion = latest.version
                deck.lastCheckedAt = .now
                deck.lastSyncError = nil
            }
            deck.markModifiedByMe()
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
    private func revise(_ deck: Deck, toMatch newText: String, reporter: ProcessingReporter = .silent) async throws -> String {
        guard let changes = TextDiff.changes(from: deck.sourceText, to: newText) else {
            deck.sourceText = newText
            deck.refreshPriorities()
            return "No changes to the notes"
        }

        var cardsByKey: [String: Flashcard] = [:]
        var existing: [ExistingCard] = []
        for (index, card) in deck.sortedCards.enumerated() {
            let key = "c\(index + 1)"
            cardsByKey[key] = card
            existing.append(ExistingCard(id: key, front: card.front, back: card.back, locked: card.isUserEdited))
        }

        let engineKind = AIEngineKind.selected
        let engine = try engineKind.makeEngine()
        // Editing work scales with the size of the edits, not the whole doc.
        reporter.send(.workload(characters: changes.rendered.count, engine: engineKind))
        let revision = try await engine.reviseDeck(
            existing: existing,
            changes: changes,
            updatedNotes: newText,
            density: deck.density,
            progress: reporter.generationHandler
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
        // New or removed exam comments can change which existing cards are priorities.
        deck.refreshPriorities()
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
