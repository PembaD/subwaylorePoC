import Foundation
import Testing
@testable import SubwayLore

struct ChatTitleTests {
    private func message(in chat: Chat, text: String, at time: TimeInterval, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, senderID: UUID(), senderName: "Alex", text: text,
                    sentAt: Date(timeIntervalSince1970: time), chatID: chat.id)
    }

    @Test func newChatsUseFirstNameOrFallbackAndDistinctIDs() {
        let identity = PeerIdentity.make().updatingProfile(firstName: " Alex ", lastName: "Rider")
        let first = Chat.make(for: identity)
        let second = Chat.make(for: identity)
        #expect(first.title == "Alex’s chat")
        #expect(first.id != second.id)
        #expect(first.createdByPeerID == identity.id)
        #expect(Chat.make(for: PeerIdentity.make()).title == "New chat")
        let longName = PeerIdentity.make().updatingProfile(firstName: String(repeating: "🚇", count: 40), lastName: "Rider")
        #expect(Chat.make(for: longName).title.utf8.count <= 80)
    }

    @Test func titleUsesFirstMessageNotLatestAndNormalizesWhitespace() {
        let chat = Chat.make(for: PeerIdentity.make())
        let first = message(in: chat, text: "  Hello\n nearby\t riders!  ", at: 1)
        let later = message(in: chat, text: "This must not replace the title", at: 2)
        #expect(chat.displayTitle(messages: [later, first]) == "Hello nearby riders!")
        #expect(chat.displayTitle(messages: [first]) == chat.displayTitle(messages: [first, later]))
        #expect(chat.displayTitle(messages: []) == "New chat")
        #expect(chat.displayTitle(messages: [message(in: Chat.make(for: PeerIdentity.make()), text: "Another chat", at: 0)]) == "New chat")
    }

    @Test func excerptKeepsAtMostFortyCharactersWithoutSplittingEmoji() {
        #expect(ChatTitle.excerpt(String(repeating: "a", count: 100)) == String(repeating: "a", count: 40))
        let emoji = ChatTitle.excerpt(String(repeating: "🚇", count: 100))
        #expect(emoji.count == 40)
        #expect(emoji == String(repeating: "🚇", count: 40))
        #expect(ChatTitle.excerpt(String(repeating: "👨‍👩‍👧‍👦", count: 100)).utf8.count <= 240)
    }

    @Test func equalTimestampsChooseSameMessageRegardlessOfDeliveryOrder() {
        let chat = Chat.make(for: PeerIdentity.make())
        let a = message(in: chat, text: "First", at: 1,
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = message(in: chat, text: "Second", at: 1,
                        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(chat.displayTitle(messages: [b, a]) == "First")
        #expect(chat.displayTitle(messages: [a, b]) == "First")
    }

    @Test func derivedHistoryTitlePersistsWithoutChangingIdentityOrBreakingRejoin() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ChatTitleTests-\(UUID())/chats.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let identity = PeerIdentity.make().updatingProfile(firstName: "Alex", lastName: "Rider")
        let chat = Chat.make(for: identity)
        let store = ChatStore(url: url)
        try await store.join(chat, localPeerID: identity.id)
        let first = message(in: chat, text: "Anyone heading downtown?", at: 1)
        let latest = message(in: chat, text: "Yes, same stop!", at: 2)
        try await store.merge([latest, first], chatID: chat.id)

        let reopened = ChatStore(url: url)
        try await reopened.join(chat, localPeerID: identity.id)
        let history = try await reopened.history(for: identity.id)
        let entry = try #require(history.first)
        #expect(history.count == 1)
        #expect(entry.id == chat.id)
        #expect(entry.chat == chat)
        #expect(entry.displayTitle == "Anyone heading downtown?")
        #expect(entry.lastMessage?.text == "Yes, same stop!")
    }
}
