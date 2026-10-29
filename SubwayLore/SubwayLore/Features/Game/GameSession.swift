import Foundation

actor GameSession {
    private static let resultSaveError = "This round’s leaderboard could not be saved on this device."
    private let coordinator: ActivityCoordinator
    private let resultsStore: GameResultsStore
    private let clock: any SessionClock
    private var lease: ActivityLease?
    private var identity: PeerIdentity
    private var snapshot = GameSnapshot()
    private var match: TimeItMatch?
    private var peers: [DiscoveredPeer] = []
    private var continuation: AsyncStream<GameSnapshot>.Continuation?
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var joinTask: Task<Void, Never>?
    private var pendingResultAcks: Set<UUID> = []
    private var finishedRounds: Set<UUID> = []
    private var hostConnected = false

    init(identity: PeerIdentity, coordinator: ActivityCoordinator,
         clock: any SessionClock = ContinuousSessionClock(), resultsStore: GameResultsStore = GameResultsStore()) {
        self.identity = identity
        self.coordinator = coordinator
        self.clock = clock
        self.resultsStore = resultsStore
    }

    func currentSnapshot() -> GameSnapshot { snapshot }

    private func activeLease() throws -> ActivityLease {
        guard let lease else { throw ActivityCoordinatorError.superseded }
        return lease
    }

    func snapshots() -> AsyncStream<GameSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation?.finish()
            self.continuation = continuation
            continuation.yield(snapshot)
        }
    }

    private var isHost: Bool { snapshot.lobby?.hostPeerID == identity.id }

    func create() async throws -> GameLobby {
        await leave()
        let lobby = GameLobby(id: UUID(), kind: .timeIt, hostPeerID: identity.id,
                              hostDisplayName: identity.displayName, createdAt: Date())
        match = TimeItMatch(lobby: lobby)
        snapshot = GameSnapshot(lobby: lobby, phase: .lobby)
        publish()
        try await open(lobby)
        await advertise()
        publish()
        return lobby
    }

    func join(_ game: DiscoveredGame) async throws -> GameLobby {
        guard game.lobby.kind == .timeIt, game.isJoinable, game.playerCount < GameLobby.maximumPlayers else { throw TimeItError.gameFull }
        await leave()
        snapshot = GameSnapshot(lobby: game.lobby,
            players: [GamePlayer(id: identity.id, displayName: identity.displayName, isConnected: false)], phase: .lobby)
        try await open(game.lobby)
        let expected = generation
        joinTask = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(20)) } catch { return }
            await self?.joinTimedOut(generation: expected)
        }
        publish()
        return game.lobby
    }

    private func open(_ lobby: GameLobby) async throws {
        let expected = generation
        let opened = try await coordinator.open(identity: identity, activity: .game(lobby),
            admissionPolicy: { [weak self] peerID in
                guard let self else { return "Game is no longer available" }
                return await self.reserve(peerID, generation: expected)
            },
            handler: { [weak self] event in await self?.handle(event, generation: expected) })
        guard expected == generation else {
            await opened.close()
            throw ActivityCoordinatorError.superseded
        }
        lease = opened
        await opened.updatePeers(peers)
    }

    private func reserve(_ peerID: UUID, generation expected: UUID) -> String? {
        guard expected == generation, snapshot.phase != .ended, let lobby = snapshot.lobby else {
            return "Game is no longer available"
        }
        if isHost {
            do {
                try match?.reserve(peerID)
                publish()
                return nil
            } catch TimeItError.gameFull { return "Game is full (8 players maximum)" }
            catch { return "Round already starting. Join between rounds." }
        }
        return peerID == lobby.hostPeerID ? nil : "Join through the game creator"
    }

    func updatePeers(_ peers: [DiscoveredPeer]) async {
        self.peers = peers
        guard snapshot.lobby != nil, snapshot.phase != .ended else { return }
        await lease?.updatePeers(peers)
    }

    func updateIdentity(_ identity: PeerIdentity) async {
        await leave()
        self.identity = identity
    }

    func startRound() async throws {
        guard isHost, snapshot.canStart else { throw TimeItError.notReady }
        guard var hostMatch = match else { throw TimeItError.notReady }
        let round = try hostMatch.prepare(target: Int.random(in: TimeItRules.targetRange))
        match = hostMatch
        resultTask?.cancel()
        pendingResultAcks = []
        snapshot.error = nil
        publish()
        let expected = generation
        deadline?.cancel()
        deadline = Task { [weak self, clock] in
            do { try await clock.sleep(for: .seconds(10)) } catch { return }
            await self?.preparationTimedOut(round.id, generation: expected)
        }
        await advertise()
        await broadcast(.prepare(round), generation: expected)
    }

    func markRunning(roundID: UUID) {
        guard snapshot.round?.id == roundID, snapshot.phase == .countdown else { return }
        snapshot.phase = .running
        match?.markRunning()
        if isHost {
            let expected = generation
            deadline?.cancel()
            deadline = Task { [weak self, clock] in
                // Two seconds of transport grace follow the local 20-second attempt window.
                do { try await clock.sleep(for: .seconds(22)) } catch { return }
                await self?.forfeitMissing(roundID, generation: expected)
            }
        }
        publish()
    }

    func submit(roundID: UUID, elapsedMilliseconds: Int?) async throws {
        guard let lobby = snapshot.lobby, snapshot.round?.id == roundID, snapshot.phase == .running,
              snapshot.localAttempt == nil else { return }
        if let elapsedMilliseconds, !(0...TimeItRules.maximumMilliseconds).contains(elapsedMilliseconds) {
            throw TimeItError.invalidAttempt
        }
        let attempt = TimingAttempt(gameID: lobby.id, roundID: roundID, playerID: identity.id,
                                    elapsedMilliseconds: elapsedMilliseconds)
        if !isHost {
            snapshot.localAttempt = attempt
            publish()
        }
        let expected = generation
        if isHost { try await acceptAttempt(attempt) }
        else {
            do { try await send(.attempt(attempt), to: lobby.hostPeerID) }
            catch {
                guard expected == generation else { return }
                await end("Your result could not reach the creator. The game ended.")
            }
        }
    }

    private func handle(_ event: ActivityTransportEvent, generation expected: UUID) async {
        guard expected == generation, snapshot.lobby != nil, snapshot.phase != .ended else { return }
        do {
            switch event {
            case .connected(let peer):
                guard case .game(let remote) = peer.activity, remote.id == snapshot.lobby?.id,
                      remote.hostPeerID == snapshot.lobby?.hostPeerID else { throw TimeItError.invalidRound }
                if isHost {
                    try match?.connect(peer.id, name: peer.displayName)
                    publish()
                    await broadcast(.roster(snapshot.players))
                    await advertise()
                } else {
                    guard peer.id == remote.hostPeerID else { throw TimeItError.invalidRound }
                    snapshot.lobby = remote
                    hostConnected = true
                    joinTask?.cancel()
                }
            case .disconnected(let id):
                if isHost {
                    guard match?.players.contains(where: { $0.id == id }) == true else { return }
                    match?.remove(id)
                    publish()
                    pendingResultAcks.remove(id)
                    if snapshot.phase == .preparing { await abortPreparation() }
                    else if snapshot.phase == .countdown || snapshot.phase == .running { try await finishIfComplete() }
                    await broadcast(.roster(snapshot.players))
                    await advertise()
                } else if id == snapshot.lobby?.hostPeerID, hostConnected {
                    await end("The creator disconnected. This game has ended.")
                }
            case .message(let envelope):
                if case .game(let packet) = envelope.body, packet.gameID == snapshot.lobby?.id {
                    try await receive(packet.event, from: envelope.senderID)
                }
            case .admissionRejected(let reason):
                if !isHost, !hostConnected { await end(reason) }
            case .issue(let error):
                snapshot.error = error
            case .deactivated:
                await end("Another activity was opened.")
            case .participants: break
            }
        } catch {
            guard expected == generation else { return }
            // Stale or conflicting round messages cannot change accepted game state.
            if isHost { snapshot.error = "An invalid or outdated game message was ignored." }
            else { await end("The game state could not be verified. Please join a new game.") }
        }
        guard expected == generation else { return }
        publish()
    }

    private func receive(_ event: GameEvent, from sender: UUID) async throws {
        guard let lobby = snapshot.lobby else { return }
        if isHost {
            guard match?.players.contains(where: { $0.id == sender }) == true else { return }
            switch event {
            case .prepared(let roundID):
                if match?.acknowledge(sender, roundID: roundID) == true {
                    deadline?.cancel()
                    publish()
                    await broadcast(.start(roundID))
                }
            case .attempt(let attempt):
                guard attempt.playerID == sender else { throw TimeItError.invalidAttempt }
                if snapshot.phase == .results, let outcome = snapshot.outcome,
                   outcome.round.id == attempt.roundID, outcome.attempts.contains(attempt) {
                    try await send(.result(outcome), to: sender)
                } else { try await acceptAttempt(attempt) }
            case .resultAck(let id):
                if snapshot.outcome?.round.id == id { pendingResultAcks.remove(sender) }
            case .left:
                await lease?.disconnect(sender)
            default: throw TimeItError.invalidRound
            }
            return
        }
        guard sender == lobby.hostPeerID else { throw TimeItError.invalidRound }
        switch event {
        case .roster(let players):
            let ids = players.map(\.id)
            guard Set(ids).count == ids.count, ids.contains(identity.id), ids.contains(lobby.hostPeerID),
                  ids.count <= GameLobby.maximumPlayers else { throw TimeItError.invalidRound }
            snapshot.players = players
        case .prepare(let round):
            try TimeItRules.validate(round, hostID: lobby.hostPeerID)
            guard round.gameID == lobby.id, round.players.contains(where: { $0.id == identity.id }) else {
                throw TimeItError.invalidRound
            }
            if finishedRounds.contains(round.id) { return }
            if snapshot.round?.id != round.id {
                guard snapshot.phase == .lobby || snapshot.phase == .results else { throw TimeItError.invalidRound }
                snapshot.round = round
                snapshot.phase = .preparing
                snapshot.players = round.players
                snapshot.localAttempt = nil
                snapshot.outcome = nil
                snapshot.completedPlayerIDs = []
                        snapshot.error = nil
            }
            try await send(.prepared(round.id), to: sender)
        case .start(let id):
            guard snapshot.round?.id == id else { return }
            guard !snapshot.roundStarted else { return }
            snapshot.phase = .countdown
            let expected = generation
            deadline?.cancel()
            deadline = Task { [weak self, clock] in
                do { try await clock.sleep(for: .seconds(40)) } catch { return }
                await self?.resultTimedOut(id, generation: expected)
            }
        case .progress(let id, let completed):
            guard let round = snapshot.round, round.id == id,
                  completed.isSubset(of: Set(round.players.map(\.id))) else { return }
            snapshot.completedPlayerIDs.formUnion(completed)
        case .result(let result):
            let expected = generation
            guard snapshot.round == result.round else { return }
            let verified = try TimeItRules.outcome(round: result.round, attempts: result.attempts, hostID: sender)
            guard verified == result else { throw TimeItError.invalidAttempt }
            if let local = snapshot.localAttempt,
               result.attempts.first(where: { $0.playerID == identity.id }) != local { throw TimeItError.invalidAttempt }
            snapshot.outcome = result
            snapshot.phase = .results
            snapshot.completedPlayerIDs = Set(result.round.players.map(\.id))
            finishedRounds.insert(result.round.id)
            deadline?.cancel()
            let saved = await saveResult(result)
            guard expected == generation, snapshot.round == result.round, saved else { return }
            try await send(.resultAck(result.round.id), to: sender)
        case .roundAborted(let id):
            guard snapshot.round?.id == id else { return }
            finishedRounds.insert(id)
            snapshot.phase = .lobby
            snapshot.round = nil
                snapshot.error = "A player was not ready to receive the round. Waiting for the creator to start again."
        case .ended(let reason): await end(reason)
        default: throw TimeItError.invalidRound
        }
    }

    private func acceptAttempt(_ attempt: TimingAttempt) async throws {
        let expected = generation
        guard var hostMatch = match else { throw TimeItError.notReady }
        try hostMatch.record(attempt)
        match = hostMatch
        publish()
        await broadcast(.progress(roundID: attempt.roundID, completed: snapshot.completedPlayerIDs), generation: expected)
        guard expected == generation else { return }
        try await finishIfComplete()
    }

    private func finishIfComplete() async throws {
        guard var hostMatch = match, let round = hostMatch.round, hostMatch.attempts.count == round.players.count,
              hostMatch.phase == .running || hostMatch.phase == .countdown else { return }
        let outcome = try hostMatch.finish()
        match = hostMatch
        let expected = generation
        deadline?.cancel()
        finishedRounds.insert(outcome.round.id)
        pendingResultAcks = Set(snapshot.players.filter { $0.id != identity.id && $0.isConnected }.map(\.id))
        _ = await saveResult(outcome)
        guard expected == generation, match?.outcome == outcome else { return }
        publish()
        await advertise()
        await broadcast(.result(outcome), generation: expected)
        guard expected == generation else { return }
        resultTask?.cancel()
        resultTask = Task { [weak self, clock] in
            for _ in 0..<5 {
                do { try await clock.sleep(for: .seconds(2)) } catch { return }
                await self?.retryResult(outcome, generation: expected)
            }
            await self?.resultDeliveryFinished(generation: expected)
        }
    }

    private func retryResult(_ outcome: RoundOutcome, generation expected: UUID) async {
        guard generation == expected, snapshot.outcome == outcome else { return }
        _ = await saveResult(outcome)
        guard generation == expected, snapshot.outcome == outcome else { return }
        publish()
        for id in pendingResultAcks {
            guard expected == generation else { return }
            do { try await send(.result(outcome), to: id) }
            catch {
                guard expected == generation else { return }
                snapshot.error = "Retrying result delivery to a player."
                publish()
            }
        }
    }

    private func saveResult(_ outcome: RoundOutcome) async -> Bool {
        let expected = generation
        do {
            try await resultsStore.record(outcome.completedRound())
            if expected == generation, snapshot.error == Self.resultSaveError { snapshot.error = nil }
            return true
        } catch {
            guard expected == generation else { return false }
            snapshot.error = Self.resultSaveError
            publish()
            return false
        }
    }

    private func resultDeliveryFinished(generation expected: UUID) {
        guard expected == generation, !pendingResultAcks.isEmpty else { return }
        snapshot.error = "Some players did not acknowledge the results. They can leave and join the next round."
        publish()
    }

    private func forfeitMissing(_ id: UUID, generation expected: UUID) async {
        guard expected == generation, snapshot.round?.id == id, let round = match?.round else { return }
        do {
            for player in round.players where match?.attempts[player.id] == nil {
                try match?.record(TimingAttempt(gameID: round.gameID, roundID: round.id, playerID: player.id, elapsedMilliseconds: nil))
            }
            try await finishIfComplete()
        } catch {
            guard expected == generation else { return }
            await end("The round could not be finalized. Please start a new game.")
        }
    }

    private func preparationTimedOut(_ id: UUID, generation expected: UUID) async {
        guard expected == generation, snapshot.phase == .preparing, snapshot.round?.id == id else { return }
        await abortPreparation()
    }

    private func abortPreparation() async {
        guard let id = snapshot.round?.id else { return }
        let expected = generation
        finishedRounds.insert(id)
        deadline?.cancel()
        match?.abortPreparation()
        publish()
        snapshot.error = "One player did not receive the round. Try Start again."
        await broadcast(.roundAborted(id), generation: expected)
        guard expected == generation else { return }
        await advertise()
        publish()
    }

    private func resultTimedOut(_ id: UUID, generation expected: UUID) async {
        guard expected == generation, snapshot.round?.id == id, snapshot.phase != .results else { return }
        await end("The creator did not deliver results. Please join a new game.")
    }

    private func joinTimedOut(generation expected: UUID) async {
        guard expected == generation, !hostConnected else { return }
        await end("The game could not be joined. It may be full or already playing.")
    }

    private func send(_ event: GameEvent, to id: UUID) async throws {
        guard let lobby = snapshot.lobby else { return }
        try await activeLease().send(.game(GamePacket(gameID: lobby.id, event: event)), to: id)
    }

    private func broadcast(_ event: GameEvent, generation expectedGeneration: UUID? = nil) async {
        let expected = expectedGeneration ?? generation
        guard expected == generation else { return }
        for player in snapshot.players where player.id != identity.id && player.isConnected {
            guard expected == generation else { return }
            do { try await send(event, to: player.id) }
            catch {
                guard expected == generation else { return }
                snapshot.error = "A game update could not be delivered. Waiting for the player’s connection."
                publish()
            }
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
        snapshot.phase = .ended
        snapshot.error = reason
        generation = UUID()
        let expected = generation
        cancelTasks()
        publish()
        if host { await broadcast(.ended(reason), generation: expected) }
        guard expected == generation else { return }
        let previousLease = lease
        lease = nil
        await previousLease?.close()
    }

    func leave(gameID: UUID? = nil, reason: String = "The creator left the game.") async {
        guard let lobby = snapshot.lobby else { return }
        if let gameID, gameID != lobby.id { return }
        let expected = generation
        if !isHost, snapshot.phase != .ended {
            do { try await send(.left, to: lobby.hostPeerID) }
            catch { /* Closing the scoped connection also communicates departure. */ }
        }
        guard expected == generation, snapshot.lobby?.id == lobby.id else { return }
        await end(reason)
        guard snapshot.lobby?.id == lobby.id, snapshot.phase == .ended else { return }
        generation = UUID()
        cancelTasks()
        match = nil
        snapshot = GameSnapshot()
        pendingResultAcks = []
        finishedRounds = []
        hostConnected = false
        publish()
    }

    private func publish() {
        if let match, snapshot.phase != .ended {
            snapshot.players = match.players
            snapshot.phase = match.phase
            snapshot.round = match.round
            snapshot.outcome = match.outcome
            snapshot.completedPlayerIDs = Set(match.attempts.keys)
            snapshot.localAttempt = match.attempts[identity.id]
        }
        continuation?.yield(snapshot)
    }

    private func cancelTasks() {
        deadline?.cancel()
        resultTask?.cancel()
        joinTask?.cancel()
        deadline = nil
        resultTask = nil
        joinTask = nil
    }
}
