import Foundation

struct Chat: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let createdByPeerID: UUID
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

struct ChatParticipant: Identifiable, Equatable, Sendable {
    var id: UUID { peerID }
    let chatID: UUID
    let peerID: UUID
    let displayName: String
    let state: PeerLinkState
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
    var participants: [ChatParticipant] = []
    var state: ChatSessionState = .idle
    var isSynchronizing = false
    var error: String?
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
    var lastActivityAt: Date { lastMessage?.sentAt ?? chat.createdAt }
}
