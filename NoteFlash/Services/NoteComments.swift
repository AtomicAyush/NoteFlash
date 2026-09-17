import CryptoKit
import Foundation

/// A comment (with its replies) on a Google Doc or Slides presentation.
nonisolated struct DriveComment: Sendable, Equatable {
    /// The text the comment is attached to, when there is one.
    var quote: String?
    var content: String
    var replies: [String] = []
    var modified: Date?
}

/// Puts comments into the notes text, each right after the line it's attached to, so the
/// model reads them in context. Comments that mention the exam are marked as priorities.
nonisolated enum CommentWeaver {
    static let commentPrefix = "» "
    static let priorityLabel = "EXAM PRIORITY"

    static func weave(_ comments: [DriveComment], into text: String) -> String {
        let usable = comments.filter(isUsable)
        guard !usable.isEmpty else { return text }

        var lines = text.components(separatedBy: "\n")
        let keys = lines.map(key)
        var attached: [Int: [String]] = [:]
        var unattached: [String] = []
        for comment in usable {
            if let index = lineIndex(for: comment.quote, in: keys) {
                attached[index, default: []].append(line(for: comment, anchored: true))
            } else if namesSomething(comment) {
                // Away from the text it was on, a comment is only worth keeping if it says what
                // it's about: "On Exam" on its own names nothing to study.
                unattached.append(line(for: comment, anchored: false))
            }
        }
        for index in attached.keys.sorted(by: >) {
            lines.insert(contentsOf: attached[index] ?? [], at: index + 1)
        }
        var result = lines.joined(separator: "\n")
        if !unattached.isEmpty {
            result += "\n\n## Comments\n" + unattached.joined(separator: "\n")
        }
        return result
    }

    /// A comment with something to say: some words, and — when it isn't attached to any text —
    /// something to study rather than only a note about the exam.
    static func isUsable(_ comment: DriveComment) -> Bool {
        guard !words(of: comment).isEmpty else { return false }
        return comment.quote.map(clean)?.isEmpty == false || namesSomething(comment)
    }

    /// Two words of substance, so "On Exam" and "Assume on exam" don't count but "Midterm covers
    /// everything through Yorktown" does.
    static func namesSomething(_ comment: DriveComment) -> Bool {
        CardMatcher.keywords(in: words(of: comment).joined(separator: " "))
            .subtracting(PriorityNotes.signalWords).count >= 2
    }

    private static func words(of comment: DriveComment) -> [String] {
        ([comment.content] + comment.replies).map(clean).filter { !$0.isEmpty }
    }

    static func line(for comment: DriveComment, anchored: Bool) -> String {
        let content = clean(comment.content)
        let replies = comment.replies.map(clean).filter { !$0.isEmpty }
        let isPriority = ExamSignals.mentionsExam(content) || replies.contains(where: ExamSignals.mentionsExam)
        var line = commentPrefix + (isPriority ? "\(priorityLabel) — comment" : "Comment")
        if anchored, let quote = comment.quote.map(clean), !quote.isEmpty {
            line += " on “\(quote.count > 80 ? String(quote.prefix(80)) + "…" : quote)”"
        }
        line += ": " + content
        if !replies.isEmpty {
            line += " (replies: " + replies.joined(separator: "; ") + ")"
        }
        return line
    }

    static func isCommentLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(commentPrefix)
    }

    /// Changes whenever a comment or reply is added, edited, or removed.
    static func fingerprint(_ comments: [DriveComment]) -> String {
        let material = comments.map { comment in
            ([comment.quote ?? "", comment.content] + comment.replies).joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(material.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The first line containing the quote (or its first line, for quotes spanning lines).
    private static func lineIndex(for quote: String?, in keys: [String]) -> Int? {
        guard let quote else { return nil }
        let firstLine = quote.components(separatedBy: .newlines).map(key).first { !$0.isEmpty } ?? ""
        guard firstLine.count >= 2 else { return nil }
        let probe = String(firstLine.prefix(60))
        return keys.firstIndex { $0.contains(probe) }
    }

    private static func key(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace || $0 == "•" })
            .joined(separator: " ")
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Recognizes notes that say something will be on an exam.
nonisolated enum ExamSignals {
    /// Phrases that clearly mean "this will be tested".
    private static let strongSources = [
        #"\bon (the|our|this|next|an|a|every|each) (exam|test|quiz|midterm|final|finals)\b"#,
        #"\b(will|could|might|may|is going to|are going to) be (tested|asked|on (the )?(exam|test|quiz|midterm|final))\b"#,
        #"\b(exam|test|quiz|midterm|final) (question|material|topic|content|item)s?\b"#,
        #"\btestable\b"#,
        #"\bhigh[- ]yield\b"#,
    ]
    /// Words that, in a comment, almost always refer to an exam.
    private static let commentSources = strongSources + [
        #"\b(exam|midterm|finals?|quiz)\b"#,
        #"\b(know|memorize|study|learn) (this|these|that)\b"#,
        #"\bimportant\b"#,
    ]

    private static let strongPatterns = compile(strongSources)
    private static let commentPatterns = compile(commentSources)

    private static func compile(_ sources: [String]) -> [NSRegularExpression] {
        sources.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    /// For comments, which are short and usually about studying.
    static func mentionsExam(_ comment: String) -> Bool {
        matches(comment, commentPatterns)
    }

    /// For lines of the notes themselves, where only clear phrases count.
    static func linesMentionsExam(_ line: String) -> Bool {
        matches(line, strongPatterns)
    }

    private static func matches(_ text: String, _ patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}

/// A point the student was told will be on the exam.
nonisolated struct PriorityItem: Sendable, Equatable {
    /// What the point is about: the commented text, or the flagged line.
    let topic: String
    /// The comment or line that flagged it.
    let note: String
    /// False for comments not attached to any text, which name no specific point.
    var isAnchored = true
}

/// Finds exam priorities in notes and decides which cards cover them.
nonisolated enum PriorityNotes {
    /// Words that say "exam" rather than what the point is about.
    static let signalWords: Set<String> = [
        "exam", "test", "tested", "quiz", "midterm", "final", "question", "know", "memorize", "study",
        "assume", "assumed",
        "important", "definitely", "remember", "priority", "comment", "will", "sure", "going", "learn",
        "highyield", "high", "yield", "testable", "material", "topic", "content", "item", "replie",
        "these", "those", "next", "every", "each", "well", "really", "pay", "attention", "focus", "review",
        "chapter", "class", "lecture", "again", "before", "friday", "monday", "tuesday", "wednesday", "thursday",
    ]

    static func items(in text: String) -> [PriorityItem] {
        var items: [PriorityItem] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(CommentWeaver.commentPrefix + CommentWeaver.priorityLabel) {
                let quote = line.firstMatch(of: #/“(.+?)”/#).map { String($0.1) }
                let note = (line.range(of: "”: ") ?? line.range(of: ": ")).map { String(line[$0.upperBound...]) } ?? line
                items.append(PriorityItem(topic: quote ?? note, note: note, isAnchored: quote != nil))
            } else if !CommentWeaver.isCommentLine(line), ExamSignals.linesMentionsExam(line) {
                items.append(PriorityItem(topic: line, note: line))
            }
        }
        return items
    }

    static func isPriority(front: String, back: String, items: [PriorityItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let cardWords = CardMatcher.keywords(in: front + " " + back)
        return items.contains { covers(cardWords, $0) }
    }

    static func covers(_ cardWords: Set<String>, _ item: PriorityItem) -> Bool {
        var topicWords = CardMatcher.keywords(in: item.topic).subtracting(signalWords)
        if topicWords.isEmpty {
            topicWords = CardMatcher.keywords(in: item.note).subtracting(signalWords)
        }
        guard !topicWords.isEmpty else { return false }
        return cardWords.intersection(topicWords).count >= min(2, topicWords.count)
    }

    /// The flagged line with its neighbors, for writing cards about one priority.
    static func context(for item: PriorityItem, in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let topic = item.topic.lowercased()
        let probe = String(topic.prefix(60))
        guard let index = lines.firstIndex(where: { !CommentWeaver.isCommentLine($0) && $0.lowercased().contains(probe) })
                ?? lines.firstIndex(where: { $0.contains(item.note) }) else {
            return item.note
        }
        let range = max(0, index - 2)...min(lines.count - 1, index + 3)
        return lines[range].joined(separator: "\n")
    }
}
