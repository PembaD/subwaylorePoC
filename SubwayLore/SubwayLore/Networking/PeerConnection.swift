import Foundation
import Network

struct ConnectedPeer: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let capabilities: [String]
}

enum PeerConnectionError: Error, Equatable, Sendable {
    case connectionClosed
    case expectedHello
    case invalidHelloSender
    case unexpectedPeer(expected: UUID, received: UUID)
    case invalidHelloAcceptance
    case handshakeIncomplete
}

actor PeerConnection {
    let id: UUID
    let direction: ConnectionDirection

    private let connection: NetworkConnection<TLS>
    private let localIdentity: PeerIdentity
    private let expectedPeerID: UUID?
    private let diagnostics: DiagnosticsRecorder
    private let messageHandler: @Sendable (PeerEnvelope) async -> Void
    private var decoder = FrameDecoder()
    private var sequence: UInt64 = 0
    private var remotePeer: ConnectedPeer?
    private var isClosed = false

    init(
        id: UUID = UUID(),
        connection: NetworkConnection<TLS>,
        direction: ConnectionDirection,
        localIdentity: PeerIdentity,
        expectedPeerID: UUID?,
        diagnostics: DiagnosticsRecorder,
        messageHandler: @escaping @Sendable (PeerEnvelope) async -> Void
    ) {
        self.id = id
        self.connection = connection
        self.direction = direction
        self.localIdentity = localIdentity
        self.expectedPeerID = expectedPeerID
        self.diagnostics = diagnostics
        self.messageHandler = messageHandler
    }

    func handshake() async throws -> ConnectedPeer {
        record(.info, "TLS connection starting", metadata: ["direction": direction.rawValue])
        try await send(
            .hello(
                HelloMessage(
                    peerID: localIdentity.id,
                    displayName: localIdentity.displayName,
                    capabilities: ["phase3", "framed-json"]
                )
            )
        )

        var receivedPeer: ConnectedPeer?
        var receivedAcceptance = false

        while receivedPeer == nil || !receivedAcceptance {
            for envelope in try await receiveEnvelopes() {
                try envelope.validateProtocolVersion()

                switch envelope.body {
                case .hello(let hello):
                    guard envelope.senderID == hello.peerID else {
                        throw PeerConnectionError.invalidHelloSender
                    }
                    if let expectedPeerID, expectedPeerID != hello.peerID {
                        throw PeerConnectionError.unexpectedPeer(
                            expected: expectedPeerID,
                            received: hello.peerID
                        )
                    }
                    receivedPeer = ConnectedPeer(
                        id: hello.peerID,
                        displayName: hello.displayName,
                        capabilities: hello.capabilities
                    )
                    try await send(.helloAccepted(HelloAcceptedMessage(peerID: localIdentity.id)))

                case .helloAccepted(let accepted):
                    guard envelope.senderID == accepted.peerID else {
                        throw PeerConnectionError.invalidHelloAcceptance
                    }
                    receivedAcceptance = true

                default:
                    throw PeerConnectionError.expectedHello
                }
            }
        }

        guard let receivedPeer else {
            throw PeerConnectionError.handshakeIncomplete
        }
        guard receivedAcceptance else {
            throw PeerConnectionError.handshakeIncomplete
        }

        remotePeer = receivedPeer
        record(.info, "Application handshake complete", remotePeerID: receivedPeer.id)
        return receivedPeer
    }

    func receiveUntilClosed() async throws {
        guard let remotePeer else { throw PeerConnectionError.handshakeIncomplete }

        while !Task.isCancelled && !isClosed {
            for envelope in try await receiveEnvelopes() {
                try envelope.validateProtocolVersion()
                guard envelope.senderID == remotePeer.id else {
                    throw PeerConnectionError.invalidHelloSender
                }

                switch envelope.body {
                case .goodbye:
                    record(.info, "Remote peer disconnected", remotePeerID: remotePeer.id)
                    isClosed = true
                    return
                case .hello, .helloAccepted:
                    throw PeerConnectionError.expectedHello
                case .text:
                    await messageHandler(envelope)
                case .ping, .pong:
                    record(.debug, "Phase 4 message received", remotePeerID: remotePeer.id)
                }
            }
        }
    }

    func sendChatMessage(_ message: ChatMessage) async throws {
        sequence &+= 1
        try await sendEnvelope(message.envelope(sequence: sequence))
    }

    func close(reason: String? = nil, notifyPeer: Bool = true) async {
        guard !isClosed else { return }
        isClosed = true

        if notifyPeer {
            try? await send(.goodbye(GoodbyeMessage(reason: reason)))
        }
        try? await connection.send(Data(), endOfStream: true)
        record(.debug, "Connection closed", remotePeerID: remotePeer?.id)
    }

    private func send(_ message: PeerMessage) async throws {
        sequence &+= 1
        let envelope = PeerEnvelope(
            senderID: localIdentity.id,
            sequence: sequence,
            body: message
        )
        try await sendEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: PeerEnvelope) async throws {
        let payload = try JSONEncoder().encode(envelope)
        let framed = try MessageFramer.frame(payload)
        try await connection.send(framed)
        record(.debug, "Protocol message sent", remotePeerID: remotePeer?.id, metadata: [
            "bytes": String(framed.count),
            "sequence": String(envelope.sequence),
            "messageID": envelope.id.uuidString,
        ])
    }

    private func receiveEnvelopes() async throws -> [PeerEnvelope] {
        let message = try await connection.receive(
            atLeast: 1,
            atMost: MessageFramer.maximumPayloadSize + MessageFramer.headerSize
        )
        guard !message.content.isEmpty else {
            throw PeerConnectionError.connectionClosed
        }

        let payloads = try decoder.append(message.content)
        return try payloads.map { payload in
            try JSONDecoder().decode(PeerEnvelope.self, from: payload)
        }
    }

    private func record(
        _ severity: DiagnosticSeverity,
        _ summary: String,
        remotePeerID: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        let connectionID = id
        Task {
            await diagnostics.record(
                severity: severity,
                category: .connection,
                localPeerID: localIdentity.id,
                remotePeerID: remotePeerID,
                connectionID: connectionID,
                summary: summary,
                metadata: metadata
            )
        }
    }
}
