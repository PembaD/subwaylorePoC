import Foundation

enum ConnectionDirection: String, Equatable, Sendable {
    case incoming
    case outgoing
}

enum ConnectionArbitration {
    static func preferredDirection(localPeerID: UUID, remotePeerID: UUID) -> ConnectionDirection {
        localPeerID.uuidString < remotePeerID.uuidString ? .outgoing : .incoming
    }

    static func shouldInitiate(localPeerID: UUID, remotePeerID: UUID) -> Bool {
        preferredDirection(localPeerID: localPeerID, remotePeerID: remotePeerID) == .outgoing
    }
}
