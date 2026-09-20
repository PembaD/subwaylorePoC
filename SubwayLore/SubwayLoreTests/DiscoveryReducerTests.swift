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
        let candidates = [
            peer(id: "local", name: "Rider-LOCAL"),
            peer(id: "b", name: "Rider-B"),
            peer(id: "b", name: "Rider-B Updated"),
        ]

        let changes = reducer.replacePeers(candidates, localDisplayName: "Rider-LOCAL")

        #expect(reducer.snapshot.peers == [peer(id: "b", name: "Rider-B Updated")])
        #expect(changes.addedIDs == ["b"])
        #expect(changes.removedIDs.isEmpty)
        #expect(reducer.snapshot.state == .peerFound)
    }

    @Test func peersAreSortedByDisplayNameThenIdentifier() {
        var reducer = DiscoveryReducer()

        _ = reducer.replacePeers(
            [
                peer(id: "3", name: "Zulu"),
                peer(id: "2", name: "alpha"),
                peer(id: "1", name: "Alpha"),
            ],
            localDisplayName: "Local"
        )

        #expect(reducer.snapshot.peers.map(\.id) == ["1", "2", "3"])
    }

    @Test func replacingPeersReportsAdditionsAndRemovals() {
        var reducer = DiscoveryReducer()
        _ = reducer.replacePeers(
            [peer(id: "a", name: "A"), peer(id: "b", name: "B")],
            localDisplayName: "Local"
        )

        let changes = reducer.replacePeers(
            [peer(id: "b", name: "B"), peer(id: "c", name: "C")],
            localDisplayName: "Local"
        )

        #expect(changes == DiscoveryPeerChanges(addedIDs: ["c"], removedIDs: ["a"]))
    }

    @Test func emptyPeerListReturnsToSearching() {
        var reducer = DiscoveryReducer()
        _ = reducer.replacePeers([peer(id: "a", name: "A")], localDisplayName: "Local")

        _ = reducer.replacePeers([], localDisplayName: "Local")

        #expect(reducer.snapshot.peers.isEmpty)
        #expect(reducer.snapshot.state == .searching)
    }

    @Test func stopResetsAllDiscoveryState() {
        var reducer = DiscoveryReducer()
        reducer.listenerReady(port: 12_345)
        _ = reducer.replacePeers([peer(id: "a", name: "A")], localDisplayName: "Local")

        reducer.stop()

        #expect(reducer.snapshot == DiscoverySnapshot())
    }

    private func peer(id: String, name: String) -> DiscoveredPeer {
        DiscoveredPeer(id: id, displayName: name, domain: "local.")
    }
}
