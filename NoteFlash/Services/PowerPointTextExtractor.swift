import Foundation

/// Reads the text of a PowerPoint (.pptx) presentation, slide by slide: titles become
/// headings, body text becomes bullets, tables become rows, and speaker notes are kept.
nonisolated enum PowerPointTextExtractor {
    struct Result: Sendable {
        let text: String
        let slideCount: Int
    }

    enum ExtractionError: LocalizedError {
        case notAPresentation

        var errorDescription: String? {
            "That file couldn't be opened as a PowerPoint (.pptx) presentation. Older .ppt files aren't supported; save it as .pptx first."
        }
    }

    static func isPresentation(_ data: Data) -> Bool {
        guard ZipArchive.isZip(data), let archive = try? ZipArchive(data: data) else { return false }
        return archive.contains("ppt/presentation.xml")
    }

    static func extract(from data: Data) throws -> Result {
        guard ZipArchive.isZip(data), let archive = try? ZipArchive(data: data),
              archive.contains("ppt/presentation.xml") else {
            throw ExtractionError.notAPresentation
        }
        let slidePaths = orderedSlidePaths(in: archive)
        var sections: [String] = []
        for (index, path) in slidePaths.enumerated() {
            guard let xml = try? archive.data(for: path) else { continue }
            let slide = SlideParser.parse(xml)
            var lines: [String] = []
            lines.append("## \(slide.title ?? "Slide \(index + 1)")")
            lines += slide.lines

            if let notesPath = relatedPath(of: path, type: "notesSlide", in: archive),
               let notesXML = try? archive.data(for: notesPath) {
                let notes = SlideParser.parse(notesXML, notesOnly: true).lines
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "• ").union(.whitespaces)) }
                    .filter { !$0.isEmpty }
                if !notes.isEmpty {
                    lines.append("Speaker notes: " + notes.joined(separator: " "))
                }
            }
            // Skip slides with nothing but a placeholder heading.
            if slide.title != nil || lines.count > 1 {
                sections.append(lines.joined(separator: "\n"))
            }
        }
        return Result(text: sections.joined(separator: "\n\n"), slideCount: slidePaths.count)
    }

    // MARK: Package structure

    /// Slides in presentation order, from presentation.xml and its relationships.
    static func orderedSlidePaths(in archive: ZipArchive) -> [String] {
        let relationships = relationships(for: "ppt/presentation.xml", in: archive)
        var ordered: [String] = []
        if let xml = try? archive.data(for: "ppt/presentation.xml") {
            for id in SlideListParser.slideRelationshipIDs(in: xml) {
                if let target = relationships[id]?.target, archive.contains(target), !ordered.contains(target) {
                    ordered.append(target)
                }
            }
        }
        if !ordered.isEmpty { return ordered }
        // Fall back to file names: slide1.xml, slide2.xml, …
        return archive.paths
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func relatedPath(of path: String, type: String, in archive: ZipArchive) -> String? {
        relationships(for: path, in: archive).values
            .first { $0.type.hasSuffix("/\(type)") }
            .map(\.target)
            .flatMap { archive.contains($0) ? $0 : nil }
    }

    struct Relationship {
        let type: String
        let target: String
    }

    /// A part's relationships by ID, with targets resolved to archive paths.
    static func relationships(for path: String, in archive: ZipArchive) -> [String: Relationship] {
        let directory = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let relsPath = directory.isEmpty ? "_rels/\(file).rels" : "\(directory)/_rels/\(file).rels"
        guard let xml = try? archive.data(for: relsPath) else { return [:] }
        var result: [String: Relationship] = [:]
        for (id, type, target, external) in RelationshipParser.parse(xml) where !external {
            result[id] = Relationship(type: type, target: resolve(target, relativeTo: directory))
        }
        return result
    }

    static func resolve(_ target: String, relativeTo directory: String) -> String {
        var components = target.hasPrefix("/")
            ? []
            : directory.split(separator: "/").map(String.init)
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }
}

// MARK: - XML parsers

