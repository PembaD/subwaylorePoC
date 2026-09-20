import Foundation
import Testing
@testable import SubwayLore

struct DiagnosticsRecorderTests {
    @Test
    func recorderKeepsOnlyItsConfiguredCapacity() async {
        let recorder = DiagnosticsRecorder(maximumEventCount: 2)
        let localPeerID = UUID()

        for index in 0..<3 {
            await recorder.record(
                severity: .info,
                category: .protocolMessage,
                localPeerID: localPeerID,
                summary: "Event \(index)"
            )
        }

        let events = await recorder.snapshot()
        #expect(events.map(\.summary) == ["Event 1", "Event 2"])
    }

    @Test
    func recorderExportsValidJSONAndClears() async throws {
        let recorder = DiagnosticsRecorder()
        await recorder.record(
            severity: .warning,
            category: .framing,
            localPeerID: UUID(),
            summary: "Partial frame",
            metadata: ["bytes": "12"]
        )

        let data = try await recorder.exportJSON()
        let decoded = try JSONDecoder.iso8601.decode([DiagnosticEvent].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.metadata["bytes"] == "12")

        await recorder.clear()
        #expect(await recorder.snapshot().isEmpty)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
