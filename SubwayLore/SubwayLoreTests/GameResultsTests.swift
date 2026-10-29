import Foundation
import Testing
@testable import SubwayLore

struct GameResultsTests {
    private let a = UUID(), b = UUID(), c = UUID()

    private func round(gameID: UUID = UUID(), ranks: [Int?] = [1, 2, 3]) -> CompletedRound {
        CompletedRound(gameKind: .timeIt, gameID: gameID, roundID: UUID(),
            players: zip([a, b, c], ranks).map {
                PlayerRoundResult(playerID: $0.0, displayName: $0.0.uuidString, placement: $0.1, measurements: [:])
            })
    }

    @Test func sharedFirstPlacesCountAsWinsAndDuplicateRoundsCountOnce() {
        let first = round(ranks: [1, 1, 3])
        let entries = GameStandings.leaderboard([first, first], kind: .timeIt)
        #expect(entries.first { $0.id == a }?.wins == 1)
        #expect(entries.first { $0.id == b }?.sharedWins == 1)
        #expect(entries.allSatisfy { $0.played == 1 })
        #expect(entries.first { $0.id == c }?.wins == 0)
    }

    @Test func headToHeadComparesPlacementsEvenWhenNeitherPlayerWins() {
        let rounds = [round(ranks: [2, 3, 1]), round(ranks: [3, 2, 1]), round(ranks: [2, 2, 1])]
        let record = GameStandings.headToHead(rounds, kind: .timeIt, playerID: a).first { $0.id == b }
        #expect(record?.wins == 1)
        #expect(record?.losses == 1)
        #expect(record?.draws == 1)
        let opposite = GameStandings.headToHead([round(ranks: [2, 3, 1])], kind: .timeIt, playerID: b)
        #expect(opposite.first { $0.id == a }?.losses == 1)
    }

    @Test func forfeitsLoseToFinishersAndTwoForfeitsDoNotCreateDraws() {
        let value = round(ranks: [nil, nil, 1])
        let records = GameStandings.headToHead([value], kind: .timeIt, playerID: a)
        #expect(records.count == 1)
        #expect(records.first?.id == c)
        #expect(records.first?.losses == 1)
        #expect(GameStandings.leaderboard([value], kind: .timeIt).first { $0.id == a }?.played == 1)
    }

    @Test func matchScopeExcludesOtherGamesAndAbsentPlayers() {
        let matchID = UUID()
        let first = round(gameID: matchID)
        let other = round(ranks: [3, 1, 2])
        let entries = GameStandings.leaderboard([first, other], kind: .timeIt, gameID: matchID)
        #expect(entries.first { $0.id == a }?.wins == 1)
        #expect(entries.first { $0.id == b }?.wins == 0)
        #expect(GameStandings.headToHead([first], kind: .timeIt, playerID: UUID()).isEmpty)
    }

    @Test func timeItAdapterKeepsTiesMeasurementsAndForfeits() throws {
        let players = [a, b, c].map { GamePlayer(id: $0, displayName: "Rider", isConnected: true) }
        let round = TimeItRound(id: UUID(), gameID: UUID(), targetSeconds: 1, players: players)
        let attempts = zip([a, b, c], [900, 1100, nil] as [Int?]).map {
            TimingAttempt(gameID: round.gameID, roundID: round.id, playerID: $0.0, elapsedMilliseconds: $0.1)
        }
        let outcome = try TimeItRules.outcome(round: round, attempts: attempts, hostID: a)
        let saved = outcome.completedRound()
        #expect(saved.players.map(\.placement) == [1, 1, nil])
        #expect(saved.players[0].measurements["errorMilliseconds"] == 100)
        #expect(saved.players[2].measurements.isEmpty)
    }

