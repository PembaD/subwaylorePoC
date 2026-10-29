import Foundation

enum TimeItError: Error, Equatable {
    case invalidRound, invalidAttempt, conflictingAttempt, gameFull, roundInProgress, notReady
}

enum TimeItRules {
    static let maximumMilliseconds = 20_000

    static func validate(_ round: TimeItRound, hostID: UUID) throws {
        let ids = round.players.map(\.id)
        guard (3...10).contains(round.targetSeconds), (2...GameLobby.maximumPlayers).contains(ids.count),
              Set(ids).count == ids.count, ids.contains(hostID), round.players.allSatisfy(\.isConnected) else {
            throw TimeItError.invalidRound
        }
    }

    static func outcome(round: TimeItRound, attempts: [TimingAttempt], hostID: UUID) throws -> RoundOutcome {
        try validate(round, hostID: hostID)
        guard attempts.count == round.players.count,
              Set(attempts.map(\.playerID)) == Set(round.players.map(\.id)),
              attempts.allSatisfy({ $0.gameID == round.gameID && $0.roundID == round.id
                  && ($0.elapsedMilliseconds.map { (0...maximumMilliseconds).contains($0) } ?? true) }) else {
            throw TimeItError.invalidAttempt
        }
        let target = round.targetSeconds * 1000
        let ranked = attempts.sorted {
            let a = $0.elapsedMilliseconds.map { abs($0 - target) } ?? Int.max
            let b = $1.elapsedMilliseconds.map { abs($0 - target) } ?? Int.max
            return a == b ? $0.playerID.uuidString < $1.playerID.uuidString : a < b
        }
        let best = ranked.compactMap(\.elapsedMilliseconds).map { abs($0 - target) }.min()
        let winners = Set(ranked.filter { attempt in
            guard let elapsed = attempt.elapsedMilliseconds, let best else { return false }
            return abs(elapsed - target) == best
        }.map(\.playerID))
        return RoundOutcome(round: round, attempts: ranked, winnerIDs: winners)
    }
}

// The creator's authoritative state is independent of clocks, networking, and SwiftUI.
struct TimeItMatch: Sendable {
    let lobby: GameLobby
    private(set) var players: [GamePlayer]
    private(set) var phase: GamePhase = .lobby
    private(set) var round: TimeItRound?
    private(set) var acknowledged: Set<UUID> = []
    private(set) var attempts: [UUID: TimingAttempt] = [:]
    private(set) var outcome: RoundOutcome?

    init(lobby: GameLobby) {
        self.lobby = lobby
        players = [GamePlayer(id: lobby.hostPeerID, displayName: lobby.hostDisplayName, isConnected: true)]
    }

    mutating func reserve(_ id: UUID) throws {
        if players.contains(where: { $0.id == id }) { return }
        guard phase == .lobby || phase == .results else { throw TimeItError.roundInProgress }
        guard players.count < GameLobby.maximumPlayers else { throw TimeItError.gameFull }
        players.append(GamePlayer(id: id, displayName: "Joining rider", isConnected: false))
    }

    mutating func connect(_ id: UUID, name: String) throws {
        try reserve(id)
        guard let index = players.firstIndex(where: { $0.id == id }) else { return }
        players[index].displayName = name
        players[index].isConnected = true
    }

    mutating func prepare(target: Int) throws -> TimeItRound {
        guard phase == .lobby || phase == .results else { throw TimeItError.roundInProgress }
        let value = TimeItRound(id: UUID(), gameID: lobby.id, targetSeconds: target, players: players)
        try TimeItRules.validate(value, hostID: lobby.hostPeerID)
        round = value
        attempts = [:]
        outcome = nil
        acknowledged = [lobby.hostPeerID]
        phase = .preparing
        return value
    }

    mutating func acknowledge(_ id: UUID, roundID: UUID) -> Bool {
        guard phase == .preparing, let round, round.id == roundID,
              round.players.contains(where: { $0.id == id }) else { return false }
        acknowledged.insert(id)
        if acknowledged == Set(round.players.map(\.id)) {
            phase = .countdown
            return true
        }
        return false
    }

    mutating func record(_ attempt: TimingAttempt) throws {
        guard phase == .running || (phase == .countdown && attempt.elapsedMilliseconds == nil), let round,
              attempt.gameID == lobby.id, attempt.roundID == round.id,
              round.players.contains(where: { $0.id == attempt.playerID }),
              attempt.elapsedMilliseconds.map({ (0...TimeItRules.maximumMilliseconds).contains($0) }) ?? true else {
            throw TimeItError.invalidAttempt
        }
        if let existing = attempts[attempt.playerID] {
            guard existing == attempt else { throw TimeItError.conflictingAttempt }
            return
        }
        attempts[attempt.playerID] = attempt
    }

    mutating func markRunning() { if phase == .countdown { phase = .running } }
    mutating func abortPreparation() {
        phase = .lobby
        round = nil
        acknowledged = []
        attempts = [:]
        outcome = nil
    }
    mutating func remove(_ id: UUID) {
        guard id != lobby.hostPeerID else { return }
        players.removeAll { $0.id == id }
        if phase == .countdown || phase == .running, let round,
           round.players.contains(where: { $0.id == id }), attempts[id] == nil {
            attempts[id] = TimingAttempt(gameID: lobby.id, roundID: round.id, playerID: id, elapsedMilliseconds: nil)
        }
    }
    mutating func finish() throws -> RoundOutcome {
        guard let round, phase == .countdown || phase == .running else { throw TimeItError.notReady }
        let result = try TimeItRules.outcome(round: round, attempts: Array(attempts.values), hostID: lobby.hostPeerID)
        phase = .results
        outcome = result
        return result
    }
}
