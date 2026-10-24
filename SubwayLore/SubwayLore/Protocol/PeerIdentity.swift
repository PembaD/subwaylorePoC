import Foundation

struct PeerIdentity: Codable, Hashable, Sendable {
    static let storageKey = "poc.peerIdentity"

    let id: UUID
    let displayName: String
    var firstName: String? = nil
    var lastName: String? = nil

    func updatingProfile(firstName: String, lastName: String) -> PeerIdentity {
        let first = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        return PeerIdentity(
            id: id,
            displayName: "\(first) \(last)",
            firstName: first,
            lastName: last
        )
    }

    static func make() -> PeerIdentity {
        let id = UUID()
        let suffix = id.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(4)
            .uppercased()

        return PeerIdentity(id: id, displayName: "Rider-\(suffix)")
    }
}

@MainActor
struct PeerIdentityStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = PeerIdentity.storageKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadOrCreate() -> PeerIdentity {
        if let data = defaults.data(forKey: key),
           let identity = try? JSONDecoder().decode(PeerIdentity.self, from: data) {
            return identity
        }

        let identity = PeerIdentity.make()
        if let data = try? JSONEncoder().encode(identity) {
            defaults.set(data, forKey: key)
        }
        return identity
    }

    func save(_ identity: PeerIdentity) throws {
        defaults.set(try JSONEncoder().encode(identity), forKey: key)
    }
}
