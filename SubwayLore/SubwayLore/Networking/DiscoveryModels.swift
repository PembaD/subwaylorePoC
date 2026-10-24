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
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let senderID: UUID
    let senderName: String
    let text: String
    let sentAt: Date

    func envelope(sequence: UInt64) throws -> PeerEnvelope {
        PeerEnvelope(
            id: id,
            senderID: senderID,
            sequence: sequence,
            sentAt: sentAt,
            body: .text(try TextMessage(text: text))
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
    var linkStates: [UUID: PeerLinkState] = [:]
    var listenerPort: UInt16?
    var chatMessages: [ChatMessage] = []
    var isChatActive = false

    var connectedPeerCount: Int {
        linkStates.values.count { $0 == .connected }
    }

    func linkState(for peer: DiscoveredPeer) -> PeerLinkState {
        guard let peerID = peer.peerID else { return .discovered }
        return linkStates[peerID] ?? .discovered
    }
}
