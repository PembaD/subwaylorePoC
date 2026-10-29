import SwiftUI

struct TriviaGameView: View {
    @ObservedObject var model: AppViewModel
    let lobby: GameLobby
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var questionStarted: ContinuousClock.Instant?
    @State private var tappedAnswer: TriviaAnswer?
    @State private var isStarting = false
    @State private var actionError: String?

    private var state: TriviaSnapshot { model.triviaSnapshot }
    private var isHost: Bool { lobby.hostPeerID == model.identity.id }
    private var questionKey: String? {
        guard state.phase == .answering, let round = state.round else { return nil }
        return "\(round.id)-\(state.questionIndex)"
    }
    private var selectedAnswer: TriviaAnswer? {
        if let tappedAnswer, tappedAnswer.roundID == state.round?.id, tappedAnswer.questionIndex == state.questionIndex {
            return tappedAnswer
        }
        return state.localAnswer
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if state.phase == .lobby || state.phase == .results { players }
                if state.phase == .answering || state.phase == .review, let card = state.card, let question = card.question {
                    questionCard(card, question: question)
                } else if state.phase == .results, let result = state.outcome {
                    results(result)
                    StandingsCard(rounds: model.completedRounds, kind: .subwayTrivia, gameID: lobby.id,
                                  localPlayerID: model.identity.id, title: "Match standings")
                } else if state.phase == .ended {
                    intro(title: "Game ended", detail: state.error ?? "Find another game nearby.")
                    Button("Back to nearby riders") { dismiss() }.buttonStyle(.borderedProminent)
                } else if state.phase == .preparing {
                    ProgressView().tint(.loreOrange)
                    intro(title: "All aboard!", detail: "Getting everyone ready for the quiz…")
                } else {
                    intro(title: "NYC Subway Trivia", detail: "\(TriviaRules.questionCount) questions · 15 seconds each\nOne point per correct answer. No speed bonus.")
                    Text(isHost ? "Nearby riders can join from Live Games." : "Waiting for the creator to start.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                }
                if isHost, state.phase == .lobby || state.phase == .results {
                    Button {
                        isStarting = true
                        actionError = nil
                        Task {
                            do { try await model.startTrivia() }
                            catch { actionError = "Wait until at least two players are fully connected." }
                            isStarting = false
                        }
                    } label: {
                        Text(state.phase == .results ? "Play again" : "Start quiz")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.loreInk).frame(maxWidth: .infinity, minHeight: 56)
                            .background(Color.loreOrange.opacity(state.canStart ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).disabled(!state.canStart || isStarting)
                        .accessibilityIdentifier("startTrivia")
                    if state.players.count < 2 {
                        Text("At least 2 players are needed.").font(.caption).foregroundStyle(.white.opacity(0.5))
                    } else if state.awaitingResultAcks {
                        Text("Delivering final results…").font(.caption).foregroundStyle(.white.opacity(0.5))
                    } else if state.waitingForQuestionHistory {
                        Text("Getting everyone ready…").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                } else if !isHost, state.phase == .results {
                    Text("Waiting for the creator to play again.").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }
                if let error = actionError ?? state.error, state.phase != .ended {
                    Text(error).font(.caption).foregroundStyle(Color.loreOrange).multilineTextAlignment(.center)
                }
            }.padding(20)
        }
        .background(Color.loreInk.ignoresSafeArea())
        .navigationTitle("Subway Trivia").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden().toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Leave") { model.leaveTrivia(lobby.id); dismiss() } } }
        .tint(.loreOrange)
        .task(id: questionKey) {
            guard let key = questionKey, let round = state.round else { return }
            let index = state.questionIndex
            questionStarted = ContinuousClock.now
            tappedAnswer = nil
            do {
                try await Task.sleep(for: .seconds(TriviaRules.answerSeconds))
                guard questionKey == key, selectedAnswer == nil else { return }
                try await model.submitTriviaAnswer(nil, roundID: round.id, questionIndex: index)
            } catch {
                if !Task.isCancelled { actionError = "Your answer could not be sent." }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.leaveTrivia(lobby.id); dismiss() }
        }
        .onDisappear { model.leaveTrivia(lobby.id) }
    }

    private var players: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("PLAYERS", systemImage: "person.3.fill").foregroundStyle(Color.loreOrange)
                Spacer()
                Text("\(state.players.count) / 8").foregroundStyle(.white.opacity(0.5))
            }.font(.system(size: 11, weight: .bold, design: .rounded))
            ForEach(state.players) { player in
                HStack {
                    Circle().fill(player.isConnected ? Color.loreGreen : .white.opacity(0.2)).frame(width: 7, height: 7)
                    Text(player.id == model.identity.id ? "\(player.displayName) (You)" : player.displayName)
                    Spacer()
                    if player.id == lobby.hostPeerID { Text("CREATOR").font(.caption2).foregroundStyle(Color.loreOrange) }
                    else if !player.isConnected { Text("Connecting…").font(.caption2).foregroundStyle(.white.opacity(0.5)) }
                }.font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }
        }.padding(18).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private func intro(title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "tram.fill").font(.system(size: 42)).foregroundStyle(Color.loreOrange)
            Text(title).font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(.white)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private func questionCard(_ card: TriviaCard, question: TriviaQuestion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("QUESTION \(state.questionIndex + 1) / \(TriviaRules.questionCount)")
                Spacer()
                if state.phase == .answering {
                    TimelineView(.animation(minimumInterval: 0.1)) { _ in
                        Text("\(secondsRemaining)s").monospacedDigit().accessibilityLabel("\(secondsRemaining) seconds remaining")
                    }
                } else { Text("ANSWER") }
            }.font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color.loreOrange)
            Text(question.category.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            Text(question.prompt).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(card.optionOrder.enumerated()), id: \.offset) { index, option in
                let chosen = selectedAnswer?.option == option
                let reviewing = state.phase == .review
                let correct = option == question.correctOption
                let accent: Color = reviewing && correct ? .loreGreen : (chosen ? .loreOrange : .white.opacity(0.3))
                Button {
                    choose(option)
                } label: {
                    HStack(spacing: 12) {
                        Text(["A", "B", "C", "D"][index])
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(accent).frame(width: 30, height: 30)
                            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        Text(question.choices[option]).font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if reviewing && correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.loreGreen) }
                        else if chosen { Image(systemName: reviewing ? "xmark.circle" : "lock.fill").foregroundStyle(Color.loreOrange) }
                    }
                    .padding(12).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(accent.opacity(chosen || (reviewing && correct) ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(chosen || (reviewing && correct) ? 0.6 : 0.15)) }
                }
                .buttonStyle(.plain)
                .disabled(reviewing || selectedAnswer != nil || questionStarted == nil || secondsRemaining == 0)
                .accessibilityIdentifier("triviaOption\(["A", "B", "C", "D"][index])")
            }
            if state.phase == .review {
                Text(selectedAnswer?.option == question.correctOption ? "Correct! +1 point" :
                     (selectedAnswer?.option == nil ? "Time’s up — the correct answer is highlighted." : "The correct answer is highlighted."))
                    .font(.subheadline.bold()).foregroundStyle(Color.loreGreen)
                Text(state.questionIndex == TriviaRules.questionCount - 1 ? "Final scores coming up…" : "Next question coming up…")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            } else if selectedAnswer != nil {
                Text(selectedAnswer?.option == nil ? "Time’s up" : "Answer locked in")
                    .font(.subheadline.bold()).foregroundStyle(Color.loreOrange)
                Text("\(state.answeredPlayerIDs.count) / \(state.round?.players.count ?? 0) answered")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            if let round = state.round {
                let running = TriviaOutcome(round: round, questions: state.questionResults, departedPlayerIDs: [])
                Text("Your score: \(running.score(model.identity.id))")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private var secondsRemaining: Int {
        guard let questionStarted else { return TriviaRules.answerSeconds }
        let elapsed = questionStarted.duration(to: ContinuousClock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return max(0, TriviaRules.answerSeconds - Int(max(0, seconds)))
    }

    private func choose(_ option: Int) {
        guard state.phase == .answering, selectedAnswer == nil, secondsRemaining > 0, let round = state.round else { return }
        let index = state.questionIndex
        tappedAnswer = TriviaAnswer(roundID: round.id, questionIndex: index, playerID: model.identity.id, option: option)
        Task {
            do { try await model.submitTriviaAnswer(option, roundID: round.id, questionIndex: index) }
            catch { actionError = "Your answer could not be sent." }
        }
    }

    private func results(_ result: TriviaOutcome) -> some View {
        let completed = result.completedRound()
        let ranked = completed.players.sorted {
            let a = $0.placement ?? Int.max, b = $1.placement ?? Int.max
            return a == b ? $0.playerID.uuidString < $1.playerID.uuidString : a < b
        }
        return VStack(alignment: .leading, spacing: 18) {
            Text("End of the line!").font(.system(size: 27, weight: .black, design: .rounded)).foregroundStyle(Color.loreOrange)
            Text("\(result.round.cards.count) questions · Final scores").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            ForEach(ranked, id: \.playerID) { player in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.displayName).font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(player.placement == nil ? "Left the match" : "\(result.score(player.playerID)) / \(result.round.cards.count) correct")
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if player.placement == 1 { Image(systemName: "trophy.fill").foregroundStyle(Color.loreOrange) }
                }.foregroundStyle(.white)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }
}
