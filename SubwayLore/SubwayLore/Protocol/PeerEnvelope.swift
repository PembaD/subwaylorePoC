import Foundation

struct PeerEnvelope: Codable, Identifiable, Equatable, Sendable {
    static let currentProtocolVersion: UInt16 = 1

    let protocolVersion: UInt16
    let id: UUID
    let senderID: UUID
    let sequence: UInt64
    let sentAt: Date
    let body: PeerMessage

    init(
        protocolVersion: UInt16 = Self.currentProtocolVersion,
        id: UUID = UUID(),
        senderID: UUID,
        sequence: UInt64,
        sentAt: Date = Date(),
        body: PeerMessage
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.senderID = senderID
        self.sequence = sequence
        self.sentAt = sentAt
        self.body = body
    }

    func validateProtocolVersion() throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw PeerEnvelopeError.unsupportedProtocolVersion(
                received: protocolVersion,
                supported: Self.currentProtocolVersion
            )
        }
    }
}

enum PeerEnvelopeError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(received: UInt16, supported: UInt16)
}
