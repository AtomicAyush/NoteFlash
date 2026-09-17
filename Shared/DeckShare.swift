import Foundation

/// A deck packed up for sharing: the cards, the notes they came from, and enough to rebuild the
/// deck exactly in NoteFlash.
nonisolated struct SharedDeck: Codable, Sendable {
    struct Card: Codable, Sendable {
        var front: String
        var back: String
        /// Covers a point the notes say will be on the exam.
        var isPriority: Bool = false
    }

    /// The Google Drive file the cards were made from, so a collaborator who can open the same
    /// file gets a deck that keeps itself up to date instead of a fixed copy.
    struct Source: Codable, Sendable {
        var id: String
        /// A `DriveFileKind` raw value.
        var kind: String?
        var name: String?
        /// A link that opens the file in Docs, Slides, or Drive.
        var url: String?
        /// The file version the cards were written from.
        var version: String?
    }

    /// Marks the payload as a NoteFlash deck rather than any other JSON in the page.
    static let format = "noteflash.deck"
    /// Bumped only for changes older versions can't read.
    static let currentVersion = 1

    var format = SharedDeck.format
    var version = SharedDeck.currentVersion
    var title: String
    var exportedAt = Date.now
    /// A `CardDensity` raw value, so a regenerate matches how the deck was written.
    var density: String
    /// The notes the cards came from, for studying, editing, and regenerating.
    var notes: String
    var cards: [Card]
    /// Set when the sender's deck was linked to a file in Google Drive.
    var source: Source?

    var priorityCount: Int { cards.filter(\.isPriority).count }
}

/// Shares a deck as one file anyone can open: a web page that studies and prints on its own,
/// with the deck itself embedded in it so NoteFlash can add the cards back exactly as written.
nonisolated enum DeckShare {
    /// The element holding the deck's JSON inside the shared page.
    static let payloadElementID = "noteflash-deck"

    // MARK: Writing

    static func html(for deck: SharedDeck) -> String {
        let title = escaped(deck.title.isEmpty ? "Flashcards" : deck.title)
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="NoteFlash">
            <title>\(title)</title>
            <style>
            \(styles)
            </style>
            </head>
            <body>
            <main>
            <header>
            <h1>\(title)</h1>
            <p class="count">\(countLine(for: deck))</p>
            </header>
            \(studySection)
            <section aria-labelledby="all-cards">
            <h2 id="all-cards">All cards</h2>
            <ol class="cards">
            \(deck.cards.map(listItem).joined(separator: "\n"))
            </ol>
            </section>
            \(notesSection(deck.notes))
            <footer>
            <p>Made with <strong>NoteFlash</strong>. Open this file in NoteFlash on iPhone or iPad
            to add these cards to your own decks, with your own study progress.</p>
            </footer>
            </main>
            <script type="application/json" id="\(payloadElementID)">\(payloadJSON(for: deck))</script>
            <script>
            \(script)
            </script>
            </body>
            </html>

            """
    }

    /// A file name for the shared page, safe on every platform.
    static func fileName(for title: String) -> String {
        let stripped = title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let name = stripped.isEmpty ? "Flashcards" : String(stripped.prefix(60))
        return "\(name) — NoteFlash.html"
    }

    private static func countLine(for deck: SharedDeck) -> String {
        var line = "\(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")"
        if deck.priorityCount > 0 {
            line += " · \(deck.priorityCount) on the exam"
        }
        return line
    }

    private static func listItem(_ card: SharedDeck.Card) -> String {
        let badge = card.isPriority ? "<span class=\"flag\">On the exam</span>" : ""
        return """
            <li\(card.isPriority ? " class=\"priority\"" : "")>
            <p class="q">\(escaped(card.front))\(badge)</p>
            <p class="a">\(escaped(card.back))</p>
            </li>
            """
    }

    /// Hidden until the page's script fills it in, so the list below is always the fallback.
    private static var studySection: String {
        """
        <section id="study" hidden aria-labelledby="study-heading">
        <h2 id="study-heading" class="visually-hidden">Study</h2>
        <button type="button" id="card" aria-live="polite">
        <span id="side-label">Question</span>
        <span id="card-text"></span>
        <span class="hint">Tap to see the answer</span>
        </button>
        <div class="controls">
        <button type="button" id="prev" aria-label="Previous card">‹</button>
        <p id="progress" aria-live="polite"></p>
        <button type="button" id="next" aria-label="Next card">›</button>
        </div>
        </section>
        """
    }

    private static func notesSection(_ notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
            <section>
            <details>
            <summary>Notes these cards came from</summary>
            <pre class="notes">\(escaped(trimmed))</pre>
            </details>
            </section>
            """
    }

    /// The deck as JSON, safe to sit inside a `<script>` element.
    private static func payloadJSON(for deck: SharedDeck) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(deck), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        // "</script>" would end the element early; < is the same string to any JSON reader.
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Reading

    /// The deck inside a shared page, or nil for any other file.
    static func deck(inPage html: String) -> SharedDeck? {
        guard let json = payloadJSON(inPage: html), let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let deck = try? decoder.decode(SharedDeck.self, from: data),
              deck.format == SharedDeck.format, !deck.cards.isEmpty else { return nil }
        return deck
    }

    static func deck(inPage data: Data) -> SharedDeck? {
        guard let html = text(of: data) else { return nil }
        return deck(inPage: html)
    }

    /// True for files worth looking inside for a deck.
    static func isPage(name: String) -> Bool {
        ["html", "htm", "xhtml"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func payloadJSON(inPage html: String) -> String? {
        // The element's attributes can be in any order, so find the id and then the element.
        guard let idRange = html.range(of: payloadElementID) else { return nil }
        guard let openRange = html.range(of: "<script", options: .backwards, range: html.startIndex..<idRange.lowerBound),
              let contentStart = html.range(of: ">", range: idRange.upperBound..<html.endIndex)?.upperBound,
              let contentEnd = html.range(of: "</script", range: contentStart..<html.endIndex)?.lowerBound,
              // The id must belong to the tag that opens the element.
              !html[openRange.upperBound..<idRange.lowerBound].contains(">") else { return nil }
        return String(html[contentStart..<contentEnd])
    }

    /// The readable text of a web page, for making cards from a page that isn't a shared deck.
    static func plainText(ofPage html: String) -> String {
        var text = html
        // Scripts and styles aren't readable text.
        for element in ["script", "style", "head", "noscript", "svg"] {
            text = removingElements(named: element, from: text)
        }
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = HTMLText.decodingEntities(text)
        // Collapse the blank lines that stripped markup leaves behind.
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static func plainText(ofPage data: Data) -> String? {
        text(of: data).map(plainText(ofPage:))
    }

    private static func text(of data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func removingElements(named name: String, from html: String) -> String {
        html.replacingOccurrences(
            of: "<\(name)\\b[^>]*>[\\s\\S]*?</\(name)\\s*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
