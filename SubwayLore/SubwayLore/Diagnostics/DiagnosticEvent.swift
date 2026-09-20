import Foundation

enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
}

enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case app
    case discovery
    case connection
    case protocolMessage
    case framing
    case lifecycle
}

struct DiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let severity: DiagnosticSeverity
    let category: DiagnosticCategory
    let localPeerID: UUID
    let remotePeerID: UUID?
    let connectionID: UUID?
    let summary: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        localPeerID: UUID,
        remotePeerID: UUID? = nil,
        connectionID: UUID? = nil,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.localPeerID = localPeerID
        self.remotePeerID = remotePeerID
        self.connectionID = connectionID
        self.summary = summary
        self.metadata = metadata
    }
}
