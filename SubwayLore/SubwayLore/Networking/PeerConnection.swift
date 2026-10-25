import Foundation
import Network

struct ConnectedPeer: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let capabilities: [String]
    let chat: Chat
}

enum PeerConnectionError: Error, Equatable, Sendable {
    case connectionClosed
    case expectedHello
    case invalidHelloSender
    case unexpectedPeer(expected: UUID, received: UUID)
    case invalidHelloAcceptance
    case handshakeIncomplete
    case admissionRejected(String)
    case wrongChat
}

actor PeerConnection {
    let id: UUID
    let direction: ConnectionDirection

    private let connection: NetworkConnection<TLS>
    private let localIdentity: PeerIdentity
    private let localChat: Chat
    private let expectedPeerID: UUID?
    private let diagnostics: DiagnosticsRecorder
    private let messageHandler: @Sendable (PeerEnvelope) async -> Void
    private let admissionCheck: @Sendable (UUID) async -> String?
    private var decoder = FrameDecoder()
    private var sequence: UInt64 = 0
    private var remotePeer: ConnectedPeer?
    private var isClosed = false
    private var pendingEnvelopes: [PeerEnvelope] = []

    init(
        id: UUID = UUID(),
        connection: NetworkConnection<TLS>,
        direction: ConnectionDirection,
        localIdentity: PeerIdentity,
        chat: Chat,
        expectedPeerID: UUID?,
        diagnostics: DiagnosticsRecorder,
        admissionCheck: @escaping @Sendable (UUID) async -> String?,
        messageHandler: @escaping @Sendable (PeerEnvelope) async -> Void
    ) {
        self.id = id
        self.connection = connection
        self.direction = direction
        self.localIdentity = localIdentity
        self.localChat = chat
        self.expectedPeerID = expectedPeerID
        self.diagnostics = diagnostics
        self.messageHandler = messageHandler
        self.admissionCheck = admissionCheck
    }

    func handshake() async throws -> ConnectedPeer {
        let requestID = UUID()
        try await send(.hello(HelloMessage(
            peerID: localIdentity.id, displayName: localIdentity.displayName,
            capabilities: ["chats-v2", "history"]
        )))
        var hello: HelloMessage?
        var acceptanceSender: UUID?
        var acceptedChat: Chat?
        var answeredRequest = false
        while hello == nil || acceptanceSender == nil || acceptedChat == nil || !answeredRequest {
            for envelope in try await receiveEnvelopes() {
                try envelope.validateProtocolVersion()
                switch envelope.body {
                case .hello(let value):
                    guard hello == nil, envelope.senderID == value.peerID,
                          value.peerID != localIdentity.id else {
                        throw PeerConnectionError.invalidHelloSender
                    }
                    if let expectedPeerID, expectedPeerID != value.peerID {
                        throw PeerConnectionError.unexpectedPeer(expected: expectedPeerID, received: value.peerID)
                    }
                    hello = value
                    try await send(.helloAccepted(HelloAcceptedMessage(peerID: localIdentity.id)))
                    try await send(.joinChatRequest(JoinChatRequest(chatID: localChat.id, requestID: requestID)))
                case .helloAccepted(let value):
                    guard envelope.senderID == value.peerID else {
                        throw PeerConnectionError.invalidHelloAcceptance
                    }
                    acceptanceSender = value.peerID
                case .joinChatRequest(let request):
                    guard let hello, hello.peerID == envelope.senderID else {
                        throw PeerConnectionError.expectedHello
                    }
                    guard request.chatID == localChat.id else {
                        try await send(.joinChatRejected(JoinChatRejected(
                            requestID: request.requestID, reason: "Chat is no longer available"
                        )))
                        throw PeerConnectionError.wrongChat
                    }
                    if let reason = await admissionCheck(hello.peerID) {
                        try await send(.joinChatRejected(JoinChatRejected(requestID: request.requestID, reason: reason)))
                        throw PeerConnectionError.admissionRejected(reason)
                    }
                    answeredRequest = true
                    try await send(.joinChatAccepted(JoinChatAccepted(requestID: request.requestID, chat: localChat)))
                case .joinChatAccepted(let accepted):
                    guard let hello, envelope.senderID == hello.peerID,
                          accepted.requestID == requestID,
                          accepted.chat.id == localChat.id else { throw PeerConnectionError.wrongChat }
                    acceptedChat = accepted.chat
                case .joinChatRejected(let rejected):
                    guard rejected.requestID == requestID else { throw PeerConnectionError.wrongChat }
                    throw PeerConnectionError.admissionRejected(rejected.reason)
                default:
                    // A fast remote may send history alongside the final handshake frames.
                    pendingEnvelopes.append(envelope)
                }
            }
        }
        guard let hello, acceptanceSender == hello.peerID, let acceptedChat else {
            throw PeerConnectionError.handshakeIncomplete
        }
        let peer = ConnectedPeer(id: hello.peerID, displayName: hello.displayName,
                                 capabilities: hello.capabilities, chat: acceptedChat)
        remotePeer = peer
        record(.info, "Chat admission complete", remotePeerID: peer.id)
        return peer
    }

    func receiveUntilClosed() async throws {
        guard let remotePeer else { throw PeerConnectionError.handshakeIncomplete }

        while !Task.isCancelled && !isClosed {
            let envelopes: [PeerEnvelope]
            if pendingEnvelopes.isEmpty {
                envelopes = try await receiveEnvelopes()
            } else {
                envelopes = pendingEnvelopes
                pendingEnvelopes.removeAll()
            }
            for envelope in envelopes {
                try envelope.validateProtocolVersion()
                guard envelope.senderID == remotePeer.id else {
                    throw PeerConnectionError.invalidHelloSender
                }

                switch envelope.body {
                case .goodbye:
                    record(.info, "Remote peer disconnected", remotePeerID: remotePeer.id)
                    return
                case .hello, .helloAccepted:
                    throw PeerConnectionError.expectedHello
                case .chatText, .historyInventory, .historyRequest, .historyBatch, .historyComplete, .historySyncRequest:
                    await messageHandler(envelope)
                case .ping(let ping):
                    try await send(.pong(PongMessage(correlationID: ping.correlationID,
                                                    originalSentAt: envelope.sentAt, receivedAt: Date())))
                    await messageHandler(envelope)
                case .pong:
                    await messageHandler(envelope)
                default:
                    throw PeerConnectionError.expectedHello
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

    func send(_ message: PeerMessage) async throws {
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
