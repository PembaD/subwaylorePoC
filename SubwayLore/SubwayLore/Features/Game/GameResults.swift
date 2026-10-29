import Foundation

// Games supply placements; standings and head-to-head records do not need to know their rules.
struct PlayerRoundResult: Codable, Equatable, Sendable {
    let playerID: UUID
    let displayName: String
    let placement: Int? // nil means did not finish
    let measurements: [String: Int]
}

struct CompletedRound: Codable, Equatable, Sendable {
    struct Key: Hashable, Sendable {
        let gameKind: GameKind
        let gameID: UUID
        let roundID: UUID
    }
    let gameKind: GameKind
    let gameID: UUID
    let roundID: UUID
    let players: [PlayerRoundResult]
    var key: Key { Key(gameKind: gameKind, gameID: gameID, roundID: roundID) }
}

extension RoundOutcome {
    func completedRound() -> CompletedRound {
        let target = round.targetSeconds * 1000
        let errors = attempts.compactMap { $0.elapsedMilliseconds.map { abs($0 - target) } }
        let players = round.players.map { player in
            let elapsed = attempts.first { $0.playerID == player.id }?.elapsedMilliseconds
            let error = elapsed.map { abs($0 - target) }
            return PlayerRoundResult(playerID: player.id, displayName: player.displayName,
                placement: error.map { value in 1 + errors.filter { $0 < value }.count },
                measurements: elapsed.map { ["elapsedMilliseconds": $0, "errorMilliseconds": abs($0 - target)] } ?? [:])
        }
        return CompletedRound(gameKind: .timeIt, gameID: round.gameID, roundID: round.id, players: players)
    }
}

struct LeaderboardEntry: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var played = 0
    var wins = 0
    var sharedWins = 0
}

struct HeadToHeadRecord: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var wins = 0
    var draws = 0
    var losses = 0
}

enum GameStandings {
    static func leaderboard(_ rounds: [CompletedRound], kind: GameKind, gameID: UUID? = nil) -> [LeaderboardEntry] {
        var entries: [UUID: LeaderboardEntry] = [:]
        for round in unique(rounds, kind: kind, gameID: gameID) {
            let shared = round.players.filter { $0.placement == 1 }.count > 1
            for player in round.players {
                var entry = entries[player.playerID] ?? LeaderboardEntry(id: player.playerID, displayName: player.displayName)
                entry.displayName = player.displayName
                entry.played += 1
                if player.placement == 1 { entry.wins += 1; if shared { entry.sharedWins += 1 } }
                entries[player.playerID] = entry
            }
        }
        return entries.values.sorted {
            if $0.wins != $1.wins { return $0.wins > $1.wins }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func headToHead(_ rounds: [CompletedRound], kind: GameKind, playerID: UUID,
                           gameID: UUID? = nil) -> [HeadToHeadRecord] {
        var records: [UUID: HeadToHeadRecord] = [:]
        for round in unique(rounds, kind: kind, gameID: gameID) {
            guard let local = round.players.first(where: { $0.playerID == playerID }) else { continue }
            for other in round.players where other.playerID != playerID {
                // Two forfeits are not a competitive draw.
                guard local.placement != nil || other.placement != nil else { continue }
                var record = records[other.playerID] ?? HeadToHeadRecord(id: other.playerID, displayName: other.displayName)
                record.displayName = other.displayName
                let a = local.placement ?? Int.max, b = other.placement ?? Int.max
                if a < b { record.wins += 1 }
                else if a == b { record.draws += 1 }
                else { record.losses += 1 }
                records[other.playerID] = record
            }
        }
        return records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func unique(_ rounds: [CompletedRound], kind: GameKind, gameID: UUID?) -> [CompletedRound] {
        var seen: Set<CompletedRound.Key> = []
        return rounds.filter {
            $0.gameKind == kind && (gameID == nil || $0.gameID == gameID) && seen.insert($0.key).inserted
        }
    }
}

enum GameResultsError: Error, Equatable { case unsupportedVersion, conflictingRound, invalidRound }

actor GameResultsStore {
    private struct Document: Codable {
        var version = 1
        var rounds: [CompletedRound] = []
    }
    private let url: URL?
    private var document: Document?

    // Sessions can use an isolated memory store; the app supplies a persistent store.
    init(url: URL? = nil) { self.url = url }

    static func persistent() -> GameResultsStore {
        var filename = "game-results-v1.json"
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SUBWAYLORE_TEST_STORE"], let id = UUID(uuidString: value) {
            filename = "game-results-ui-test-\(id).json"
        }
        #endif
        return GameResultsStore(url: URL.applicationSupportDirectory.appending(path: "SubwayLore")
            .appending(path: filename))
    }

    func rounds() throws -> [CompletedRound] { try load().rounds }

    func record(_ round: CompletedRound) throws {
        guard round.players.count >= 2, Set(round.players.map(\.playerID)).count == round.players.count,
              round.players.allSatisfy({ $0.placement.map { (1...round.players.count).contains($0) } ?? true }) else {
            throw GameResultsError.invalidRound
        }
        var updated = try load()
        if let existing = updated.rounds.first(where: { $0.key == round.key }) {
            guard existing == round else { throw GameResultsError.conflictingRound }
            return
        }
        updated.rounds.append(round)
        if let url {
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        document = updated
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
        document = decoded
        return decoded
    }
}
