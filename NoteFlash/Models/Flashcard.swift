import Foundation
import SwiftData

@Model
final class Flashcard {
    /// Learn mode: 0 = not started, 1 = answered multiple choice, 2 = mastered (recalled without options).
    static let masteredLevel = 2
    /// How long "New"/"Updated" badges stay visible after a sync.
    static let badgeLifetime: TimeInterval = 3 * 24 * 60 * 60

    var id: UUID = UUID()
    var front: String = ""
    var back: String = ""
    var order: Int = 0
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var isStarred: Bool = false
    /// Set when the user edits or writes a card by hand; syncs never overwrite these.
    var isUserEdited: Bool = false
    /// Covers a point the notes (or their comments) say will be on the exam.
    var isPriority: Bool = false

    var syncBadgeRaw: String?
    var syncBadgeDate: Date?

    var masteryLevel: Int = 0
    var timesStudied: Int = 0
    var timesCorrect: Int = 0
    var lastStudiedAt: Date?

    var deck: Deck?

    init(front: String, back: String, order: Int, isUserEdited: Bool = false) {
        self.front = front
        self.back = back
        self.order = order
        self.isUserEdited = isUserEdited
    }

    var activeSyncBadge: SyncBadge? {
        guard let raw = syncBadgeRaw, let date = syncBadgeDate,
              Date.now.timeIntervalSince(date) < Self.badgeLifetime else { return nil }
        return SyncBadge(rawValue: raw)
    }

    func setBadge(_ badge: SyncBadge?) {
        syncBadgeRaw = badge?.rawValue
        syncBadgeDate = badge == nil ? nil : .now
    }

    func recordAnswer(correct: Bool) {
        timesStudied += 1
        if correct { timesCorrect += 1 }
        lastStudiedAt = .now
    }

    func resetProgress() {
        masteryLevel = 0
        timesStudied = 0
        timesCorrect = 0
        lastStudiedAt = nil
    }
}
