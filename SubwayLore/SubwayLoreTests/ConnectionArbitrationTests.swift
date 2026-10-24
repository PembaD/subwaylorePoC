import Foundation
import Testing
@testable import SubwayLore

struct ConnectionArbitrationTests {
    private let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

    @Test func lowerPeerInitiatesOutgoingConnection() {
        #expect(ConnectionArbitration.shouldInitiate(localPeerID: lower, remotePeerID: higher))
        #expect(ConnectionArbitration.preferredDirection(localPeerID: lower, remotePeerID: higher) == .outgoing)
    }

    @Test func higherPeerKeepsIncomingConnection() {
        #expect(!ConnectionArbitration.shouldInitiate(localPeerID: higher, remotePeerID: lower))
        #expect(ConnectionArbitration.preferredDirection(localPeerID: higher, remotePeerID: lower) == .incoming)
    }
}
