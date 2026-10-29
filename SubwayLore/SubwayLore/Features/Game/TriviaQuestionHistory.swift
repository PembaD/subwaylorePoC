import Foundation

struct TriviaQuestionHistory: Codable, Equatable, Sendable {
    var bankVersion = TriviaQuestionBank.version
    var seen: Set<Int> = []

    func validate() throws {
        guard bankVersion == TriviaQuestionBank.version,
              seen.isSubset(of: Set(TriviaQuestionBank.questions.map(\.id))) else { throw TriviaError.invalidRound }
    }

    mutating func record(_ questionID: Int) {
        if seen.count == TriviaQuestionBank.questions.count { seen = [] }
        seen.insert(questionID)
    }
}

actor TriviaQuestionHistoryStore {
    private struct Document: Codable {
        var version = 1
        var players: [String: TriviaQuestionHistory] = [:]
    }
    private let url: URL?
    private var document: Document?
    init(url: URL? = nil) { self.url = url }

    static func persistent() -> TriviaQuestionHistoryStore {
        var filename = "trivia-question-history-v1.json"
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SUBWAYLORE_TEST_STORE"], let id = UUID(uuidString: value) {
            filename = "trivia-question-history-ui-test-\(id).json"
        }
        #endif
        return TriviaQuestionHistoryStore(url: URL.applicationSupportDirectory.appending(path: "SubwayLore").appending(path: filename))
    }

    func history(for playerID: UUID) throws -> TriviaQuestionHistory {
        try load().players[playerID.uuidString] ?? TriviaQuestionHistory()
    }

    func record(_ questionID: Int, for playerID: UUID) throws -> TriviaQuestionHistory {
        guard TriviaQuestionBank.question(questionID) != nil else { throw TriviaError.invalidRound }
        var updated = try load()
        var history = updated.players[playerID.uuidString] ?? TriviaQuestionHistory()
        history.record(questionID)
        updated.players[playerID.uuidString] = history
        if let url {
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        document = updated
        return history
    }

    private func load() throws -> Document {
        if let document { return document }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            let empty = Document()
            document = empty
            return empty
        }
        let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard decoded.version == 1 else { throw GameResultsError.unsupportedVersion }
        for history in decoded.players.values { try history.validate() }
        document = decoded
        return decoded
    }
}
