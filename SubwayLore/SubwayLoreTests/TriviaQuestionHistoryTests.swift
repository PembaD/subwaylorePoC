import Foundation
import Testing
@testable import SubwayLore

struct TriviaQuestionHistoryTests {
    private func players() -> [GamePlayer] {
        [GamePlayer(id: UUID(), displayName: "A", isConnected: true),
         GamePlayer(id: UUID(), displayName: "B", isConnected: true)]
    }

    @Test func stablePlayersExhaustOneHundredQuestionsBeforeAnyRepeat() {
        let players = players()
        var histories: [UUID: TriviaQuestionHistory] = [:]
        var allSeen: Set<Int> = []
        for _ in 0..<20 {
            let round = TriviaRules.makeRound(gameID: UUID(), players: players, histories: histories)
            #expect(round.cards.count == 5)
            let ids = Set(round.cards.map(\.questionID))
            #expect(allSeen.isDisjoint(with: ids))
            allSeen.formUnion(ids)
            for player in players {
                var history = histories[player.id] ?? TriviaQuestionHistory()
                for card in round.cards { history.record(card.questionID) }
                histories[player.id] = history
            }
        }
        #expect(allSeen.count == 100)
        let next = TriviaRules.makeRound(gameID: UUID(), players: players, histories: histories)
        #expect(next.cards.count == 5)
        #expect(Set(next.cards.map(\.questionID)).count == 5)
    }

    @Test func mixedPlayersGetCommonUnseenQuestionsWheneverPossible() {
        let players = players()
        let histories = [players[0].id: TriviaQuestionHistory(seen: Set(1...40)),
                         players[1].id: TriviaQuestionHistory(seen: Set(41...80))]
        let round = TriviaRules.makeRound(gameID: UUID(), players: players, histories: histories)
        #expect(round.cards.allSatisfy { (81...100).contains($0.questionID) })
    }

    @Test func incompatibleHistoriesMinimizeRepeatCountAndStillGiveFiveDistinctQuestions() {
        let players = players()
        let histories = [players[0].id: TriviaQuestionHistory(seen: Set(1...50)),
                         players[1].id: TriviaQuestionHistory(seen: Set(51...100))]
        let round = TriviaRules.makeRound(gameID: UUID(), players: players, histories: histories)
        #expect(round.cards.count == 5)
        #expect(Set(round.cards.map(\.questionID)).count == 5)
        for card in round.cards {
            #expect(histories.values.filter { $0.seen.contains(card.questionID) }.count == 1)
        }
    }

    @Test func cycleBoundaryUsesRemainingUnseenQuestionsBeforeStartingFresh() {
        let players = players()
        let history = TriviaQuestionHistory(seen: Set(1...98))
        let round = TriviaRules.makeRound(gameID: UUID(), players: players,
            histories: [players[0].id: history, players[1].id: history])
        #expect(Set(round.cards.prefix(2).map(\.questionID)) == [99, 100])
        #expect(Set(round.cards.map(\.questionID)).count == 5)
    }

    @Test func historyPersistsAcrossRestartAndIsKeyedByPlayerIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.json")
        let player = UUID()
        let store = TriviaQuestionHistoryStore(url: url)
        _ = try await store.record(1, for: player)
        _ = try await store.record(2, for: player)
        let reopened = TriviaQuestionHistoryStore(url: url)
        #expect(try await reopened.history(for: player).seen == [1, 2])
        #expect(try await reopened.history(for: UUID()).seen.isEmpty)
        await #expect(throws: TriviaError.invalidRound) { try await reopened.record(101, for: player) }
        #expect(try await reopened.history(for: player).seen == [1, 2])
    }
}
