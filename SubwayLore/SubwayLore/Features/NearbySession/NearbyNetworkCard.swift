import SwiftUI

struct NearbyNetworkCard: View {
    let identity: PeerIdentity
    let snapshot: DiscoverySnapshot

    private let positions: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.24),
        CGPoint(x: 0.80, y: 0.20),
        CGPoint(x: 0.86, y: 0.72),
        CGPoint(x: 0.18, y: 0.76),
        CGPoint(x: 0.50, y: 0.12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            networkMap
            footer
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(alignment: .topTrailing) {
                    RadialGradient(
                        colors: [Color.loreGreen.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                    .frame(width: 220, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NEARBY NETWORK")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.42))

                Text(statusTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            statusIndicator
        }
    }

    private var networkMap: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.54)

            ZStack {
                ForEach(Array(visiblePeers.enumerated()), id: \.element.id) { index, _ in
                    let destination = point(for: positions[index], in: geometry.size)
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: destination)
                    }
                    .stroke(
                        peerColor(index).opacity(0.65),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6])
                    )
                }

                if visiblePeers.isEmpty {
                    Circle()
                        .stroke(Color.loreGreen.opacity(0.18), lineWidth: 1)
                        .frame(width: 116, height: 116)
                    Circle()
                        .stroke(Color.loreGreen.opacity(0.1), lineWidth: 1)
                        .frame(width: 164, height: 164)
                }

                localNode
                    .position(center)

                ForEach(Array(visiblePeers.enumerated()), id: \.element.id) { index, peer in
                    peerNode(peer, color: peerColor(index))
                        .position(point(for: positions[index], in: geometry.size))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.78), value: visiblePeers)
        }
        .frame(height: 210)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(networkAccessibilityLabel)
    }

    private var localNode: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color.loreGreen.gradient)
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Color.loreInk)
                }
                .overlay {
                    Circle().stroke(.white.opacity(0.4), lineWidth: 2)
                }
                .shadow(color: Color.loreGreen.opacity(0.42), radius: 14)

            Text("YOU")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Color.loreGreen)
        }
    }

    private func peerNode(_ peer: DiscoveredPeer, color: Color) -> some View {
        VStack(spacing: 5) {
            Circle()
                .fill(color.gradient)
                .frame(width: 43, height: 43)
                .overlay {
                    Text(initials(for: peer.displayName))
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                .overlay {
                    Circle().stroke(Color.loreInk, lineWidth: 3)
                }

            Text(shortName(peer.displayName))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .frame(width: 76)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: footerSymbol)
                .foregroundStyle(statusColor)

            Text(statusDetail)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))

            Spacer()

            if snapshot.peers.count > visiblePeers.count {
                Text("+\(snapshot.peers.count - visiblePeers.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
        }
    }

    private var visiblePeers: [DiscoveredPeer] {
        Array(snapshot.peers.prefix(positions.count))
    }

    private var statusTitle: String {
        switch snapshot.state {
        case .peerFound: "Your car is forming"
        case .permissionUnavailable: "Local access needed"
        case .failed: "Discovery paused"
        case .notStarted: "Ready when you are"
        case .waitingForPermission: "Connecting locally"
        case .searching: "Looking for riders"
        }
    }

    private var statusDetail: String {
        switch snapshot.state {
        case .peerFound:
            "\(snapshot.peers.count) nearby \(snapshot.peers.count == 1 ? "rider" : "riders")"
        case .permissionUnavailable: "Enable Local Network access in Settings"
        case .failed: "Unable to search right now"
        case .notStarted: "Discovery has not started"
        case .waitingForPermission: "Waiting for Local Network access"
        case .searching: "Keep Subway Lore open nearby"
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.8), radius: 4)

            Text(statusLabel)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusLabel: String {
        switch snapshot.state {
        case .peerFound: "FOUND"
        case .permissionUnavailable, .failed: "ACTION"
        case .notStarted: "READY"
        case .waitingForPermission, .searching: "SEARCHING"
        }
    }

    private var statusColor: Color {
        switch snapshot.state {
        case .permissionUnavailable, .failed: .loreOrange
        default: .loreGreen
        }
    }

    private var footerSymbol: String {
        switch snapshot.state {
        case .permissionUnavailable, .failed: "exclamationmark.triangle.fill"
        case .peerFound: "dot.radiowaves.left.and.right"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    private var networkAccessibilityLabel: String {
        snapshot.peers.isEmpty
            ? "No nearby riders discovered"
            : "\(snapshot.peers.count) nearby riders discovered"
    }

    private func point(for normalizedPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalizedPoint.x * size.width, y: normalizedPoint.y * size.height)
    }

    private func peerColor(_ index: Int) -> Color {
        [.lorePurple, .loreBlue, .loreOrange, .loreGreen, .lorePurple][index % 5]
    }

    private func initials(for name: String) -> String {
        let suffix = name.split(separator: "-").last.map(String.init) ?? name
        return String(suffix.prefix(2)).uppercased()
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Rider-", with: "")
    }
}
