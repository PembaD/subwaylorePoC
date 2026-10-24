import Foundation
import OSLog

actor DiagnosticsRecorder {
    private static let logger = Logger(
        subsystem: "com.subwaylore.SubwayLore",
        category: "Diagnostics"
    )

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
        log(event)
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

    private func log(_ event: DiagnosticEvent) {
        let context = Self.context(for: event)
        let message = "[\(event.category.rawValue)] \(event.summary) \(context)"

        switch event.severity {
        case .debug:
            Self.logger.debug("\(message, privacy: .public)")
        case .info:
            Self.logger.info("\(message, privacy: .public)")
        case .warning:
            Self.logger.notice("\(message, privacy: .public)")
        case .error:
            Self.logger.error("\(message, privacy: .public)")
        }
    }

    private static func context(for event: DiagnosticEvent) -> String {
        var fields = ["localPeerID=\(event.localPeerID.uuidString)"]

        if let remotePeerID = event.remotePeerID {
            fields.append("remotePeerID=\(remotePeerID.uuidString)")
        }
        if let connectionID = event.connectionID {
            fields.append("connectionID=\(connectionID.uuidString)")
        }
        fields.append(contentsOf: event.metadata.keys.sorted().map { key in
            "\(key)=\(event.metadata[key] ?? "")"
        })

        return fields.joined(separator: " ")
    }
}
