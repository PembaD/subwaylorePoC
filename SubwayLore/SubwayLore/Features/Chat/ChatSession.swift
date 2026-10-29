import Foundation

actor ChatSession {
    private let store: ChatStore
    private let coordinator: ActivityCoordinator
    private let clock: any SessionClock
    private var lease: ActivityLease?
    private var historyTimeouts: [UUID: Task<Void, Never>] = [:]
    private var historyTransfers: [UUID: Task<Void, Never>] = [:]
    private var identity: PeerIdentity
    private var snapshot = ChatSnapshot()
    private var continuation: AsyncStream<ChatSnapshot>.Continuation?
    private var generation = UUID()
    private var peers: [DiscoveredPeer] = []
    private var pendingHistory: [UUID: UUID] = [:]
    private var hasMembership: Bool {
        if case .joined = snapshot.state { return true }
        return false
    }

    init(identity: PeerIdentity, store: ChatStore, coordinator: ActivityCoordinator,
         clock: any SessionClock = ContinuousSessionClock()) {
        self.identity = identity
        self.store = store
        self.coordinator = coordinator
        self.clock = clock
    }

    func currentSnapshot() -> ChatSnapshot { snapshot }

    private func activeLease() throws -> ActivityLease {
        guard let lease else { throw ActivityCoordinatorError.superseded }
        return lease
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
        await lease?.updatePeers(peers)
    }

    func updateIdentity(_ identity: PeerIdentity) async {
        await leave()
        self.identity = identity
    }

    func create() async throws -> Chat {
        let chat = Chat.make(for: identity)
        try await resume(chat)
        return chat
    }

    func join(_ discovered: DiscoveredChat) async throws -> Chat {
        if let saved = snapshot.history.first(where: { $0.id == discovered.id })?.chat {
            try await resume(saved)
            return saved
        }
        // Discovery is only a hint; canonical metadata arrives in joinActivityAccepted.
        let hint = Chat(id: discovered.id, title: discovered.title, createdAt: .distantPast,
                        createdByPeerID: identity.id)
        try await begin(hint, member: false)
        return hint
    }

    func preview(_ chat: Chat) async throws {
        await coordinator.deactivate()
        await leave()
        snapshot.chat = chat
        snapshot.messages = try await store.messages(in: chat.id)
        publish()
    }

    func resume(_ chat: Chat) async throws {
        try await store.join(chat, localPeerID: identity.id)
        try await begin(chat, member: true)
    }

    private func begin(_ chat: Chat, member: Bool) async throws {
        await leave()
        generation = UUID()
        let expected = generation
        snapshot.chat = chat
        snapshot.state = member ? .joined(chat.id) : .joining(chat.id)
        snapshot.error = nil
        do { snapshot.messages = try await store.messages(in: chat.id) }
        catch { snapshot.error = "Unable to load chat history." }
        publish()
        let opened = try await coordinator.open(identity: identity, activity: .chat(chat),
            handler: { [weak self] event in await self?.handle(event, generation: expected) })
        guard expected == generation else {
            await opened.close()
            throw ActivityCoordinatorError.superseded
        }
        lease = opened
        await opened.updatePeers(peers)
        if member { await opened.advertise(chat, displayTitle: snapshot.displayTitle) }
        await loadHistory()
    }

    func leave(chatID: UUID? = nil) async {
        if let chatID, snapshot.chat?.id != chatID { return }
        generation = UUID()
        if let chat = snapshot.chat { snapshot.state = .leaving(chat.id) }
        pendingHistory.removeAll()
        for task in historyTimeouts.values { task.cancel() }
        for task in historyTransfers.values { task.cancel() }
        historyTimeouts.removeAll()
        historyTransfers.removeAll()
        let previousLease = lease
        lease = nil
        await previousLease?.close()
        snapshot.chat = nil
        snapshot.messages = []
        snapshot.participants = []
        snapshot.state = .idle
        snapshot.isSynchronizing = false
        publish()
    }

    func send(_ text: String) async throws {
        guard let chat = snapshot.chat, hasMembership, snapshot.isActive else {
            throw PeerProtocolError.admissionRejected("Join the chat before sending a message.")
        }
        let validated = try TextMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let message = ChatMessage(id: UUID(), senderID: identity.id, senderName: identity.displayName,
                                  text: validated.text, sentAt: Date(), chatID: chat.id)
        let expected = generation
        try await store.merge([message], chatID: chat.id)
        guard expected == generation else { return }
        try await refreshMessages(chat.id)
        do { try await activeLease().broadcast(message) }
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
                do { try await activeLease().send(.historySyncRequest(chat.id), to: participant.peerID) }
                catch { snapshot.error = "History sync could not reach a rider. Try again when connected." }
            }
            await sendInventory(to: participant.peerID, generation: generation)
        }
        publish()
    }

    private func handle(_ event: ActivityTransportEvent, generation expected: UUID) async {
        guard generation == expected, snapshot.isActive, let chat = snapshot.chat else { return }
        do {
            switch event {
            case .connected(let peer):
                guard case .chat(let remoteChat) = peer.activity else { throw PeerProtocolError.wrongActivity }
                if !hasMembership {
                    try await store.join(remoteChat, localPeerID: identity.id)
                    guard generation == expected else { return }
                    snapshot.chat = remoteChat
                    snapshot.state = .joined(remoteChat.id)
                    await lease?.adoptChat(remoteChat)
                    // Future handshakes must advertise canonical metadata, never the initial hint.
                    await lease?.advertise(remoteChat, displayTitle: snapshot.displayTitle)
                }
                snapshot.error = nil
                scheduleInventory(to: peer.id, generation: expected)
                await loadHistory()
            case .participants(let participants):
                snapshot.participants = participants
                if participants.count > 8 {
                    snapshot.error = "This device supports eight direct rider connections. Some riders may not receive your messages."
                }
            case .issue(let message):
                snapshot.error = message
            case .deactivated:
                await leave()
            case .disconnected, .admissionRejected:
                break
            case .message(let envelope):
                guard hasMembership else { return }
                try await receive(envelope, chatID: chat.id, generation: expected)
            }
        } catch {
            guard generation == expected else { return }
            snapshot.error = "Chat data could not be saved or synchronized. Try again."
        }
        guard generation == expected else { return }
        snapshot.isSynchronizing = !pendingHistory.isEmpty
        publish()
    }

    private func receive(_ envelope: PeerEnvelope, chatID: UUID, generation expected: UUID) async throws {
        switch envelope.body {
        case .historySyncRequest(let requestedChatID):
            guard requestedChatID == chatID else { throw PeerProtocolError.wrongActivity }
            scheduleInventory(to: envelope.senderID, generation: expected)
        case .chatText(let message):
            guard message.chatID == chatID, message.id == envelope.id,
                  message.senderID == envelope.senderID else { throw PeerProtocolError.wrongActivity }
            try await store.merge([message], chatID: chatID)
            guard generation == expected else { return }
            try await refreshMessages(chatID)
        case .historyInventory(let inventory):
            guard inventory.chatID == chatID, inventory.messageIDs.count <= 100 else {
                throw PeerProtocolError.wrongActivity
            }
            let known = try await store.messages(in: chatID)
            let missing = ChatHistorySync.missingIDs(inventory, knownMessages: known)
            guard !missing.isEmpty, generation == expected else { return }
            pendingHistory[inventory.requestID] = envelope.senderID
            do {
                try await activeLease().send(.historyRequest(HistoryRequest(
                    chatID: chatID, requestID: inventory.requestID, messageIDs: missing)), to: envelope.senderID)
            } catch {
                guard expected == generation else { return }
                pendingHistory.removeValue(forKey: inventory.requestID)
                throw error
            }
            guard expected == generation else { return }
            let clock = self.clock
            historyTimeouts[inventory.requestID]?.cancel()
            historyTimeouts[inventory.requestID] = Task { [weak self] in
                do { try await clock.sleep(for: .seconds(30)) } catch { return }
                await self?.historyTimedOut(inventory.requestID, generation: expected)
            }
        case .historyRequest(let request):
            guard request.chatID == chatID, request.messageIDs.count <= 100 else {
                throw PeerProtocolError.wrongActivity
            }
            guard historyTransfers[request.requestID] == nil else { return }
            historyTransfers[request.requestID] = Task { [weak self] in
                await self?.sendHistory(request, to: envelope.senderID, generation: expected)
            }
        case .historyBatch(let batch):
            guard batch.chatID == chatID, batch.messages.count <= 100,
                  pendingHistory[batch.requestID] == envelope.senderID else { throw PeerProtocolError.wrongActivity }
            try await store.merge(batch.messages, chatID: chatID)
            guard generation == expected else { return }
            try await refreshMessages(chatID)
        case .historyComplete(let complete):
            guard complete.chatID == chatID, pendingHistory[complete.requestID] == envelope.senderID else {
                throw PeerProtocolError.wrongActivity
            }
            pendingHistory.removeValue(forKey: complete.requestID)
            historyTimeouts.removeValue(forKey: complete.requestID)?.cancel()
        default: break
        }
    }

    private func sendHistory(_ request: HistoryRequest, to peerID: UUID, generation expected: UUID) async {
        defer {
            if expected == generation { historyTransfers.removeValue(forKey: request.requestID) }
        }
        guard expected == generation, snapshot.chat?.id == request.chatID else { return }
        do {
            let requested = Set(request.messageIDs)
            let messages = try await store.messages(in: request.chatID).filter { requested.contains($0.id) }
            // One record per frame bounds size while the receive loop remains free to process other traffic.
            for message in messages {
                guard generation == expected else { return }
                try await activeLease().send(.historyBatch(HistoryBatch(
                    chatID: request.chatID, requestID: request.requestID, messages: [message])), to: peerID)
            }
            guard generation == expected else { return }
            try await activeLease().send(.historyComplete(HistoryComplete(
                chatID: request.chatID, requestID: request.requestID)), to: peerID)
        } catch {
            guard expected == generation else { return }
            snapshot.error = "History transfer was interrupted. Tap Retry to synchronize again."
            publish()
        }
    }

    private func historyTimedOut(_ id: UUID, generation expected: UUID) {
        guard expected == generation, pendingHistory.removeValue(forKey: id) != nil else { return }
        historyTimeouts.removeValue(forKey: id)
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
                try await activeLease().send(.historyInventory(page), to: peerID)
            }
        } catch {
            guard expected == generation else { return }
            snapshot.error = "History sync was interrupted. Tap Retry to synchronize again."
            publish()
        }
    }

    private func scheduleInventory(to peerID: UUID, generation expected: UUID) {
        let taskID = UUID()
        historyTransfers[taskID] = Task { [weak self] in
            await self?.sendInventory(to: peerID, generation: expected)
            await self?.finishTransfer(taskID, generation: expected)
        }
    }

    private func finishTransfer(_ id: UUID, generation expected: UUID) {
        if expected == generation { historyTransfers.removeValue(forKey: id) }
    }

    private func refreshMessages(_ chatID: UUID) async throws {
        let messages = try await store.messages(in: chatID)
        let history = try await store.history(for: identity.id)
        guard snapshot.chat?.id == chatID else { return }
        let previousTitle = snapshot.displayTitle
        snapshot.messages = messages
        snapshot.history = history
        publish()
        if previousTitle != snapshot.displayTitle, snapshot.isActive, hasMembership, let chat = snapshot.chat {
            await lease?.advertise(chat, displayTitle: snapshot.displayTitle)
        }
    }

    private func publish() { continuation?.yield(snapshot) }
}
