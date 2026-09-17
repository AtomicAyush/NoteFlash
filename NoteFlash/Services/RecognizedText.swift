import Foundation

/// Decides when to run text recognition on PDF pages that already have typed text, and combines
/// the two. Notes from apps like GoodNotes often mix typed text boxes with handwriting, which
/// only text recognition can read.
nonisolated enum RecognizedText {
    /// Apps whose PDFs usually contain handwriting.
    private static let noteTakingApps = [
        "goodnotes", "notability", "noteshelf", "nebo", "collanote", "notewise", "onenote",
        "flexcil", "zoomnotes", "noteful", "freenotes", "penultimate", "samsung notes", "liquidtext",
    ]

    static func isFromNoteTakingApp(creator: String?, producer: String?) -> Bool {
        [creator, producer].compactMap { $0?.lowercased() }.contains { name in
            // Apple Notes exports are named just "Notes".
            name == "notes" || noteTakingApps.contains { name.contains($0) }
        }
    }

    /// True when recognition found much more text than the page's typed text, which suggests
    /// handwriting or text inside pictures.
    static func findsMissingText(typed: String, recognized: String) -> Bool {
        wordCount(recognized) > wordCount(typed) * 3 / 2 + 15
    }

    /// The typed text, followed by recognized lines it doesn't already contain.
    static func merge(typed: String, recognized: String) -> String {
        let typedKey = normalized(typed)
        guard !typedKey.isEmpty else { return recognized }
        let typedWords = Set(typedKey.split(separator: " "))
        var extra: [String] = []
        for line in recognized.components(separatedBy: .newlines) {
            let key = normalized(line)
            guard key.count >= 3, !typedKey.contains(key) else { continue }
            // Recognition often reads typed lines slightly differently; skip lines that are mostly typed words.
            let words = key.split(separator: " ")
            let known = words.filter { typedWords.contains($0) || isMisreading($0, of: typedWords) }.count
            guard Double(known) < Double(words.count) * 0.8 else { continue }
            extra.append(line.trimmingCharacters(in: .whitespaces))
        }
        return extra.isEmpty ? typed : typed + "\n" + extra.joined(separator: "\n")
    }

    /// True when a longer word is one character off from a typed word ("contro1s" for "controls").
    private static func isMisreading(_ word: Substring, of typedWords: Set<Substring>) -> Bool {
        guard word.count >= 4 else { return false }
        return typedWords.contains { abs($0.count - word.count) <= 1 && withinOneEdit($0, word) }
    }

    private static func withinOneEdit(_ a: Substring, _ b: Substring) -> Bool {
        let a = Array(a), b = Array(b)
        if a.count == b.count {
            return zip(a, b).filter { $0 != $1 }.count <= 1
        }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        var i = 0, j = 0, skipped = false
        while i < short.count && j < long.count {
            if short[i] == long[j] {
                i += 1
            } else if skipped {
                return false
            } else {
                skipped = true
            }
            j += 1
        }
        return true
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
