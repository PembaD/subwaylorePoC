import Foundation

enum MessageFramer {
    static let headerSize = MemoryLayout<UInt32>.size
    static let maximumPayloadSize = 64 * 1_024

    static func frame(
        _ payload: Data,
        maximumPayloadSize: Int = Self.maximumPayloadSize
    ) throws -> Data {
        guard !payload.isEmpty else {
            throw FramingError.emptyPayload
        }
        guard payload.count <= maximumPayloadSize else {
            throw FramingError.oversizedPayload(
                actual: payload.count,
                maximum: maximumPayloadSize
            )
        }
        guard payload.count <= Int(UInt32.max) else {
            throw FramingError.oversizedPayload(
                actual: payload.count,
                maximum: Int(UInt32.max)
            )
        }

        var networkLength = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of: &networkLength) { Data($0) }
        result.append(payload)
        return result
    }
}

struct FrameDecoder: Sendable {
    private(set) var bufferedByteCount = 0

    private var buffer = Data()
    private let maximumPayloadSize: Int
    private let maximumBufferedBytes: Int

    init(
        maximumPayloadSize: Int = MessageFramer.maximumPayloadSize,
        maximumBufferedBytes: Int = MessageFramer.maximumPayloadSize * 4
    ) {
        precondition(maximumPayloadSize > 0)
        precondition(maximumBufferedBytes >= maximumPayloadSize + MessageFramer.headerSize)
        self.maximumPayloadSize = maximumPayloadSize
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    mutating func append(_ incomingData: Data) throws -> [Data] {
        guard buffer.count + incomingData.count <= maximumBufferedBytes else {
            throw FramingError.bufferLimitExceeded(maximum: maximumBufferedBytes)
        }

        buffer.append(incomingData)
        var payloads: [Data] = []

        while buffer.count >= MessageFramer.headerSize {
            let payloadLength = decodeLength(from: buffer)

            guard payloadLength > 0 else {
                throw FramingError.invalidPayloadLength(payloadLength)
            }
            guard payloadLength <= maximumPayloadSize else {
                throw FramingError.oversizedPayload(
                    actual: payloadLength,
                    maximum: maximumPayloadSize
                )
            }

            let frameLength = MessageFramer.headerSize + payloadLength
            guard buffer.count >= frameLength else {
                break
            }

            let frameStart = buffer.startIndex
            let payloadStart = buffer.index(
                frameStart,
                offsetBy: MessageFramer.headerSize
            )
            let frameEnd = buffer.index(
                payloadStart,
                offsetBy: payloadLength
            )

            payloads.append(buffer.subdata(in: payloadStart..<frameEnd))
            buffer.removeSubrange(frameStart..<frameEnd)
        }

        bufferedByteCount = buffer.count
        return payloads
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
    }

    private func decodeLength(from data: Data) -> Int {
        data.prefix(MessageFramer.headerSize).reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
    }
}

enum FramingError: Error, Equatable, Sendable {
    case emptyPayload
    case invalidPayloadLength(Int)
    case oversizedPayload(actual: Int, maximum: Int)
    case bufferLimitExceeded(maximum: Int)
}
