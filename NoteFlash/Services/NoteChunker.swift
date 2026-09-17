import Foundation

/// Splits long notes into sections small enough for the on-device model's context window.
nonisolated enum NoteChunker {
    /// Breaks `text` into chunks of at most `maxCharacters`, preferring heading and line
    /// boundaries. Chunks that start mid-section are prefixed with that section's heading.
    static func chunks(of text: String, maxCharacters: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed.isEmpty ? [] : [trimmed] }

        var chunks: [String] = []
        var current: [String] = []
        var currentSize = 0
        var heading: String?
        var chunkHeading: String?

        func flush() {
            let body = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                if let chunkHeading {
                    chunks.append("(Continuing the section \"\(chunkHeading)\")\n\(body)")
                } else {
                    chunks.append(body)
                }
            }
            current = []
            currentSize = 0
        }

        for line in trimmed.components(separatedBy: .newlines) {
            let isHeading = isHeadingLine(line)
            // Start a fresh chunk at a heading once the current one has some substance.
            if isHeading, currentSize > maxCharacters / 3 { flush() }
            if currentSize + line.count + 1 > maxCharacters { flush() }
            if current.isEmpty { chunkHeading = isHeading ? nil : heading }
            if isHeading {
                heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
            }

            if line.count > maxCharacters {
                for piece in hardSplit(line, maxCharacters: maxCharacters) {
                    current = [piece]
                    currentSize = piece.count
                    flush()
                    chunkHeading = heading
                }
                continue
            }
            current.append(line)
            currentSize += line.count + 1
        }
        flush()
        return chunks
    }

    /// Splits text roughly in half at a line (or sentence) boundary. Used when a chunk still overflows.
    static func halves(of text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        if lines.count > 1 {
            let middle = lines.count / 2
            return [
                lines[..<middle].joined(separator: "\n"),
                lines[middle...].joined(separator: "\n"),
            ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let pieces = hardSplit(text, maxCharacters: max(1, text.count / 2 + 1))
        return pieces.count > 1 ? pieces : [text]
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("#")
    }

    /// Splits a single long line at sentence ends, falling back to spaces.
    private static func hardSplit(_ line: String, maxCharacters: Int) -> [String] {
        var pieces: [String] = []
        var remaining = Substring(line)
        while remaining.count > maxCharacters {
            let window = remaining.prefix(maxCharacters)
            let cut = window.lastIndex(where: { ".!?".contains($0) }).map { window.index(after: $0) }
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let piece = remaining[..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            remaining = remaining[cut...]
            if cut == remaining.startIndex && piece.isEmpty { break }
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }
}

/// Finds existing cards that an edited section of notes probably affects.
nonisolated enum CardMatcher {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "with", "that", "this", "from", "which", "what",
        "when", "where", "who", "how", "why", "its", "into", "than", "then", "they", "their", "there",
        "has", "have", "had", "been", "being", "can", "could", "would", "should", "will", "not", "but",
        "also", "such", "each", "other", "some", "any", "all", "more", "most", "used", "use", "does",
        "make", "made", "take", "takes", "took", "place", "using", "called", "known", "include", "includes",
        "form", "forms", "part", "type", "many", "much", "very", "only", "same", "like", "about", "after",
        "before", "between", "during", "through", "over", "under", "both", "either", "key", "important",
    ]

    static func keywords(in text: String) -> Set<String> {
        var words = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var word = String(raw)
            guard word.count >= 3, !stopwords.contains(word) else { continue }
            if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            guard !stopwords.contains(word) else { continue }
            words.insert(word)
        }
        return words
    }

    static func related(to hunk: TextDiff.Hunk, in cards: [ExistingCard], limit: Int) -> [ExistingCard] {
        let changedWords = keywords(in: (hunk.removed + hunk.added).joined(separator: " "))
        let removedWords = keywords(in: hunk.removed.joined(separator: " "))
        guard !changedWords.isEmpty else { return [] }

        let scored: [(card: ExistingCard, score: Double)] = cards.compactMap { card in
            let cardWords = keywords(in: card.front + " " + card.back)
            guard !cardWords.isEmpty else { return nil }
            let overlap = cardWords.intersection(changedWords).count
            guard overlap > 0 else { return nil }
            var score = Double(overlap) / Double(cardWords.count)
            if !cardWords.isDisjoint(with: removedWords) { score += 0.2 }
            return score >= 0.3 || overlap >= 2 ? (card, score) : nil
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map(\.card)
    }

    /// True when none of an answer's keywords appear in the notes anymore.
    static func isAnswerMissing(_ answer: String, fromNoteWords noteWords: Set<String>) -> Bool {
        let answerWords = keywords(in: answer)
        return !answerWords.isEmpty && answerWords.isDisjoint(with: noteWords)
    }

    /// True when a card clearly came from deleted lines and no remaining line covers it as well:
    /// its best match among the removed lines shares at least two more key words than its best
    /// match among the lines still in the notes.
    static func isSourcedFromRemovedText(
        _ card: ExistingCard,
        removedLines: [Set<String>],
        noteLines: [Set<String>]
    ) -> Bool {
        let cardWords = keywords(in: card.front + " " + card.back)
        let fromRemoved = removedLines.lazy.map { $0.intersection(cardWords).count }.max() ?? 0
        guard fromRemoved >= 3 else { return false }
        let fromNotes = noteLines.lazy.map { $0.intersection(cardWords).count }.max() ?? 0
        return fromRemoved >= fromNotes + 2
    }

    /// True when some line of the notes contains both the answer and the question's topic.
    static func isSupported(front: String, back: String, byLines lines: [Set<String>]) -> Bool {
        let answerWords = keywords(in: back)
        let topicWords = keywords(in: front).subtracting(answerWords)
        guard !answerWords.isEmpty else { return true }
        // Numbers must match exactly: "100,000" isn't supported by a line saying "500,000".
        let numbers = answerWords.filter { $0.contains(where: \.isNumber) }
        let needed = min(2, topicWords.count)
        return lines.contains { line in
            !line.isDisjoint(with: answerWords)
                && numbers.isSubset(of: line)
                && line.intersection(topicWords).count >= needed
        }
    }

    /// True when the answer has a number that was deleted from the notes and appears nowhere in
    /// them now, like "100,000" after the notes changed it to "500,000".
    static func hasOutdatedNumber(_ answer: String, removedWords: Set<String>, noteWords: Set<String>) -> Bool {
        keywords(in: answer).contains { word in
            word.contains(where: \.isNumber) && removedWords.contains(word) && !noteWords.contains(word)
        }
    }

    /// Lines with facts to write cards about: not headings, continuation labels, or comments.
    static func contentLines(of text: String) -> [String] {
        TextDiff.lines(of: text).filter { !isContextLine($0) && !keywords(in: $0).isEmpty }
    }

    static func isContextLine(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("(Continuing") || CommentWeaver.isCommentLine(line)
    }

    /// Lines of the notes that no card is about. A card is about a line when it shares three of
    /// the line's key words (or half of a short line's).
    static func uncoveredLines(in text: String, by cards: [GeneratedCard]) -> [String] {
        let cardWords = cards.map { keywords(in: $0.front + " " + $0.back) }
        return contentLines(of: text).filter { line in
            let lineWords = keywords(in: line)
            let needed = min(3, (lineWords.count + 1) / 2)
            return !cardWords.contains { $0.intersection(lineWords).count >= needed }
        }
    }

    /// True when two cards test essentially the same material.
    static func isNearDuplicate(_ a: GeneratedCard, of b: GeneratedCard) -> Bool {
        let wordsA = keywords(in: a.front + " " + a.back)
        let wordsB = keywords(in: b.front + " " + b.back)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        let jaccard = Double(wordsA.intersection(wordsB).count) / Double(wordsA.union(wordsB).count)
        return jaccard >= 0.6
    }
}

/// Notices a response that keeps writing cards it already wrote, as the small on-device model
/// sometimes does, so it can be stopped instead of running on to its card limit.
nonisolated struct RepetitionWatch {
    static let limit = 4
    private var checked = 0
    private var kept: [GeneratedCard] = []
    private(set) var repeats = 0

    /// Looks at the cards finished since the last call (the last card may still be streaming).
    /// True once the response has repeated itself `limit` times.
    mutating func isLooping(_ cards: [GeneratedCard]) -> Bool {
        let finished = cards.dropLast()
        for card in finished.dropFirst(checked) {
            let front = CardWriting.normalizedKey(card.front)
            if kept.contains(where: { CardWriting.normalizedKey($0.front) == front || CardMatcher.isNearDuplicate(card, of: $0) }) {
                repeats += 1
            } else {
                kept.append(card)
            }
        }
        checked = max(checked, finished.count)
        return repeats >= Self.limit
    }
}
