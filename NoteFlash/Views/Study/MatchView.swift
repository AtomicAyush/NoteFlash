import SwiftData
import SwiftUI

/// Match terms to definitions against the clock. Wrong matches add a one-second penalty.
struct MatchView: View {
    let deck: Deck
    let cards: [Flashcard]

    private struct Tile: Identifiable {
        let id = UUID()
        let cardID: UUID
        let text: String
        let isTerm: Bool
        /// The answer on this tile's card, used to accept duplicate definitions.
        let back: String
    }

    private enum Phase {
        case ready
        case playing
        case finished
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var phase: Phase = .ready
    @State private var tiles: [Tile] = []
    @State private var matchedIDs: Set<UUID> = []
    @State private var selectedID: UUID?
    @State private var wrongIDs: Set<UUID> = []
    @State private var startDate = Date.now
    @State private var penalty: Double = 0
    @State private var finalTime: Double = 0
    @State private var isNewBest = false

    private let pairCount = 6
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .ready: readyView
                case .playing: gameView
                case .finished: finishedView
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Ready to play?")
                .font(.title.bold())
            Text("Match every term with its definition as fast as you can. Wrong matches add 1 second.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let best = deck.bestMatchTime {
                Label("Best time: \(formatted(best))", systemImage: "trophy.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button {
                startGame()
            } label: {
                Text("Start Game").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var gameView: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: startDate, by: 0.1)) { context in
                HStack {
                    Label(formatted(context.date.timeIntervalSince(startDate) + penalty), systemImage: "timer")
                        .font(.title3.monospacedDigit().bold())
                    Spacer()
                    if penalty > 0 {
                        Text("+\(Int(penalty))s penalty")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(tiles) { tile in
                    tileView(tile)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func tileView(_ tile: Tile) -> some View {
        let isMatched = matchedIDs.contains(tile.id)
        let isSelected = selectedID == tile.id
        let isWrong = wrongIDs.contains(tile.id)
        let borderColor: Color = isWrong ? .red : (isSelected ? .accentColor : .clear)

        return Button {
            tap(tile)
        } label: {
            Text(tile.text)
                .font(tile.isTerm ? .subheadline.weight(.semibold) : .caption)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104)
                .background(
                    isSelected ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 14)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(borderColor, lineWidth: 3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("match-tile")
        .opacity(isMatched ? 0 : 1)
        .scaleEffect(isMatched ? 0.6 : 1)
        .offset(x: isWrong ? 4 : 0)
        .animation(isWrong ? .linear(duration: 0.06).repeatCount(5) : .snappy, value: isWrong)
        .animation(.snappy, value: isMatched)
        .allowsHitTesting(!isMatched)
    }

    private var finishedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: isNewBest ? "trophy.fill" : "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(isNewBest ? Color.orange : Color.green)
            Text(formatted(finalTime))
                .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
            if isNewBest {
                Text("New best time!")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
            } else if let best = deck.bestMatchTime {
                Text("Best: \(formatted(best))")
                    .foregroundStyle(.secondary)
            }
            if penalty > 0 {
                Text("Includes \(Int(penalty))s of penalties")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                startGame()
            } label: {
                Text("Play Again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: Game logic

    private func startGame() {
        let chosen = cards.shuffled().prefix(pairCount)
        tiles = chosen.flatMap { card in
            [
                Tile(cardID: card.id, text: card.front, isTerm: true, back: card.back),
                Tile(cardID: card.id, text: card.back, isTerm: false, back: card.back),
            ]
        }
        .shuffled()
        matchedIDs = []
        selectedID = nil
        wrongIDs = []
        penalty = 0
        isNewBest = false
        startDate = .now
        phase = .playing
    }

    private func tap(_ tile: Tile) {
        guard wrongIDs.isEmpty, !matchedIDs.contains(tile.id) else { return }
        guard let firstID = selectedID, let first = tiles.first(where: { $0.id == firstID }) else {
            selectedID = tile.id
            return
        }
        if first.id == tile.id {
            selectedID = nil
            return
        }

        // A term also matches another card's identical definition.
        let term = first.isTerm ? first : tile
        let definition = first.isTerm ? tile : first
        let isMatch = first.isTerm != tile.isTerm
            && (term.cardID == definition.cardID || term.back == definition.text)
        selectedID = nil

        if isMatch {
            matchedIDs.formUnion([first.id, tile.id])
            if matchedIDs.count == tiles.count { finish() }
        } else {
            penalty += 1
            wrongIDs = [first.id, tile.id]
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                wrongIDs = []
            }
        }
    }

    private func finish() {
        finalTime = Date.now.timeIntervalSince(startDate) + penalty
        // Only full-size games count toward the best time.
        if tiles.count == pairCount * 2 {
            if deck.bestMatchTime.map({ finalTime < $0 }) ?? true {
                deck.bestMatchTime = finalTime
                isNewBest = true
            }
            try? modelContext.save()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation { phase = .finished }
        }
    }

    private func formatted(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}
