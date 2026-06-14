import Foundation
import Compression

// Volcengine Seed ASR streaming binary frame protocol (v3).
// Frame layout: 4-byte header + 4-byte sequence (int32 BE) + 4-byte payload size (uint32 BE) + gzip(payload).

enum SeedWSProtocol {
    static let protocolVersion: UInt8 = 0b0001
    static let headerSize: UInt8 = 0b0001

    enum MessageType: UInt8 {
        case fullClientRequest = 0b0001
        case audioOnlyRequest = 0b0010
        case fullServerResponse = 0b1001
        case serverAck = 0b1011
        case serverErrorResponse = 0b1111
    }

    struct Flags: OptionSet {
        let rawValue: UInt8
        static let none = Flags([])
        static let posSequence = Flags(rawValue: 0b0001)
        static let negSequence = Flags(rawValue: 0b0010)
        static let negWithSequence = Flags(rawValue: 0b0011)
    }

    static let jsonSerialization: UInt8 = 0b0001
    static let gzipCompression: UInt8 = 0b0001
    static let noCompression: UInt8 = 0b0000

    static func buildHeader(messageType: MessageType, flags: Flags) -> Data {
        var data = Data(count: 4)
        data[0] = (Self.protocolVersion << 4) | Self.headerSize
        data[1] = (messageType.rawValue << 4) | flags.rawValue
        data[2] = (Self.jsonSerialization << 4) | Self.gzipCompression
        data[3] = 0x00
        return data
    }

    static func buildFullClientRequest(payload: [String: Any], sequence: Int32) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let body = gzipCompress(json) else {
            throw SeedASRError.encodeFailed("gzip init payload")
        }
        var frame = buildHeader(messageType: .fullClientRequest, flags: .posSequence)
        frame.append(int32BE(sequence))
        frame.append(uint32BE(UInt32(body.count)))
        frame.append(body)
        return frame
    }

    static func buildAudioRequest(audio: Data, sequence: Int32, isLast: Bool) throws -> Data {
        guard let body = gzipCompress(audio) else {
            throw SeedASRError.encodeFailed("gzip audio")
        }
        let flags: Flags = isLast ? .negWithSequence : .posSequence
        let seqValue: Int32 = isLast ? -sequence : sequence
        var frame = buildHeader(messageType: .audioOnlyRequest, flags: flags)
        frame.append(int32BE(seqValue))
        frame.append(uint32BE(UInt32(body.count)))
        frame.append(body)
        return frame
    }

    struct ParsedResponse {
        let messageType: MessageType?
        let isLast: Bool
        let payload: [String: Any]?
        let errorCode: UInt32?
        let decompressionFailed: Bool
    }

    static func parseResponse(_ data: Data) -> ParsedResponse {
        guard data.count >= 4 else {
            return ParsedResponse(messageType: nil, isLast: false, payload: nil, errorCode: nil, decompressionFailed: false)
        }
        let b1 = data[1]
        let b2 = data[2]
        let msgRaw = b1 >> 4
        let flagsRaw = b1 & 0x0F
        let compression = b2 & 0x0F
        let messageType = MessageType(rawValue: msgRaw)
        let isLast = (flagsRaw == Flags.negSequence.rawValue) || (flagsRaw == Flags.negWithSequence.rawValue)

        var cursor = 4
        // sequence (4 bytes) present whenever any seq flag is set
        if flagsRaw == Flags.posSequence.rawValue
            || flagsRaw == Flags.negSequence.rawValue
            || flagsRaw == Flags.negWithSequence.rawValue {
            cursor += 4
        }

        var errorCode: UInt32?
        if messageType == .serverErrorResponse {
            guard data.count >= cursor + 4 else {
                return ParsedResponse(messageType: messageType, isLast: isLast, payload: nil, errorCode: nil, decompressionFailed: false)
            }
            errorCode = readUInt32BE(data, at: cursor)
            cursor += 4
        }

        guard data.count >= cursor + 4 else {
            return ParsedResponse(messageType: messageType, isLast: isLast, payload: nil, errorCode: errorCode, decompressionFailed: false)
        }
        let payloadLen = Int(readUInt32BE(data, at: cursor))
        cursor += 4

        guard data.count >= cursor + payloadLen else {
            return ParsedResponse(messageType: messageType, isLast: isLast, payload: nil, errorCode: errorCode, decompressionFailed: false)
        }
        var payloadData = data.subdata(in: cursor..<(cursor + payloadLen))
        if compression == Self.gzipCompression, !payloadData.isEmpty {
            guard let decompressed = gzipDecompress(payloadData) else {
                return ParsedResponse(messageType: messageType, isLast: isLast, payload: nil, errorCode: errorCode, decompressionFailed: true)
            }
            payloadData = decompressed
        }

        var json: [String: Any]?
        if !payloadData.isEmpty {
            json = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any]
        }
        return ParsedResponse(messageType: messageType, isLast: isLast, payload: json, errorCode: errorCode, decompressionFailed: false)
    }

    // MARK: - Big-endian helpers

    static func int32BE(_ v: Int32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    static func uint32BE(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = data[offset..<(offset + 4)]
        var v: UInt32 = 0
        for byte in bytes { v = (v << 8) | UInt32(byte) }
        return v
    }
}

// MARK: - Audio Helper

enum SeedAudio {
    /// Float [-1,1] (16kHz mono) → PCM s16le LE bytes
    static func floatToPCM16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var int16 = Int16(clamped * 32767.0)
            withUnsafeBytes(of: &int16) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - Gzip via Compression framework

private func gzipCompress(_ data: Data) -> Data? {
    // compression_encode_buffer + raw.baseAddress are not reliable for zero-length input,
    // and finish() builds the terminal audio frame with Data(). Emit a canonical gzip
    // stream wrapping an empty deflate block so buildAudioRequest never fails on empty input.
    if data.isEmpty {
        return Data([
            0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
            0x03, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ])
    }
    let bufferSize = max(64, data.count * 2 + 64)
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { dst.deallocate() }
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
        guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let written = compression_encode_buffer(dst, bufferSize, src, data.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { return nil }
        // Wrap raw deflate (COMPRESSION_ZLIB) into gzip (RFC 1952): 10-byte header + deflate body + 8-byte trailer (crc32 + size).
        var gz = Data()
        gz.append(contentsOf: [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        gz.append(Data(bytes: dst, count: written))
        var crc = crc32(of: data).littleEndian
        var size = UInt32(data.count & 0xFFFFFFFF).littleEndian
        withUnsafeBytes(of: &crc) { gz.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { gz.append(contentsOf: $0) }
        return gz
    }
}

private func gzipDecompress(_ data: Data) -> Data? {
    // Strip RFC 1952 gzip header (10 bytes) + 8-byte trailer, decode raw deflate.
    guard data.count > 18 else { return nil }
    let body = data.subdata(in: 10..<(data.count - 8))
    let bufferSize = max(64, body.count * 12 + 1024)
    let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { dst.deallocate() }
    return body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
        guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let written = compression_decode_buffer(dst, bufferSize, src, body.count, nil, COMPRESSION_ZLIB)
        guard written > 0 else { return nil }
        return Data(bytes: dst, count: written)
    }
}

private func crc32(of data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1)))
        }
    }
    return crc ^ 0xFFFFFFFF
}
