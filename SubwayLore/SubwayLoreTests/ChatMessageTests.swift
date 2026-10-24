import Foundation
import Testing
@testable import SubwayLore

struct ChatMessageTests {
    private func message(id: UUID = UUID()) -> ChatMessage {
        ChatMessage(
            id: id,
            senderID: UUID(),
            senderName: "Alex Rider",
            text: "Hello, nearby riders",
            sentAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func broadcastPreservesIdentityAcrossRecipientSequences() throws {
        let original = message()
        for sequence in [UInt64(1), 7, 42] {
            let envelope = try original.envelope(sequence: sequence)
            let framed = try MessageFramer.frame(JSONEncoder().encode(envelope))
            var decoder = FrameDecoder()
            let payload = try #require(decoder.append(framed).first)
            let received = try JSONDecoder().decode(PeerEnvelope.self, from: payload)

            #expect(received.id == original.id)
            #expect(received.senderID == original.senderID)
            #expect(received.sentAt == original.sentAt)
            #expect(received.sequence == sequence)
            #expect(received.body == .text(try TextMessage(text: original.text)))
        }
    }

    @Test func repeatedDeliveryDoesNotDuplicateMessage() throws {
        let original = message()
        var reducer = DiscoveryReducer()
        reducer.appendChatMessage(original)

        for sequence in [UInt64(2), 8] {
            let envelope = try original.envelope(sequence: sequence)
            reducer.appendChatMessage(ChatMessage(
                id: envelope.id,
                senderID: envelope.senderID,
                senderName: "Updated display name",
                text: original.text,
                sentAt: envelope.sentAt
            ))
        }

        #expect(reducer.snapshot.chatMessages == [original])
    }

    @Test func sameTextWithDifferentIDsRemainsTwoMessages() {
        var reducer = DiscoveryReducer()
        let first = message()
        let second = message()
        reducer.appendChatMessage(first)
        reducer.appendChatMessage(second)

        #expect(reducer.snapshot.chatMessages.count == 2)
        #expect(Set(reducer.snapshot.chatMessages.map(\.id)) == [first.id, second.id])
    }
}
