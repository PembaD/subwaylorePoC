import Foundation
import Testing
@testable import SubwayLore

struct TriviaSessionTests {
    private struct Node: Sendable {
        let identity = PeerIdentity.make()
        let transport = FakeActivityTransport()
        let store = GameResultsStore()
        let questionHistoryStore = TriviaQuestionHistoryStore()
        let coordinator: ActivityCoordinator
        let session: TriviaSession
        init(clock: ManualSessionClock) {
            coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
            session = TriviaSession(identity: identity, coordinator: coordinator, clock: clock, resultsStore: store,
                                    questionHistoryStore: questionHistoryStore)
        }
    }

    // Deliver only newly sent messages, preserving each connection's send order.
    private func pump(_ nodes: [Node], offsets: inout [UUID: Int]) async {
        for _ in 0..<100 {
            var delivered = false
            for node in nodes {
                let sent = await node.transport.sent
                let offset = offsets[node.identity.id] ?? 0
                offsets[node.identity.id] = sent.count
                for (index, message) in sent.enumerated() where index >= offset {
                    guard let recipient = nodes.first(where: { $0.identity.id == message.0 }) else { continue }
                    await recipient.transport.emit(.message(PeerEnvelope(senderID: node.identity.id,
                        sequence: UInt64(index + 1), body: message.1)))
                    delivered = true
                }
            }
            if !delivered { return }
        }
        Issue.record("Trivia message exchange did not settle")
    }

    private func connect(_ host: Node, _ guest: Node, lobby: GameLobby) async throws {
        _ = try await guest.session.join(DiscoveredGame(lobby: lobby, playerCount: 1, isJoinable: true))
        #expect(await host.transport.connect(ConnectedPeer(id: guest.identity.id, displayName: "Guest", capabilities: [], activity: .game(lobby))) == nil)
        #expect(await guest.transport.connect(ConnectedPeer(id: host.identity.id, displayName: "Creator", capabilities: [], activity: .game(lobby))) == nil)
    }