/// Text from one slide (or notes page).
nonisolated private final class SlideParser: NSObject, XMLParserDelegate {
    struct Slide {
        var title: String?
        var lines: [String]
    }

    /// Placeholders that hold slide furniture rather than content.
    private static let skippedPlaceholders: Set<String> = ["dt", "ftr", "hdr", "sldNum", "sldImg"]

    private let notesOnly: Bool
    private var title: String?
    private var lines: [String] = []

    // Current shape
    private var shapeDepth = 0
    private var placeholderType: String?
    private var hasPlaceholder = false
    private var shapeLines: [(level: Int, bullet: Bool?, text: String)] = []

    // Current paragraph and table
    private var paragraph = ""
    private var paragraphLevel = 0
    /// The paragraph's own bullet setting, when it has one.
    private var paragraphBullet: Bool?
    private var inParagraph = false
    private var inText = false
    private var tableDepth = 0
    private var row: [String] = []
    private var cell = ""
    private var inCell = false

    private init(notesOnly: Bool) {
        self.notesOnly = notesOnly
    }

    static func parse(_ data: Data, notesOnly: Bool = false) -> Slide {
        let handler = SlideParser(notesOnly: notesOnly)
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.shouldProcessNamespaces = false
        parser.parse()
        return Slide(title: handler.title, lines: handler.lines)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "p:sp":
            shapeDepth += 1
            if shapeDepth == 1 {
                placeholderType = nil
                hasPlaceholder = false
                shapeLines = []
            }
        case "p:ph":
            hasPlaceholder = true
            placeholderType = attributes["type"]
        case "a:tbl":
            tableDepth += 1
        case "a:tr":
            row = []
        case "a:tc":
            inCell = true
            cell = ""
        case "a:p":
            inParagraph = true
            paragraph = ""
            paragraphLevel = 0
            paragraphBullet = nil
        case "a:pPr":
            paragraphLevel = Int(attributes["lvl"] ?? "") ?? 0
        case "a:buNone":
            paragraphBullet = false
        case "a:buChar", "a:buAutoNum", "a:buBlip":
            paragraphBullet = true
        case "a:t":
            inText = true
        case "a:br":
            if inParagraph { paragraph += " " }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { paragraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "a:t":
            inText = false
        case "a:p":
            inParagraph = false
            let text = Self.clean(paragraph)
            guard !text.isEmpty else { break }
            if inCell {
                cell += cell.isEmpty ? text : " " + text
            } else if shapeDepth > 0 {
                shapeLines.append((paragraphLevel, paragraphBullet, text))
            }
        case "a:tc":
            inCell = false
            row.append(cell)
        case "a:tr":
            let cells = row.filter { !$0.isEmpty }
            if !cells.isEmpty && !notesOnly { lines.append(cells.joined(separator: " | ")) }
        case "a:tbl":
            tableDepth -= 1
        case "p:sp":
            if shapeDepth == 1 { finishShape() }
            shapeDepth -= 1
        default:
            break
        }
    }

    private func finishShape() {
        guard !shapeLines.isEmpty else { return }
        if let type = placeholderType, Self.skippedPlaceholders.contains(type) { return }
        if notesOnly {
            // Notes pages keep only the notes body.
            guard hasPlaceholder, placeholderType == nil || placeholderType == "body" else { return }
            lines += shapeLines.map(\.text)
            return
        }
        switch placeholderType {
        case "title", "ctrTitle":
            let text = shapeLines.map(\.text).joined(separator: " ")
            if title == nil {
                title = text
            } else {
                lines.append(text)
            }
        case "subTitle":
            lines += shapeLines.map(\.text)
        default:
            // Body placeholders are bulleted unless a paragraph says otherwise; text boxes are plain.
            let bulletedByDefault = hasPlaceholder && (placeholderType == nil || placeholderType == "body" || placeholderType == "obj")
            for line in shapeLines {
                if line.bullet ?? (bulletedByDefault || line.level > 0) {
                    lines.append(String(repeating: "  ", count: line.level) + "• " + line.text)
                } else {
                    lines.append(line.text)
                }
            }
        }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{000B}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// The slide relationship IDs listed in presentation.xml, in order.
nonisolated private final class SlideListParser: NSObject, XMLParserDelegate {
    private var ids: [String] = []

    static func slideRelationshipIDs(in data: Data) -> [String] {
        let handler = SlideListParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.ids
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard name == "p:sldId" else { return }
        if let id = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") && $0.key != "id" })?.value {
            ids.append(id)
        }
    }
}

nonisolated private final class RelationshipParser: NSObject, XMLParserDelegate {
    private var items: [(String, String, String, Bool)] = []

    static func parse(_ data: Data) -> [(id: String, type: String, target: String, external: Bool)] {
        let handler = RelationshipParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.items.map { (id: $0.0, type: $0.1, target: $0.2, external: $0.3) }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard name == "Relationship" || name.hasSuffix(":Relationship"),
              let id = attributes["Id"], let target = attributes["Target"] else { return }
        items.append((id, attributes["Type"] ?? "", target, attributes["TargetMode"] == "External"))
    }
}
