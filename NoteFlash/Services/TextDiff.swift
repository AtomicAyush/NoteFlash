import CryptoKit
import Foundation

/// The edits between two versions of some notes, as line-level hunks.
nonisolated struct NoteChanges: Sendable {
    let hunks: [TextDiff.Hunk]

    /// Compact diff text ("- removed", "+ added", "  context"), hunks separated by "  …".
    var rendered: String {
        hunks.map(\.rendered).joined(separator: "\n  …\n")
    }
}

nonisolated enum TextDiff {
    struct Line: Sendable {
        enum Kind: Sendable { case context, removed, added }
        let kind: Kind
        let text: String

        var rendered: String {
            switch kind {
            case .context: "  \(text)"
            case .removed: "- \(text)"
            case .added: "+ \(text)"
            }
        }
    }

    struct Hunk: Sendable {
        let lines: [Line]

        var removed: [String] { lines.filter { $0.kind == .removed }.map(\.text) }
        var added: [String] { lines.filter { $0.kind == .added }.map(\.text) }
        var context: [String] { lines.filter { $0.kind == .context }.map(\.text) }
        var rendered: String { lines.map(\.rendered).joined(separator: "\n") }
        var characterCount: Int { lines.reduce(0) { $0 + $1.text.count + 3 } }

        /// Each contiguous run of removed/added lines as its own hunk, without context.
        var changeBlocks: [Hunk] {
            var blocks: [Hunk] = []
            var current: [Line] = []
            for line in lines {
                if line.kind == .context {
                    if !current.isEmpty { blocks.append(Hunk(lines: current)) }
                    current = []
                } else {
                    current.append(line)
                }
            }
            if !current.isEmpty { blocks.append(Hunk(lines: current)) }
            return blocks
        }

        /// Splits a large hunk into pieces of at most `maxCharacters`, keeping lines in order.
        func split(maxCharacters: Int) -> [Hunk] {
            guard characterCount > maxCharacters, lines.count > 1 else { return [self] }
            var pieces: [Hunk] = []
            var current: [Line] = []
            var size = 0
            for line in lines {
                let lineSize = line.text.count + 3
                if size + lineSize > maxCharacters, !current.isEmpty {
                    pieces.append(Hunk(lines: current))
                    current = []
                    size = 0
                }
                current.append(line)
                size += lineSize
            }
            if !current.isEmpty { pieces.append(Hunk(lines: current)) }
            return pieces.filter { !$0.removed.isEmpty || !$0.added.isEmpty }
        }
    }

    /// Normalized lines used for comparison: trimmed, with blank lines dropped.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Hash of the normalized text, so whitespace-only edits don't trigger a resync.
    static func fingerprint(of text: String) -> String {
        let digest = SHA256.hash(data: Data(lines(of: text).joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Line-level changes between two versions, or nil when nothing meaningful changed.
    static func changes(from old: String, to new: String, context: Int = 2) -> NoteChanges? {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        let difference = newLines.difference(from: oldLines)
        guard !difference.isEmpty else { return nil }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // Walk both sides in order; lines in neither set are shared and appear in the same order.
        var rows: [Line] = []
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                rows.append(Line(kind: .removed, text: oldLines[i]))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                rows.append(Line(kind: .added, text: newLines[j]))
                j += 1
            } else {
                rows.append(Line(kind: .context, text: i < oldLines.count ? oldLines[i] : newLines[j]))
                i += 1
                j += 1
            }
        }

        // Group changed rows (plus surrounding context) into hunks.
        let changedRows = rows.indices.filter { rows[$0].kind != .context }
        var ranges: [ClosedRange<Int>] = []
        for index in changedRows {
            let range = max(0, index - context)...min(rows.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return NoteChanges(hunks: ranges.map { Hunk(lines: Array(rows[$0])) })
    }

    /// Rendered diff text, or nil when nothing changed.
    static func summary(from old: String, to new: String, context: Int = 2) -> String? {
        changes(from: old, to: new, context: context)?.rendered
    }
}
