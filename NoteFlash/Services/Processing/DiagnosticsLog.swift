import Foundation
import Observation
import OSLog

/// A short, persistent history of processing events, shown in Settings to help diagnose
/// failures. Also written to the system log (subsystem com.ayushkansal.NoteFlash).
@Observable
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()

    private static let logger = Logger(subsystem: "com.ayushkansal.NoteFlash", category: "processing")
    private static let maxEntries = 300
    private static var fileURL: URL {
        URL.documentsDirectory.appending(path: "NoteFlash-processing-log.txt")
    }

    private(set) var entries: [String] = []

    private init() {
        if let saved = try? String(contentsOf: Self.fileURL, encoding: .utf8) {
            entries = saved.split(separator: "\n").suffix(Self.maxEntries).map(String.init)
        }
    }

    func record(_ message: String) {
        Self.logger.notice("\(message, privacy: .public)")
        let time = Date.now.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
        entries.append("\(time)  \(message)")
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        try? entries.joined(separator: "\n").write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    /// Enough detail to tell errors apart, e.g. "LanguageModelSession.GenerationError.rateLimited(…) [domain 3]".
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let reflected = String(reflecting: error)
        let trimmed = reflected.count > 300 ? reflected.prefix(300) + "…" : Substring(reflected)
        return "\(trimmed) [\(nsError.domain) \(nsError.code)]"
    }
}
