import Foundation

/// Forgiving comparison for typed answers in Learn mode.
nonisolated enum AnswerChecker {
    static func isCorrect(_ answer: String, expected: String) -> Bool {
        let given = normalize(answer)
        let target = normalize(expected)
        guard !given.isEmpty else { return false }
        if given == target { return true }
        let distance = levenshtein(Array(given), Array(target))
        let similarity = 1 - Double(distance) / Double(max(given.count, target.count))
        return similarity >= 0.85
    }

    /// Long answers are graded by the student instead of by string matching.
    static func needsSelfGrading(_ expected: String) -> Bool {
        expected.split(whereSeparator: \.isWhitespace).count > 6
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        let words = String(cleaned).split(separator: " ").map(String.init)
        let articles: Set<String> = ["a", "an", "the"]
        let trimmed = words.first.map { articles.contains($0) } == true ? Array(words.dropFirst()) : words
        return trimmed.joined(separator: " ")
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
