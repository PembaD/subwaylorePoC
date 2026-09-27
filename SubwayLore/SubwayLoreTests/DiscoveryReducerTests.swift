import Foundation
import Testing
@testable import SubwayLore

struct DiscoveryReducerTests {
    @Test func startWaitsForPermission() {
        var reducer = DiscoveryReducer()

        reducer.start()

        #expect(reducer.snapshot.state == .waitingForPermission)
    }

    @Test func readyListenerPublishesPortAndSearches() {
        var reducer = DiscoveryReducer()

        reducer.listenerReady(port: 42_424)

        #expect(reducer.snapshot.listenerPort == 42_424)
        #expect(reducer.snapshot.state == .searching)
    }

    @Test func localPeerIsFilteredAndDuplicatesAreCollapsed() {
        var reducer = DiscoveryReducer()
        let localPeerID = UUID()
        let candidates = [
            peer(id: "local", peerID: localPeerID, name: "Rider-LOCAL (2)"),
            peer(id: "legacy", name: "Rider-OLD"),
            peer(id: "b", peerID: UUID(), name: "Rider-B"),
            peer(id: "b", peerID: UUID(), name: "Rider-B Updated"),
        ]

        let changes = reducer.replacePeers(
            candidates,
            localPeerID: localPeerID
        )

        #expect(reducer.snapshot.peers.map(\.id) == ["b"])
        #expect(reducer.snapshot.peers.map(\.displayName) == ["Rider-B Updated"])
        #expect(changes.addedIDs == ["b"])
        #expect(changes.removedIDs.isEmpty)
        #expect(reducer.snapshot.state == .peerFound)
    }

    @Test func peersAreSortedByDisplayNameThenIdentifier() {
        var reducer = DiscoveryReducer()

        _ = reducer.replacePeers(
            [
                peer(id: "3", peerID: UUID(), name: "Zulu"),
                peer(id: "2", peerID: UUID(), name: "alpha"),
                peer(id: "1", peerID: UUID(), name: "Alpha"),
            ],
            localPeerID: UUID()
        )

        #expect(reducer.snapshot.peers.map(\.id) == ["1", "2", "3"])
    }

    @Test func replacingPeersReportsAdditionsAndRemovals() {
        var reducer = DiscoveryReducer()
        _ = reducer.replacePeers(
            [peer(id: "a", peerID: UUID(), name: "A"), peer(id: "b", peerID: UUID(), name: "B")],
            localPeerID: UUID()
        )

        let changes = reducer.replacePeers(
            [peer(id: "b", peerID: UUID(), name: "B"), peer(id: "c", peerID: UUID(), name: "C")],
            localPeerID: UUID()
        )

        #expect(changes == DiscoveryPeerChanges(addedIDs: ["c"], removedIDs: ["a"]))
    }

    @Test func emptyPeerListReturnsToSearching() {
        var reducer = DiscoveryReducer()
        _ = reducer.replacePeers(
            [peer(id: "a", peerID: UUID(), name: "A")],
            localPeerID: UUID()
        )

        _ = reducer.replacePeers([], localPeerID: UUID())

        #expect(reducer.snapshot.peers.isEmpty)
        #expect(reducer.snapshot.state == .searching)
    }

    @Test func stopResetsAllDiscoveryState() {
        var reducer = DiscoveryReducer()
        reducer.listenerReady(port: 12_345)
        _ = reducer.replacePeers(
            [peer(id: "a", peerID: UUID(), name: "A")],
            localPeerID: UUID()
        )

        reducer.stop()

        #expect(reducer.snapshot == DiscoverySnapshot())
    }

    private func peer(id: String, peerID: UUID? = nil, name: String) -> DiscoveredPeer {
        DiscoveredPeer(id: id, peerID: peerID, displayName: name, domain: "local.")
    }
}
