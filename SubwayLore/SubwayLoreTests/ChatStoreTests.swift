import Foundation
import Testing
@testable import SubwayLore

struct ChatStoreTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ChatStoreTests-\(UUID())/chats.json")
    }
    private func chat(title: String = "Morning commute") -> Chat {
        Chat(id: UUID(), title: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000), createdByPeerID: UUID())
    }
    private func message(_ chat: Chat, id: UUID = UUID(), text: String = "Hello") -> ChatMessage {
        ChatMessage(id: id, senderID: UUID(), senderName: "Alex Rider", text: text,
                    sentAt: chat.createdAt, chatID: chat.id)
    }

    @Test func persistenceAndRejoinKeepOneConversation() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = chat()
        let peerID = UUID()
        let original = message(a)
        let first = ChatStore(url: url)
        try await first.join(a, localPeerID: peerID)
        try await first.merge([original], chatID: a.id)

        let reopened = ChatStore(url: url)
        try await reopened.join(a, localPeerID: peerID)
        #expect(try await reopened.history(for: peerID).count == 1)
        #expect(try await reopened.messages(in: a.id) == [original])
        #expect(try await reopened.history(for: UUID()).isEmpty)
    }

    @Test func overlappingHistoryIsIdempotentButSeparateMessagesSurvive() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = chat()
        let store = ChatStore(url: url)
        try await store.join(a, localPeerID: UUID())
        let first = message(a)
        let second = message(a)
        try await store.merge([first, second], chatID: a.id)
        try await store.merge([second, first, first], chatID: a.id)
        #expect(try await store.messages(in: a.id).count == 2)
    }

    @Test func conflictingMessageDoesNotOverwriteOriginalOrPartiallyCommitBatch() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = chat()
        let store = ChatStore(url: url)
        try await store.join(a, localPeerID: UUID())
        let original = message(a)
        try await store.merge([original], chatID: a.id)
        let conflict = message(a, id: original.id, text: "Changed content")
        await #expect(throws: ChatStoreError.conflictingMessage) {
            try await store.merge([message(a), conflict], chatID: a.id)
        }
        #expect(try await store.messages(in: a.id) == [original])
    }

    @Test func wrongChatMessagesAreRejectedAndSameTitlesStaySeparate() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = chat()
        let b = chat()
        let store = ChatStore(url: url)
        let peerID = UUID()
        try await store.join(a, localPeerID: peerID)
        try await store.join(b, localPeerID: peerID)
        await #expect(throws: ChatStoreError.invalidMessage) {
            try await store.merge([message(b)], chatID: a.id)
        }
        #expect(try await store.history(for: peerID).count == 2)
    }

    @Test func corruptStoreIsNotSilentlyReplaced() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("invalid json".utf8)
        try corrupt.write(to: url)
        let store = ChatStore(url: url)
        await #expect(throws: (any Error).self) { try await store.join(chat(), localPeerID: UUID()) }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func advertisementsAreGroupedByChatIDNotTitle() {
        let a = chat()
        let b = chat()
        let peers = [
            DiscoveredPeer(id: "A", peerID: UUID(), displayName: "Alex", domain: "local", chatID: a.id, chatTitle: a.title),
            DiscoveredPeer(id: "B", peerID: UUID(), displayName: "Blair", domain: "local", chatID: a.id, chatTitle: a.title),
            DiscoveredPeer(id: "C", peerID: UUID(), displayName: "Casey", domain: "local", chatID: b.id, chatTitle: b.title)
        ]
        let live = DiscoveredChat.aggregate(peers)
        #expect(live.count == 2)
        #expect(live.first(where: { $0.id == a.id })?.advertisingPeerIDs.count == 2)
    }
}
