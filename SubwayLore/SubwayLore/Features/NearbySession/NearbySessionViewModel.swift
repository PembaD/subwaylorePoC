import Foundation

@MainActor
final class NearbySessionViewModel: ObservableObject {
    @Published private(set) var snapshot = DiscoverySnapshot()
    let identity: PeerIdentity

    private let discovery: PeerDiscovery
    private var monitorTask: Task<Void, Never>?

    init(
        identityStore: PeerIdentityStore = PeerIdentityStore(),
        diagnostics: DiagnosticsRecorder = DiagnosticsRecorder()
    ) {
        let identity = identityStore.loadOrCreate()
        self.identity = identity
        self.discovery = PeerDiscovery(identity: identity, diagnostics: diagnostics)
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await discovery.snapshots()
            await discovery.start()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { break }
                self.snapshot = snapshot
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        Task { await discovery.stop() }
    }

    func restart() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            await discovery.stop()
            let snapshots = await discovery.snapshots()
            await discovery.start()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { break }
                self.snapshot = snapshot
            }
        }
    }
}
