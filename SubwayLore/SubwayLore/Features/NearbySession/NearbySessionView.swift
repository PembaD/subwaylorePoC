import SwiftUI

struct NearbySessionView: View {
    @StateObject private var model = NearbySessionViewModel()

    var body: some View {
        ZStack {
            Color.loreInk.ignoresSafeArea()

            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.snapshot.state.title, systemImage: statusSymbol)
                            .font(.headline)
                            .foregroundStyle(statusColor)
                        Text(model.snapshot.state.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(model.identity.displayName)
                }

                if let port = model.snapshot.listenerPort {
                    Section("Listener") {
                        LabeledContent("Bonjour service", value: PeerDiscovery.serviceType)
                        LabeledContent("TCP port", value: String(port))
                    }
                }

                Section("Nearby riders (\(model.snapshot.peers.count))") {
                    if model.snapshot.peers.isEmpty {
                        Text(emptyPeerMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.snapshot.peers) { peer in
                            Label(peer.displayName, systemImage: "iphone.radiowaves.left.and.right")
                        }
                    }
                }

                Section {
                    Button("Restart discovery") { model.restart() }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Nearby diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var emptyPeerMessage: String {
        switch model.snapshot.state {
        case .permissionUnavailable:
            "Discovery cannot search until local-network access is restored."
        default:
            "No other Subway Lore devices are advertising nearby."
        }
    }

    private var statusSymbol: String {
        switch model.snapshot.state {
        case .peerFound: "checkmark.circle.fill"
        case .permissionUnavailable, .failed: "exclamationmark.triangle.fill"
        case .searching, .waitingForPermission: "dot.radiowaves.left.and.right"
        case .notStarted: "pause.circle"
        }
    }

    private var statusColor: Color {
        switch model.snapshot.state {
        case .peerFound: .loreGreen
        case .permissionUnavailable, .failed: .orange
        default: .white
        }
    }
}
