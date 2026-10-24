import Foundation
import Network

actor PeerDiscovery {
    static let serviceType = "_subwaylore._tcp"
    private static let peerIDTXTKey = "peerID"

    private var identity: PeerIdentity
    private let diagnostics: DiagnosticsRecorder

    private var listener: NetworkListener<TLS>?
    private var browser: NetworkBrowser<Bonjour>?
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var reducer = DiscoveryReducer()
    private var snapshotContinuation: AsyncStream<DiscoverySnapshot>.Continuation?
    private var generation = UUID()
    private var endpointByPeerID: [UUID: Bonjour.Endpoint] = [:]
    private var pendingPeerIDs: Set<UUID> = []
    private var connections: [UUID: PeerConnection] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var remotePeerIDByConnectionID: [UUID: UUID] = [:]
    private var activeConnectionIDByPeerID: [UUID: UUID] = [:]
    private var chatPeerIDs: Set<UUID> = []
    private var maximumChatPeers = 8

    init(
        identity: PeerIdentity,
        diagnostics: DiagnosticsRecorder
    ) {
        self.identity = identity
        self.diagnostics = diagnostics
    }

    func snapshots() -> AsyncStream<DiscoverySnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuation?.finish()
            snapshotContinuation = continuation
            continuation.yield(reducer.snapshot)
        }
    }

    func updateIdentity(_ identity: PeerIdentity) async {
        await stop()
        self.identity = identity
        start()
    }

    func start() {
        guard listenerTask == nil, browserTask == nil else { return }

        let currentGeneration = UUID()
        generation = currentGeneration
        reducer.start()
        publishSnapshot()
        record(.info, "Nearby discovery starting")

        listenerTask = Task { [weak self] in
            await self?.runListener(generation: currentGeneration)
        }
        browserTask = Task { [weak self] in
            await self?.runBrowser(generation: currentGeneration)
        }
    }

    func stop() async {
        generation = UUID()
        listenerTask?.cancel()
        browserTask?.cancel()
        listenerTask = nil
        browserTask = nil
        listener = nil
        browser = nil
        await closeAllConnections(reason: "Nearby discovery stopped")
        chatPeerIDs.removeAll()
        endpointByPeerID.removeAll()
        reducer.stop()
        publishSnapshot()
        record(.info, "Nearby discovery stopped")
    }

    func joinChat(maximumPeers: Int = 8) async {
        guard !reducer.snapshot.isChatActive else { return }
        maximumChatPeers = max(1, maximumPeers)
        reducer.setChatActive(true)
        refreshChatPeerSelection()
        publishSnapshot()
        record(.info, "Car chat joined", metadata: ["maximumPeers": String(maximumChatPeers)])
        await connectToSelectedChatPeers(generation: generation)
    }

    func leaveChat() async {
        guard reducer.snapshot.isChatActive else { return }
        await closeAllConnections(reason: "Left car chat")
        chatPeerIDs.removeAll()
        reducer.setChatActive(false)
        publishSnapshot()
        record(.info, "Car chat left")
    }

    func sendChatMessage(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reducer.snapshot.isChatActive,
              let validated = try? TextMessage(text: text) else { return }

        let message = ChatMessage(
            id: UUID(),
            senderID: identity.id,
            senderName: identity.displayName,
            text: validated.text,
            sentAt: Date()
        )
        reducer.appendChatMessage(message)
        publishSnapshot()

        for connectionID in activeConnectionIDByPeerID.values {
            guard let connection = connections[connectionID] else { continue }
            do {
                try await connection.sendText(validated.text)
            } catch {
                record(.warning, "Unable to send chat message", metadata: [
                    "connectionID": connectionID.uuidString,
                    "error": String(describing: error),
                ])
            }
        }
    }

    private func runListener(generation expectedGeneration: UUID) async {
        do {
            let provider = BonjourListenerProvider.bonjour(
                name: identity.displayName,
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    Self.peerIDTXTKey: identity.id.uuidString,
                ])
            )
            let parameters = try TransportConfiguration.parameters()

            let listener = try NetworkListener(for: provider, using: parameters)
                .onStateUpdate { [weak self] listener, state in
                    Task { await self?.handleListenerState(state, port: listener.port, generation: expectedGeneration) }
                }
                .onServiceRegistrationUpdate { [weak self] _, change in
                    Task { await self?.handleRegistrationChange(change, generation: expectedGeneration) }
                }

            guard generation == expectedGeneration else { return }
            self.listener = listener

            try await listener.run { [weak self] connection in
                guard let self else { return }
                await self.recordIncomingConnection(generation: expectedGeneration)
                await self.startConnection(
                    connection,
                    direction: .incoming,
                    expectedPeerID: nil,
                    generation: expectedGeneration
                )
            }
        } catch is CancellationError {
            // Expected when the nearby session stops.
        } catch {
            handleFailure(error, component: "listener", generation: expectedGeneration)
        }
    }

    private func runBrowser(generation expectedGeneration: UUID) async {
        do {
            let parameters = NWParameters.tcp.peerToPeerIncluded(true)
            let browser = NetworkBrowser(
                for: .bonjour(Self.serviceType, includeTxtRecord: true),
                using: parameters
            )
            .onStateUpdate { [weak self] _, state in
                Task { await self?.handleBrowserState(state, generation: expectedGeneration) }
            }

            guard generation == expectedGeneration else { return }
            self.browser = browser

            try await browser.run { [weak self] endpoints in
                await self?.replaceEndpoints(endpoints, generation: expectedGeneration)
            }
        } catch is CancellationError {
            // Expected when the nearby session stops.
        } catch {
            handleFailure(error, component: "browser", generation: expectedGeneration)
        }
    }

    private func handleListenerState(
        _ state: NetworkListener<TLS>.State,
        port: NWEndpoint.Port?,
        generation expectedGeneration: UUID
    ) {
        guard generation == expectedGeneration else { return }

        switch state {
        case .setup:
            record(.debug, "Listener setup")
        case .waiting(let error):
            handleWaiting(error, component: "listener")
        case .ready:
            reducer.listenerReady(port: port.map(\.rawValue))
            publishSnapshot()
            record(.info, "Listener ready", metadata: ["port": port.map(String.init(describing:)) ?? "unknown"])
        case .failed(let error):
            handleFailure(error, component: "listener", generation: expectedGeneration)
        case .cancelled:
            record(.debug, "Listener cancelled")
        @unknown default:
            record(.warning, "Unknown listener state")
        }
    }

    private func handleBrowserState(
        _ state: NetworkBrowser<Bonjour>.State,
        generation expectedGeneration: UUID
    ) {
        guard generation == expectedGeneration else { return }

        switch state {
        case .setup:
            record(.debug, "Browser setup")
        case .waiting(let error):
            handleWaiting(error, component: "browser")
        case .ready:
            reducer.browserReady()
            publishSnapshot()
            record(.info, "Browser ready")
        case .failed(let error):
            handleFailure(error, component: "browser", generation: expectedGeneration)
        case .cancelled:
            record(.debug, "Browser cancelled")
        @unknown default:
            record(.warning, "Unknown browser state")
        }
    }

    private func replaceEndpoints(_ endpoints: [Bonjour.Endpoint], generation expectedGeneration: UUID) async {
        guard generation == expectedGeneration else { return }

        let peers = endpoints.map { endpoint in
                DiscoveredPeer(
                    id: endpoint.id,
                    peerID: endpoint.txtRecord[Self.peerIDTXTKey].flatMap(UUID.init(uuidString:)),
                    displayName: endpoint.name,
                    domain: endpoint.domain
                )
            }
        let changes = reducer.replacePeers(
            peers,
            localPeerID: identity.id
        )
        endpointByPeerID = Dictionary(
            uniqueKeysWithValues: endpoints.compactMap { endpoint in
                endpoint.txtRecord[Self.peerIDTXTKey]
                    .flatMap(UUID.init(uuidString:))
                    .map { ($0, endpoint) }
            }
        )
        publishSnapshot()

        for id in changes.addedIDs {
            record(.info, "Peer discovered", metadata: ["endpoint": id])
        }
        for id in changes.removedIDs {
            record(.info, "Peer removed", metadata: ["endpoint": id])
        }

        if reducer.snapshot.isChatActive {
            refreshChatPeerSelection()
            await connectToSelectedChatPeers(generation: expectedGeneration)
        }
    }

    private func handleWaiting(_ error: NWError, component: String) {
        if Self.isPermissionError(error) {
            reducer.permissionUnavailable("Enable Local Network access for Subway Lore in Settings, then try again.")
            publishSnapshot()
            record(.error, "Local-network permission unavailable", metadata: ["component": component, "error": String(describing: error)])
        } else {
            reducer.waitForPermission()
            publishSnapshot()
            record(.warning, "Discovery waiting", metadata: ["component": component, "error": String(describing: error)])
        }
    }

    private func handleFailure(_ error: Error, component: String, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        let message = String(describing: error)
        if let networkError = error as? NWError, Self.isPermissionError(networkError) {
            reducer.permissionUnavailable("Enable Local Network access for Subway Lore in Settings, then try again.")
        } else {
            reducer.fail("\(component.capitalized) failed: \(message)")
        }
        publishSnapshot()
        record(.error, "Discovery component failed", metadata: ["component": component, "error": message])
    }

    private func handleRegistrationChange(
        _ change: NetworkListener<TLS>.ServiceRegistrationChange,
        generation expectedGeneration: UUID
    ) {
        guard generation == expectedGeneration else { return }
        switch change {
        case .add(let endpoint):
            record(.info, "Bonjour service registered", metadata: ["endpoint": String(describing: endpoint)])
        case .remove(let endpoint):
            record(.info, "Bonjour service unregistered", metadata: ["endpoint": String(describing: endpoint)])
        @unknown default:
            record(.warning, "Unknown service registration change")
        }
    }

    private func recordIncomingConnection(generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        record(.info, "Incoming TLS connection accepted")
    }

    private func openOutgoingConnection(
        to endpoint: Bonjour.Endpoint,
        peerID: UUID,
        generation expectedGeneration: UUID
    ) async {
        guard generation == expectedGeneration,
              reducer.snapshot.isChatActive,
              chatPeerIDs.contains(peerID),
              activeConnectionIDByPeerID[peerID] == nil,
              !pendingPeerIDs.contains(peerID) else { return }
        do {
            let parameters = try TransportConfiguration.parameters()
            let connection = NetworkConnection<TLS>(to: endpoint, using: parameters)
            pendingPeerIDs.insert(peerID)
            reducer.setLinkState(.connecting, for: peerID)
            publishSnapshot()
            record(.info, "Opening outgoing TLS connection", metadata: ["peerID": peerID.uuidString])
            startConnection(
                connection,
                direction: .outgoing,
                expectedPeerID: peerID,
                generation: expectedGeneration
            )
        } catch {
            pendingPeerIDs.remove(peerID)
            reducer.setLinkState(.discovered, for: peerID)
            publishSnapshot()
            record(.error, "Unable to configure outgoing TLS connection", metadata: [
                "peerID": peerID.uuidString,
                "error": String(describing: error),
            ])
        }
    }

    private func startConnection(
        _ networkConnection: NetworkConnection<TLS>,
        direction: ConnectionDirection,
        expectedPeerID: UUID?,
        generation expectedGeneration: UUID
    ) {
        guard generation == expectedGeneration else { return }
        let connection = PeerConnection(
            connection: networkConnection,
            direction: direction,
            localIdentity: identity,
            expectedPeerID: expectedPeerID,
            diagnostics: diagnostics,
            messageHandler: { [weak self] envelope in
                await self?.receiveMessage(envelope)
            }
        )
        let connectionID = connection.id
        connections[connectionID] = connection
        connectionTasks[connectionID] = Task { [weak self] in
            await self?.runConnection(
                connection,
                connectionID: connectionID,
                direction: direction,
                expectedPeerID: expectedPeerID,
                generation: expectedGeneration
            )
        }
    }

    private func runConnection(
        _ connection: PeerConnection,
        connectionID: UUID,
        direction: ConnectionDirection,
        expectedPeerID: UUID?,
        generation expectedGeneration: UUID
    ) async {
        do {
            let remotePeer = try await connection.handshake()
            guard generation == expectedGeneration else {
                await connection.close(reason: "Stale discovery generation", notifyPeer: false)
                return
            }

            if try await acceptConnection(
                connection,
                connectionID: connectionID,
                remotePeer: remotePeer,
                direction: direction
            ) {
                try await connection.receiveUntilClosed()
            }
        } catch is CancellationError {
            // Expected when discovery stops or a duplicate connection loses arbitration.
        } catch {
            record(.warning, "Peer connection ended", metadata: [
                "connectionID": connectionID.uuidString,
                "error": String(describing: error),
            ])
        }

        await finishConnection(
            connection,
            connectionID: connectionID,
            expectedPeerID: expectedPeerID
        )
    }

    private func acceptConnection(
        _ connection: PeerConnection,
        connectionID: UUID,
        remotePeer: ConnectedPeer,
        direction: ConnectionDirection
    ) async throws -> Bool {
        guard reducer.snapshot.isChatActive, chatPeerIDs.contains(remotePeer.id) else {
            await connection.close(reason: "Car chat is not active", notifyPeer: false)
            return false
        }

        let preferredDirection = ConnectionArbitration.preferredDirection(
            localPeerID: identity.id,
            remotePeerID: remotePeer.id
        )
        guard direction == preferredDirection else {
            record(.info, "Duplicate connection rejected by direction arbitration", metadata: [
                "peerID": remotePeer.id.uuidString,
                "direction": direction.rawValue,
            ])
            await connection.close(reason: "Duplicate connection", notifyPeer: false)
            if preferredDirection == .outgoing,
               let endpoint = endpointByPeerID[remotePeer.id] {
                pendingPeerIDs.remove(remotePeer.id)
                await openOutgoingConnection(
                    to: endpoint,
                    peerID: remotePeer.id,
                    generation: generation
                )
            }
            return false
        }

        if let activeID = activeConnectionIDByPeerID[remotePeer.id], activeID != connectionID {
            record(.info, "Duplicate connection rejected", metadata: [
                "peerID": remotePeer.id.uuidString,
                "keptConnectionID": activeID.uuidString,
            ])
            await connection.close(reason: "Duplicate connection", notifyPeer: false)
            return false
        }

        pendingPeerIDs.remove(remotePeer.id)
        remotePeerIDByConnectionID[connectionID] = remotePeer.id
        activeConnectionIDByPeerID[remotePeer.id] = connectionID
        reducer.setLinkState(.connected, for: remotePeer.id)
        publishSnapshot()
        record(.info, "Secure peer connection established", metadata: [
            "peerID": remotePeer.id.uuidString,
            "direction": direction.rawValue,
        ])
        return true
    }

    private func finishConnection(
        _ connection: PeerConnection,
        connectionID: UUID,
        expectedPeerID: UUID?
    ) async {
        await connection.close(notifyPeer: false)
        connections.removeValue(forKey: connectionID)
        connectionTasks.removeValue(forKey: connectionID)

        let peerID = remotePeerIDByConnectionID.removeValue(forKey: connectionID) ?? expectedPeerID
        if let peerID {
            pendingPeerIDs.remove(peerID)
            if activeConnectionIDByPeerID[peerID] == connectionID {
                activeConnectionIDByPeerID.removeValue(forKey: peerID)
                reducer.setLinkState(.discovered, for: peerID)
                publishSnapshot()
            }
        }
    }

    private func refreshChatPeerSelection() {
        let visiblePeerIDs = reducer.snapshot.peers.compactMap(\.peerID)
        chatPeerIDs = Set(visiblePeerIDs.prefix(maximumChatPeers))
    }

    private func connectToSelectedChatPeers(generation expectedGeneration: UUID) async {
        for peerID in chatPeerIDs {
            guard let endpoint = endpointByPeerID[peerID] else { continue }
            await openOutgoingConnection(to: endpoint, peerID: peerID, generation: expectedGeneration)
        }
    }

    private func receiveMessage(_ envelope: PeerEnvelope) {
        guard reducer.snapshot.isChatActive,
              case .text(let textMessage) = envelope.body else { return }
        let senderName = reducer.snapshot.peers.first(where: { $0.peerID == envelope.senderID })?.displayName
            ?? "Nearby rider"
        reducer.appendChatMessage(
            ChatMessage(
                id: envelope.id,
                senderID: envelope.senderID,
                senderName: senderName,
                text: textMessage.text,
                sentAt: envelope.sentAt
            )
        )
        publishSnapshot()
    }

    private func closeAllConnections(reason: String) async {
        let tasks = Array(connectionTasks.values)
        let currentConnections = Array(connections.values)
        for task in tasks { task.cancel() }
        for connection in currentConnections {
            await connection.close(reason: reason)
        }
        connectionTasks.removeAll()
        connections.removeAll()
        remotePeerIDByConnectionID.removeAll()
        activeConnectionIDByPeerID.removeAll()
        pendingPeerIDs.removeAll()
    }

    private func publishSnapshot() {
        snapshotContinuation?.yield(reducer.snapshot)
    }

    private func record(
        _ severity: DiagnosticSeverity,
        _ summary: String,
        metadata: [String: String] = [:]
    ) {
        Task {
            await diagnostics.record(
                severity: severity,
                category: .discovery,
                localPeerID: identity.id,
                summary: summary,
                metadata: metadata
            )
        }
    }

    private static func isPermissionError(_ error: NWError) -> Bool {
        switch error {
        case .posix(.EACCES), .posix(.EPERM):
            true
        default:
            String(describing: error).localizedCaseInsensitiveContains("PolicyDenied")
        }
    }
}
