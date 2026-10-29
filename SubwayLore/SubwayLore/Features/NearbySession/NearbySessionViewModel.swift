import Foundation

@MainActor
final class NearbySessionViewModel: ObservableObject {
    @Published private(set) var snapshot = DiscoverySnapshot()
    @Published private(set) var chatSnapshot = ChatSnapshot()
    @Published private(set) var identity: PeerIdentity
    @Published var presentedChat: Chat?
    private let identityStore: PeerIdentityStore
    private let discovery: PeerDiscovery
    private let session: ChatSession
    private var monitorTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?

    var liveChats: [DiscoveredChat] {
        var chats = DiscoveredChat.aggregate(snapshot.peers)
        if chatSnapshot.isActive, let local = chatSnapshot.chat,
           !chats.contains(where: { $0.id == local.id }) {
            chats.append(DiscoveredChat(id: local.id, title: local.title, advertisingPeerIDs: []))
        }
        return chats.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    init(identityStore: PeerIdentityStore = PeerIdentityStore(),
         diagnostics: DiagnosticsRecorder = DiagnosticsRecorder(), store: ChatStore = ChatStore()) {
        let identity = identityStore.loadOrCreate()
        self.identityStore = identityStore
        self.identity = identity
        let transport = PeerTransport(diagnostics: diagnostics)
        let discovery = PeerDiscovery(identity: identity, diagnostics: diagnostics,
                                      incomingHandler: { connection in await transport.accept(connection) })
        self.discovery = discovery
        self.session = ChatSession(identity: identity, store: store, transport: transport, discovery: discovery)
    }

    func start() {
        guard monitorTask == nil else { return }
        chatTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await session.snapshots()
            await session.loadHistory()
            for await value in snapshots {
                guard !Task.isCancelled else { return }
                chatSnapshot = value
            }
        }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await discovery.snapshots()
            await discovery.start()
            for await value in snapshots {
                guard !Task.isCancelled else { return }
                snapshot = value
                await session.updatePeers(value.peers)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        chatTask?.cancel()
        monitorTask = nil
        chatTask = nil
        Task {
            await session.leave()
            await discovery.stop()
        }
    }

    func restart() {
        Task {
            await discovery.stop()
            await discovery.start()
        }
    }

    func createChat(title: String) async throws {
        presentedChat = try await session.create(title: title)
    }

    func joinChat(_ chat: DiscoveredChat) async throws {
        presentedChat = try await session.join(chat)
    }

    func previewChat(_ chat: Chat) async throws {
        try await session.preview(chat)
        presentedChat = chat
    }

    func resumeChat(_ chat: Chat) async throws { try await session.resume(chat) }

    func leaveChat(_ chatID: UUID) {
        Task { await session.leave(chatID: chatID) }
    }

    func sendChatMessage(_ text: String) async throws { try await session.send(text) }

    func retryHistory() { Task { await session.retryHistory() } }

    func saveProfile(firstName: String, lastName: String) async throws {
        let updated = identity.updatingProfile(firstName: firstName, lastName: lastName)
        try identityStore.save(updated)
        identity = updated
        await session.updateIdentity(updated)
        await discovery.updateIdentity(updated)
    }
}
