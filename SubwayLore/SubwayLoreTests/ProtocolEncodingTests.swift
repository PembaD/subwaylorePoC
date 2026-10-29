import Foundation
import Testing
@testable import SubwayLore

struct ProtocolEncodingTests {
    @Test
    func allMessagesRoundTripThroughJSON() throws {
        let senderID = UUID()
        let correlationID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messages: [PeerMessage] = [
            .hello(HelloMessage(peerID: senderID, displayName: "Rider-1234", capabilities: ["text", "ping"])),
            .helloAccepted(HelloAcceptedMessage(peerID: senderID)),
            .ping(PingMessage(correlationID: correlationID)),
            .pong(PongMessage(correlationID: correlationID, originalSentAt: now, receivedAt: now.addingTimeInterval(0.02))),
            .text(try TextMessage(text: "Hello, train car")),
            .goodbye(GoodbyeMessage(reason: "POC finished"))
        ]

        for (index, message) in messages.enumerated() {
            let envelope = PeerEnvelope(
                id: UUID(),
                senderID: senderID,
                sequence: UInt64(index),
                sentAt: now,
                body: message
            )
            let encoded = try JSONEncoder().encode(envelope)
            let decoded = try JSONDecoder().decode(PeerEnvelope.self, from: encoded)
            #expect(decoded == envelope)
        }
    }

    @Test func chatAdmissionAndHistoryMessagesRoundTripThroughFrames() throws {
        let chat = Chat(id: UUID(), title: "Morning commute", createdAt: Date(), createdByPeerID: UUID())
        let requestID = UUID()
        let original = ChatMessage(id: UUID(), senderID: UUID(), senderName: "Alex", text: "Hello",
                                   sentAt: Date(), chatID: chat.id)
        let messages: [PeerMessage] = [
            .joinChatRequest(JoinChatRequest(chatID: chat.id, requestID: requestID)),
            .joinChatAccepted(JoinChatAccepted(requestID: requestID, chat: chat)),
            .joinChatRejected(JoinChatRejected(requestID: requestID, reason: "Capacity reached")),
            .chatText(original),
            .historySyncRequest(chat.id),
            .historyInventory(HistoryInventory(chatID: chat.id, requestID: requestID, messageIDs: [original.id])),
            .historyRequest(HistoryRequest(chatID: chat.id, requestID: requestID, messageIDs: [original.id])),
            .historyBatch(HistoryBatch(chatID: chat.id, requestID: requestID, messages: [original])),
            .historyComplete(HistoryComplete(chatID: chat.id, requestID: requestID))
        ]
        for body in messages {
            // The forwarding peer and the historical author's IDs intentionally differ.
            let sent = PeerEnvelope(senderID: UUID(), sequence: 1, body: body)
            let framed = try MessageFramer.frame(JSONEncoder().encode(sent))
            var decoder = FrameDecoder()
            let payload = try #require(decoder.append(framed).first)
            #expect(try JSONDecoder().decode(PeerEnvelope.self, from: payload) == sent)
        }
    }

    @Test
    func unsupportedProtocolVersionIsRejected() {
        let envelope = PeerEnvelope(
            protocolVersion: 99,
            senderID: UUID(),
            sequence: 0,
            body: .ping(PingMessage(correlationID: UUID()))
        )

        #expect(throws: PeerEnvelopeError.unsupportedProtocolVersion(received: 99, supported: PeerEnvelope.currentProtocolVersion)) {
            try envelope.validateProtocolVersion()
        }
    }

    @Test
    func textValidationRejectsEmptyAndOversizedMessages() {
        #expect(throws: PeerMessageValidationError.emptyText) {
            try TextMessage(text: "")
        }

        let oversized = String(repeating: "a", count: TextMessage.maximumCharacterCount + 1)
        #expect(throws: PeerMessageValidationError.textTooLong(actual: 1_001, maximum: 1_000)) {
            try TextMessage(text: oversized)
        }
    }

    @Test
    func textValidationAlsoAppliesWhileDecoding() throws {
        let invalidJSON = Data("\"\"".utf8)

        #expect(throws: PeerMessageValidationError.emptyText) {
            try JSONDecoder().decode(TextMessage.self, from: invalidJSON)
        }
    }
}
