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

    @Test @MainActor
    func profilePersistsWithoutChangingPeerID() throws {
        let suiteName = "PeerIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PeerIdentityStore(defaults: defaults)
        let original = store.loadOrCreate()
        let updated = original.updatingProfile(firstName: "  Alex ", lastName: " Rider  ")

        try store.save(updated)
        let reloaded = store.loadOrCreate()

        #expect(reloaded.id == original.id)
        #expect(reloaded.firstName == "Alex")
        #expect(reloaded.lastName == "Rider")
        #expect(reloaded.displayName == "Alex Rider")
    }

    @Test
    func existingIdentityDecodesWithoutProfileFields() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id.uuidString)\",\"displayName\":\"Rider-ABCD\"}".utf8)
        let identity = try JSONDecoder().decode(PeerIdentity.self, from: data)

        #expect(identity.id == id)
        #expect(identity.displayName == "Rider-ABCD")
        #expect(identity.firstName == nil)
        #expect(identity.lastName == nil)
    }
}
