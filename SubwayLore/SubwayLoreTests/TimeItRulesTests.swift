import Foundation
import Testing
@testable import SubwayLore

struct TimeItRulesTests {
    private func lobby() -> GameLobby {
        GameLobby(id: UUID(), kind: .timeIt, hostPeerID: UUID(), hostDisplayName: "Alex", createdAt: Date())
    }
    private func match(guests: Int = 2) throws -> TimeItMatch {
        var match = TimeItMatch(lobby: lobby())
        for index in 0..<guests { try match.connect(UUID(), name: "Guest \(index)") }
        return match
    }
    private func begin(_ match: inout TimeItMatch, target: Int = 5) throws -> TimeItRound {
        let round = try match.prepare(target: target)
        for player in round.players where player.id != match.lobby.hostPeerID {
            _ = match.acknowledge(player.id, roundID: round.id)
        }
        match.markRunning()
        return round
    }
    private func attempt(_ round: TimeItRound, _ player: UUID, _ milliseconds: Int?) -> TimingAttempt {
        TimingAttempt(gameID: round.gameID, roundID: round.id, playerID: player, elapsedMilliseconds: milliseconds)
    }

    @Test func exactNameAndEightPlayerCapacityIncludeCreator() throws {
        #expect(GameKind.timeIt.title == "Time |t!")
        var match = try match(guests: 7)
        #expect(match.players.count == 8)
        #expect(throws: TimeItError.gameFull) { try match.reserve(UUID()) }
        let existing = match.players[1].id
        try match.reserve(existing)
        #expect(match.players.count == 8)
    }

    @Test func joiningDoesNotStartAndUnconnectedSeatsBlockStart() throws {
        var match = TimeItMatch(lobby: lobby())
        #expect(throws: TimeItError.invalidRound) { try match.prepare(target: 5) }
        let guest = UUID()
        try match.reserve(guest)
        #expect(match.phase == .lobby)
        #expect(throws: TimeItError.invalidRound) { try match.prepare(target: 5) }
        try match.connect(guest, name: "Guest")
        #expect(match.phase == .lobby)
        _ = try match.prepare(target: 5)
        #expect(match.phase == .preparing)
    }

    @Test(arguments: [1, 6]) func targetBoundariesAreAccepted(_ target: Int) throws {
        var match = try match()
        #expect(try match.prepare(target: target).targetSeconds == target)
    }

    @Test(arguments: [0, 7]) func invalidTargetsAreRejected(_ target: Int) throws {
        var match = try match()
        #expect(throws: TimeItError.invalidRound) { try match.prepare(target: target) }
        #expect(match.phase == .lobby)
    }

    @Test func rosterLocksAndCountdownRequiresEveryAcknowledgement() throws {
        var match = try match()
        let round = try match.prepare(target: 5)
        let guests = round.players.filter { $0.id != match.lobby.hostPeerID }
        #expect(throws: TimeItError.roundInProgress) { try match.reserve(UUID()) }
        let unknown = match.acknowledge(UUID(), roundID: round.id)
        let stale = match.acknowledge(guests[0].id, roundID: UUID())
        let first = match.acknowledge(guests[0].id, roundID: round.id)
        let duplicate = match.acknowledge(guests[0].id, roundID: round.id)
        let last = match.acknowledge(guests[1].id, roundID: round.id)
        #expect(!unknown)
        #expect(!stale)
        #expect(!first)
        #expect(!duplicate)
        #expect(last)
        #expect(match.phase == .countdown)
        let repeatedStart = match.acknowledge(guests[1].id, roundID: round.id)
        #expect(!repeatedStart)
        let early = attempt(round, round.players[0].id, 5000)
        #expect(throws: TimeItError.invalidAttempt) { try match.record(early) }
    }

    @Test func closestWinsAndSameBestErrorsProduceJointWinners() throws {
        var match = try match()
        let round = try begin(&match)
        let a = round.players[0].id, b = round.players[1].id, c = round.players[2].id
        try match.record(attempt(round, a, 4900))
        try match.record(attempt(round, b, 5100))
        try match.record(attempt(round, c, 4500))
        let result = try match.finish()
        #expect(result.winnerIDs == [a, b])
        #expect(result.attempts.last?.playerID == c)
        #expect(match.phase == .results)
    }

    @Test func disconnectForfeitsOnlyMissingAttemptAndOthersKeepPlaying() throws {
        var match = try match()
        let round = try begin(&match)
        let a = round.players[0].id, b = round.players[1].id, c = round.players[2].id
        let submitted = attempt(round, b, 5001)
        try match.record(submitted)
        match.remove(b)
        match.remove(c)
        #expect(match.attempts[b] == submitted)
        #expect(match.attempts[c]?.elapsedMilliseconds == nil)
        #expect(match.phase == .running)
        try match.record(attempt(round, a, 5100))
        #expect(try match.finish().winnerIDs == [b])
    }

    @Test func allForfeitsProduceNoWinner() throws {
        var match = try match()
        let round = try begin(&match)
        for player in round.players { try match.record(attempt(round, player.id, nil)) }
        #expect(try match.finish().winnerIDs.isEmpty)
    }

