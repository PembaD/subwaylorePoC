import Foundation
import Testing
@testable import SubwayLore

struct MessageFramerTests {
    @Test
    func completeFrameRoundTrips() throws {
        let payload = Data("hello".utf8)
        let framed = try MessageFramer.frame(payload)
        var decoder = FrameDecoder()

        #expect(try decoder.append(framed) == [payload])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func fragmentedFrameIsBufferedUntilComplete() throws {
        let payload = Data("fragmented message".utf8)
        let framed = try MessageFramer.frame(payload)
        var decoder = FrameDecoder()
        var output: [Data] = []

        for byte in framed {
            output.append(contentsOf: try decoder.append(Data([byte])))
        }

        #expect(output == [payload])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func coalescedFramesAreEmittedInOrder() throws {
        let payloads = [Data("one".utf8), Data("two".utf8), Data("three".utf8)]
        let stream = try payloads.reduce(into: Data()) { result, payload in
            result.append(try MessageFramer.frame(payload))
        }
        var decoder = FrameDecoder()

        #expect(try decoder.append(stream) == payloads)
    }

    @Test
    func completeFrameAndPartialFrameAreHandledTogether() throws {
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        var stream = try MessageFramer.frame(first)
        let secondFrame = try MessageFramer.frame(second)
        stream.append(secondFrame.prefix(6))
        var decoder = FrameDecoder()

        #expect(try decoder.append(stream) == [first])
        #expect(decoder.bufferedByteCount == 6)
        #expect(try decoder.append(secondFrame.dropFirst(6)) == [second])
    }

    @Test
    func invalidLengthsAreRejected() throws {
        var decoder = FrameDecoder(maximumPayloadSize: 8, maximumBufferedBytes: 32)

        do {
            _ = try decoder.append(Data([0, 0, 0, 0]))
            Issue.record("Expected zero-length frame to fail")
        } catch {
            #expect(error as? FramingError == .invalidPayloadLength(0))
        }

        decoder.reset()
        do {
            _ = try decoder.append(Data([0, 0, 0, 9]))
            Issue.record("Expected oversized frame to fail")
        } catch {
            #expect(error as? FramingError == .oversizedPayload(actual: 9, maximum: 8))
        }
    }

    @Test
    func encoderRejectsEmptyAndOversizedPayloads() {
        #expect(throws: FramingError.emptyPayload) {
            try MessageFramer.frame(Data())
        }
        #expect(throws: FramingError.oversizedPayload(actual: 9, maximum: 8)) {
            try MessageFramer.frame(Data(repeating: 1, count: 9), maximumPayloadSize: 8)
        }
    }
}
