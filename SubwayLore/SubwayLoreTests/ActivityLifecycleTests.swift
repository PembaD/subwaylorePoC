import Foundation
import Testing
@testable import SubwayLore

struct ActivityLifecycleTests {
    private func game(host: PeerIdentity) -> GameLobby {
        GameLobby(id: UUID(), kind: .timeIt, hostPeerID: host.id, hostDisplayName: host.displayName, createdAt: Date())
    }

    @Test func obsoleteLeaseCannotSendOrCloseNewActivity() async throws {
        let transport = FakeActivityTransport()
        let advertising = FakeActivityAdvertising()
        let coordinator = ActivityCoordinator(transport: transport, advertising: advertising)
        let identity = PeerIdentity.make()
        let chat = Chat.make(for: identity)
        let first = try await coordinator.open(identity: identity, activity: .chat(chat), handler: { _ in })
        let lobby = game(host: identity)
        let second = try await coordinator.open(identity: identity, activity: .game(lobby), handler: { _ in })
        let closeCount = await transport.closeCount
        await first.close()
        #expect(await transport.activity == .game(lobby))
        #expect(await transport.closeCount == closeCount)
        await #expect(throws: ActivityCoordinatorError.superseded) {
            try await first.send(.historySyncRequest(chat.id), to: UUID())
        }
        await first.advertise(chat)
        #expect(await advertising.activityID == nil)
        await second.close()
        #expect(await transport.activity == nil)
    }

    @Test func concurrentOpenTransitionsAreSerializedAndLatestWins() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let identity = PeerIdentity.make()
        let chat = Chat.make(for: identity)
        let lobby = game(host: identity)
        await transport.pauseNextOpen()
        let first = Task {
            do { _ = try await coordinator.open(identity: identity, activity: .chat(chat), handler: { _ in }); return false }
            catch ActivityCoordinatorError.superseded { return true }
            catch { return false }
        }
        await eventually { await transport.openIsPaused }
        let second = Task { try await coordinator.open(identity: identity, activity: .game(lobby), handler: { _ in }) }
        // A second open must be enqueued before unblocking the first transition.
        await eventually { await coordinator.currentActivityID() == lobby.id }
        await transport.resumeOpen()
        let current = try await second.value
        #expect(await first.value)
        #expect(await transport.activity == .game(lobby))
        await current.close()
    }

    @Test func switchingSessionsDeactivatesChatAndInactiveCleanupCannotCloseGame() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let identity = PeerIdentity.make()
        let url = FileManager.default.temporaryDirectory.appending(path: "ActivityLifecycle-\(UUID())/chats.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let chatSession = ChatSession(identity: identity, store: ChatStore(url: url), coordinator: coordinator)
        let gameSession = GameSession(identity: identity, coordinator: coordinator)
        let chat = try await chatSession.create()
        let lobby = try await gameSession.create()
        #expect(await chatSession.currentSnapshot().state == .idle)
        #expect(await transport.activity == .game(lobby))
        await chatSession.leave(chatID: chat.id)
        await chatSession.leave()
        #expect(await transport.activity == .game(lobby))
        // An old network callback must not reach the new owner.
        await transport.emit(.admissionRejected("Old chat failure"), using: 0)
        #expect(await gameSession.currentSnapshot().phase == .lobby)
        await gameSession.leave()
    }

    @Test func realGameSessionProjectsAuthoritativeMatchAndCompletesRound() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let identity = PeerIdentity.make()
        let clock = ManualSessionClock()
        let resultsStore = GameResultsStore()
        let session = GameSession(identity: identity, coordinator: coordinator, clock: clock, resultsStore: resultsStore)
        let lobby = try await session.create()
        let guestID = UUID()
        let rejected = await transport.connect(ConnectedPeer(id: guestID, displayName: "Guest", capabilities: [], activity: .game(lobby)))
        #expect(rejected == nil)
        #expect(await session.currentSnapshot().canStart)
        try await session.startRound()
        let round = try #require(await session.currentSnapshot().round)
        await transport.emit(.message(PeerEnvelope(senderID: guestID, sequence: 1,
            body: .game(GamePacket(gameID: lobby.id, event: .prepared(round.id))))))
        #expect(await session.currentSnapshot().phase == .countdown)
        await session.markRunning(roundID: round.id)
        try await session.submit(roundID: round.id, elapsedMilliseconds: round.targetSeconds * 1000)
        let guestAttempt = TimingAttempt(gameID: lobby.id, roundID: round.id, playerID: guestID,
                                         elapsedMilliseconds: round.targetSeconds * 1000 + 100)
        await transport.emit(.message(PeerEnvelope(senderID: guestID, sequence: 2,
            body: .game(GamePacket(gameID: lobby.id, event: .attempt(guestAttempt))))))
        let result = await session.currentSnapshot()
        #expect(result.phase == .results)
        #expect(result.outcome?.winnerIDs == [identity.id])
        #expect(result.localAttempt?.elapsedMilliseconds == round.targetSeconds * 1000)
        #expect(result.completedPlayerIDs == [identity.id, guestID])
        #expect(try await resultsStore.rounds() == [result.outcome?.completedRound()].compactMap { $0 })
        // A retransmitted attempt resends the result without incrementing standings.
        await transport.emit(.message(PeerEnvelope(senderID: guestID, sequence: 3,
            body: .game(GamePacket(gameID: lobby.id, event: .attempt(guestAttempt))))))
        #expect(try await resultsStore.rounds().count == 1)
        await session.leave()
        await eventually { await clock.pendingCount == 0 }
    }

    @Test func manualClockDrivesGuestJoinTimeoutAndLeaveCancelsIt() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let clock = ManualSessionClock()
        let identity = PeerIdentity.make()
        let session = GameSession(identity: identity, coordinator: coordinator, clock: clock)
        let lobby = game(host: PeerIdentity.make())
        _ = try await session.join(DiscoveredGame(lobby: lobby, playerCount: 1, isJoinable: true))
        await eventually { await clock.pendingCount == 1 }
        await clock.advance(by: .seconds(20))
        await eventually { await session.currentSnapshot().phase == .ended }
        #expect(await session.currentSnapshot().error != nil)
        await session.leave()

        _ = try await session.join(DiscoveredGame(lobby: lobby, playerCount: 1, isJoinable: true))
        await eventually { await clock.pendingCount == 1 }
        await session.leave()
        await eventually { await clock.pendingCount == 0 }
        await clock.advance(by: .seconds(60))
        #expect(await session.currentSnapshot().phase == .idle)
    }

    @Test func failedGameBroadcastIsVisibleAndPreparationTimeoutRecoversLobby() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let clock = ManualSessionClock()
        let identity = PeerIdentity.make()
        let session = GameSession(identity: identity, coordinator: coordinator, clock: clock)
        let lobby = try await session.create()
        _ = await transport.connect(ConnectedPeer(id: UUID(), displayName: "Guest", capabilities: [], activity: .game(lobby)))
        await transport.setFailSends(true)
        try await session.startRound()
        #expect(await session.currentSnapshot().phase == .preparing)
        #expect(await session.currentSnapshot().error != nil)
        await eventually { await clock.pendingCount == 1 }
        await clock.advance(by: .seconds(10))
        await eventually { await session.currentSnapshot().phase == .lobby }
        #expect(await session.currentSnapshot().round == nil)
        #expect(await session.currentSnapshot().canStart)
        await session.leave()
    }

    @Test func chatHistoryTimersAreCancelledWhenSwitchingToGame() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let clock = ManualSessionClock()
        let identity = PeerIdentity.make()
        let url = FileManager.default.temporaryDirectory.appending(path: "HistoryCancellation-\(UUID())/chats.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let chatSession = ChatSession(identity: identity, store: ChatStore(url: url), coordinator: coordinator, clock: clock)
        let gameSession = GameSession(identity: identity, coordinator: coordinator, clock: clock)
        let chat = try await chatSession.create()
        let guest = UUID()
        await transport.emit(.message(PeerEnvelope(senderID: guest, sequence: 1,
            body: .historyInventory(HistoryInventory(chatID: chat.id, requestID: UUID(), messageIDs: [UUID()])))))
        #expect(await chatSession.currentSnapshot().isSynchronizing)
        await eventually { await clock.pendingCount == 1 }
        let lobby = try await gameSession.create()
        await eventually { await clock.pendingCount == 0 }
        await clock.advance(by: .seconds(60))
        #expect(await chatSession.currentSnapshot().state == .idle)
        #expect(await gameSession.currentSnapshot().error == nil)
        #expect(await transport.activity == .game(lobby))
        await gameSession.leave()
    }

    @Test func failedHistoryRequestDoesNotLeaveAnEndlessSyncIndicator() async throws {
        let transport = FakeActivityTransport()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let identity = PeerIdentity.make()
        let clock = ManualSessionClock()
        let url = FileManager.default.temporaryDirectory.appending(path: "HistoryFailure-\(UUID())/chats.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = ChatSession(identity: identity, store: ChatStore(url: url), coordinator: coordinator, clock: clock)
        let chat = try await session.create()
        await transport.setFailSends(true)
        await transport.emit(.message(PeerEnvelope(senderID: UUID(), sequence: 1,
            body: .historyInventory(HistoryInventory(chatID: chat.id, requestID: UUID(), messageIDs: [UUID()])))))
        #expect(await session.currentSnapshot().error != nil)
        #expect(await session.currentSnapshot().isSynchronizing == false)
        #expect(await clock.pendingCount == 0)
        await session.leave()
    }
}
