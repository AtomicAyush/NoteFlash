import SwiftData
import SwiftUI

/// Quizlet-style Learn: multiple choice first, then recall without options, in short rounds.
/// Progress is saved on each card, so a session can be resumed later.
struct LearnView: View {
    let title: String
    let cards: [Flashcard]

    private enum Kind {
        case multipleChoice([String])
        case written
        case selfGraded
    }

    private struct Question {
        let card: Flashcard
        let kind: Kind
    }

    private enum Feedback: Equatable {
        case none
        case correct
        case incorrect
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var roundQueue: [Flashcard] = []
    @State private var question: Question?
    @State private var questionNumber = 0
    @State private var feedback: Feedback = .none
    @State private var selectedOption: String?
    @State private var typedAnswer = ""
    @State private var isRevealed = false
    @State private var roundCorrect = 0
    @State private var roundAnswered = 0
    @State private var isShowingRoundSummary = false
    @State private var didStart = false
    @FocusState private var isAnswerFocused: Bool

    private let roundSize = 7

    private var masteredCount: Int { cards.filter { $0.masteryLevel >= Flashcard.masteredLevel }.count }
    private var familiarCount: Int { cards.filter { $0.masteryLevel == 1 }.count }
    private var isComplete: Bool { masteredCount == cards.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                progressHeader
                if isShowingRoundSummary {
                    roundSummary
                } else if let question {
                    questionView(question)
                } else if isComplete, didStart {
                    completeView
                } else {
                    Spacer()
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
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            startRound()
        }
        .onDisappear {
            try? modelContext.save()
        }
    }

