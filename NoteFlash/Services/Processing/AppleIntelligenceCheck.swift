import Foundation
import FoundationModels
import UIKit

/// Runs each kind of Apple Intelligence request the app makes and records the results in the
/// Processing Log. Available from the log screen, and at launch with `-appleModelSelfTest` in
/// Debug builds.
enum AppleIntelligenceCheck {
    static var isRequestedAtLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-appleModelSelfTest")
        #else
        false
        #endif
    }

    private static let notes = """
        # Photosynthesis
        Photosynthesis converts light energy into chemical energy stored in glucose.
        It takes place in the chloroplasts of plant cells.
        Chlorophyll is the green pigment that absorbs light.
        The Calvin cycle occurs in the stroma, where RuBisCO fixes carbon dioxide.
        """

    private static var isRunning = false

    static func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let log = DiagnosticsLog.shared
        let model = SystemLanguageModel.default
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        log.record("Check: \(system), availability \(model.availability), context \(model.contextSize) tokens")

        await probe("plain respond") {
            let session = LanguageModelSession(instructions: "You are concise.")
            return try await session.respond(to: "Name one organelle.").content
        }
        await probe("permissive respond") {
            let session = LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations))
            return try await session.respond(to: "Write one flashcard as Q: and A: lines.\n\(notes)").content
        }
        await probe("guided respond") {
            let session = LanguageModelSession(instructions: "You write study flashcards.")
            let result = try await session.respond(to: "Write flashcards.\n\(notes)", generating: AppleCardSet.self)
            return "\(result.content.cards.count) cards, title \(result.content.title)"
        }
        await probe("guided stream") {
            let session = LanguageModelSession(instructions: "You write study flashcards.")
            var snapshots = 0
            var last = ""
            for try await snapshot in session.streamResponse(to: "Write flashcards.\n\(notes)", generating: AppleCardSet.self) {
                snapshots += 1
                last = "\(snapshot.content.cards?.count ?? 0) cards"
            }
            return "\(snapshots) snapshots, \(last)"
        }
        await probe("guided stream, stopped early") {
            let session = LanguageModelSession(instructions: "You write study flashcards.")
            var snapshots = 0
            for try await snapshot in session.streamResponse(to: "Write flashcards.\n\(notes)", generating: AppleCardSet.self) {
                snapshots += 1
                if (snapshot.content.cards?.count ?? 0) >= 1 { break }
            }
            let next = LanguageModelSession(instructions: "You are concise.")
            let reply = try await next.respond(to: "Name one planet.").content
            return "stopped after \(snapshots) snapshots; next request: \(reply)"
        }
        await probe("two requests at once") {
            let first = LanguageModelSession(instructions: "You are concise.")
            let second = LanguageModelSession(instructions: "You are concise.")
            async let a = first.respond(to: "Name one organelle.")
            async let b = second.respond(to: "Name one planet.")
            let (x, y) = try await (a, b)
            return "\(x.content) / \(y.content)"
        }
        if #available(iOS 27.0, *) {
            let readsImages = AppleFlashcardEngine.readsPageImages
            log.record("Check: model reads images: \(readsImages ? "yes" : "no")")
            if readsImages, let sample = Self.handwritingSample() {
                await probe("read handwriting from an image") {
                    let session = LanguageModelSession(instructions: "You read photos of handwritten notes.")
                    let prompt = Prompt {
                        "Transcribe the handwritten text in this image exactly, including symbols."
                        Attachment(sample.image)
                    }
                    return try await session.respond(to: prompt).content
                }
                await probe("cards from a handwritten page image") {
                    guard let pdf = await ImageNotes.makePDF(from: [sample.png]) else { return "couldn't make a PDF" }
                    let details = PDFDetails(pages: [NotePage(index: 0, text: "", isRecognized: true)], title: "Algorithms")
                    let deck = try await AppleFlashcardEngine().generateDeck(
                        from: .pdf(data: pdf, text: "", details: details), density: .balanced, progress: nil
                    )
                    return "\(deck.cards.count) cards: " + deck.cards.prefix(3).map { "\($0.front) → \($0.back)" }.joined(separator: "; ")
                }
            }
        }
        await probe("full deck") {
            let deck = try await AppleFlashcardEngine().generateDeck(from: .text(notes), density: .balanced, progress: nil)
            return "\(deck.cards.count) cards, title \(deck.title)"
        }
        #if DEBUG
        // Debug builds: also make a deck from Documents/selftest-notes.txt, if present.
        let notesFile = URL.documentsDirectory.appending(path: "selftest-notes.txt")
        if let custom = try? String(contentsOf: notesFile, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await probe("deck from selftest-notes.txt (\(custom.count) chars)") {
                let steps = ProgressSteps()
                let deck = try await AppleFlashcardEngine().generateDeck(from: .text(custom), density: .balanced) { progress in
                    steps.report(progress)
                }
                let sample = deck.cards.prefix(3).map { "\($0.front) → \($0.back)" }.joined(separator: "; ")
                return "\(deck.cards.count) cards, title \(deck.title): \(sample)"
            }
        }
        #endif
        log.record("Check: done")
    }

    /// Handwriting-style notes with math symbols, as an image and as PNG data.
    private static func handwritingSample() -> (image: CGImage, png: Data)? {
        let lines = ["Big-O: f(n) ∈ O(g(n)) if f(n) ≤ c·g(n)", "Merge sort runs in Θ(n log n)", "Binary search needs a sorted array"]
        let size = CGSize(width: 1200, height: 560)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let image = renderer.image { context in
            UIColor(red: 1, green: 0.98, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let font = UIFont(name: "Noteworthy-Light", size: 52) ?? .systemFont(ofSize: 52)
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 50, y: 60 + CGFloat(index) * 150),
                    withAttributes: [.font: font, .foregroundColor: UIColor(white: 0.12, alpha: 1)]
                )
            }
        }
        guard let cgImage = image.cgImage, let png = image.pngData() else { return nil }
        return (cgImage, png)
    }

    private static func probe(_ name: String, _ work: () async throws -> String) async {
        let start = Date.now
        do {
            let result = try await work()
            let seconds = Date.now.timeIntervalSince(start)
            DiagnosticsLog.shared.record("Check \(name): OK in \(String(format: "%.1f", seconds))s — \(result.prefix(120))")
        } catch {
            DiagnosticsLog.shared.record("Check \(name): FAILED (\(AppleModelFailure(error))) — \(type(of: error)): \(DiagnosticsLog.describe(error))")
        }
    }
}

#if DEBUG
/// Logs generation progress in 10% steps.
private nonisolated final class ProgressSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1

    func report(_ progress: GenerationProgress) {
        let step = Int(progress.fraction * 10)
        lock.lock()
        let isNew = step > lastStep
        if isNew { lastStep = step }
        lock.unlock()
        guard isNew else { return }
        Task { @MainActor in
            DiagnosticsLog.shared.record("  progress \(step * 10)% — \(progress.detail)")
        }
    }
}
#endif