    @Test func threeDevicesPlayFiveQuestionsAndPersistIdenticalVerifiedResultsOnce() async throws {
        let clock = ManualSessionClock()
        let host = Node(clock: clock), a = Node(clock: clock), b = Node(clock: clock)
        let nodes = [host, a, b]
        var offsets: [UUID: Int] = [:]
        let lobby = try await host.session.create()
        try await connect(host, a, lobby: lobby)
        try await connect(host, b, lobby: lobby)
        await pump(nodes, offsets: &offsets)
        #expect(await host.session.currentSnapshot().players.count == 3)
        try await host.session.start()
        await pump(nodes, offsets: &offsets)
        let round = try #require(await host.session.currentSnapshot().round)
        for index in 0..<TriviaRules.questionCount {
            for node in nodes {
                let state = await node.session.currentSnapshot()
                #expect(state.phase == .answering)
                #expect(state.questionIndex == index)
                #expect(state.card == round.cards[index])
                // Host and A tie for first; B is wrong on every question.
                try await node.session.submit(option: node.identity.id == b.identity.id ? 1 : 0,
                                               roundID: round.id, questionIndex: index)
            }
            await pump(nodes, offsets: &offsets)
            for node in nodes { #expect(await node.session.currentSnapshot().phase == .review) }
            #expect(try await host.store.rounds().isEmpty)
            await eventually { await clock.pendingCount(for: .seconds(3)) == 1 }
            await clock.advance(by: .seconds(3))
            await eventually {
                await pump(nodes, offsets: &offsets)
                for node in nodes {
                    let phase = await node.session.currentSnapshot().phase
                    if phase != (index == TriviaRules.questionCount - 1 ? .results : .answering) { return false }
                }
                return true
            }
        }
        let outcome = try #require(await host.session.currentSnapshot().outcome)
        let saved = outcome.completedRound()
        for node in nodes {
            #expect(await node.session.currentSnapshot().phase == .results)
            #expect(await node.session.currentSnapshot().outcome == outcome)
            #expect(try await node.store.rounds() == [saved])
            #expect(try await node.questionHistoryStore.history(for: node.identity.id).seen == Set(round.cards.map(\.questionID)))
        }
        #expect(await host.session.currentSnapshot().canStart)
        #expect(outcome.score(host.identity.id) == TriviaRules.questionCount)
        #expect(saved.players.filter { $0.placement == 1 }.count == 2)
        // Retransmission acknowledges again without adding another match win.
        let message = PeerMessage.game(GamePacket(gameID: lobby.id, event: .trivia(.result(outcome))))
        await a.transport.emit(.message(PeerEnvelope(senderID: host.identity.id, sequence: 1000, body: message)))
        #expect(try await a.store.rounds().count == 1)
        let oldReveal = PeerMessage.game(GamePacket(gameID: lobby.id, event: .trivia(.reveal(outcome.questions[TriviaRules.questionCount - 1]))))
        await a.transport.emit(.message(PeerEnvelope(senderID: host.identity.id, sequence: 1001, body: oldReveal)))
        #expect(await a.session.currentSnapshot().phase == .results)
        try await host.session.start()
        await pump(nodes, offsets: &offsets)
        #expect(await host.session.currentSnapshot().round?.id != round.id)
        let next = try #require(await host.session.currentSnapshot().round)
        #expect(Set(next.cards.map(\.questionID)).isDisjoint(with: Set(round.cards.map(\.questionID))))
        let oldPrepare = PeerMessage.game(GamePacket(gameID: lobby.id, event: .trivia(.prepare(round))))
        await a.transport.emit(.message(PeerEnvelope(senderID: host.identity.id, sequence: 1002, body: oldPrepare)))
        #expect(await a.session.currentSnapshot().round?.id != round.id)
        for node in nodes { await node.session.leave() }
        await eventually { await clock.pendingCount == 0 }
    }

    @Test func timeoutsRevealUnansweredQuestionsAndMidQuizAdmissionIsClosed() async throws {
        let clock = ManualSessionClock()
        let host = Node(clock: clock), guest = Node(clock: clock)
        let lobby = try await host.session.create()
        try await connect(host, guest, lobby: lobby)
        var offsets: [UUID: Int] = [:]
        await pump([host, guest], offsets: &offsets)
        try await host.session.start()
        await pump([host, guest], offsets: &offsets)
        #expect(await host.transport.connect(ConnectedPeer(id: UUID(), displayName: "Late", capabilities: [], activity: .game(lobby))) != nil)
        await eventually { await clock.pendingCount(for: .seconds(17)) == 1 }
        await clock.advance(by: .seconds(17))
        await eventually { await host.session.currentSnapshot().phase == .review }
        await pump([host, guest], offsets: &offsets)
        let result = try #require(await guest.session.currentSnapshot().questionResults.first)
        #expect(result.answers.allSatisfy { $0.option == nil })
        #expect(try await guest.store.rounds().isEmpty)
        await host.session.leave()
        await guest.session.leave()
        await eventually { await clock.pendingCount == 0 }
    }

    @Test func preparationAndJoinDeadlinesEndCleanly() async throws {
        let clock = ManualSessionClock()
        let host = Node(clock: clock), guest = Node(clock: clock)
        let lobby = try await host.session.create()
        _ = try await guest.session.join(DiscoveredGame(lobby: lobby, playerCount: 1, isJoinable: true))
        await eventually { await clock.pendingCount(for: .seconds(20)) == 1 }
        await clock.advance(by: .seconds(20))
        await eventually { await guest.session.currentSnapshot().phase == .ended }
        #expect(await host.transport.connect(ConnectedPeer(id: guest.identity.id, displayName: "Guest", capabilities: [], activity: .game(lobby))) == nil)
        await host.transport.emit(.message(PeerEnvelope(senderID: guest.identity.id, sequence: 1,
            body: .game(GamePacket(gameID: lobby.id, event: .trivia(.history(TriviaQuestionHistory())))))))
        try await host.session.start()
        await eventually { await clock.pendingCount(for: .seconds(10)) == 1 }
        await clock.advance(by: .seconds(10))
        await eventually { await host.session.currentSnapshot().phase == .ended }
        #expect(try await host.store.rounds().isEmpty)
        await host.session.leave()
        await guest.session.leave()
    }

    @Test func switchingToAnotherActivityCancelsTriviaAndStaleCleanupCannotCloseIt() async throws {
        let clock = ManualSessionClock()
        let node = Node(clock: clock)
        let lobby = try await node.session.create()
        let chat = Chat.make(for: node.identity)
        let current = try await node.coordinator.open(identity: node.identity, activity: .chat(chat), handler: { _ in })
        #expect(await node.session.currentSnapshot().phase == .ended)
        await node.session.leave(gameID: lobby.id)
        await node.transport.emit(.admissionRejected("Stale trivia callback"), using: 0)
        #expect(await node.coordinator.currentActivityID() == chat.id)
        await current.close()
        await eventually { await clock.pendingCount == 0 }
    }

    @Test func guestDeparturePreservesCurrentAnswerAndHostDepartureEndsTheQuiz() async throws {
        let clock = ManualSessionClock()
        let host = Node(clock: clock), a = Node(clock: clock), b = Node(clock: clock)
        let nodes = [host, a, b]
        let lobby = try await host.session.create()
        try await connect(host, a, lobby: lobby)
        try await connect(host, b, lobby: lobby)
        var offsets: [UUID: Int] = [:]
        await pump(nodes, offsets: &offsets)
        try await host.session.start()
        await pump(nodes, offsets: &offsets)
        let round = try #require(await host.session.currentSnapshot().round)
        try await b.session.submit(option: 0, roundID: round.id, questionIndex: 0)
        await pump(nodes, offsets: &offsets)
        await host.transport.emit(.disconnected(b.identity.id))
        try await host.session.submit(option: 0, roundID: round.id, questionIndex: 0)
        try await a.session.submit(option: 1, roundID: round.id, questionIndex: 0)
        await pump(nodes, offsets: &offsets)
        #expect(await host.session.currentSnapshot().questionResults.first?.answers.first { $0.playerID == b.identity.id }?.option == 0)
        await a.transport.emit(.disconnected(host.identity.id))
        #expect(await a.session.currentSnapshot().phase == .ended)
        #expect(try await a.store.rounds().isEmpty)
        for node in nodes { await node.session.leave() }
        await eventually { await clock.pendingCount == 0 }
    }
}
