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
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            chatID: UUID()
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
            #expect(received.body == .chatText(original))
        }
    }

}
