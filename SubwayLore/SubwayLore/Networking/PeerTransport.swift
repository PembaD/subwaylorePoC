import Foundation
import Network

enum PeerTransportEvent: Sendable {
    case connected(ConnectedPeer)
    case participants([ChatParticipant])
    case message(PeerEnvelope)
    case issue(String)
}

actor PeerTransport {
    private struct Record {
        let id: UUID
        let connection: PeerConnection
        let direction: ConnectionDirection
        let expectedPeerID: UUID?
        var remotePeerID: UUID?
        var task: Task<Void, Never>?
        var lastReceivedAt = Date()
        var lastPingAt = Date.distantPast
        var remoteDisplayName: String?
    }
    private let diagnostics: DiagnosticsRecorder
    private var identity: PeerIdentity?
    private var chat: Chat?
    private var generation = UUID()
    private var records: [UUID: Record] = [:]
    private var active: [UUID: UUID] = [:]
    private var candidates: [UUID: DiscoveredPeer] = [:]
    private var attempts: [UUID: Int] = [:]
    private var retryAt: [UUID: Date] = [:]
    private var ticker: Task<Void, Never>?
    private var handler: (@Sendable (PeerTransportEvent) async -> Void)?
    private var endpointLookup: (@Sendable (UUID) async -> Bonjour.Endpoint?)?

    init(diagnostics: DiagnosticsRecorder) { self.diagnostics = diagnostics }

    func open(identity: PeerIdentity, chat: Chat,
              endpointLookup: @escaping @Sendable (UUID) async -> Bonjour.Endpoint?,
              handler: @escaping @Sendable (PeerTransportEvent) async -> Void) async {
        await close()
        self.identity = identity
        self.chat = chat
        self.handler = handler
        self.endpointLookup = endpointLookup
        let expected = generation
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile(generation: expected)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func updatePeers(_ peers: [DiscoveredPeer]) async {
        guard let chat, let identity else { return }
        candidates = peers.reduce(into: [:]) { result, peer in
            if peer.chatID == chat.id, let id = peer.peerID, id != identity.id { result[id] = peer }
        }
        await publishParticipants()
    }

    func adoptChat(_ chat: Chat) {
        guard self.chat?.id == chat.id else { return }
        self.chat = chat
    }

    func accept(_ connection: NetworkConnection<TLS>) async {
        guard chat != nil, records.count < 16 else { return }
        launch(connection, direction: .incoming, expectedPeerID: nil)
    }

    private func reconcile(generation expected: UUID) async {
        guard expected == generation, chat != nil else { return }
        for id in Array(active.values) {
            guard let record = records[id] else { continue }
            if Date().timeIntervalSince(record.lastReceivedAt) > 35 {
                record.task?.cancel()
                await finish(id, generation: expected)
            } else if Date().timeIntervalSince(record.lastPingAt) > 10 {
                records[id]?.lastPingAt = Date()
                Task { try? await record.connection.send(.ping(PingMessage(correlationID: UUID()))) }
            }
        }
        guard expected == generation else { return }
        // Existing admitted links survive short Bonjour gaps. New attempts require an advertisement.
        for id in candidates.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard active[id] == nil,
                  !records.values.contains(where: { $0.expectedPeerID == id || $0.remotePeerID == id }),
                  reservedPeerIDs.count < 8,
                  retryAt[id, default: .distantPast] <= Date() else { continue }
            guard let endpoint = await endpointLookup?(id), expected == generation else { continue }
            do {
                let parameters = try TransportConfiguration.parameters()
                launch(NetworkConnection<TLS>(to: endpoint, using: parameters), direction: .outgoing, expectedPeerID: id)
            } catch {
                scheduleRetry(id)
                await handler?(.issue("Unable to configure a nearby connection. Retrying."))
            }
        }
        await publishParticipants()
    }

    private func launch(_ network: NetworkConnection<TLS>, direction: ConnectionDirection, expectedPeerID: UUID?) {
        guard let identity, let chat else { return }
        let id = UUID()
        let expectedGeneration = generation
        let connection = PeerConnection(
            id: id, connection: network, direction: direction, localIdentity: identity, chat: chat,
            expectedPeerID: expectedPeerID, diagnostics: diagnostics,
            admissionCheck: { [weak self] peerID in
                guard let self else { return "Chat is no longer available" }
                return await self.reserve(peerID: peerID, connectionID: id, generation: expectedGeneration)
            },
            messageHandler: { [weak self] envelope in
                await self?.deliver(envelope, connectionID: id, generation: expectedGeneration)
            }
        )
        records[id] = Record(id: id, connection: connection, direction: direction, expectedPeerID: expectedPeerID)
        records[id]?.task = Task { [weak self] in
            await self?.run(connection, id: id, generation: expectedGeneration)
        }
    }

    private func reserve(peerID: UUID, connectionID: UUID, generation expected: UUID) -> String? {
        guard expected == generation, chat != nil, records[connectionID] != nil else {
            return "Chat is no longer available"
        }
        let reserved = reservedPeerIDs
        guard reserved.contains(peerID) || reserved.count < 8 else {
            return "This device is at its eight-rider connection limit"
        }
        records[connectionID]?.remotePeerID = peerID
        return nil
    }

    private var reservedPeerIDs: Set<UUID> {
        Set(records.values.compactMap { $0.remotePeerID ?? $0.expectedPeerID })
    }

    private func run(_ connection: PeerConnection, id: UUID, generation expected: UUID) async {
        do {
            let peer = try await withThrowingTaskGroup(of: ConnectedPeer.self) { group in
                group.addTask { try await connection.handshake() }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw PeerConnectionError.admissionRejected("Connection timed out")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            guard expected == generation, let record = records[id], let identity else {
                await connection.close(notifyPeer: false)
                return
            }
            if let existingID = active[peer.id], existingID != id, let existing = records[existingID] {
                let preferred = ConnectionArbitration.preferredDirection(localPeerID: identity.id, remotePeerID: peer.id)
                guard record.direction == preferred, existing.direction != preferred else {
                    await finish(id, generation: expected)
                    return
                }
                active.removeValue(forKey: peer.id)
                records.removeValue(forKey: existingID)
                existing.task?.cancel()
                Task { await existing.connection.close(notifyPeer: false) }
            }
            guard active.count < 8 else {
                await handler?(.issue("This device is at its eight-rider connection limit."))
                await finish(id, generation: expected)
                return
            }
            records[id]?.remotePeerID = peer.id
            records[id]?.remoteDisplayName = peer.displayName
            active[peer.id] = id
            attempts[peer.id] = 0
            retryAt.removeValue(forKey: peer.id)
            await handler?(.connected(peer))
            guard expected == generation else { return }
            await publishParticipants()
            try await connection.receiveUntilClosed()
        } catch {
            if expected == generation, !Task.isCancelled {
                await diagnostics.record(severity: .warning, category: .connection,
                    localPeerID: identity?.id ?? UUID(), connectionID: id,
                    summary: "Chat connection ended", metadata: ["error": String(describing: error)])
                await handler?(.issue("A rider could not be reached. Retrying nearby connections."))
            }
        }
        await finish(id, generation: expected)
    }

    private func deliver(_ envelope: PeerEnvelope, connectionID: UUID, generation expected: UUID) async {
        guard generation == expected, active[envelope.senderID] == connectionID else { return }
        records[connectionID]?.lastReceivedAt = Date()
        await handler?(.message(envelope))
    }

    private func finish(_ id: UUID, generation expected: UUID) async {
        guard expected == generation, let record = records.removeValue(forKey: id) else { return }
        let peerID = record.remotePeerID ?? record.expectedPeerID
        if let peerID {
            if active[peerID] == id { active.removeValue(forKey: peerID) }
            if active[peerID] == nil { scheduleRetry(peerID) }
        }
        Task { await record.connection.close(notifyPeer: false) }
        await publishParticipants()
    }

    private func scheduleRetry(_ id: UUID) {
        let attempt = attempts[id, default: 0]
        attempts[id] = min(attempt + 1, 5)
        retryAt[id] = Date().addingTimeInterval(min(pow(2, Double(attempt)), 30) + Double.random(in: 0...0.5))
    }

    private func publishParticipants() async {
        guard let chat else { return }
        var participants = candidates.map { id, peer in
            ChatParticipant(chatID: chat.id, peerID: id, displayName: peer.displayName,
                state: active[id] != nil ? .connected :
                    (records.values.contains { $0.expectedPeerID == id } ? .connecting : .discovered))
        }
        for peerID in active.keys where candidates[peerID] == nil {
            participants.append(ChatParticipant(chatID: chat.id, peerID: peerID,
                displayName: active[peerID].flatMap { records[$0]?.remoteDisplayName } ?? "Nearby rider", state: .connected))
        }
        participants.sort { $0.peerID.uuidString < $1.peerID.uuidString }
        await handler?(.participants(participants))
    }

    func send(_ message: PeerMessage, to peerID: UUID) async throws {
        guard let chat, message.chatID == chat.id else { throw PeerConnectionError.wrongChat }
        guard let id = active[peerID], let connection = records[id]?.connection else {
            throw PeerConnectionError.connectionClosed
        }
        try await connection.send(message)
    }

    func broadcast(_ message: ChatMessage) async throws {
        guard message.chatID == chat?.id else { throw PeerConnectionError.wrongChat }
        let current = active.values.compactMap { records[$0]?.connection }
        var firstError: (any Error)?
        for connection in current {
            do { try await connection.sendChatMessage(message) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    func close() async {
        generation = UUID()
        ticker?.cancel()
        ticker = nil
        let previous = Array(records.values)
        records.removeAll()
        active.removeAll()
        candidates.removeAll()
        attempts.removeAll()
        retryAt.removeAll()
        chat = nil
        handler = nil
        for record in previous {
            record.task?.cancel()
            Task { await record.connection.close(reason: "Left chat") }
        }
    }
}
