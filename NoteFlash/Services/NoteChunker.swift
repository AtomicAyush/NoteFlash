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

    /// True when two cards test essentially the same material.
    static func isNearDuplicate(_ a: GeneratedCard, of b: GeneratedCard) -> Bool {
        let wordsA = keywords(in: a.front + " " + a.back)
        let wordsB = keywords(in: b.front + " " + b.back)
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
        let jaccard = Double(wordsA.intersection(wordsB).count) / Double(wordsA.union(wordsB).count)
        return jaccard >= 0.6
    }
}
