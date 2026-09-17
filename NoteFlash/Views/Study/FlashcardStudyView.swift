import SwiftData
import SwiftUI

/// Flip cards and sort them into "Know" and "Still learning", Quizlet-style.
struct FlashcardStudyView: View {
    let title: String
    let cards: [Flashcard]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var queue: [Flashcard] = []
    @State private var index = 0
    @State private var isFlipped = false
    @State private var knownIDs: Set<UUID> = []
    @State private var learningIDs: Set<UUID> = []
    @State private var history: [(cardID: UUID, known: Bool)] = []
    @State private var dragOffset: CGSize = .zero
    @State private var isAdvancing = false
    @State private var answerFirst = false
    @State private var shuffle = false

    private let swipeThreshold: CGFloat = 110
    private var isFinished: Bool { !queue.isEmpty && index >= queue.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if isFinished {
                    summary
                } else if index < queue.count {
                    progressHeader
                    cardView(for: queue[index])
                    controls
                }
            }
            .padding()
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Options", systemImage: "slider.horizontal.3") {
                        Toggle("Shuffle", systemImage: "shuffle", isOn: $shuffle)
                        Toggle("Show answer first", systemImage: "arrow.left.arrow.right", isOn: $answerFirst)
                        Button("Restart", systemImage: "arrow.counterclockwise") { start(with: cards) }
                    }
                }
            }
            .onChange(of: shuffle) { start(with: cards) }
        }
        .onAppear {
            if queue.isEmpty { start(with: cards) }
        }
        .onDisappear {
            try? modelContext.save()
        }
    }

    // MARK: Pieces

    private var progressHeader: some View {
        VStack(spacing: 10) {
            HStack {
                counter(learningIDs.count, color: .orange)
                Spacer()
                Text("\(index + 1) / \(queue.count)")
                    .font(.headline.monospacedDigit())
                Spacer()
                counter(knownIDs.count, color: .green)
            }
            ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
        }
    }

    private func counter(_ value: Int, color: Color) -> some View {
        Text(value, format: .number)
            .font(.subheadline.bold().monospacedDigit())
            .foregroundStyle(color)
            .frame(minWidth: 44)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: .capsule)
    }

    private func cardView(for card: Flashcard) -> some View {
        let termLabel = "Question"
        let definitionLabel = "Answer"
        let frontText = answerFirst ? card.back : card.front
        let backText = answerFirst ? card.front : card.back
        let swipeProgress = min(abs(dragOffset.width) / swipeThreshold, 1)

        return ZStack {
            CardFace(label: answerFirst ? definitionLabel : termLabel, text: frontText)
                .opacity(isFlipped ? 0 : 1)
            CardFace(label: answerFirst ? termLabel : definitionLabel, text: backText)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
        }
        .animation(.linear(duration: 0.01).delay(0.16), value: isFlipped)
        .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFlipped ? backText : frontText)
        .accessibilityHint("Double-tap to flip the card")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("flashcard")
        .accessibilityAction {
            withAnimation(.spring(duration: 0.4)) { isFlipped.toggle() }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                card.isStarred.toggle()
            } label: {
                Image(systemName: card.isStarred ? "star.fill" : "star")
                    .font(.title3)
                    .foregroundStyle(card.isStarred ? Color.yellow : Color.secondary)
                    .padding(18)
            }
            .accessibilityLabel(card.isStarred ? "Unstar" : "Star")
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28)
                .stroke(dragOffset.width > 0 ? Color.green : Color.orange, lineWidth: 4)
                .opacity(swipeProgress)
        }
        .overlay(alignment: .top) {
            if dragOffset.width != 0 {
                Text(dragOffset.width > 0 ? "Know" : "Still learning")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(dragOffset.width > 0 ? Color.green : Color.orange, in: .capsule)
                    .opacity(swipeProgress)
                    .padding(.top, 16)
            }
        }
        .offset(x: dragOffset.width, y: dragOffset.height * 0.15)
        .rotationEffect(.degrees(Double(dragOffset.width / 25)))
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.spring(duration: 0.4)) { isFlipped.toggle() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard !isAdvancing else { return }
                    dragOffset = value.translation
                }
                .onEnded { value in
                    if value.translation.width > swipeThreshold {
                        answer(known: true)
                    } else if value.translation.width < -swipeThreshold {
                        answer(known: false)
                    } else {
                        withAnimation(.spring) { dragOffset = .zero }
                    }
                }
        )
        .id(card.id)
    }

    private var controls: some View {
        HStack(spacing: 32) {
            roundButton("xmark", color: .orange, label: "Still learning") { answer(known: false) }
            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3)
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(history.isEmpty)
            .accessibilityLabel("Undo")
            roundButton("checkmark", color: .green, label: "Know") { answer(known: true) }
        }
        .padding(.bottom, 8)
    }

    private func roundButton(_ symbol: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title.bold())
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(color)
        .accessibilityLabel(label)
    }

    private var summary: some View {
        let fraction = queue.isEmpty ? 0 : Double(knownIDs.count) / Double(queue.count)
        return VStack(spacing: 22) {
            Spacer()
            ProgressRing(progress: fraction, lineWidth: 14)
                .frame(width: 160, height: 160)
                .overlay {
                    VStack(spacing: 0) {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.largeTitle.bold())
                        Text("known")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            Text(learningIDs.isEmpty ? "You know every card!" : "Nice work! Keep going.")
                .font(.title2.bold())
            HStack(spacing: 12) {
                StatPill(title: "Still learning", value: learningIDs.count, color: .orange)
                StatPill(title: "Know", value: knownIDs.count, color: .green)
            }
            Spacer()
            if !learningIDs.isEmpty {
                Button {
                    start(with: queue.filter { learningIDs.contains($0.id) })
                } label: {
                    Text("Keep Reviewing ^[\(learningIDs.count) Card](inflect: true)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            Button {
                start(with: cards)
            } label: {
                Text("Restart All Cards")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button("Done") { dismiss() }
                .padding(.top, 4)
        }
    }

    // MARK: Actions

    private func start(with newCards: [Flashcard]) {
        withTransaction(Transaction(animation: nil)) {
            queue = shuffle ? newCards.shuffled() : newCards
            index = 0
            knownIDs = []
            learningIDs = []
            history = []
            isFlipped = false
            dragOffset = .zero
        }
    }

    private func answer(known: Bool) {
        guard !isAdvancing, index < queue.count else { return }
        isAdvancing = true
        let card = queue[index]
        card.recordAnswer(correct: known)
        if known {
            knownIDs.insert(card.id)
            learningIDs.remove(card.id)
        } else {
            learningIDs.insert(card.id)
            knownIDs.remove(card.id)
        }
        history.append((card.id, known))

        withAnimation(.easeIn(duration: 0.2)) {
            dragOffset = CGSize(width: known ? 700 : -700, height: dragOffset.height)
        } completion: {
            withTransaction(Transaction(animation: nil)) {
                isFlipped = false
                dragOffset = .zero
                index += 1
            }
            isAdvancing = false
        }
    }

    private func undo() {
        guard let last = history.popLast(), index > 0 else { return }
        withTransaction(Transaction(animation: nil)) {
            index -= 1
            isFlipped = false
            dragOffset = .zero
        }
        knownIDs.remove(last.cardID)
        learningIDs.remove(last.cardID)
        if let card = queue.first(where: { $0.id == last.cardID }) {
            card.timesStudied = max(0, card.timesStudied - 1)
            if last.known { card.timesCorrect = max(0, card.timesCorrect - 1) }
        }
    }
}

private struct CardFace: View {
    let label: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(text)
                .font(.title2.weight(.medium))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.4)
            Spacer(minLength: 0)
            Text("Tap to flip")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        )
    }
}
