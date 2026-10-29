import Foundation
import Testing
@testable import SubwayLore

struct ChatHistorySyncTests {
    @Test func returningPeerMergesMissingPagesFromTwoParticipantsExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ChatSyncTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = Chat(id: UUID(), title: "A, B, C", createdAt: Date(), createdByPeerID: UUID())
        let cID = UUID()
        let a = ChatStore(url: directory.appending(path: "a.json"))
        let b = ChatStore(url: directory.appending(path: "b.json"))
        let cURL = directory.appending(path: "c.json")
        let c = ChatStore(url: cURL)
        try await a.join(chat, localPeerID: chat.createdByPeerID)
        try await b.join(chat, localPeerID: UUID())
        try await c.join(chat, localPeerID: cID)
        let messages = (0..<205).map { index in
            ChatMessage(id: UUID(), senderID: chat.createdByPeerID, senderName: "Alex",
                        text: "Message \(index)", sentAt: chat.createdAt.addingTimeInterval(Double(index)), chatID: chat.id)
        }
        try await a.merge(messages, chatID: chat.id)
        try await b.merge(messages, chatID: chat.id)
        try await c.merge(Array(messages.prefix(3)), chatID: chat.id)

        let reopenedC = ChatStore(url: cURL)
        let initialC = try await reopenedC.messages(in: chat.id)
        let aPages = ChatHistorySync.inventoryPages(try await a.messages(in: chat.id), chatID: chat.id)
        let bPages = ChatHistorySync.inventoryPages(try await b.messages(in: chat.id), chatID: chat.id)
        #expect(aPages.map(\.messageIDs.count) == [100, 100, 5])
        // Both inventories are compared to the same initial state, simulating overlapping transfers.
        for page in aPages + bPages {
            let requested = Set(ChatHistorySync.missingIDs(page, knownMessages: initialC))
            try await reopenedC.merge(messages.filter { requested.contains($0.id) }, chatID: chat.id)
        }
        #expect(try await reopenedC.messages(in: chat.id) == messages)
        #expect(try await reopenedC.history(for: cID).count == 1)
    }

    @Test func largestAllowedTextAndUnicodeHistoryRecordFitsFrame() throws {
        let chatID = UUID()
        let record = ChatMessage(id: UUID(), senderID: UUID(), senderName: "Alex",
                                 text: String(repeating: "🚇", count: TextMessage.maximumCharacterCount),
                                 sentAt: Date(), chatID: chatID)
        let envelope = PeerEnvelope(senderID: UUID(), sequence: 1,
            body: .historyBatch(HistoryBatch(chatID: chatID, requestID: UUID(), messages: [record])))
        let data = try JSONEncoder().encode(envelope)
        #expect(data.count < MessageFramer.maximumPayloadSize)
        _ = try MessageFramer.frame(data)
    }
}
