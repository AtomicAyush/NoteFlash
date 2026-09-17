import Foundation

/// Reads comments from a Word (.docx) file. Google Docs exports comments this way, which is
/// how comments are read from docs shared by link (the plain-text export leaves them out).
nonisolated enum DocxComments {
    static func comments(in data: Data) -> [DriveComment] {
        guard ZipArchive.isZip(data), let archive = try? ZipArchive(data: data),
              let commentsXML = try? archive.data(for: "word/comments.xml") else { return [] }
        let bodies = CommentsParser.parse(commentsXML)
        guard !bodies.isEmpty else { return [] }
        let quotes = (try? archive.data(for: "word/document.xml")).map(RangesParser.parse) ?? [:]
        return bodies.map { id, content in
            DriveComment(quote: quotes[id].flatMap { $0.isEmpty ? nil : $0 }, content: content)
        }
    }
}

/// `<w:comment w:id="3">…<w:t>text</w:t>…</w:comment>`, in document order.
nonisolated private final class CommentsParser: NSObject, XMLParserDelegate {
    private var results: [(String, String)] = []
    private var currentID: String?
    private var paragraphs: [String] = []
    private var paragraph = ""
    private var inText = false

    static func parse(_ data: Data) -> [(id: String, content: String)] {
        let handler = CommentsParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.results.map { (id: $0.0, content: $0.1) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "w:comment":
            currentID = attributes["w:id"]
            paragraphs = []
        case "w:p":
            paragraph = ""
        case "w:t":
            inText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText && currentID != nil { paragraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "w:t":
            inText = false
        case "w:p":
            if currentID != nil { paragraphs.append(paragraph) }
        case "w:comment":
            if let id = currentID {
                let content = paragraphs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { results.append((id, content)) }
            }
            currentID = nil
        default:
            break
        }
    }
}

/// The document text between each comment's range markers.
nonisolated private final class RangesParser: NSObject, XMLParserDelegate {
    private var open: Set<String> = []
    private var quotes: [String: String] = [:]
    private var inText = false

    static func parse(_ data: Data) -> [String: String] {
        let handler = RangesParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.quotes.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "w:commentRangeStart":
            if let id = attributes["w:id"] { open.insert(id) }
        case "w:commentRangeEnd":
            if let id = attributes["w:id"] { open.remove(id) }
        case "w:t":
            inText = true
        case "w:p":
            // Keep paragraphs apart, so a quote spanning lines matches its first line.
            for id in open where !(quotes[id] ?? "").isEmpty { quotes[id, default: ""] += "\n" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        for id in open { quotes[id, default: ""] += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "w:t" { inText = false }
    }
}
