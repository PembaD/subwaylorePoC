import Foundation

enum GameKind: String, Codable, Sendable {
    case timeIt
    var title: String { "Time |t!" }
}

struct GameLobby: Codable, Hashable, Identifiable, Sendable {
    static let maximumPlayers = 8
    let id: UUID
    let kind: GameKind
    let hostPeerID: UUID
    let hostDisplayName: String
    let createdAt: Date
}

struct GamePlayer: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var displayName: String
    var isConnected: Bool
}

struct DiscoveredGame: Identifiable, Equatable, Sendable {
    let lobby: GameLobby
    let playerCount: Int
    let isJoinable: Bool
    var id: UUID { lobby.id }

    static func aggregate(_ peers: [DiscoveredPeer]) -> [DiscoveredGame] {
        var games: [UUID: DiscoveredGame] = [:]
        for peer in peers {
            guard let id = peer.gameID, let host = peer.gameHostID, host == peer.peerID,
                  peer.gameKind == GameKind.timeIt.rawValue,
                  (1...GameLobby.maximumPlayers).contains(peer.gamePlayerCount) else { continue }
            games[id] = DiscoveredGame(lobby: GameLobby(id: id, kind: .timeIt, hostPeerID: host,
                hostDisplayName: peer.displayName, createdAt: .distantPast),
                playerCount: peer.gamePlayerCount, isJoinable: peer.gameIsJoinable)
        }
        return games.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

struct TimeItRound: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let gameID: UUID
    let targetSeconds: Int
    let players: [GamePlayer]
}

struct TimingAttempt: Codable, Equatable, Sendable {
    let gameID: UUID
    let roundID: UUID
    let playerID: UUID
    // nil means a timeout or a departure before submission.
    let elapsedMilliseconds: Int?
}

struct RoundOutcome: Codable, Equatable, Sendable {
    let round: TimeItRound
    let attempts: [TimingAttempt]
    let winnerIDs: Set<UUID>
}

enum GamePhase: String, Codable, Sendable {
    case idle, lobby, preparing, countdown, running, results, ended
}

struct GameSnapshot: Equatable, Sendable {
    var lobby: GameLobby?
    var players: [GamePlayer] = []
    var phase: GamePhase = .idle
    var round: TimeItRound?
    var roundStarted: Bool {
        round != nil && (phase == .countdown || phase == .running || phase == .results)
    }
    var localAttempt: TimingAttempt?
    var completedPlayerIDs: Set<UUID> = []
    var outcome: RoundOutcome?
    var error: String?

    var canStart: Bool {
        (phase == .lobby || phase == .results) && players.count >= 2 && players.allSatisfy(\.isConnected)
    }
}

struct GamePacket: Codable, Equatable, Sendable {
    let gameID: UUID
    let event: GameEvent
}

enum GameEvent: Codable, Equatable, Sendable {
    case roster([GamePlayer])
    case prepare(TimeItRound)
    case prepared(UUID)
    case start(UUID)
    case attempt(TimingAttempt)
    case progress(roundID: UUID, completed: Set<UUID>)
    case result(RoundOutcome)
    case resultAck(UUID)
    case roundAborted(UUID)
    case ended(String)
    case left
}
