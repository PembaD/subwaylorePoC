import Foundation

struct HelloMessage: Codable, Equatable, Sendable {
    let peerID: UUID
    let displayName: String
    let capabilities: [String]
}

struct HelloAcceptedMessage: Codable, Equatable, Sendable {
    let peerID: UUID
}

struct PingMessage: Codable, Equatable, Sendable {
    let correlationID: UUID
}

struct PongMessage: Codable, Equatable, Sendable {
    let correlationID: UUID
    let originalSentAt: Date
    let receivedAt: Date
}

struct TextMessage: Codable, Equatable, Sendable {
    static let maximumCharacterCount = 1_000

    let text: String

    init(text: String) throws {
        guard !text.isEmpty else {
            throw PeerMessageValidationError.emptyText
        }
        guard text.count <= Self.maximumCharacterCount else {
            throw PeerMessageValidationError.textTooLong(
                actual: text.count,
                maximum: Self.maximumCharacterCount
            )
        }
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(text: container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

struct GoodbyeMessage: Codable, Equatable, Sendable {
    let reason: String?
}

enum PeerMessage: Codable, Equatable, Sendable {
    case hello(HelloMessage)
    case helloAccepted(HelloAcceptedMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case text(TextMessage)
    case goodbye(GoodbyeMessage)
}

enum PeerMessageValidationError: Error, Equatable, Sendable {
    case emptyText
    case textTooLong(actual: Int, maximum: Int)
}
