import Foundation

// Sessions receive a scoped lease. Closing an obsolete lease cannot close another activity.
struct ActivityLease: Sendable {
    let activity: ActivityDescriptor
    fileprivate let token: UUID
    fileprivate let coordinator: ActivityCoordinator

    func close() async { await coordinator.release(token) }
    func updatePeers(_ peers: [DiscoveredPeer]) async { await coordinator.updatePeers(peers, token: token) }
    func adoptChat(_ chat: Chat) async { await coordinator.adoptChat(chat, token: token) }
    func advertise(_ chat: Chat?, displayTitle: String? = nil) async {
        await coordinator.advertise(chat, displayTitle: displayTitle, token: token)
    }
    func advertiseGame(_ game: GameLobby?, playerCount: Int = 0, isJoinable: Bool = false) async {
        await coordinator.advertiseGame(game, playerCount: playerCount, isJoinable: isJoinable, token: token)
    }
    func send(_ message: PeerMessage, to peerID: UUID) async throws {
        try await coordinator.send(message, to: peerID, token: token)
    }
    func broadcast(_ message: ChatMessage) async throws { try await coordinator.broadcast(message, token: token) }
    func disconnect(_ peerID: UUID) async { await coordinator.disconnect(peerID, token: token) }
}

actor ActivityCoordinator {
    private struct Owner {
        let token: UUID
        let activity: ActivityDescriptor
        let handler: ActivityEventHandler
    }
    private let transport: any ActivityTransport
    private let advertising: any ActivityAdvertising
    private var owner: Owner?
    private var transition: Task<Void, Never>?

    init(transport: any ActivityTransport, advertising: any ActivityAdvertising) {
        self.transport = transport
        self.advertising = advertising
    }

    func open(identity: PeerIdentity, activity: ActivityDescriptor,
              admissionPolicy: ActivityAdmissionPolicy? = nil,
              handler: @escaping ActivityEventHandler) async throws -> ActivityLease {
        let token = UUID()
        let previousOwner = owner
        let previousTransition = transition
        owner = Owner(token: token, activity: activity, handler: handler)
        let task = Task { [transport, advertising, weak self] in
            await previousTransition?.value
            await previousOwner?.handler(.deactivated)
            await transport.close()
            await advertising.advertise(nil, displayTitle: nil)
            guard let self, await self.isCurrent(token) else { return }
            await transport.open(identity: identity, activity: activity, admissionPolicy: admissionPolicy,
                handler: { [weak self] event in await self?.deliver(event, token: token) })
        }
        transition = task
        await task.value
        guard isCurrent(token) else { throw ActivityCoordinatorError.superseded }
        return ActivityLease(activity: activity, token: token, coordinator: self)
    }

    fileprivate func release(_ token: UUID) async {
        guard isCurrent(token) else { return }
        owner = nil
        let previous = transition
        let task = Task { [transport, advertising] in
            await previous?.value
            await transport.close()
            await advertising.advertise(nil, displayTitle: nil)
        }
        transition = task
        await task.value
    }

    private func isCurrent(_ token: UUID) -> Bool { owner?.token == token }
    func currentActivityID() -> UUID? { owner?.activity.id }
    func deactivate() async {
        guard let previous = owner else { return }
        await previous.handler(.deactivated)
        await release(previous.token)
    }
    private func deliver(_ event: ActivityTransportEvent, token: UUID) async {
        guard let owner, owner.token == token else { return }
        await owner.handler(event)
    }

    fileprivate func updatePeers(_ peers: [DiscoveredPeer], token: UUID) async {
        guard isCurrent(token) else { return }
        await transport.updatePeers(peers)
    }
    fileprivate func adoptChat(_ chat: Chat, token: UUID) async {
        guard isCurrent(token), owner?.activity.kind == "chat", owner?.activity.id == chat.id else { return }
        await transport.adoptChat(chat)
    }
    fileprivate func advertise(_ chat: Chat?, displayTitle: String?, token: UUID) async {
        guard isCurrent(token), owner?.activity.kind == "chat", chat == nil || chat?.id == owner?.activity.id else { return }
        await advertising.advertise(chat, displayTitle: displayTitle)
    }
    fileprivate func advertiseGame(_ game: GameLobby?, playerCount: Int, isJoinable: Bool, token: UUID) async {
        guard isCurrent(token), owner?.activity.kind == "game", game == nil || game?.id == owner?.activity.id else { return }
        await advertising.advertiseGame(game, playerCount: playerCount, isJoinable: isJoinable)
    }
    fileprivate func send(_ message: PeerMessage, to peerID: UUID, token: UUID) async throws {
        guard isCurrent(token) else { throw ActivityCoordinatorError.superseded }
        guard message.scopeID == owner?.activity.id, message.scopeKind == owner?.activity.kind else {
            throw PeerProtocolError.wrongActivity
        }
        try await transport.send(message, to: peerID)
    }
    fileprivate func broadcast(_ message: ChatMessage, token: UUID) async throws {
        guard isCurrent(token) else { throw ActivityCoordinatorError.superseded }
        guard owner?.activity.kind == "chat", message.chatID == owner?.activity.id else {
            throw PeerProtocolError.wrongActivity
        }
        try await transport.broadcast(message)
    }
    fileprivate func disconnect(_ peerID: UUID, token: UUID) async {
        guard isCurrent(token) else { return }
        await transport.disconnect(peerID)
    }
}
