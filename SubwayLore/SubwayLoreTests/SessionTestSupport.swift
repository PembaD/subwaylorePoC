import Foundation
import Testing
@testable import SubwayLore

enum TestTransportError: Error { case sendFailed }

actor FakeActivityTransport: ActivityTransport {
    private(set) var activity: ActivityDescriptor?
    private(set) var closeCount = 0
    private(set) var sent: [(UUID, PeerMessage)] = []
    private(set) var broadcasts: [ChatMessage] = []
    private(set) var handlers: [ActivityEventHandler] = []
    private var handler: ActivityEventHandler?
    private var policy: ActivityAdmissionPolicy?
    var failSends = false
    private var pauseOpen = false
    private var openGate: CheckedContinuation<Void, Never>?
    private(set) var openIsPaused = false

    func setFailSends(_ value: Bool) { failSends = value }
    func pauseNextOpen() { pauseOpen = true }
    func resumeOpen() { openGate?.resume(); openGate = nil; openIsPaused = false }

    func open(identity: PeerIdentity, activity: ActivityDescriptor,
              admissionPolicy: ActivityAdmissionPolicy?, handler: @escaping ActivityEventHandler) async {
        self.activity = activity
        self.policy = admissionPolicy
        self.handler = handler
        handlers.append(handler)
        if pauseOpen {
            pauseOpen = false
            openIsPaused = true
            await withCheckedContinuation { openGate = $0 }
        }
    }
    func updatePeers(_ peers: [DiscoveredPeer]) {}
    func adoptChat(_ chat: Chat) { activity = .chat(chat) }
    func send(_ message: PeerMessage, to peerID: UUID) throws {
        if failSends { throw TestTransportError.sendFailed }
        sent.append((peerID, message))
    }
    func broadcast(_ message: ChatMessage) throws {
        if failSends { throw TestTransportError.sendFailed }
        broadcasts.append(message)
    }
    func disconnect(_ peerID: UUID) async { await handler?(.disconnected(peerID)) }
    func close() { closeCount += 1; activity = nil; handler = nil; policy = nil }
    func emit(_ event: ActivityTransportEvent, using oldIndex: Int? = nil) async {
        if let oldIndex { await handlers[oldIndex](event) }
        else { await handler?(event) }
    }
    func connect(_ peer: ConnectedPeer) async -> String? {
        if let rejection = await policy?(peer.id) { return rejection }
        await handler?(.connected(peer))
        return nil
    }
}

actor FakeActivityAdvertising: ActivityAdvertising {
    private(set) var activityID: UUID?
    func advertise(_ chat: Chat?, displayTitle: String?) { activityID = chat?.id }
    func advertiseGame(_ game: GameLobby?, playerCount: Int, isJoinable: Bool) { activityID = game?.id }
}

actor ManualSessionClock: SessionClock {
    private struct Waiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var now: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    var pendingCount: Int { waiters.count }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = Waiter(deadline: now + duration, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    func advance(by duration: Duration) {
        now += duration
        let ready = waiters.filter { $0.value.deadline <= now }.map(\.key)
        for id in ready { waiters.removeValue(forKey: id)?.continuation.resume() }
    }
}

func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<2000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("Expected asynchronous state was not reached", sourceLocation: sourceLocation)
}
