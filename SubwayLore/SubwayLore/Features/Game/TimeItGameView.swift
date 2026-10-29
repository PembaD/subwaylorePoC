import SwiftUI

struct TimeItGameView: View {
    @ObservedObject var model: AppViewModel
    let lobby: GameLobby
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var countdown: Int?
    @State private var startInstant: ContinuousClock.Instant?
    @State private var hasTapped = false
    @State private var stoppedAttempt: TimingAttempt?
    @State private var revealedRoundID: UUID?
    @State private var isStarting = false
    @State private var actionError: String?

    private var state: GameSnapshot { model.gameSnapshot }
    private var isHost: Bool { lobby.hostPeerID == model.identity.id }
    private var timerKey: UUID? { state.roundStarted && state.phase != .ended ? state.round?.id : nil }
    private var isShowingStoppedTime: Bool {
        guard let stoppedAttempt else { return false }
        return state.round?.id == stoppedAttempt.roundID && revealedRoundID != stoppedAttempt.roundID && state.phase != .ended
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if state.phase == .preparing || state.phase == .countdown || state.phase == .running || isShowingStoppedTime {
                    HStack {
                        Label("\(state.round?.players.count ?? state.players.count) players", systemImage: "person.3.fill")
                        Spacer()
                        Text("\(state.completedPlayerIDs.count) finished")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(16)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
                } else { players }
                if state.phase == .results, !isShowingStoppedTime, let outcome = state.outcome {
                    results(outcome)
                    StandingsCard(rounds: model.completedRounds, kind: lobby.kind, gameID: lobby.id,
                                  localPlayerID: model.identity.id, title: "Match standings")
                } else if state.phase == .ended {
                    statusCard(title: "Game ended", detail: state.error ?? "Return to find another game.")
                    Button("Back to nearby riders") { dismiss() }.buttonStyle(.borderedProminent).tint(.loreOrange)
                } else if let round = state.round {
                    timerCard(round)
                } else {
                    statusCard(title: isHost ? "Your lobby is open" :
                                (state.players.contains(where: { $0.id == model.identity.id && $0.isConnected }) ? "You’re in!" : "Joining the game…"),
                               detail: isHost ? "Nearby riders can join from Live Games. Start when everyone is here."
                                              : "Waiting for the creator to start.")
                }

                if isHost, !isShowingStoppedTime, state.phase == .lobby || state.phase == .results {
                    Button {
                        guard !isStarting else { return }
                        isStarting = true
                        actionError = nil
                        Task {
                            do { try await model.startGameRound() }
                            catch { actionError = "Wait until at least two players are fully connected." }
                            isStarting = false
                        }
                    } label: {
                        Text(state.phase == .results ? "Start next round" : "Start game")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.loreInk).frame(maxWidth: .infinity, minHeight: 58)
                            .background(Color.loreOrange.opacity(state.canStart ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain).disabled(!state.canStart || isStarting)
                    .accessibilityIdentifier("startGame")
                    if state.players.count < 2 {
                        Text("At least 2 players are needed.").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                } else if !isHost, !isShowingStoppedTime, state.phase == .lobby || state.phase == .results {
                    Text("Waiting for the creator to start.").font(.subheadline).foregroundStyle(.white.opacity(0.5))
                }

                if let error = actionError ?? state.error, state.phase != .ended {
                    Text(error).font(.caption).foregroundStyle(Color.loreOrange).multilineTextAlignment(.center)
                }
            }.padding(20)
        }
        .background(Color.loreInk.ignoresSafeArea())
        .navigationTitle("Time |t!")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Leave") { model.leaveGame(lobby.id); dismiss() }
            }
        }
        .tint(.loreOrange)
        .task(id: timerKey) {
            guard let roundID = timerKey else { return }
            startInstant = nil
            hasTapped = false
            stoppedAttempt = nil
            revealedRoundID = nil
            do {
                for value in stride(from: 3, through: 1, by: -1) {
                    countdown = value
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                // Start is captured locally; packet latency is never included in elapsed time.
                startInstant = ContinuousClock.now
                countdown = nil
                await model.markGameRunning(roundID)
                try await Task.sleep(for: .seconds(20))
                if !hasTapped, state.round?.id == roundID, state.phase == .running {
                    hasTapped = true
                    try await model.submitGameAttempt(roundID, milliseconds: nil)
                }
            } catch {
                if timerKey == roundID { countdown = nil }
            }
        }
        .task(id: stoppedAttempt?.roundID) {
            guard let roundID = stoppedAttempt?.roundID else { return }
            do {
                try await Task.sleep(for: .milliseconds(1500))
                revealedRoundID = roundID
            } catch { /* Leaving or starting another round cancels the confirmation. */ }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.leaveGame(lobby.id); dismiss() }
        }
        .onDisappear { model.leaveGame(lobby.id) }
    }

    private var players: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("PLAYERS", systemImage: "person.3.fill").foregroundStyle(Color.loreOrange)
                Spacer()
                Text("\(state.players.count) / 8").foregroundStyle(.white.opacity(0.5))
            }.font(.system(size: 11, weight: .bold, design: .rounded))
            ForEach(state.players) { player in
                HStack(spacing: 10) {
                    Circle().fill(player.isConnected ? Color.loreGreen : Color.white.opacity(0.2)).frame(width: 7, height: 7)
                    Text(player.id == model.identity.id ? "\(player.displayName) (You)" : player.displayName)
                        .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    Spacer()
                    if player.id == lobby.hostPeerID {
                        Text("CREATOR").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(Color.loreOrange)
                    } else if !player.isConnected {
                        Text("Connecting…").font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }.padding(18).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private func statusCard(title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "stopwatch.fill").font(.system(size: 44)).foregroundStyle(Color.loreOrange)
            Text(title).font(.system(size: 24, weight: .black, design: .rounded)).foregroundStyle(.white)
            Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 35).padding(.horizontal, 20)
    }

    private func timerCard(_ round: TimeItRound) -> some View {
        VStack(spacing: 24) {
            Text("YOUR TARGET").font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(.white.opacity(0.5))
            Text("\(round.targetSeconds) seconds")
                .font(.system(size: 42, weight: .black, design: .rounded)).foregroundStyle(Color.loreOrange)

            if state.phase == .preparing {
                ProgressView().tint(.loreOrange)
                Text("Starting…").foregroundStyle(.white.opacity(0.6))
            } else if let countdown, state.localAttempt == nil {
                Text("\(countdown)").font(.system(size: 80, weight: .black, design: .rounded)).foregroundStyle(.white)
                    .accessibilityLabel("Starting in \(countdown)")
            } else if hasTapped || state.localAttempt != nil {
                let attempt = stoppedAttempt?.roundID == round.id ? stoppedAttempt : state.localAttempt
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(Color.loreGreen)
                Text(attempt?.elapsedMilliseconds == nil ? "Time’s up" : "Locked in")
                    .font(.title2.bold()).foregroundStyle(.white)
                if let elapsed = attempt?.elapsedMilliseconds {
                    Text(String(format: "%.3f s", Double(elapsed) / 1000))
                        .font(.system(size: 48, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                        .accessibilityIdentifier("stoppedTime")
                }
                let remaining = max(0, round.players.count - state.completedPlayerIDs.count)
                Text(remaining > 0 ? "\(remaining) players still timing" : "Results coming up…")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.5))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    Text(String(format: "%.2f", elapsedSeconds))
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .monospacedDigit().foregroundStyle(.white)
                        .accessibilityIdentifier("runningTimer")
                }
                Text("Stop exactly at \(round.targetSeconds) seconds.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.6))
                Button(action: stop) {
                    Text("STOP").font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(Color.loreInk).frame(maxWidth: .infinity, minHeight: 110)
                        .background(Color.loreOrange, in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain).disabled(startInstant == nil || state.phase != .running)
                .accessibilityIdentifier("stopTimer")
            }
        }.frame(maxWidth: .infinity).padding(24)
            .background(Color.loreOrange.opacity(0.07), in: RoundedRectangle(cornerRadius: 26))
    }

    private var elapsedSeconds: Double {
        guard let startInstant else { return 0 }
        let elapsed = startInstant.duration(to: ContinuousClock.now).components
        return max(0, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }

    private func results(_ outcome: RoundOutcome) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(resultTitle(outcome)).font(.system(size: 27, weight: .black, design: .rounded)).foregroundStyle(Color.loreOrange)
            Text("Target: \(outcome.round.targetSeconds) seconds").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            ForEach(outcome.attempts, id: \.playerID) { attempt in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.round.players.first(where: { $0.id == attempt.playerID })?.displayName ?? "Rider")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        if let elapsed = attempt.elapsedMilliseconds {
                            Text(String(format: "%.3f s · %.3f s off", Double(elapsed) / 1000,
                                        Double(abs(elapsed - outcome.round.targetSeconds * 1000)) / 1000))
                                .font(.caption).foregroundStyle(.white.opacity(0.5))
                        } else {
                            Text("Did not finish").font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    Spacer()
                    if outcome.winnerIDs.contains(attempt.playerID) {
                        Image(systemName: "trophy.fill").foregroundStyle(Color.loreOrange)
                    }
                }.foregroundStyle(.white).padding(.vertical, 8)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private func resultTitle(_ outcome: RoundOutcome) -> String {
        if outcome.winnerIDs.isEmpty { return "No winner this round" }
        if outcome.winnerIDs.contains(model.identity.id) { return outcome.winnerIDs.count > 1 ? "You tied for first!" : "You win!" }
        if outcome.winnerIDs.count > 1 { return "Joint winners!" }
        let name = outcome.round.players.first { outcome.winnerIDs.contains($0.id) }?.displayName ?? "A rider"
        return "\(name) wins!"
    }

    private func stop() {
        guard !hasTapped, let startInstant, let roundID = state.round?.id, state.phase == .running else { return }
        let elapsed = startInstant.duration(to: ContinuousClock.now).components
        let milliseconds = Int((Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15).rounded())
        let submittedMilliseconds = milliseconds <= TimeItRules.maximumMilliseconds ? milliseconds : nil
        stoppedAttempt = TimingAttempt(gameID: lobby.id, roundID: roundID, playerID: model.identity.id,
                                       elapsedMilliseconds: submittedMilliseconds)
        hasTapped = true
        Task {
            do {
                try await model.submitGameAttempt(roundID, milliseconds: submittedMilliseconds)
            } catch { actionError = "Your attempt could not be submitted." }
        }
    }
}
