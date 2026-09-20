import Foundation

struct DiscoveryPeerChanges: Equatable, Sendable {
    let addedIDs: Set<String>
    let removedIDs: Set<String>
}

struct DiscoveryReducer: Sendable {
    private(set) var snapshot = DiscoverySnapshot()

    mutating func start() {
        snapshot.state = .waitingForPermission
    }

    mutating func listenerReady(port: UInt16?) {
        snapshot.listenerPort = port
        if snapshot.peers.isEmpty {
            snapshot.state = .searching
        }
    }

    mutating func browserReady() {
        snapshot.state = snapshot.peers.isEmpty ? .searching : .peerFound
    }

    mutating func replacePeers(
        _ candidates: [DiscoveredPeer],
        localDisplayName: String
    ) -> DiscoveryPeerChanges {
        let oldIDs = Set(snapshot.peers.map(\.id))
        let peers = candidates
            .filter { $0.displayName != localDisplayName }
            .reduce(into: [String: DiscoveredPeer]()) { result, peer in
                result[peer.id] = peer
            }
            .values
            .sorted {
                let nameOrder = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
            }
        let newIDs = Set(peers.map(\.id))

        snapshot.peers = peers
        snapshot.state = peers.isEmpty ? .searching : .peerFound

        return DiscoveryPeerChanges(
            addedIDs: newIDs.subtracting(oldIDs),
            removedIDs: oldIDs.subtracting(newIDs)
        )
    }

    mutating func waitForPermission() {
        snapshot.state = .waitingForPermission
    }

    mutating func permissionUnavailable(_ message: String) {
        snapshot.state = .permissionUnavailable(message)
    }

    mutating func fail(_ message: String) {
        snapshot.state = .failed(message)
    }

    mutating func stop() {
        snapshot = DiscoverySnapshot()
    }
}
