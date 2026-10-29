import Foundation

enum TriviaError: Error, Equatable { case invalidRound, invalidAnswer, conflict, notReady, gameFull }

struct TriviaCard: Codable, Equatable, Sendable {
    let questionID: Int
    let optionOrder: [Int]
    var question: TriviaQuestion? { TriviaQuestionBank.question(questionID) }
}

struct TriviaRound: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let gameID: UUID
    let bankVersion: Int
    let players: [GamePlayer]
    let cards: [TriviaCard]
}

struct TriviaAnswer: Codable, Equatable, Sendable {
    let roundID: UUID
    let questionIndex: Int
    let playerID: UUID
    let option: Int? // Original bank option ID, independent of its displayed A–D position.
}

struct TriviaQuestionResult: Codable, Equatable, Sendable {
    let roundID: UUID
    let questionIndex: Int
    let answers: [TriviaAnswer]
}

struct TriviaOutcome: Codable, Equatable, Sendable {
    let round: TriviaRound
    let questions: [TriviaQuestionResult]
    let departedPlayerIDs: Set<UUID>

    func score(_ playerID: UUID) -> Int {
        questions.filter { result in
            guard round.cards.indices.contains(result.questionIndex),
                  let correct = round.cards[result.questionIndex].question?.correctOption else { return false }
            return result.answers.contains { $0.playerID == playerID && $0.option == correct }
        }.count
    }

    func completedRound() -> CompletedRound {
        let eligible = round.players.filter { !departedPlayerIDs.contains($0.id) }
        let players = round.players.map { player in
            let score = score(player.id)
            return PlayerRoundResult(playerID: player.id, displayName: player.displayName,
                placement: departedPlayerIDs.contains(player.id) ? nil : 1 + eligible.filter { self.score($0.id) > score }.count,
                measurements: ["correctAnswers": score, "questionCount": round.cards.count])
        }
        return CompletedRound(gameKind: .subwayTrivia, gameID: round.gameID, roundID: round.id, players: players)
    }
}

enum TriviaPhase: String, Sendable { case idle, lobby, preparing, answering, review, results, ended }

struct TriviaSnapshot: Equatable, Sendable {
    var lobby: GameLobby?
    var players: [GamePlayer] = []
    var phase: TriviaPhase = .idle
    var round: TriviaRound?
    var questionIndex = 0
    var localAnswer: TriviaAnswer?
    var answeredPlayerIDs: Set<UUID> = []
    var questionResults: [TriviaQuestionResult] = []
    var outcome: TriviaOutcome?
    var error: String?
    var awaitingResultAcks = false
    var waitingForQuestionHistory = false

    var card: TriviaCard? {
        guard let round, round.cards.indices.contains(questionIndex) else { return nil }
        return round.cards[questionIndex]
    }
    var canStart: Bool {
        (phase == .lobby || phase == .results) && !awaitingResultAcks && !waitingForQuestionHistory
            && players.count >= 2 && players.allSatisfy(\.isConnected)
    }
}

enum TriviaEvent: Codable, Equatable, Sendable {
    case history(TriviaQuestionHistory)
    case roster([GamePlayer])
    case prepare(TriviaRound)
    case prepared(UUID)
    case question(roundID: UUID, index: Int)
    case answer(TriviaAnswer)
    case progress(roundID: UUID, index: Int, players: Set<UUID>)
    case reveal(TriviaQuestionResult)
    case reviewAck(roundID: UUID, index: Int)
    case result(TriviaOutcome)
    case resultAck(UUID)
    case ended(String)
    case left
}

enum TriviaRules {
    static let questionCount = 5
    static let answerSeconds = 15

    static func makeRound(gameID: UUID, players: [GamePlayer],
                          histories: [UUID: TriviaQuestionHistory] = [:]) -> TriviaRound {
        var working = players.map { histories[$0.id] ?? TriviaQuestionHistory() }
        var cards: [TriviaCard] = []
        for _ in 0..<questionCount {
            // Prefer unseen for everyone; different groups can have no common unseen question.
            for index in working.indices where working[index].seen.count == TriviaQuestionBank.questions.count {
                working[index].seen = []
            }
            let available = TriviaQuestionBank.questions.shuffled().filter { question in
                !cards.contains { $0.questionID == question.id }
            }
            let selected = available.min { a, b in
                working.filter { $0.seen.contains(a.id) }.count < working.filter { $0.seen.contains(b.id) }.count
            }
            guard let selected else { break }
            cards.append(TriviaCard(questionID: selected.id, optionOrder: [0, 1, 2, 3].shuffled()))
            for index in working.indices { working[index].record(selected.id) }
        }
        return TriviaRound(id: UUID(), gameID: gameID, bankVersion: TriviaQuestionBank.version, players: players, cards: cards)
    }

