import Foundation
import Network

actor PeerDiscovery {
    static let serviceType = "_subwaylore._tcp"

    typealias IncomingConnection = NetworkConnection<TLS>
    typealias IncomingConnectionHandler = @Sendable (IncomingConnection) async -> Void

    private let identity: PeerIdentity
    private let diagnostics: DiagnosticsRecorder
    private let incomingConnectionHandler: IncomingConnectionHandler

    private var listener: NetworkListener<TLS>?
    private var browser: NetworkBrowser<Bonjour>?
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?
    private var reducer = DiscoveryReducer()
    private var snapshotContinuation: AsyncStream<DiscoverySnapshot>.Continuation?
    private var generation = UUID()

    init(
        identity: PeerIdentity,
        diagnostics: DiagnosticsRecorder,
        incomingConnectionHandler: @escaping IncomingConnectionHandler = { _ in }
    ) {
        self.identity = identity
        self.diagnostics = diagnostics
        self.incomingConnectionHandler = incomingConnectionHandler
    }

    func snapshots() -> AsyncStream<DiscoverySnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotContinuation?.finish()
            snapshotContinuation = continuation
            continuation.yield(reducer.snapshot)
        }
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

    func stop() {
        generation = UUID()
        listenerTask?.cancel()
        browserTask?.cancel()
        listenerTask = nil
        browserTask = nil
        listener = nil
        browser = nil
        reducer.stop()
        publishSnapshot()
        record(.info, "Nearby discovery stopped")
    }

    private func runListener(generation expectedGeneration: UUID) async {
        do {
            let provider = BonjourListenerProvider.bonjour(
                name: identity.displayName,
                type: Self.serviceType
            )
            let parameters = NWParametersBuilder.parameters {
                TLS {
                    TCP()
                }
            }
            .peerToPeerIncluded(true)

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
                await self.incomingConnectionHandler(connection)
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

    private func replaceEndpoints(_ endpoints: [Bonjour.Endpoint], generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }

        let peers = endpoints.map { endpoint in
                DiscoveredPeer(
                    id: endpoint.id,
                    displayName: endpoint.name,
                    domain: endpoint.domain
                )
            }
        let changes = reducer.replacePeers(peers, localDisplayName: identity.displayName)
        publishSnapshot()

        for id in changes.addedIDs {
            record(.info, "Peer discovered", metadata: ["endpoint": id])
        }
        for id in changes.removedIDs {
            record(.info, "Peer removed", metadata: ["endpoint": id])
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
        record(.info, "Incoming connection accepted for Phase 3")
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
