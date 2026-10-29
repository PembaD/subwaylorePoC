import Foundation

enum NearbyDiscoveryState: Equatable, Sendable {
    case notStarted
    case waitingForPermission
    case searching
    case peerFound
    case permissionUnavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .notStarted: "Not started"
        case .waitingForPermission: "Waiting for local-network access"
        case .searching: "Searching for nearby riders"
        case .peerFound: "Nearby riders found"
        case .permissionUnavailable: "Local-network access unavailable"
        case .failed: "Discovery failed"
        }
    }

    var detail: String {
        switch self {
        case .notStarted:
            "Start discovery when you are ready."
        case .waitingForPermission:
            "Allow local-network access when iOS asks."
        case .searching:
            "Access is available, but no other Subway Lore devices are advertising yet."
        case .peerFound:
            "These devices are advertising Subway Lore nearby."
        case let .permissionUnavailable(message), let .failed(message):
            message
        }
    }
}

struct DiscoveredPeer: Identifiable, Equatable, Sendable {
    let id: String
    let peerID: UUID?
    let displayName: String
    let domain: String
    var chatID: UUID? = nil
    var chatTitle: String? = nil
    var gameID: UUID? = nil
    var gameHostID: UUID? = nil
    var gameKind: String? = nil
    var gamePlayerCount = 0
    var gameIsJoinable = false
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let senderID: UUID
    let senderName: String
    let text: String
    let sentAt: Date
    var chatID: UUID

    func envelope(sequence: UInt64) throws -> PeerEnvelope {
        _ = try TextMessage(text: text)
        return PeerEnvelope(
            id: id,
            senderID: senderID,
            sequence: sequence,
            sentAt: sentAt,
            body: .chatText(self)
        )
    }
}

enum PeerLinkState: Equatable, Sendable {
    case discovered
    case connecting
    case connected
}

struct DiscoverySnapshot: Equatable, Sendable {
    var state: NearbyDiscoveryState = .notStarted
    var peers: [DiscoveredPeer] = []
    var listenerPort: UInt16?
}
