import Foundation

enum ActivityDescriptor: Codable, Equatable, Sendable {
    case chat(Chat)
    case game(GameLobby)

    var id: UUID {
        switch self { case .chat(let chat): chat.id; case .game(let game): game.id }
    }
    var kind: String {
        switch self { case .chat: "chat"; case .game: "game" }
    }
    func matches(_ other: ActivityDescriptor) -> Bool {
        guard id == other.id, kind == other.kind else { return false }
        if case .game(let a) = self, case .game(let b) = other { return a.hostPeerID == b.hostPeerID && a.kind == b.kind }
        return true
    }
    func remoteLimit(for localID: UUID) -> Int {
        switch self {
        case .chat: 8
        case .game(let game): localID == game.hostPeerID ? GameLobby.maximumPlayers - 1 : 1
        }
    }
    func allows(peerID: UUID, localID: UUID) -> Bool {
        switch self {
        case .chat: peerID != localID
        case .game(let game): peerID != localID && (localID == game.hostPeerID || peerID == game.hostPeerID)
        }
    }
}

struct ActivityJoinRequest: Codable, Equatable, Sendable {
    let activity: ActivityDescriptor
    let requestID: UUID
}
struct ActivityJoinAccepted: Codable, Equatable, Sendable {
    let activity: ActivityDescriptor
    let requestID: UUID
}
