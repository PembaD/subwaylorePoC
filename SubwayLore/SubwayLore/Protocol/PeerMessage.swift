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
    case joinChatRequest(JoinChatRequest)
    case joinChatAccepted(JoinChatAccepted)
    case joinChatRejected(JoinChatRejected)
    case chatText(ChatMessage)
    case historyInventory(HistoryInventory)
    case historyRequest(HistoryRequest)
    case historyBatch(HistoryBatch)
    case historyComplete(HistoryComplete)
    case historySyncRequest(UUID)

    var chatID: UUID? {
        switch self {
        case .joinChatRequest(let value): value.chatID
        case .joinChatAccepted(let value): value.chat.id
        case .chatText(let value): value.chatID
        case .historyInventory(let value): value.chatID
        case .historyRequest(let value): value.chatID
        case .historyBatch(let value): value.chatID
        case .historyComplete(let value): value.chatID
        case .historySyncRequest(let id): id
        default: nil
        }
    }
}

struct JoinChatRequest: Codable, Equatable, Sendable {
    let chatID: UUID
    let requestID: UUID
}

struct JoinChatAccepted: Codable, Equatable, Sendable {
    let requestID: UUID
    let chat: Chat
}

struct JoinChatRejected: Codable, Equatable, Sendable {
    let requestID: UUID
    let reason: String
}

struct HistoryInventory: Codable, Equatable, Sendable {
    let chatID: UUID
    let requestID: UUID
    let messageIDs: [UUID]
}

struct HistoryRequest: Codable, Equatable, Sendable {
    let chatID: UUID
    let requestID: UUID
    let messageIDs: [UUID]
}

struct HistoryBatch: Codable, Equatable, Sendable {
    let chatID: UUID
    let requestID: UUID
    let messages: [ChatMessage]
}

struct HistoryComplete: Codable, Equatable, Sendable {
    let chatID: UUID
    let requestID: UUID
}

enum PeerMessageValidationError: Error, Equatable, Sendable {
    case emptyText
    case textTooLong(actual: Int, maximum: Int)
}
