import Foundation

enum ChatStoreError: Error, Equatable {
    case unsupportedVersion
    case unknownChat
    case conflictingChat
    case conflictingMessage
    case invalidMessage
}

actor ChatStore {
    private struct Document: Codable {
        var version = 1
        var chats: [Chat] = []
        var memberships: [ChatMembership] = []
        var messages: [ChatMessage] = []
    }

    private let url: URL
    private var document: Document?

    init(url: URL? = nil) {
        var filename = "chats-v1.json"
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SUBWAYLORE_TEST_STORE"],
           let id = UUID(uuidString: value) {
            filename = "ui-test-\(id).json"
        }
        #endif
        self.url = url ?? URL.applicationSupportDirectory
            .appending(path: "SubwayLore", directoryHint: .isDirectory)
            .appending(path: filename)
    }

    private func load() throws -> Document {
        if let document { return document }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let empty = Document()
            document = empty
            return empty
        }
        let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard decoded.version == 1 else { throw ChatStoreError.unsupportedVersion }
        document = decoded
        return decoded
    }

    private func commit(_ updated: Document) throws {
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        document = updated
    }

    func join(_ chat: Chat, localPeerID: UUID) throws {
        guard !chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              chat.title.utf8.count <= 80 else { throw ChatStoreError.conflictingChat }
        var updated = try load()
        if let existing = updated.chats.first(where: { $0.id == chat.id }) {
            guard existing == chat else { throw ChatStoreError.conflictingChat }
        } else {
            updated.chats.append(chat)
        }
        if !updated.memberships.contains(where: { $0.chatID == chat.id && $0.localPeerID == localPeerID }) {
            updated.memberships.append(ChatMembership(chatID: chat.id, localPeerID: localPeerID, joinedAt: Date()))
        }
        try commit(updated)
    }

    func merge(_ messages: [ChatMessage], chatID: UUID) throws {
        var updated = try load()
        guard updated.chats.contains(where: { $0.id == chatID }) else { throw ChatStoreError.unknownChat }
        for message in messages {
            guard message.chatID == chatID,
                  message.senderName.utf8.count <= 256,
                  (try? TextMessage(text: message.text)) != nil else { throw ChatStoreError.invalidMessage }
            if let existing = updated.messages.first(where: { $0.chatID == chatID && $0.id == message.id }) {
                guard existing == message else { throw ChatStoreError.conflictingMessage }
            } else {
                updated.messages.append(message)
            }
        }
        try commit(updated)
    }

    func messages(in chatID: UUID) throws -> [ChatMessage] {
        try load().messages.filter { $0.chatID == chatID }.sorted {
            $0.sentAt == $1.sentAt ? $0.id.uuidString < $1.id.uuidString : $0.sentAt < $1.sentAt
        }
    }

    func history(for peerID: UUID) throws -> [ChatHistoryEntry] {
        let stored = try load()
        let joined = Set(stored.memberships.filter { $0.localPeerID == peerID }.map(\.chatID))
        return try stored.chats.filter { joined.contains($0.id) }.map { chat in
            let messages = try messages(in: chat.id)
            return ChatHistoryEntry(chat: chat, lastMessage: messages.last, firstMessage: messages.first)
        }.sorted {
            $0.lastActivityAt == $1.lastActivityAt ? $0.id.uuidString < $1.id.uuidString : $0.lastActivityAt > $1.lastActivityAt
        }
    }
}
