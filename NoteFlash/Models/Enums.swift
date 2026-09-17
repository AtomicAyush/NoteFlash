import Foundation

/// Where a deck's notes came from.
nonisolated enum SourceKind: String, Identifiable, Sendable {
    case text
    case pdf
    case powerPoint
    case googleDoc
    case googleSlides
    case drivePDF
    case drivePowerPoint
    /// A deck another NoteFlash user shared.
    case shared

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .pdf: "PDF"
        case .powerPoint: "PowerPoint"
        case .googleDoc: "Google Doc"
        case .googleSlides: "Google Slides"
        case .drivePDF: "PDF in Google Drive"
        case .drivePowerPoint: "PowerPoint in Google Drive"
        case .shared: "Shared deck"
        }
    }

    /// Notes the user can edit themselves, rather than a file NoteFlash read them from.
    var hasEditableNotes: Bool { self == .text || self == .shared }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .pdf, .drivePDF: "doc.richtext"
        case .powerPoint, .drivePowerPoint: "rectangle.on.rectangle"
        case .googleDoc: "doc.text"
        case .googleSlides: "rectangle.on.rectangle.angled"
        case .shared: "person.2.fill"
        }
    }

    /// The Drive file type for decks linked to Google Drive.
    var driveFileKind: DriveFileKind? {
        switch self {
        case .text, .pdf, .powerPoint, .shared: nil
        case .googleDoc: .document
        case .googleSlides: .presentation
        case .drivePDF: .pdf
        case .drivePowerPoint: .powerPoint
        }
    }
}

/// Ways to order the deck list, following Google Drive's sort options.
nonisolated enum DeckSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case modified
    case modifiedByMe
    case opened
    case created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "Name"
        case .modified: "Last modified"
        case .modifiedByMe: "Last modified by me"
        case .opened: "Last opened by me"
        case .created: "Date created"
        }
    }

    var ascendingByDefault: Bool { self == .name }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name: ascending ? "A to Z" : "Z to A"
        default: ascending ? "Oldest first" : "Newest first"
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

/// Marks cards that a Google Drive sync or notes edit changed recently.
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