    @Test func duplicateAttemptsAreIdempotentAndConflictsCannotOverwrite() throws {
        var match = try match()
        let round = try begin(&match)
        let player = round.players[0].id
        let first = attempt(round, player, 5000)
        try match.record(first)
        try match.record(first)
        #expect(match.attempts.count == 1)
        #expect(throws: TimeItError.conflictingAttempt) { try match.record(attempt(round, player, 4999)) }
        #expect(match.attempts[player] == first)
        #expect(throws: TimeItError.invalidAttempt) { try match.record(attempt(round, UUID(), 5000)) }
        #expect(throws: TimeItError.invalidAttempt) { try match.record(attempt(round, round.players[1].id, -1)) }
        #expect(throws: TimeItError.invalidAttempt) { try match.record(attempt(round, round.players[1].id, 20_001)) }
    }

    @Test func newRoundsHaveNewIDsAndIgnoreOldAttempts() throws {
        var match = try match()
        let first = try begin(&match)
        for player in first.players { try match.record(attempt(first, player.id, 5000)) }
        _ = try match.finish()
        let next = try begin(&match, target: 3)
        #expect(first.id != next.id)
        #expect(match.attempts.isEmpty)
        #expect(throws: TimeItError.invalidAttempt) { try match.record(attempt(first, first.players[0].id, 5000)) }
    }

    @Test func gameTransportIsStarScopedWhileChatKeepsItsMeshLimit() {
        let game = lobby()
        let guest = UUID(), otherGuest = UUID()
        let scope = ActivityDescriptor.game(game)
        #expect(scope.remoteLimit(for: game.hostPeerID) == 7)
        #expect(scope.remoteLimit(for: guest) == 1)
        #expect(scope.allows(peerID: guest, localID: game.hostPeerID))
        #expect(scope.allows(peerID: game.hostPeerID, localID: guest))
        #expect(!scope.allows(peerID: otherGuest, localID: guest))
        let chat = Chat(id: game.id, title: "Chat", createdAt: game.createdAt, createdByPeerID: game.hostPeerID)
        #expect(!scope.matches(.chat(chat)))
        #expect(ActivityDescriptor.chat(chat).remoteLimit(for: guest) == 8)
    }

    @Test func gameProtocolRoundTripsAndCarriesSeparateScope() throws {
        var match = try match()
        let round = try begin(&match)
        let record = attempt(round, round.players[0].id, 5000)
        let events: [GameEvent] = [.roster(round.players), .prepare(round), .prepared(round.id), .start(round.id),
                                  .attempt(record), .progress(roundID: round.id, completed: [record.playerID]),
                                  .resultAck(round.id), .roundAborted(round.id), .ended("Creator left"), .left]
        for event in events {
            let body = PeerMessage.game(GamePacket(gameID: round.gameID, event: event))
            let envelope = PeerEnvelope(senderID: UUID(), sequence: 1, body: body)
            #expect(try JSONDecoder().decode(PeerEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
            #expect(body.scopeID == round.gameID)
            #expect(body.scopeKind == "game")
            #expect(body.chatID == nil)
        }
        for player in round.players { try match.record(attempt(round, player.id, 5000)) }
        let outcome = try match.finish()
        let result = PeerMessage.game(GamePacket(gameID: round.gameID, event: .result(outcome)))
        #expect(try JSONDecoder().decode(PeerMessage.self, from: JSONEncoder().encode(result)) == result)
        let join = PeerMessage.joinActivityRequest(ActivityJoinRequest(activity: .game(match.lobby), requestID: UUID()))
        #expect(try JSONDecoder().decode(PeerMessage.self, from: JSONEncoder().encode(join)) == join)
    }

    @Test func liveGamesAcceptOnlyCreatorAdvertisementsWithValidCounts() {
        let game = lobby()
        let host = DiscoveredPeer(id: "host", peerID: game.hostPeerID, displayName: "Alex", domain: "local",
            gameID: game.id, gameHostID: game.hostPeerID, gameKind: "timeIt", gamePlayerCount: 3, gameIsJoinable: true)
        let guest = DiscoveredPeer(id: "guest", peerID: UUID(), displayName: "Guest", domain: "local",
            gameID: game.id, gameHostID: game.hostPeerID, gameKind: "timeIt", gamePlayerCount: 3, gameIsJoinable: true)
        var invalid = host
        invalid.gamePlayerCount = 9
        #expect(DiscoveredGame.aggregate([host, guest]).count == 1)
        #expect(DiscoveredGame.aggregate([guest, invalid]).isEmpty)
        #expect(DiscoveredGame.aggregate([host]).first?.playerCount == 3)
    }

    @Test func sharedAdmissionRoundTripsForBothActivityKinds() throws {
        let game = lobby()
        let chat = Chat.make(for: PeerIdentity.make())
        for activity in [ActivityDescriptor.game(game), .chat(chat)] {
            let requestID = UUID()
            let messages: [PeerMessage] = [
                .joinActivityRequest(ActivityJoinRequest(activity: activity, requestID: requestID)),
                .joinActivityAccepted(ActivityJoinAccepted(activity: activity, requestID: requestID)),
                .joinActivityRejected(ActivityJoinRejected(requestID: requestID, reason: "Not available"))
            ]
            for message in messages {
                #expect(try JSONDecoder().decode(PeerMessage.self, from: JSONEncoder().encode(message)) == message)
            }
        }
    }
}