    // MARK: Header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let total = CGFloat(max(cards.count, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: geometry.size.width * CGFloat(masteredCount + familiarCount) / total)
                    Capsule().fill(Color.green)
                        .frame(width: geometry.size.width * CGFloat(masteredCount) / total)
                }
            }
            .frame(height: 10)
            .animation(.snappy, value: masteredCount + familiarCount)

            HStack {
                Label("\(familiarCount) familiar", systemImage: "circle.lefthalf.filled")
                Spacer()
                Label("\(masteredCount) of \(cards.count) mastered", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Question

    @ViewBuilder
    private func questionView(_ question: Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(prompt(for: question.kind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(question.card.front)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))

                switch question.kind {
                case .multipleChoice(let options):
                    multipleChoice(options, card: question.card)
                case .written:
                    written(card: question.card)
                case .selfGraded:
                    selfGraded(card: question.card)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .id(questionNumber)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

        if feedback == .incorrect {
            HStack {
                if case .written = question.kind {
                    Button("I was right") { overrideAsCorrect(question.card) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                Button {
                    advance()
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func prompt(for kind: Kind) -> String {
        switch kind {
        case .multipleChoice: "Choose the matching answer"
        case .written: "Type the answer"
        case .selfGraded: "Say or think the answer, then reveal it"
        }
    }

    private func multipleChoice(_ options: [String], card: Flashcard) -> some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.self) { option in
                Button {
                    choose(option, for: card)
                } label: {
                    Text(option)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(optionBackground(option, card: card), in: .rect(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(optionBorder(option, card: card), lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .disabled(feedback != .none)
                .accessibilityIdentifier("learn-option")
            }
        }
    }

    private func optionBorder(_ option: String, card: Flashcard) -> Color {
        guard feedback != .none else { return Color.secondary.opacity(0.25) }
        if option == card.back { return .green }
        if option == selectedOption { return .red }
        return Color.secondary.opacity(0.15)
    }

    private func optionBackground(_ option: String, card: Flashcard) -> Color {
        guard feedback != .none else { return Color(uiColor: .secondarySystemGroupedBackground) }
        if option == card.back { return .green.opacity(0.15) }
        if option == selectedOption { return .red.opacity(0.12) }
        return Color(uiColor: .secondarySystemGroupedBackground)
    }

    @ViewBuilder
    private func written(card: Flashcard) -> some View {
        TextField("Your answer", text: $typedAnswer, axis: .vertical)
            .lineLimit(1...4)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .focused($isAnswerFocused)
            .submitLabel(.done)
            .onSubmit { submitWritten(for: card) }
            .disabled(feedback != .none)
            .onAppear { isAnswerFocused = true }

        switch feedback {
        case .none:
            HStack {
                Button("Don't know") { submitWritten(for: card, giveUp: true) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Check") { submitWritten(for: card) }
                    .buttonStyle(.borderedProminent)
                    .disabled(typedAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        case .correct:
            resultBanner(correct: true, answer: card.back)
        case .incorrect:
            resultBanner(correct: false, answer: card.back)
        }
    }

    @ViewBuilder
    private func selfGraded(card: Flashcard) -> some View {
        if isRevealed {
            Text(card.back)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 16))
            if feedback == .none {
                HStack {
                    Button {
                        grade(card, correct: false)
                    } label: {
                        Text("Not yet").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    Button {
                        grade(card, correct: true)
                    } label: {
                        Text("I got it").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .controlSize(.large)
            }
        } else {
            Button {
                withAnimation { isRevealed = true }
            } label: {
                Text("Reveal Answer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func resultBanner(correct: Bool, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(correct ? "Correct!" : "Not quite", systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.headline)
                .foregroundStyle(correct ? .green : .red)
            if !correct {
                Text("Correct answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(answer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background((correct ? Color.green : Color.red).opacity(0.1), in: .rect(cornerRadius: 16))
    }

    // MARK: Summaries

    private var roundSummary: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "flag.checkered")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Round complete")
                .font(.title.bold())
            Text("\(roundCorrect) of \(roundAnswered) answered correctly")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                StatPill(title: "Familiar", value: familiarCount, color: .accentColor)
                StatPill(title: "Mastered", value: masteredCount, color: .green)
            }
            Spacer()
            Button {
                isShowingRoundSummary = false
                startRound()
            } label: {
                Text(isComplete ? "Finish" : "Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var completeView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("You've mastered all ^[\(cards.count) card](inflect: true)!")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                cards.forEach { $0.masteryLevel = 0 }
                startRound()
            } label: {
                Text("Study Again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Button {
                dismiss()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Flow

    private func startRound() {
        roundCorrect = 0
        roundAnswered = 0
        let pending = cards
            .filter { $0.masteryLevel < Flashcard.masteredLevel }
            .shuffled()
            .sorted { $0.masteryLevel < $1.masteryLevel }
        roundQueue = Array(pending.prefix(roundSize))
        nextQuestion()
    }

    private func nextQuestion() {
        feedback = .none
        selectedOption = nil
        typedAnswer = ""
        isRevealed = false

        guard !roundQueue.isEmpty else {
            question = nil
            if roundAnswered > 0 { isShowingRoundSummary = true }
            return
        }
        let card = roundQueue.removeFirst()
        withAnimation(.snappy) {
            questionNumber += 1
            question = Question(card: card, kind: kind(for: card))
        }
    }

    private func kind(for card: Flashcard) -> Kind {
        let distractors = Array(
            Set(cards.map(\.back).filter { $0 != card.back })
        ).shuffled().prefix(3)
        if card.masteryLevel == 0, !distractors.isEmpty {
            return .multipleChoice((distractors + [card.back]).shuffled())
        }
        return AnswerChecker.needsSelfGrading(card.back) ? .selfGraded : .written
    }

    private func choose(_ option: String, for card: Flashcard) {
        guard feedback == .none else { return }
        selectedOption = option
        let correct = option == card.back
        if correct { card.masteryLevel = max(card.masteryLevel, 1) }
        record(card, correct: correct)
    }

    private func submitWritten(for card: Flashcard, giveUp: Bool = false) {
        guard feedback == .none else { return }
        let correct = !giveUp && AnswerChecker.isCorrect(typedAnswer, expected: card.back)
        if correct { card.masteryLevel = Flashcard.masteredLevel }
        record(card, correct: correct)
    }

    private func grade(_ card: Flashcard, correct: Bool) {
        if correct { card.masteryLevel = Flashcard.masteredLevel }
        record(card, correct: correct)
    }

    private func record(_ card: Flashcard, correct: Bool) {
        card.recordAnswer(correct: correct)
        roundAnswered += 1
        withAnimation(.snappy) {
            feedback = correct ? .correct : .incorrect
        }
        if correct {
            roundCorrect += 1
            let current = questionNumber
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                if questionNumber == current, feedback == .correct { advance() }
            }
        } else {
            // Missed cards come back later in the round, starting again from multiple choice.
            card.masteryLevel = 0
            roundQueue.append(card)
        }
    }

    private func overrideAsCorrect(_ card: Flashcard) {
        roundQueue.removeAll { $0.id == card.id }
        card.masteryLevel = Flashcard.masteredLevel
        card.timesCorrect += 1
        roundCorrect += 1
        advance()
    }

    private func advance() {
        nextQuestion()
    }
}
