import Foundation

struct ConnectedPeer: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let capabilities: [String]
    let activity: ActivityDescriptor
}

struct ActivityParticipant: Identifiable, Equatable, Sendable {
    var id: UUID { peerID }
    let activityID: UUID
    let peerID: UUID
    let displayName: String
    let state: PeerLinkState
}

enum ActivityTransportEvent: Sendable {
    case connected(ConnectedPeer)
    case participants([ActivityParticipant])
    case disconnected(UUID)
    case admissionRejected(String)
    case message(PeerEnvelope)
    case issue(String)
    case deactivated
}

enum PeerProtocolError: Error, Equatable, Sendable {
    case connectionClosed, expectedHello, invalidHelloSender, invalidHelloAcceptance, handshakeIncomplete, wrongActivity
    case unexpectedPeer(expected: UUID, received: UUID)
    case admissionRejected(String)
}

typealias ActivityEventHandler = @Sendable (ActivityTransportEvent) async -> Void
typealias ActivityAdmissionPolicy = @Sendable (UUID) async -> String?

protocol ActivityTransport: Sendable {
    func open(identity: PeerIdentity, activity: ActivityDescriptor,
              admissionPolicy: ActivityAdmissionPolicy?, handler: @escaping ActivityEventHandler) async
    func updatePeers(_ peers: [DiscoveredPeer]) async
    func adoptChat(_ chat: Chat) async
    func send(_ message: PeerMessage, to peerID: UUID) async throws
    func broadcast(_ message: ChatMessage) async throws
    func disconnect(_ peerID: UUID) async
    func close() async
}

protocol ActivityAdvertising: Sendable {
    func advertise(_ chat: Chat?, displayTitle: String?) async
    func advertiseGame(_ game: GameLobby?, playerCount: Int, isJoinable: Bool) async
}

protocol SessionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousSessionClock: SessionClock {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}

enum ActivityCoordinatorError: Error, Equatable { case superseded }
