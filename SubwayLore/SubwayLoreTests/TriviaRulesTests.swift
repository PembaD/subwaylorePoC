import Foundation
import Testing
@testable import SubwayLore

struct TriviaRulesTests {
    private func players(_ count: Int = 3) -> [GamePlayer] {
        (0..<count).map { GamePlayer(id: UUID(), displayName: "Rider \($0)", isConnected: true) }
    }

    @Test func bankContainsExactlyOneHundredCompleteFourChoiceQuestions() {
        let bank = TriviaQuestionBank.questions
        #expect(bank.count == 100)
        #expect(bank.map(\.id) == Array(1...100))
        #expect(Set(bank.map(\.prompt)).count == 100)
        #expect(Set(bank.map(\.category)).count == 5)
        #expect(bank.allSatisfy { $0.choices.count == 4 && Set($0.choices).count == 4 && !$0.prompt.isEmpty })
        #expect(bank.allSatisfy { $0.choices.indices.contains($0.correctOption) && $0.choices.allSatisfy { !$0.isEmpty } })
        #expect(TriviaQuestionBank.question(100)?.choices.first == "WTC Cortlandt")
    }

    @Test func roundHasFiveUniqueQuestionsAndSharedChoiceOrders() throws {
        let players = players(8)
        let round = TriviaRules.makeRound(gameID: UUID(), players: players)
        try TriviaRules.validate(round, hostID: players[0].id)
        #expect(round.cards.count == TriviaRules.questionCount)
        #expect(Set(round.cards.map(\.questionID)).count == TriviaRules.questionCount)
        #expect(round.cards.allSatisfy { Set($0.optionOrder) == Set(0...3) })
        let decoded = try JSONDecoder().decode(TriviaRound.self, from: JSONEncoder().encode(round))
        #expect(decoded == round)
    }

    @Test func invalidBanksRostersAndChoiceOrdersAreRejected() throws {
        let players = players()
        let valid = TriviaRules.makeRound(gameID: UUID(), players: players)
        for version in [0, 99] {
            let value = TriviaRound(id: valid.id, gameID: valid.gameID, bankVersion: version, players: players, cards: valid.cards)
            #expect(throws: TriviaError.invalidRound) { try TriviaRules.validate(value, hostID: players[0].id) }
        }
        var cards = valid.cards
        cards[0] = TriviaCard(questionID: cards[0].questionID, optionOrder: [0, 0, 2, 3])
        let bad = TriviaRound(id: valid.id, gameID: valid.gameID, bankVersion: 1, players: players, cards: cards)
        #expect(throws: TriviaError.invalidRound) { try TriviaRules.validate(bad, hostID: players[0].id) }
        #expect(throws: TriviaError.invalidRound) { try TriviaRules.validate(valid, hostID: UUID()) }
        let tooMany = TriviaRules.makeRound(gameID: UUID(), players: self.players(9))
        #expect(throws: TriviaError.invalidRound) { try TriviaRules.validate(tooMany, hostID: tooMany.players[0].id) }
    }