    static func validate(_ round: TriviaRound, hostID: UUID) throws {
        let ids = round.players.map(\.id)
        guard round.bankVersion == TriviaQuestionBank.version, round.cards.count == questionCount,
              Set(round.cards.map(\.questionID)).count == questionCount,
              (2...GameLobby.maximumPlayers).contains(ids.count), Set(ids).count == ids.count,
              ids.contains(hostID), round.players.allSatisfy(\.isConnected),
              round.cards.allSatisfy({ $0.question != nil && $0.optionOrder.count == 4 && Set($0.optionOrder) == Set(0...3) }) else {
            throw TriviaError.invalidRound
        }
    }

    static func validate(_ result: TriviaQuestionResult, round: TriviaRound) throws {
        guard result.roundID == round.id, round.cards.indices.contains(result.questionIndex),
              result.answers.count == round.players.count,
              Set(result.answers.map(\.playerID)) == Set(round.players.map(\.id)),
              result.answers.allSatisfy({ $0.roundID == round.id && $0.questionIndex == result.questionIndex &&
                  ($0.option.map { (0...3).contains($0) } ?? true) }) else { throw TriviaError.invalidAnswer }
    }

    static func validate(_ outcome: TriviaOutcome, hostID: UUID) throws {
        try validate(outcome.round, hostID: hostID)
        guard outcome.questions.map(\.questionIndex) == Array(0..<questionCount),
              outcome.departedPlayerIDs.isSubset(of: Set(outcome.round.players.map(\.id))),
              !outcome.departedPlayerIDs.contains(hostID) else { throw TriviaError.invalidRound }
        for result in outcome.questions { try validate(result, round: outcome.round) }
    }
}

// Pure authoritative scoring state; sessions supply deadlines and network delivery.
struct TriviaMatch: Sendable {
    let round: TriviaRound
    private(set) var phase = TriviaPhase.preparing
    private(set) var questionIndex = 0
    private(set) var answers: [UUID: TriviaAnswer] = [:]
    private(set) var results: [TriviaQuestionResult] = []
    private(set) var departed: Set<UUID> = []
    private(set) var outcome: TriviaOutcome?

    mutating func beginQuestion() throws {
        guard phase == .preparing || phase == .review, results.count < round.cards.count else { throw TriviaError.notReady }
        questionIndex = results.count
        answers = [:]
        phase = .answering
        for id in departed { try record(TriviaAnswer(roundID: round.id, questionIndex: questionIndex, playerID: id, option: nil)) }
    }

    mutating func record(_ answer: TriviaAnswer) throws {
        guard phase == .answering, answer.roundID == round.id, answer.questionIndex == questionIndex,
              round.players.contains(where: { $0.id == answer.playerID }),
              answer.option.map({ (0...3).contains($0) }) ?? true else { throw TriviaError.invalidAnswer }
        if let existing = answers[answer.playerID] {
            guard existing == answer else { throw TriviaError.conflict }
            return
        }
        answers[answer.playerID] = answer
    }

    mutating func depart(_ id: UUID) {
        guard phase != .results, round.players.contains(where: { $0.id == id }) else { return }
        departed.insert(id)
        if phase == .answering, answers[id] == nil {
            answers[id] = TriviaAnswer(roundID: round.id, questionIndex: questionIndex, playerID: id, option: nil)
        }
    }

    mutating func reveal() throws -> TriviaQuestionResult {
        guard phase == .answering, answers.count == round.players.count else { throw TriviaError.notReady }
        let result = TriviaQuestionResult(roundID: round.id, questionIndex: questionIndex,
            answers: round.players.compactMap { answers[$0.id] })
        try TriviaRules.validate(result, round: round)
        results.append(result)
        phase = .review
        return result
    }

    mutating func finish() throws -> TriviaOutcome {
        guard phase == .review, results.count == round.cards.count else { throw TriviaError.notReady }
        let value = TriviaOutcome(round: round, questions: results, departedPlayerIDs: departed)
        phase = .results
        outcome = value
        return value
    }
}