    @Test func atomicPersistenceSurvivesReopeningAndRejectsConflicts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "results.json")
        let store = GameResultsStore(url: url)
        let value = round()
        try await store.record(value)
        try await store.record(value)
        let conflict = CompletedRound(gameKind: value.gameKind, gameID: value.gameID, roundID: value.roundID,
                                      players: round(ranks: [3, 2, 1]).players)
        await #expect(throws: GameResultsError.conflictingRound) { try await store.record(conflict) }
        #expect(try await GameResultsStore(url: url).rounds() == [value])
    }

    @Test func corruptAndFutureStoresAreNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "results.json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        await #expect(throws: (any Error).self) { try await GameResultsStore(url: url).record(round()) }
        #expect(try Data(contentsOf: url) == corrupt)
        let future = Data("{\"version\":2,\"rounds\":[]}".utf8)
        try future.write(to: url)
        await #expect(throws: GameResultsError.unsupportedVersion) { try await GameResultsStore(url: url).record(round()) }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test func invalidPlacementsDoNotCommit() async throws {
        let store = GameResultsStore()
        await #expect(throws: GameResultsError.invalidRound) { try await store.record(round(ranks: [0, 1, 2])) }
        #expect(try await store.rounds().isEmpty)
    }

    @Test(arguments: [false, true]) func guestSavesVerifiedResultsBeforeAcknowledgingAndRetriesStorage(_ failFirstSave: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appending(path: "blocked")
        if failFirstSave { try Data("blocks directory creation".utf8).write(to: parent) }
        let store = GameResultsStore(url: parent.appending(path: "results.json"))
        let transport = FakeActivityTransport()
        let identity = PeerIdentity.make(), host = PeerIdentity.make()
        let coordinator = ActivityCoordinator(transport: transport, advertising: FakeActivityAdvertising())
        let session = GameSession(identity: identity, coordinator: coordinator, clock: ManualSessionClock(), resultsStore: store)
        let lobby = GameLobby(id: UUID(), kind: .timeIt, hostPeerID: host.id, hostDisplayName: "Host", createdAt: Date())
        _ = try await session.join(DiscoveredGame(lobby: lobby, playerCount: 1, isJoinable: true))
        _ = await transport.connect(ConnectedPeer(id: host.id, displayName: "Host", capabilities: [], activity: .game(lobby)))
        let round = TimeItRound(id: UUID(), gameID: lobby.id, targetSeconds: 6,
            players: [GamePlayer(id: host.id, displayName: "Host", isConnected: true),
                      GamePlayer(id: identity.id, displayName: "Guest", isConnected: true)])
        func deliver(_ event: GameEvent) async {
            await transport.emit(.message(PeerEnvelope(senderID: host.id, sequence: 1,
                body: .game(GamePacket(gameID: lobby.id, event: event)))))
        }
        await deliver(.prepare(round))
        await deliver(.start(round.id))
        await session.markRunning(roundID: round.id)
        try await session.submit(roundID: round.id, elapsedMilliseconds: 6000)
        let attempts = [TimingAttempt(gameID: lobby.id, roundID: round.id, playerID: host.id, elapsedMilliseconds: 6001),
                        TimingAttempt(gameID: lobby.id, roundID: round.id, playerID: identity.id, elapsedMilliseconds: 6000)]
        let valid = try TimeItRules.outcome(round: round, attempts: attempts, hostID: host.id)
        await deliver(.result(valid))
        if failFirstSave {
            #expect(await session.currentSnapshot().error?.contains("could not be saved") == true)
            let sent = await transport.sent
            #expect(!sent.contains { if case .game(let packet) = $0.1, case .resultAck = packet.event { return true }; return false })
            try FileManager.default.removeItem(at: parent)
            await deliver(.result(valid))
        }
        #expect(try await store.rounds() == [valid.completedRound()])
        #expect(await session.currentSnapshot().error == nil)
        let sent = await transport.sent
        #expect(sent.contains { if case .game(let packet) = $0.1, case .resultAck(round.id) = packet.event { return true }; return false })
        await deliver(.result(valid))
        #expect(try await store.rounds().count == 1)
        await session.leave()
    }
}
