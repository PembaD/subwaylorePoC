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
    let displayName: String
    let domain: String
}

struct DiscoverySnapshot: Equatable, Sendable {
    var state: NearbyDiscoveryState = .notStarted
    var peers: [DiscoveredPeer] = []
    var listenerPort: UInt16?
}
