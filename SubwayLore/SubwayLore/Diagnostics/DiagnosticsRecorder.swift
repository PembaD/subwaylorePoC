import Foundation

actor DiagnosticsRecorder {
    private let maximumEventCount: Int
    private var events: [DiagnosticEvent] = []

    init(maximumEventCount: Int = 500) {
        precondition(maximumEventCount > 0)
        self.maximumEventCount = maximumEventCount
    }

    @discardableResult
    func record(
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        localPeerID: UUID,
        remotePeerID: UUID? = nil,
        connectionID: UUID? = nil,
        summary: String,
        metadata: [String: String] = [:]
    ) -> DiagnosticEvent {
        let event = DiagnosticEvent(
            severity: severity,
            category: category,
            localPeerID: localPeerID,
            remotePeerID: remotePeerID,
            connectionID: connectionID,
            summary: summary,
            metadata: metadata
        )

        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        return event
    }

    func snapshot() -> [DiagnosticEvent] {
        events
    }

    func clear() {
        events.removeAll(keepingCapacity: true)
    }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(events)
    }
}
