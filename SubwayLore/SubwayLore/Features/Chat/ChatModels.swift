import Foundation

struct Chat: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let createdByPeerID: UUID

    static func make(for identity: PeerIdentity) -> Chat {
        let firstName = (identity.firstName ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = ChatTitle.excerpt(firstName, characterLimit: 32, byteLimit: 70)
        return Chat(id: UUID(), title: name.isEmpty ? "New chat" : "\(name)’s chat",
                    createdAt: Date(), createdByPeerID: identity.id)
    }

    func displayTitle(messages: [ChatMessage]) -> String {
        let first = messages.filter { $0.chatID == id }.min {
            $0.sentAt == $1.sentAt ? $0.id.uuidString < $1.id.uuidString : $0.sentAt < $1.sentAt
        }
        guard let first else { return title }
        let excerpt = ChatTitle.excerpt(first.text)
        return excerpt.isEmpty ? title : excerpt
    }
}

enum ChatTitle {
    static func excerpt(_ text: String, characterLimit: Int = 40, byteLimit: Int = 240) -> String {
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var result = ""
        for character in normalized.prefix(characterLimit) {
            guard result.utf8.count + String(character).utf8.count <= byteLimit else { break }
            result.append(character)
        }
        return result
    }
}

struct ChatMembership: Codable, Equatable, Sendable {
    let chatID: UUID
    let localPeerID: UUID
    let joinedAt: Date
}

struct DiscoveredChat: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let advertisingPeerIDs: Set<UUID>

    static func aggregate(_ peers: [DiscoveredPeer]) -> [DiscoveredChat] {
        let grouped = Dictionary(grouping: peers.filter { $0.chatID != nil }, by: { $0.chatID! })
        return grouped.map { id, peers in
            let ordered = peers.sorted { ($0.peerID?.uuidString ?? "") < ($1.peerID?.uuidString ?? "") }
            return DiscoveredChat(id: id, title: ordered.first?.chatTitle ?? "Nearby chat",
                                  advertisingPeerIDs: Set(peers.compactMap(\.peerID)))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

enum ChatSessionState: Equatable, Sendable {
    case idle
    case joining(UUID)
    case joined(UUID)
    case leaving(UUID)
}

struct ChatSnapshot: Equatable, Sendable {
    var history: [ChatHistoryEntry] = []
    var chat: Chat?
    var messages: [ChatMessage] = []
    var participants: [ActivityParticipant] = []
    var state: ChatSessionState = .idle
    var isSynchronizing = false
    var error: String?
    var displayTitle: String { chat?.displayTitle(messages: messages) ?? "Chat" }
    var isActive: Bool {
        switch state {
        case .joining, .joined: true
        default: false
        }
    }
    var connectedPeerCount: Int { participants.count { $0.state == .connected } }
}

struct ChatHistoryEntry: Identifiable, Equatable, Sendable {
    var id: UUID { chat.id }
    let chat: Chat
    let lastMessage: ChatMessage?
    var firstMessage: ChatMessage? = nil
    var displayTitle: String { chat.displayTitle(messages: firstMessage.map { [$0] } ?? []) }
    var lastActivityAt: Date { lastMessage?.sentAt ?? chat.createdAt }
}
