import Foundation

// The only adapter that knows Bonjour endpoints; session actors stay platform-independent.
struct NetworkActivityTransport: ActivityTransport {
    let transport: PeerTransport
    let discovery: PeerDiscovery

    func open(identity: PeerIdentity, activity: ActivityDescriptor,
              admissionPolicy: ActivityAdmissionPolicy?, handler: @escaping ActivityEventHandler) async {
        let discovery = discovery
        await transport.open(identity: identity, activity: activity,
            endpointLookup: { id in await discovery.endpoint(for: id) },
            admissionPolicy: admissionPolicy, handler: handler)
    }
    func updatePeers(_ peers: [DiscoveredPeer]) async { await transport.updatePeers(peers) }
    func adoptChat(_ chat: Chat) async { await transport.adoptChat(chat) }
    func send(_ message: PeerMessage, to peerID: UUID) async throws { try await transport.send(message, to: peerID) }
    func broadcast(_ message: ChatMessage) async throws { try await transport.broadcast(message) }
    func disconnect(_ peerID: UUID) async { await transport.disconnect(peerID) }
    func close() async { await transport.close() }
}

extension PeerDiscovery: ActivityAdvertising {}
