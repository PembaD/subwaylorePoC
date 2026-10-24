import SwiftUI

struct NearbySessionView: View {
    @ObservedObject var model: NearbySessionViewModel
    @State private var draft = ""

    var body: some View {
        ZStack {
            Color.loreInk.ignoresSafeArea()

            VStack(spacing: 0) {
                participantHeader
                Divider().overlay(Color.white.opacity(0.07))
                messageList
                composer
            }
        }
        .navigationTitle("Car Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { model.joinChat() }
        .onDisappear { model.leaveChat() }
    }

    private var participantHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(model.snapshot.connectedPeerCount) connected")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                if model.snapshot.peers.contains(where: { model.snapshot.linkState(for: $0) == .connecting }) {
                    Text("Connecting…")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    participant(initials: "YOU", name: "You", state: .connected, isLocal: true)

                    ForEach(model.snapshot.peers.prefix(8)) { peer in
                        participant(
                            initials: initials(for: peer.displayName),
                            name: shortName(peer.displayName),
                            state: model.snapshot.linkState(for: peer),
                            isLocal: false
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.05))
    }

    private func participant(
        initials: String,
        name: String,
        state: PeerLinkState,
        isLocal: Bool
    ) -> some View {
        VStack(spacing: 5) {
            Circle()
                .fill(isLocal ? Color.loreGreen : Color.white.opacity(0.09))
                .frame(width: 38, height: 38)
                .overlay {
                    Text(initials)
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundStyle(isLocal ? Color.loreInk : .white)
                }
                .overlay {
                    Circle().stroke(
                        state == .connected ? Color.loreGreen : Color.white.opacity(0.22),
                        lineWidth: 2
                    )
                }

            Text(name)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
                .frame(maxWidth: 54)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(stateLabel(state))")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if model.snapshot.chatMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.snapshot.chatMessages) { message in
                            messageBubble(message).id(message.id)
                        }
                    }
                }
                .padding(18)
            }
            .onChange(of: model.snapshot.chatMessages.count) {
                guard let id = model.snapshot.chatMessages.last?.id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.loreBlue)

            Text(model.snapshot.connectedPeerCount == 0 ? "Finding riders…" : "Start the conversation")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(model.snapshot.connectedPeerCount == 0
                 ? "Open Car Chat on another nearby device."
                 : "Messages stay with riders connected in this car.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        let isLocal = message.senderID == model.identity.id

        return VStack(alignment: isLocal ? .trailing : .leading, spacing: 4) {
            if !isLocal {
                Text(shortName(message.senderName))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Text(message.text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(isLocal ? Color.loreInk : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isLocal ? Color.loreGreen : Color.white.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
        .frame(maxWidth: .infinity, alignment: isLocal ? .trailing : .leading)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message this car", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(Color.loreInk)
                    .frame(width: 40, height: 40)
                    .background(Color.loreGreen, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(trimmedDraft.isEmpty || model.snapshot.connectedPeerCount == 0)
            .opacity(trimmedDraft.isEmpty || model.snapshot.connectedPeerCount == 0 ? 0.4 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendMessage() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        model.sendChatMessage(text)
        draft = ""
    }

    private func initials(for name: String) -> String {
        String(shortName(name).prefix(2)).uppercased()
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Rider-", with: "")
    }

    private func stateLabel(_ state: PeerLinkState) -> String {
        switch state {
        case .discovered: "nearby"
        case .connecting: "connecting"
        case .connected: "connected"
        }
    }
}
