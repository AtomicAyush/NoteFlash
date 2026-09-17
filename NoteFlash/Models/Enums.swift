import Foundation

nonisolated enum SourceKind: String, CaseIterable, Identifiable, Sendable {
    case text
    case pdf
    case googleDoc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .pdf: "PDF"
        case .googleDoc: "Google Doc"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .pdf: "doc.richtext"
        case .googleDoc: "link"
        }
    }
}

/// How many cards the AI engine should write for a given amount of notes.
nonisolated enum CardDensity: String, CaseIterable, Identifiable, Sendable {
    case essentials
    case balanced
    case thorough

    var id: String { rawValue }

    var label: String {
        switch self {
        case .essentials: "Essentials"
        case .balanced: "Balanced"
        case .thorough: "Thorough"
        }
    }

    var promptGuidance: String {
        switch self {
        case .essentials:
            "Make a compact set that covers only the most important ideas, roughly one card per major concept."
        case .balanced:
            "Cover every key term, idea, and fact in the notes without padding the deck with trivia."
        case .thorough:
            "Be exhaustive: cover every definable term, fact, date, formula, and detail that could plausibly appear on a test."
        }
    }
}

/// Marks cards that a Google Doc sync or notes edit changed recently.
nonisolated enum SyncBadge: String, Sendable {
    case new
    case updated

    var label: String {
        switch self {
        case .new: "New"
        case .updated: "Updated"
        }
    }
}

nonisolated enum StudyMode: String, Identifiable, CaseIterable, Sendable {
    case flashcards
    case learn
    case match

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flashcards: "Flashcards"
        case .learn: "Learn"
        case .match: "Match"
        }
    }

    var systemImage: String {
        switch self {
        case .flashcards: "rectangle.on.rectangle.angled"
        case .learn: "brain.head.profile"
        case .match: "square.grid.3x3.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .flashcards: "Flip and sort"
        case .learn: "Quiz to mastery"
        case .match: "Race the clock"
        }
    }
}
