import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var snapshot = DiscoverySnapshot()
    @Published private(set) var chatSnapshot = ChatSnapshot()
    @Published private(set) var identity: PeerIdentity
    @Published var presentedChat: Chat?
    @Published private(set) var gameSnapshot = GameSnapshot()
    @Published var presentedGame: GameLobby?
    @Published private(set) var completedRounds: [CompletedRound] = []
    @Published private(set) var leaderboardError: String?
    private let resultsStore: GameResultsStore
    private let identityStore: PeerIdentityStore
    private let discovery: PeerDiscovery
    private let coordinator: ActivityCoordinator
    private let session: ChatSession
    private let gameSession: GameSession
    private var monitorTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var gameTask: Task<Void, Never>?

    var liveGames: [DiscoveredGame] { DiscoveredGame.aggregate(snapshot.peers) }

    var liveChats: [DiscoveredChat] {
        var chats = DiscoveredChat.aggregate(snapshot.peers)
        if chatSnapshot.isActive, let local = chatSnapshot.chat,
           !chats.contains(where: { $0.id == local.id }) {
            chats.append(DiscoveredChat(id: local.id, title: chatSnapshot.displayTitle, advertisingPeerIDs: []))
        }
        return chats.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    init(identityStore: PeerIdentityStore = PeerIdentityStore(),
         diagnostics: DiagnosticsRecorder = DiagnosticsRecorder(), store: ChatStore = ChatStore(),
         resultsStore: GameResultsStore = .persistent()) {
        let identity = identityStore.loadOrCreate()
        self.identityStore = identityStore
        self.identity = identity
        self.resultsStore = resultsStore
        let transport = PeerTransport(diagnostics: diagnostics)
        let discovery = PeerDiscovery(identity: identity, diagnostics: diagnostics,
                                      incomingHandler: { connection in await transport.accept(connection) })
        self.discovery = discovery
        let coordinator = ActivityCoordinator(
            transport: NetworkActivityTransport(transport: transport, discovery: discovery), advertising: discovery)
        self.coordinator = coordinator
        self.session = ChatSession(identity: identity, store: store, coordinator: coordinator)
        self.gameSession = GameSession(identity: identity, coordinator: coordinator, resultsStore: resultsStore)
    }

    func start() {
        guard monitorTask == nil else { return }
        gameTask = Task { [weak self] in
            guard let self else { return }
            await refreshLeaderboard()
            for await value in await gameSession.snapshots() {
                guard !Task.isCancelled else { return }
                gameSnapshot = value
                if value.outcome != nil { await refreshLeaderboard() }
            }
        }
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
                await gameSession.updatePeers(value.peers)
            }
        }
    }

    func refreshLeaderboard() async {
        do {
            completedRounds = try await resultsStore.rounds()
            leaderboardError = nil
        } catch {
            leaderboardError = "Saved results could not be loaded. Please try again."
        }
    }

    func stop() {
        monitorTask?.cancel()
        chatTask?.cancel()
        gameTask?.cancel()
        monitorTask = nil
        chatTask = nil
        gameTask = nil
        Task {
            await coordinator.deactivate()
            await discovery.stop()
        }
    }

    func restart() {
        Task {
            await discovery.stop()
            await discovery.start()
        }
    }

    func createChat() async throws {
        presentedChat = try await session.create()
    }

    func joinChat(_ chat: DiscoveredChat) async throws {
        presentedChat = try await session.join(chat)
    }

    func previewChat(_ chat: Chat) async throws {
        try await session.preview(chat)
        presentedChat = chat
    }

    func resumeChat(_ chat: Chat) async throws {
        try await session.resume(chat)
    }

    func createGame() async throws {
        presentedGame = try await gameSession.create()
    }

    func joinGame(_ game: DiscoveredGame) async throws {
        presentedGame = try await gameSession.join(game)
    }

    func startGameRound() async throws { try await gameSession.startRound() }
    func markGameRunning(_ roundID: UUID) async { await gameSession.markRunning(roundID: roundID) }
    func submitGameAttempt(_ roundID: UUID, milliseconds: Int?) async throws {
        try await gameSession.submit(roundID: roundID, elapsedMilliseconds: milliseconds)
    }
    func leaveGame(_ gameID: UUID) {
        Task { await gameSession.leave(gameID: gameID) }
    }

    func leaveChat(_ chatID: UUID) {
        Task { await session.leave(chatID: chatID) }
    }

    func sendChatMessage(_ text: String) async throws { try await session.send(text) }

    func retryHistory() { Task { await session.retryHistory() } }

    func saveProfile(firstName: String, lastName: String) async throws {
        let updated = identity.updatingProfile(firstName: firstName, lastName: lastName)
        try identityStore.save(updated)
        identity = updated
        await coordinator.deactivate()
        await session.updateIdentity(updated)
        await gameSession.updateIdentity(updated)
        await discovery.updateIdentity(updated)
    }
}
