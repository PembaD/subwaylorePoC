import Foundation
import Testing
@testable import SubwayLore

struct PeerIdentityTests {
    @Test @MainActor
    func identityIsStableWithinOneInstallation() {
        let suiteName = "PeerIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PeerIdentityStore(defaults: defaults)

        let first = store.loadOrCreate()
        let second = store.loadOrCreate()

        #expect(first == second)
        #expect(first.displayName.hasPrefix("Rider-"))
    }

    @Test
    func newIdentitiesAreDistinct() {
        #expect(PeerIdentity.make() != PeerIdentity.make())
    }
}
