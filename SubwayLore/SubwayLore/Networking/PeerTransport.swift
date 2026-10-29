import Foundation
import Network

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
    private var activity: ActivityDescriptor?
    private var admissionPolicy: (@Sendable (UUID) async -> String?)?
    private var generation = UUID()
    private var records: [UUID: Record] = [:]
    private var active: [UUID: UUID] = [:]
    private var candidates: [UUID: DiscoveredPeer] = [:]
    private var attempts: [UUID: Int] = [:]
    private var retryAt: [UUID: Date] = [:]
    private var ticker: Task<Void, Never>?
    private var handler: (@Sendable (ActivityTransportEvent) async -> Void)?
    private var endpointLookup: (@Sendable (UUID) async -> Bonjour.Endpoint?)?

    init(diagnostics: DiagnosticsRecorder) { self.diagnostics = diagnostics }

    func open(identity: PeerIdentity, chat: Chat,
              endpointLookup: @escaping @Sendable (UUID) async -> Bonjour.Endpoint?,
              handler: @escaping @Sendable (ActivityTransportEvent) async -> Void) async {
        await open(identity: identity, activity: .chat(chat), endpointLookup: endpointLookup, handler: handler)
    }

    func open(identity: PeerIdentity, activity: ActivityDescriptor,
              endpointLookup: @escaping @Sendable (UUID) async -> Bonjour.Endpoint?,
              admissionPolicy: (@Sendable (UUID) async -> String?)? = nil,
              handler: @escaping @Sendable (ActivityTransportEvent) async -> Void) async {
        await close()
        self.identity = identity
        self.activity = activity
        self.admissionPolicy = admissionPolicy
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
        guard let activity, let identity else { return }
        candidates = peers.reduce(into: [:]) { result, peer in
            guard let id = peer.peerID, activity.allows(peerID: id, localID: identity.id) else { return }
            switch activity {
            case .chat(let chat):
                if peer.chatID == chat.id { result[id] = peer }
            case .game(let game):
                if identity.id != game.hostPeerID, id == game.hostPeerID, peer.gameID == game.id { result[id] = peer }
            }
        }
        await publishParticipants()
    }

    func adoptChat(_ chat: Chat) {
        guard case .chat(let current) = activity, current.id == chat.id else { return }
        self.activity = .chat(chat)
    }

    func accept(_ connection: NetworkConnection<TLS>) async {
        guard activity != nil, records.count < 16 else { return }
        launch(connection, direction: .incoming, expectedPeerID: nil)
    }

    private func reconcile(generation expected: UUID) async {
        guard expected == generation, activity != nil else { return }
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
                  reservedPeerIDs.count < remoteLimit,
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
        guard let identity, let activity else { return }
        let id = UUID()
        let expectedGeneration = generation
        let connection = PeerConnection(
            id: id, connection: network, direction: direction, localIdentity: identity, activity: activity,
            expectedPeerID: expectedPeerID, diagnostics: diagnostics,
            admissionCheck: { [weak self] peerID in
                guard let self else { return "Activity is no longer available" }
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

    private func reserve(peerID: UUID, connectionID: UUID, generation expected: UUID) async -> String? {
        guard expected == generation, let activity, let identity, records[connectionID] != nil else {
            return "Activity is no longer available"
        }
        guard activity.allows(peerID: peerID, localID: identity.id) else {
            return "Connect to the game creator to join"
        }
        let reserved = reservedPeerIDs
        guard reserved.contains(peerID) || reserved.count < remoteLimit else {
            return capacityMessage
        }
        records[connectionID]?.remotePeerID = peerID
        if let rejection = await admissionPolicy?(peerID) { return rejection }
        guard expected == generation, records[connectionID] != nil else { return "Activity is no longer available" }
        return nil
    }

    private var remoteLimit: Int {
        guard let activity, let identity else { return 0 }
        return activity.remoteLimit(for: identity.id)
    }

    private var capacityMessage: String {
        if case .game = activity { return "This game is full (8 players maximum)." }
        return "This device is at its eight-rider connection limit."
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
                    throw PeerProtocolError.admissionRejected("Connection timed out")
                }
                defer { group.cancelAll() }
                guard let peer = try await group.next() else { throw PeerProtocolError.handshakeIncomplete }
                return peer
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
            guard active.count < remoteLimit else {
                await handler?(.issue(capacityMessage))
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
                    summary: "Activity connection ended", metadata: ["error": String(describing: error)])
                guard expected == generation, !Task.isCancelled else { return }
                if let error = error as? PeerProtocolError, case .admissionRejected(let reason) = error {
                    await handler?(.admissionRejected(reason))
                }
            }
        }
        await finish(id, generation: expected)
    }

    private func deliver(_ envelope: PeerEnvelope, connectionID: UUID, generation expected: UUID) async {
        guard generation == expected, active[envelope.senderID] == connectionID else { return }
        records[connectionID]?.lastReceivedAt = Date()
        if let scope = envelope.body.scopeID {
            guard scope == activity?.id, envelope.body.scopeKind == activity?.kind else { return }
        }
        await handler?(.message(envelope))
    }

    private func finish(_ id: UUID, generation expected: UUID) async {
        guard expected == generation, let record = records.removeValue(forKey: id) else { return }
        Task { await record.connection.close(notifyPeer: false) }
        let peerID = record.remotePeerID ?? record.expectedPeerID
        if let peerID {
            if active[peerID] == id {
                active.removeValue(forKey: peerID)
                await handler?(.disconnected(peerID))
            } else if active[peerID] == nil {
                await handler?(.disconnected(peerID))
            }
            guard expected == generation else { return }
            if active[peerID] == nil { scheduleRetry(peerID) }
        }
        guard expected == generation else { return }
        await publishParticipants()
    }

    private func scheduleRetry(_ id: UUID) {
        let attempt = attempts[id, default: 0]
        attempts[id] = min(attempt + 1, 5)
        retryAt[id] = Date().addingTimeInterval(min(pow(2, Double(attempt)), 30) + Double.random(in: 0...0.5))
    }

    private func publishParticipants() async {
        guard let activity else { return }
        var participants = candidates.map { id, peer in
            ActivityParticipant(activityID: activity.id, peerID: id, displayName: peer.displayName,
                state: active[id] != nil ? .connected :
                    (records.values.contains { $0.expectedPeerID == id } ? .connecting : .discovered))
        }
        for peerID in active.keys where candidates[peerID] == nil {
            participants.append(ActivityParticipant(activityID: activity.id, peerID: peerID,
                displayName: active[peerID].flatMap { records[$0]?.remoteDisplayName } ?? "Nearby rider", state: .connected))
        }
        participants.sort { $0.peerID.uuidString < $1.peerID.uuidString }
        await handler?(.participants(participants))
    }

    func send(_ message: PeerMessage, to peerID: UUID) async throws {
        guard let activity, message.scopeID == activity.id, message.scopeKind == activity.kind else {
            throw PeerProtocolError.wrongActivity
        }
        guard let id = active[peerID], let connection = records[id]?.connection else {
            throw PeerProtocolError.connectionClosed
        }
        try await connection.send(message)
    }

    func broadcast(_ message: ChatMessage) async throws {
        guard case .chat(let chat) = activity, message.chatID == chat.id else { throw PeerProtocolError.wrongActivity }
        let current = active.values.compactMap { records[$0]?.connection }
        var firstError: (any Error)?
        for connection in current {
            do { try await connection.sendChatMessage(message) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    func disconnect(_ peerID: UUID) async {
        let ids = records.values.filter { $0.remotePeerID == peerID || $0.expectedPeerID == peerID }.map(\.id)
        for id in ids {
            records[id]?.task?.cancel()
            await finish(id, generation: generation)
        }
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
        activity = nil
        admissionPolicy = nil
        handler = nil
        for record in previous {
            record.task?.cancel()
            Task { await record.connection.close(reason: "Left activity") }
        }
    }
}
