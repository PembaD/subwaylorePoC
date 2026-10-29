import Foundation

actor ChatSession {
    private let store: ChatStore
    private let transport: PeerTransport
    private let discovery: PeerDiscovery
    private var identity: PeerIdentity
    private var snapshot = ChatSnapshot()
    private var continuation: AsyncStream<ChatSnapshot>.Continuation?
    private var generation = UUID()
    private var peers: [DiscoveredPeer] = []
    private var pendingHistory: [UUID: UUID] = [:]
    private var hasMembership = false

    init(identity: PeerIdentity, store: ChatStore, transport: PeerTransport, discovery: PeerDiscovery) {
        self.identity = identity
        self.store = store
        self.transport = transport
        self.discovery = discovery
    }

    func snapshots() -> AsyncStream<ChatSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation?.finish()
            self.continuation = continuation
            continuation.yield(snapshot)
        }
    }

    func loadHistory() async {
        do { snapshot.history = try await store.history(for: identity.id) }
        catch { snapshot.error = "Saved chats could not be loaded. Your history has not been overwritten." }
        publish()
    }

    func updatePeers(_ peers: [DiscoveredPeer]) async {
        self.peers = peers
        await transport.updatePeers(peers)
    }

    func updateIdentity(_ identity: PeerIdentity) async {
        await leave()
        self.identity = identity
    }

    func create(title: String) async throws -> Chat {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 80 else {
            throw PeerConnectionError.admissionRejected("Use a chat name of 80 bytes or less.")
        }
        let chat = Chat(id: UUID(), title: trimmed, createdAt: Date(), createdByPeerID: identity.id)
        try await resume(chat)
        return chat
    }

    func join(_ discovered: DiscoveredChat) async throws -> Chat {
        if let saved = snapshot.history.first(where: { $0.id == discovered.id })?.chat {
            try await resume(saved)
            return saved
        }
        // Discovery is only a hint; canonical metadata arrives in joinChatAccepted.
        let hint = Chat(id: discovered.id, title: discovered.title, createdAt: .distantPast,
                        createdByPeerID: identity.id)
        await begin(hint, member: false)
        return hint
    }

    func preview(_ chat: Chat) async throws {
        await leave()
        snapshot.chat = chat
        snapshot.messages = try await store.messages(in: chat.id)
        publish()
    }

    func resume(_ chat: Chat) async throws {
        try await store.join(chat, localPeerID: identity.id)
        await begin(chat, member: true)
    }

    private func begin(_ chat: Chat, member: Bool) async {
        await leave()
        generation = UUID()
        let expected = generation
        hasMembership = member
        snapshot.chat = chat
        snapshot.state = member ? .joined(chat.id) : .joining(chat.id)
        snapshot.error = nil
        do { snapshot.messages = try await store.messages(in: chat.id) }
        catch { snapshot.error = "Unable to load chat history." }
        publish()
        let discovery = self.discovery
        await transport.open(identity: identity, chat: chat,
            endpointLookup: { id in await discovery.endpoint(for: id) },
            handler: { [weak self] event in await self?.handle(event, generation: expected) })
        guard expected == generation else { return }
        await transport.updatePeers(peers)
        if member { await discovery.advertise(chat) }
        await loadHistory()
    }

    func leave(chatID: UUID? = nil) async {
        if let chatID, snapshot.chat?.id != chatID { return }
        let wasActive = snapshot.isActive
        generation = UUID()
        if let chat = snapshot.chat { snapshot.state = .leaving(chat.id) }
        pendingHistory.removeAll()
        await transport.close()
        if wasActive { await discovery.advertise(nil) }
        snapshot.chat = nil
        snapshot.messages = []
        snapshot.participants = []
        snapshot.state = .idle
        snapshot.isSynchronizing = false
        hasMembership = false
        publish()
    }

    func send(_ text: String) async throws {
        guard let chat = snapshot.chat, hasMembership, snapshot.isActive else {
            throw PeerConnectionError.admissionRejected("Join the chat before sending a message.")
        }
        let validated = try TextMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let message = ChatMessage(id: UUID(), senderID: identity.id, senderName: identity.displayName,
                                  text: validated.text, sentAt: Date(), chatID: chat.id)
        let expected = generation
        try await store.merge([message], chatID: chat.id)
        guard expected == generation else { return }
        try await refreshMessages(chat.id)
        do { try await transport.broadcast(message) }
        catch {
            guard expected == generation else { return }
            snapshot.error = "Message saved here. Some riders could not be reached; history sync will share it when they reconnect."
            publish()
        }
    }

    func retryHistory() async {
        snapshot.error = nil
        for participant in snapshot.participants where participant.state == .connected {
            if let chat = snapshot.chat {
                try? await transport.send(.historySyncRequest(chat.id), to: participant.peerID)
            }
            await sendInventory(to: participant.peerID, generation: generation)
        }
        publish()
    }

    private func handle(_ event: PeerTransportEvent, generation expected: UUID) async {
        guard generation == expected, snapshot.isActive, let chat = snapshot.chat else { return }
        do {
            switch event {
            case .connected(let peer):
                if !hasMembership {
                    try await store.join(peer.chat, localPeerID: identity.id)
                    guard generation == expected else { return }
                    hasMembership = true
                    snapshot.chat = peer.chat
                    snapshot.state = .joined(peer.chat.id)
                    await transport.adoptChat(peer.chat)
                    // Future handshakes must advertise canonical metadata, never the initial hint.
                    await discovery.advertise(peer.chat)
                }
                snapshot.error = nil
                Task { [weak self] in await self?.sendInventory(to: peer.id, generation: expected) }
                await loadHistory()
            case .participants(let participants):
                snapshot.participants = participants
                if participants.count > 8 {
                    snapshot.error = "This device supports eight direct rider connections. Some riders may not receive your messages."
                }
            case .issue(let message):
                snapshot.error = message
            case .message(let envelope):
                guard hasMembership else { return }
                try await receive(envelope, chatID: chat.id, generation: expected)
            }
        } catch {
            snapshot.error = "Chat data could not be saved or synchronized. Try again."
        }
        guard generation == expected else { return }
        snapshot.isSynchronizing = !pendingHistory.isEmpty
        publish()
    }

    private func receive(_ envelope: PeerEnvelope, chatID: UUID, generation expected: UUID) async throws {
        switch envelope.body {
        case .historySyncRequest(let requestedChatID):
            guard requestedChatID == chatID else { throw PeerConnectionError.wrongChat }
            Task { [weak self] in await self?.sendInventory(to: envelope.senderID, generation: expected) }
        case .chatText(let message):
            guard message.chatID == chatID, message.id == envelope.id,
                  message.senderID == envelope.senderID else { throw PeerConnectionError.wrongChat }
            try await store.merge([message], chatID: chatID)
            guard generation == expected else { return }
            try await refreshMessages(chatID)
        case .historyInventory(let inventory):
            guard inventory.chatID == chatID, inventory.messageIDs.count <= 100 else {
                throw PeerConnectionError.wrongChat
            }
            let known = try await store.messages(in: chatID)
            let missing = ChatHistorySync.missingIDs(inventory, knownMessages: known)
            guard !missing.isEmpty, generation == expected else { return }
            pendingHistory[inventory.requestID] = envelope.senderID
            try await transport.send(.historyRequest(HistoryRequest(
                chatID: chatID, requestID: inventory.requestID, messageIDs: missing)), to: envelope.senderID)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.historyTimedOut(inventory.requestID, generation: expected)
            }
        case .historyRequest(let request):
            guard request.chatID == chatID, request.messageIDs.count <= 100 else {
                throw PeerConnectionError.wrongChat
            }
            Task { [weak self] in
                await self?.sendHistory(request, to: envelope.senderID, generation: expected)
            }
        case .historyBatch(let batch):
            guard batch.chatID == chatID, batch.messages.count <= 100,
                  pendingHistory[batch.requestID] == envelope.senderID else { throw PeerConnectionError.wrongChat }
            try await store.merge(batch.messages, chatID: chatID)
            guard generation == expected else { return }
            try await refreshMessages(chatID)
        case .historyComplete(let complete):
            guard complete.chatID == chatID, pendingHistory[complete.requestID] == envelope.senderID else {
                throw PeerConnectionError.wrongChat
            }
            pendingHistory.removeValue(forKey: complete.requestID)
        default: break
        }
    }

    private func sendHistory(_ request: HistoryRequest, to peerID: UUID, generation expected: UUID) async {
        guard expected == generation, snapshot.chat?.id == request.chatID else { return }
        do {
            let requested = Set(request.messageIDs)
            let messages = try await store.messages(in: request.chatID).filter { requested.contains($0.id) }
            // One record per frame bounds size while the receive loop remains free to process other traffic.
            for message in messages {
                guard generation == expected else { return }
                try await transport.send(.historyBatch(HistoryBatch(
                    chatID: request.chatID, requestID: request.requestID, messages: [message])), to: peerID)
            }
            guard generation == expected else { return }
            try await transport.send(.historyComplete(HistoryComplete(
                chatID: request.chatID, requestID: request.requestID)), to: peerID)
        } catch {
            guard expected == generation else { return }
            snapshot.error = "History transfer was interrupted. Tap Retry to synchronize again."
            publish()
        }
    }

    private func historyTimedOut(_ id: UUID, generation expected: UUID) {
        guard expected == generation, pendingHistory.removeValue(forKey: id) != nil else { return }
        snapshot.error = "History sync was interrupted. Tap Retry to synchronize again."
        snapshot.isSynchronizing = !pendingHistory.isEmpty
        publish()
    }

    private func sendInventory(to peerID: UUID, generation expected: UUID) async {
        guard expected == generation, let chat = snapshot.chat, hasMembership else { return }
        do {
            let messages = try await store.messages(in: chat.id)
            for page in ChatHistorySync.inventoryPages(messages, chatID: chat.id) {
                guard expected == generation else { return }
                try await transport.send(.historyInventory(page), to: peerID)
            }
        } catch {
            guard expected == generation else { return }
            snapshot.error = "History sync was interrupted. Tap Retry to synchronize again."
            publish()
        }
    }

    private func refreshMessages(_ chatID: UUID) async throws {
        let messages = try await store.messages(in: chatID)
        let history = try await store.history(for: identity.id)
        guard snapshot.chat?.id == chatID else { return }
        snapshot.messages = messages
        snapshot.history = history
        publish()
    }

    private func publish() { continuation?.yield(snapshot) }
}