    @Test func firstAnswerIsImmutableAndStaleQuestionsCannotOverwriteIt() throws {
        let players = players()
        let round = TriviaRules.makeRound(gameID: UUID(), players: players)
        var match = TriviaMatch(round: round)
        try match.beginQuestion()
        let first = TriviaAnswer(roundID: round.id, questionIndex: 0, playerID: players[0].id, option: 0)
        try match.record(first)
        try match.record(first)
        #expect(match.answers.count == 1)
        #expect(throws: TriviaError.conflict) {
            try match.record(TriviaAnswer(roundID: round.id, questionIndex: 0, playerID: players[0].id, option: 1))
        }
        #expect(throws: TriviaError.invalidAnswer) {
            try match.record(TriviaAnswer(roundID: round.id, questionIndex: 1, playerID: players[1].id, option: 0))
        }
        #expect(throws: TriviaError.invalidAnswer) {
            try match.record(TriviaAnswer(roundID: round.id, questionIndex: 0, playerID: players[1].id, option: 4))
        }
        #expect(throws: TriviaError.notReady) { try match.reveal() }
        #expect(throws: TriviaError.notReady) { try match.finish() }
    }

    @Test func fullQuizScoresTiesAndConvertsToOneLeaderboardRecord() throws {
        let players = players()
        let round = TriviaRules.makeRound(gameID: UUID(), players: players)
        var match = TriviaMatch(round: round)
        for index in 0..<TriviaRules.questionCount {
            try match.beginQuestion()
            for (position, player) in players.enumerated() {
                try match.record(TriviaAnswer(roundID: round.id, questionIndex: index, playerID: player.id,
                    option: position < 2 ? 0 : nil))
            }
            _ = try match.reveal()
        }
        let outcome = try match.finish()
        try TriviaRules.validate(outcome, hostID: players[0].id)
        #expect(outcome.score(players[0].id) == TriviaRules.questionCount)
        #expect(outcome.score(players[2].id) == 0)
        let saved = outcome.completedRound()
        #expect(saved.gameKind == .subwayTrivia)
        #expect(saved.players.map(\.placement) == [1, 1, 3])
        let entries = GameStandings.leaderboard([saved, saved], kind: .subwayTrivia)
        #expect(entries.allSatisfy { $0.played == 1 })
        #expect(entries.filter { $0.wins == 1 }.count == 2)
        #expect(GameStandings.leaderboard([saved], kind: .timeIt).isEmpty)
    }

    @Test func departureKeepsAcceptedAnswerButForfeitsRemainingQuestionsAndMatch() throws {
        let players = players(2)
        let round = TriviaRules.makeRound(gameID: UUID(), players: players)
        var match = TriviaMatch(round: round)
        try match.beginQuestion()
        try match.record(TriviaAnswer(roundID: round.id, questionIndex: 0, playerID: players[1].id, option: 0))
        match.depart(players[1].id)
        #expect(match.answers[players[1].id]?.option == 0)
        for index in 0..<TriviaRules.questionCount {
            if index > 0 { try match.beginQuestion() }
            try match.record(TriviaAnswer(roundID: round.id, questionIndex: index, playerID: players[0].id, option: 1))
            _ = try match.reveal()
        }
        let result = try match.finish()
        #expect(result.score(players[1].id) == 1)
        #expect(result.completedRound().players.map(\.placement) == [1, nil])
        #expect(GameStandings.headToHead([result.completedRound()], kind: .subwayTrivia,
            playerID: players[0].id).first?.wins == 1)
    }

    @Test func discoveryDistinguishesBothGamesAndRejectsUnknownKinds() {
        let host = UUID()
        let a = DiscoveredPeer(id: "a", peerID: host, displayName: "Host", domain: "local", gameID: UUID(),
            gameHostID: host, gameKind: "subwayTrivia", gamePlayerCount: 2, gameIsJoinable: true)
        var unknown = a
        unknown.gameKind = "unknown"
        #expect(DiscoveredGame.aggregate([a]).first?.lobby.kind == .subwayTrivia)
        #expect(DiscoveredGame.aggregate([unknown]).isEmpty)
        #expect(GameKind.subwayTrivia.title == "Subway Trivia")
    }

    @Test func everyTriviaEventRoundTripsAndEightPlayerResultsFitAFrame() throws {
        let players = players(8)
        let round = TriviaRules.makeRound(gameID: UUID(), players: players)
        var match = TriviaMatch(round: round)
        for index in 0..<TriviaRules.questionCount {
            try match.beginQuestion()
            for player in players {
                try match.record(TriviaAnswer(roundID: round.id, questionIndex: index, playerID: player.id, option: index % 4))
            }
            _ = try match.reveal()
        }
        let outcome = try match.finish()
        let events: [TriviaEvent] = [
            .history(TriviaQuestionHistory(seen: [1, 2, 3])),
            .roster(players), .prepare(round), .prepared(round.id), .question(roundID: round.id, index: 0),
            .answer(outcome.questions[0].answers[0]), .progress(roundID: round.id, index: 0, players: [players[0].id]),
            .reveal(outcome.questions[0]), .reviewAck(roundID: round.id, index: 0), .result(outcome),
            .resultAck(round.id), .ended("Creator left"), .left
        ]
        for event in events {
            let body = PeerMessage.game(GamePacket(gameID: round.gameID, event: .trivia(event)))
            let envelope = PeerEnvelope(senderID: players[0].id, sequence: 1, body: body)
            let data = try JSONEncoder().encode(envelope)
            let framed = try MessageFramer.frame(data)
            var decoder = FrameDecoder()
            #expect(try decoder.append(framed) == [data])
            #expect(try JSONDecoder().decode(PeerEnvelope.self, from: data) == envelope)
            #expect(body.scopeID == round.gameID)
            #expect(body.scopeKind == "game")
        }
    }
}
