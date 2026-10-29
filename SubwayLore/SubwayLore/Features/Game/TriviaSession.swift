import Foundation

actor TriviaSession {
    private let coordinator: ActivityCoordinator
    private let resultsStore: GameResultsStore
    private let questionHistoryStore: TriviaQuestionHistoryStore
    private var questionHistories: [UUID: TriviaQuestionHistory] = [:]
    private let clock: any SessionClock
    private var identity: PeerIdentity
    private var lease: ActivityLease?
    private var snapshot = TriviaSnapshot()
    private var match: TriviaMatch?
    private var peers: [DiscoveredPeer] = []
    private var continuation: AsyncStream<TriviaSnapshot>.Continuation?
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var prepared: Set<UUID> = []
    private var reviewAcks: Set<UUID> = []
    private var resultAcks: Set<UUID> = []
    private var finishedRounds: Set<UUID> = []
    private var reviewDelayElapsed = false
    private var hostWatchID = UUID()
    private static let saveError = "This trivia match could not be saved on this device."

    init(identity: PeerIdentity, coordinator: ActivityCoordinator,
         clock: any SessionClock = ContinuousSessionClock(), resultsStore: GameResultsStore = GameResultsStore(),
         questionHistoryStore: TriviaQuestionHistoryStore = TriviaQuestionHistoryStore()) {
        self.identity = identity
        self.coordinator = coordinator
        self.clock = clock
        self.resultsStore = resultsStore
        self.questionHistoryStore = questionHistoryStore
    }

    private var isHost: Bool { snapshot.lobby?.hostPeerID == identity.id }
    func currentSnapshot() -> TriviaSnapshot { snapshot }
    func snapshots() -> AsyncStream<TriviaSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation?.finish()
            continuation = $0
            $0.yield(snapshot)
        }
    }

    func create() async throws -> GameLobby {
        await leave()
        questionHistories = [identity.id: try await questionHistoryStore.history(for: identity.id)]
        let lobby = GameLobby(id: UUID(), kind: .subwayTrivia, hostPeerID: identity.id,
                              hostDisplayName: identity.displayName, createdAt: Date())
        snapshot = TriviaSnapshot(lobby: lobby,
            players: [GamePlayer(id: identity.id, displayName: identity.displayName, isConnected: true)], phase: .lobby)
        try await open(lobby)
        await advertise()
        publish()
        return lobby
    }

    func join(_ game: DiscoveredGame) async throws -> GameLobby {
        guard game.lobby.kind == .subwayTrivia, game.isJoinable, game.playerCount < GameLobby.maximumPlayers else {
            throw TriviaError.gameFull
        }
        await leave()
        questionHistories = [identity.id: try await questionHistoryStore.history(for: identity.id)]
        snapshot = TriviaSnapshot(lobby: game.lobby,
            players: [GamePlayer(id: identity.id, displayName: identity.displayName, isConnected: false)], phase: .lobby)
        try await open(game.lobby)
        watchForHost(seconds: 20)
        publish()
        return game.lobby
    }

    private func open(_ lobby: GameLobby) async throws {
        let expected = generation
        let opened = try await coordinator.open(identity: identity, activity: .game(lobby),
            admissionPolicy: { [weak self] id in
                guard let self else { return "Game unavailable" }
                return await self.reserve(id, generation: expected)
            },
            handler: { [weak self] event in await self?.handle(event, generation: expected) })
        guard expected == generation else { await opened.close(); throw ActivityCoordinatorError.superseded }
        lease = opened
        await opened.updatePeers(peers)
    }

    private func reserve(_ id: UUID, generation expected: UUID) -> String? {
        guard generation == expected, let lobby = snapshot.lobby, snapshot.phase != .ended else { return "Game unavailable" }
        guard isHost else { return id == lobby.hostPeerID ? nil : "Join through the creator" }
        if snapshot.players.contains(where: { $0.id == id }) { return nil }
        guard snapshot.phase == .lobby || snapshot.phase == .results else { return "Quiz in progress. Join after this match." }
        guard snapshot.players.count < GameLobby.maximumPlayers else { return "Game is full (8 players maximum)" }
        snapshot.players.append(GamePlayer(id: id, displayName: "Joining rider", isConnected: false))
        publish()
        return nil
    }

    func updatePeers(_ peers: [DiscoveredPeer]) async {
        self.peers = peers
        guard snapshot.lobby != nil, snapshot.phase != .ended else { return }
        await lease?.updatePeers(peers)
    }

    func updateIdentity(_ identity: PeerIdentity) async { await leave(); self.identity = identity }

    func start() async throws {
        guard isHost, snapshot.canStart, let lobby = snapshot.lobby else { throw TriviaError.notReady }
        let round = TriviaRules.makeRound(gameID: lobby.id, players: snapshot.players, histories: questionHistories)
        try TriviaRules.validate(round, hostID: identity.id)
        match = TriviaMatch(round: round)
        snapshot.error = nil
        resultTask?.cancel()
        prepared = [identity.id]
        resultAcks = []
        publish()
        let expected = generation
        deadline?.cancel()
        deadline = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(10)) } catch { return }
            await self?.preparationExpired(round.id, generation: expected)
        }
        await advertise()
        await broadcast(.prepare(round), generation: expected)
    }

    func submit(option: Int?, roundID: UUID, questionIndex: Int) async throws {
        guard snapshot.round?.id == roundID, snapshot.questionIndex == questionIndex,
              snapshot.phase == .answering, snapshot.localAnswer == nil, let lobby = snapshot.lobby else { return }
        guard option.map({ (0...3).contains($0) }) ?? true else { throw TriviaError.invalidAnswer }
        let answer = TriviaAnswer(roundID: roundID, questionIndex: questionIndex, playerID: identity.id, option: option)
        if isHost { try await accept(answer) }
        else {
            snapshot.localAnswer = answer
            publish()
            do { try await send(.answer(answer), to: lobby.hostPeerID) }
            catch { await end("Your answer could not reach the creator.") }
        }
    }

    private func handle(_ event: ActivityTransportEvent, generation expected: UUID) async {
        guard generation == expected, snapshot.lobby != nil, snapshot.phase != .ended else { return }
        do {
            switch event {
            case .connected(let peer):
                guard case .game(let lobby) = peer.activity, lobby.kind == .subwayTrivia,
                      lobby.id == snapshot.lobby?.id, lobby.hostPeerID == snapshot.lobby?.hostPeerID else { throw TriviaError.invalidRound }
                if isHost {
                    guard let index = snapshot.players.firstIndex(where: { $0.id == peer.id }) else { throw TriviaError.invalidRound }
                    snapshot.players[index] = GamePlayer(id: peer.id, displayName: peer.displayName, isConnected: true)
                    await broadcast(.roster(snapshot.players))
                    await advertise()
                } else {
                    guard peer.id == lobby.hostPeerID else { throw TriviaError.invalidRound }
                    snapshot.lobby = lobby
                    hostWatchID = UUID()
                    deadline?.cancel()
                    try await send(.history(questionHistories[identity.id] ?? TriviaQuestionHistory()), to: peer.id)
                }
            case .disconnected(let id):
                if isHost {
                    guard snapshot.players.contains(where: { $0.id == id }) else { return }
                    snapshot.players.removeAll { $0.id == id }
                    questionHistories.removeValue(forKey: id)
                    resultAcks.remove(id)
                    if snapshot.phase == .preparing { await end("A player disconnected while the quiz was starting."); return }
                    // Finalized results are immutable; departures after the match do not change them.
                    if match?.phase == .answering || match?.phase == .review { match?.depart(id) }
                    publish()
                    if snapshot.phase == .answering { try await revealIfComplete() }
                    else if snapshot.phase == .review, reviewDelayElapsed { try await advanceIfReviewed() }
                    await broadcast(.roster(snapshot.players))
                    await advertise()
                } else if id == snapshot.lobby?.hostPeerID { await end("The creator disconnected. This game has ended.") }
            case .message(let envelope):
                guard case .game(let packet) = envelope.body, packet.gameID == snapshot.lobby?.id,
                      case .trivia(let trivia) = packet.event else { return }
                try await receive(trivia, from: envelope.senderID)
            case .admissionRejected(let reason): await end(reason)
            case .issue(let error): snapshot.error = error
            case .deactivated: await end("Another activity was opened.")
            case .participants: break
            }
        } catch {
            guard expected == generation else { return }
            if isHost { snapshot.error = "An invalid or outdated trivia message was ignored." }
            else { await end("The quiz state could not be verified. Please join a new game.") }
        }
        guard expected == generation else { return }
        publish()
    }

    private func receive(_ event: TriviaEvent, from sender: UUID) async throws {
        guard let lobby = snapshot.lobby else { return }
        if isHost {
            guard snapshot.players.contains(where: { $0.id == sender && $0.isConnected }) else { return }
            switch event {
            case .history(let history):
                try history.validate()
                questionHistories[sender] = history
            case .prepared(let id):
                guard match?.round.id == id, snapshot.phase == .preparing else { return }
                prepared.insert(sender)
                if prepared == Set(snapshot.players.map(\.id)) { try await beginQuestion() }
            case .answer(let answer):
                guard answer.playerID == sender else { throw TriviaError.invalidAnswer }
                guard answer.roundID == match?.round.id, answer.questionIndex == match?.questionIndex else { return }
                if snapshot.phase == .review, match?.answers[sender] == answer, let result = match?.results.last {
                    try await send(.reveal(result), to: sender)
                } else { try await accept(answer) }
            case .reviewAck(let id, let index):
                guard match?.round.id == id, match?.questionIndex == index, snapshot.phase == .review else { return }
                reviewAcks.insert(sender)
                if reviewDelayElapsed { try await advanceIfReviewed() }
            case .resultAck(let id):
                if snapshot.outcome?.round.id == id { resultAcks.remove(sender) }
            case .left: await lease?.disconnect(sender)
            default: throw TriviaError.invalidRound
            }
            return
        }
        guard sender == lobby.hostPeerID else { throw TriviaError.invalidRound }
        switch event {
        case .roster(let players):
            let ids = players.map(\.id)
            guard (2...GameLobby.maximumPlayers).contains(ids.count), Set(ids).count == ids.count,
                  ids.contains(identity.id), ids.contains(sender) else { throw TriviaError.invalidRound }
            snapshot.players = players
        case .prepare(let round):
            try TriviaRules.validate(round, hostID: sender)
            guard round.gameID == lobby.id, round.players.contains(where: { $0.id == identity.id }) else { throw TriviaError.invalidRound }
            if finishedRounds.contains(round.id) { return }
            if snapshot.round?.id == round.id, snapshot.round != round { throw TriviaError.conflict }
            if snapshot.round?.id != round.id {
                guard snapshot.phase == .lobby || snapshot.phase == .results else { throw TriviaError.invalidRound }
                snapshot = TriviaSnapshot(lobby: lobby, players: round.players, phase: .preparing, round: round)
                watchForHost()
            }
            try await send(.prepared(round.id), to: sender)
        case .question(let id, let index):
            guard let round = snapshot.round, round.id == id, round.cards.indices.contains(index) else { return }
            if snapshot.questionIndex == index, snapshot.phase == .answering { return }
            guard index == snapshot.questionResults.count,
                  snapshot.phase == .preparing || snapshot.phase == .review else { return }
            snapshot.questionIndex = index
            snapshot.phase = .answering
            snapshot.localAnswer = nil
            snapshot.answeredPlayerIDs = []
            watchForHost()
            let expected = generation
            guard await markQuestionSeen(round.cards[index].questionID), generation == expected,
                  snapshot.round?.id == id, snapshot.questionIndex == index else { return }
            try await send(.history(questionHistories[identity.id] ?? TriviaQuestionHistory()), to: sender)
        case .progress(let id, let index, let players):
            guard snapshot.phase == .answering, snapshot.round?.id == id, snapshot.questionIndex == index,
                  players.isSubset(of: Set(snapshot.round?.players.map(\.id) ?? [])) else { return }
            snapshot.answeredPlayerIDs.formUnion(players)
        case .reveal(let result):
            guard snapshot.phase == .answering || snapshot.phase == .review,
                  let round = snapshot.round, round.id == result.roundID, snapshot.questionIndex == result.questionIndex else { return }
            try TriviaRules.validate(result, round: round)
            if let local = snapshot.localAnswer, !result.answers.contains(local) { throw TriviaError.conflict }
            if result.questionIndex < snapshot.questionResults.count {
                guard snapshot.questionResults[result.questionIndex] == result else { throw TriviaError.conflict }
            } else {
                guard snapshot.phase == .answering, result.questionIndex == snapshot.questionResults.count else { throw TriviaError.invalidRound }
                snapshot.questionResults.append(result)
            }
            snapshot.localAnswer = result.answers.first { $0.playerID == identity.id }
            snapshot.answeredPlayerIDs = Set(round.players.map(\.id))
            snapshot.phase = .review
            watchForHost()
            try await send(.reviewAck(roundID: round.id, index: result.questionIndex), to: sender)
        case .result(let result):
            guard result.round == snapshot.round else { return }
            try TriviaRules.validate(result, hostID: sender)
            guard result.questions == snapshot.questionResults, !result.departedPlayerIDs.contains(identity.id) else { throw TriviaError.conflict }
            snapshot.outcome = result
            snapshot.phase = .results
            finishedRounds.insert(result.round.id)
            hostWatchID = UUID()
            deadline?.cancel()
            let expected = generation
            let saved = await save(result)
            guard expected == generation, snapshot.outcome == result, saved else { return }
            try await send(.resultAck(result.round.id), to: sender)
        case .ended(let reason): await end(reason)
        default: throw TriviaError.invalidRound
        }
    }

    private func beginQuestion() async throws {
        try match?.beginQuestion()
        guard let match else { throw TriviaError.notReady }
        let expected = generation, roundID = match.round.id, index = match.questionIndex
        guard await markQuestionSeen(match.round.cards[index].questionID), expected == generation,
              self.match?.round.id == roundID, self.match?.questionIndex == index else { return }
        publish()
        deadline?.cancel()
        deadline = Task { [weak self, clock] in
            // Guests get their own 15-second UI window; two seconds allow for transport.
            do { try await clock.sleep(for: .seconds(TriviaRules.answerSeconds + 2)) } catch { return }
            await self?.expireAnswers(roundID: roundID, index: index, generation: expected)
        }
        await broadcast(.question(roundID: roundID, index: index), generation: expected)
    }

    private func markQuestionSeen(_ id: Int) async -> Bool {
        let expected = generation
        do {
            let history = try await questionHistoryStore.record(id, for: identity.id)
            guard expected == generation else { return false }
            questionHistories[identity.id] = history
            return true
        } catch {
            if generation == expected { await end("Your question history could not be saved. Please try again.") }
            return false
        }
    }

    private func accept(_ answer: TriviaAnswer) async throws {
        try match?.record(answer)
        publish()
        let expected = generation
        await broadcast(.progress(roundID: answer.roundID, index: answer.questionIndex, players: snapshot.answeredPlayerIDs), generation: expected)
        guard expected == generation else { return }
        try await revealIfComplete()
    }

    private func revealIfComplete() async throws {
        guard let value = match, value.phase == .answering, value.answers.count == value.round.players.count else { return }
        let result = try match?.reveal()
        guard let result else { return }
        deadline?.cancel()
        reviewAcks = [identity.id]
        reviewDelayElapsed = false
        publish()
        let expected = generation
        await broadcast(.reveal(result), generation: expected)
        guard expected == generation, snapshot.phase == .review, snapshot.questionIndex == result.questionIndex else { return }
        deadline = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: .seconds(3))
                await self?.reviewElapsed(result, generation: expected, final: false)
                for attempt in 0..<4 {
                    try await clock.sleep(for: .seconds(2))
                    await self?.reviewElapsed(result, generation: expected, final: attempt == 3)
                }
            } catch { return }
        }
    }

    private func reviewElapsed(_ result: TriviaQuestionResult, generation expected: UUID, final: Bool) async {
        guard generation == expected, snapshot.phase == .review, snapshot.round?.id == result.roundID,
              snapshot.questionIndex == result.questionIndex else { return }
        reviewDelayElapsed = true
        do {
            if activeRoundPlayers.isSubset(of: reviewAcks) { try await advanceIfReviewed() }
            else if final { await end("A player did not receive the answer reveal. Please start a new game.") }
            else { await broadcast(.reveal(result), generation: expected) }
        } catch { await end("The quiz could not advance.") }
    }

    private var activeRoundPlayers: Set<UUID> {
        Set(match?.round.players.map(\.id) ?? []).subtracting(match?.departed ?? [])
    }

    private func advanceIfReviewed() async throws {
        guard snapshot.phase == .review, reviewDelayElapsed, activeRoundPlayers.isSubset(of: reviewAcks),
              let value = match, value.phase == .review else { return }
        deadline?.cancel()
        if value.results.count < TriviaRules.questionCount { try await beginQuestion(); return }
        guard let outcome = try match?.finish() else { return }
        let expected = generation
        resultAcks = activeRoundPlayers.subtracting([identity.id])
        _ = await save(outcome)
        guard generation == expected, match?.outcome == outcome else { return }
        publish()
        await advertise()
        await broadcast(.result(outcome), generation: expected)
        guard generation == expected, match?.outcome == outcome else { return }
        resultTask = Task { [weak self, clock] in
            for attempt in 0..<5 {
                do { try await clock.sleep(for: .seconds(2)) } catch { return }
                await self?.retryResult(outcome, generation: expected, final: attempt == 4)
            }
        }
    }

    private func retryResult(_ result: TriviaOutcome, generation expected: UUID, final: Bool) async {
        guard generation == expected, snapshot.outcome == result else { return }
        _ = await save(result)
        guard generation == expected, snapshot.outcome == result else { return }
        for id in resultAcks {
            do { try await send(.result(result), to: id) }
            catch { if expected == generation { snapshot.error = "Retrying trivia result delivery." } }
            guard generation == expected else { return }
        }
        if final, !resultAcks.isEmpty {
            snapshot.error = "Some players did not acknowledge the results."
            resultAcks = []
        }
        publish()
    }

    private func expireAnswers(roundID: UUID, index: Int, generation expected: UUID) async {
        guard generation == expected, let match, match.round.id == roundID, match.questionIndex == index, match.phase == .answering else { return }
        do {
            for player in match.round.players where match.answers[player.id] == nil {
                try self.match?.record(TriviaAnswer(roundID: roundID, questionIndex: index, playerID: player.id, option: nil))
            }
            try await revealIfComplete()
        } catch { await end("The question could not be finalized.") }
    }

    private func preparationExpired(_ id: UUID, generation expected: UUID) async {
        guard generation == expected, snapshot.round?.id == id, snapshot.phase == .preparing else { return }
        await end("A player was not ready to start the quiz. Please create another game.")
    }

    private func watchForHost(seconds: Int = 30) {
        let expected = generation
        let watchID = UUID()
        hostWatchID = watchID
        deadline?.cancel()
        deadline = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(seconds)) } catch { return }
            await self?.hostExpired(generation: expected, watchID: watchID)
        }
    }

    private func hostExpired(generation expected: UUID, watchID: UUID) async {
        guard generation == expected, hostWatchID == watchID, !isHost,
              snapshot.phase != .results, snapshot.phase != .ended else { return }
        await end("The creator did not send the next quiz update.")
    }

    private func save(_ result: TriviaOutcome) async -> Bool {
        let expected = generation
        do {
            try await resultsStore.record(result.completedRound())
            if generation == expected, snapshot.error == Self.saveError { snapshot.error = nil }
            return true
        } catch {
            if generation == expected { snapshot.error = Self.saveError; publish() }
            return false
        }
    }

    private func send(_ event: TriviaEvent, to id: UUID) async throws {
        guard let lobby = snapshot.lobby, let lease else { throw ActivityCoordinatorError.superseded }
        try await lease.send(.game(GamePacket(gameID: lobby.id, event: .trivia(event))), to: id)
    }

    private func broadcast(_ event: TriviaEvent, generation expectedGeneration: UUID? = nil) async {
        let expected = expectedGeneration ?? generation
        for player in snapshot.players where player.id != identity.id && player.isConnected {
            guard generation == expected else { return }
            do { try await send(event, to: player.id) }
            catch { if generation == expected { snapshot.error = "A quiz update could not be delivered."; publish() } }
        }
    }

    private func advertise() async {
        guard isHost, let lobby = snapshot.lobby else { return }
        let joinable = (snapshot.phase == .lobby || snapshot.phase == .results) && snapshot.players.count < GameLobby.maximumPlayers
        await lease?.advertiseGame(lobby, playerCount: snapshot.players.count, isJoinable: joinable)
    }

    private func end(_ reason: String) async {
        guard snapshot.lobby != nil, snapshot.phase != .ended else { return }
        let host = isHost
        generation = UUID()
        let expected = generation
        deadline?.cancel()
        resultTask?.cancel()
        snapshot.phase = .ended
        snapshot.error = reason
        publish()
        if host { await broadcast(.ended(reason), generation: expected) }
        guard generation == expected else { return }
        let old = lease
        lease = nil
        await old?.close()
    }

    func leave(gameID: UUID? = nil) async {
        guard let lobby = snapshot.lobby, gameID == nil || gameID == lobby.id else { return }
        let expected = generation
        if !isHost, snapshot.phase != .ended {
            do { try await send(.left, to: lobby.hostPeerID) }
            catch { /* Closing the scoped connection also communicates departure. */ }
        }
        guard generation == expected, snapshot.lobby?.id == lobby.id else { return }
        await end("The creator left the game.")
        guard snapshot.lobby?.id == lobby.id, snapshot.phase == .ended else { return }
        generation = UUID()
        match = nil
        questionHistories = [:]
        resultAcks = []
        finishedRounds = []
        snapshot = TriviaSnapshot()
        publish()
    }

    private func publish() {
        if let match, isHost, snapshot.phase != .ended {
            snapshot.phase = match.phase
            snapshot.round = match.round
            snapshot.questionIndex = match.questionIndex
            snapshot.localAnswer = match.answers[identity.id]
            snapshot.answeredPlayerIDs = Set(match.answers.keys)
            snapshot.questionResults = match.results
            snapshot.outcome = match.outcome
        }
        snapshot.awaitingResultAcks = !resultAcks.isEmpty
        if isHost { snapshot.waitingForQuestionHistory = snapshot.players.contains { questionHistories[$0.id] == nil } }
        continuation?.yield(snapshot)
    }
}
