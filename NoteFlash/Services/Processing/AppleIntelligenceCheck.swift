import Foundation
import FoundationModels

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

    static func run() async {
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
        await probe("full deck") {
            let deck = try await AppleFlashcardEngine().generateDeck(from: .text(notes), density: .balanced, progress: nil)
            return "\(deck.cards.count) cards, title \(deck.title)"
        }
        log.record("Check: done")
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
