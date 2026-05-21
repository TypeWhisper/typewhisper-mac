import AVFoundation
import XCTest
@testable import TypeWhisper

final class RecorderTranscriptionBufferTests: XCTestCase {
    func testRecentBufferReturnsTailForMicOnlySource() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic((0..<8).map(Float.init))

        let recent = buffer.recentBuffer(
            maxSampleCount: 3,
            micEnabled: true,
            systemAudioEnabled: false,
            mixer: { _, _, _ in
                XCTFail("mixer should not be used for mic-only buffers")
                return []
            }
        )

        XCTAssertEqual(recent, [5, 6, 7])
    }

    func testDeltaUsesMixedSampleCountAsNextOffset() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic([1, 2])
        buffer.appendSystem([10, 20, 30, 40])

        let delta = buffer.delta(
            since: 3,
            micEnabled: true,
            systemAudioEnabled: true,
            mixer: { range, micSamples, systemSamples in
                range.map { index in
                    let micSample = index < micSamples.count ? micSamples[index] : 0
                    let systemSample = index < systemSamples.count ? systemSamples[index] : 0
                    return micSample + systemSample
                }
            }
        )

        XCTAssertEqual(delta.nextOffset, 4)
        XCTAssertEqual(delta.samples, [40])
    }

    func testMixedRecentBufferUsesTailRangeOnly() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic([1, 2, 3, 4])
        buffer.appendSystem([10, 20, 30, 40])

        var capturedRange: Range<Int>?
        let recent = buffer.recentBuffer(
            maxSampleCount: 2,
            micEnabled: true,
            systemAudioEnabled: true,
            mixer: { range, micSamples, systemSamples in
                capturedRange = range
                return range.map { index in
                    micSamples[index] + systemSamples[index]
                }
            }
        )

        XCTAssertEqual(capturedRange, 2..<4)
        XCTAssertEqual(recent, [33, 44])
    }

    func testMixedDeltaReturnsOnlyRequestedSlice() {
        var buffer = RecorderTranscriptionBuffer()
        buffer.appendMic([1, 2, 3, 4])
        buffer.appendSystem([10, 20])

        let delta = buffer.delta(
            since: 1,
            micEnabled: true,
            systemAudioEnabled: true,
            mixer: { range, micSamples, systemSamples in
                range.map { index in
                    let micSample = index < micSamples.count ? micSamples[index] : 0
                    let systemSample = index < systemSamples.count ? systemSamples[index] : 0
                    return micSample + systemSample
                }
            }
        )

        XCTAssertEqual(delta.nextOffset, 4)
        XCTAssertEqual(delta.samples, [22, 3, 4])
    }
}

final class SystemAudioSampleProcessorTests: XCTestCase {
    func testProcessesStereoInterleavedFloat32Buffers() throws {
        var samples: [Float] = [
            0.2, 0.4,
            -0.2, 0.2,
            0, 0,
            0.6, -0.6,
            0.3, 0.3,
            -0.3, 0.1,
        ]
        let asbd = makeAudioDescription(
            sampleRate: 48_000,
            channels: 2,
            bitsPerChannel: 32,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bytesPerFrame: 8
        )

        let result = try samples.withUnsafeMutableBytes { bytes in
            try withAudioBufferList([
                .init(channels: 2, byteSize: UInt32(bytes.count), data: bytes.baseAddress)
            ]) { bufferList in
                try SystemAudioSampleProcessor.process(
                    audioBufferList: bufferList,
                    asbd: asbd,
                    transcriptionSampleRate: 16_000
                )
            }
        }

        XCTAssertEqual(result.frameCount, 6)
        XCTAssertEqual(result.pcmBuffer.format.channelCount, 2)
        XCTAssertEqual(result.pcmBuffer.frameLength, 6)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![0], count: 6)), [0.2, -0.2, 0, 0.6, 0.3, -0.3])
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![1], count: 6)), [0.4, 0.2, 0, -0.6, 0.3, 0.1])
        XCTAssertEqual(result.rms, rms(samples), accuracy: 0.0001)
        XCTAssertEqual(result.level, min(1, rms(samples) * 5), accuracy: 0.0001)
        XCTAssertFloats(result.transcriptionSamples, [0.3, 0])
    }

    func testProcessesStereoNonInterleavedFloat32Buffers() throws {
        var left: [Float] = [0.1, -0.2, 0.4, 0.8]
        var right: [Float] = [0.3, 0.2, -0.4, 0]
        let asbd = makeAudioDescription(
            sampleRate: 16_000,
            channels: 2,
            bitsPerChannel: 32,
            flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            bytesPerFrame: 4
        )

        let result = try left.withUnsafeMutableBytes { leftBytes in
            try right.withUnsafeMutableBytes { rightBytes in
                try withAudioBufferList([
                    .init(channels: 1, byteSize: UInt32(leftBytes.count), data: leftBytes.baseAddress),
                    .init(channels: 1, byteSize: UInt32(rightBytes.count), data: rightBytes.baseAddress),
                ]) { bufferList in
                    try SystemAudioSampleProcessor.process(
                        audioBufferList: bufferList,
                        asbd: asbd,
                        transcriptionSampleRate: 16_000
                    )
                }
            }
        }

        XCTAssertEqual(result.frameCount, 4)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![0], count: 4)), left)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![1], count: 4)), right)
        XCTAssertFloats(result.transcriptionSamples, [0.2, 0, 0, 0.4])
    }

    func testProcessesStereoInterleavedInt16Buffers() throws {
        var samples: [Int16] = [
            16_384, -16_384,
            32_767, 0,
            -32_767, 32_767,
            0, 0,
        ]
        let asbd = makeAudioDescription(
            sampleRate: 16_000,
            channels: 2,
            bitsPerChannel: 16,
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            bytesPerFrame: 4
        )
        let expectedLeft = [Float(16_384) / Float(Int16.max), 1, -1, 0]
        let expectedRight = [Float(-16_384) / Float(Int16.max), 0, 1, 0]

        let result = try samples.withUnsafeMutableBytes { bytes in
            try withAudioBufferList([
                .init(channels: 2, byteSize: UInt32(bytes.count), data: bytes.baseAddress)
            ]) { bufferList in
                try SystemAudioSampleProcessor.process(
                    audioBufferList: bufferList,
                    asbd: asbd,
                    transcriptionSampleRate: 16_000
                )
            }
        }

        XCTAssertEqual(result.frameCount, 4)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![0], count: 4)), expectedLeft)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![1], count: 4)), expectedRight)
        XCTAssertFloats(result.transcriptionSamples, [
            (expectedLeft[0] + expectedRight[0]) * 0.5,
            0.5,
            0,
            0,
        ])
    }

    func testProcessesStereoNonInterleavedInt16Buffers() throws {
        var left: [Int16] = [16_384, -16_384, 0, 32_767]
        var right: [Int16] = [0, 16_384, -32_767, -16_384]
        let asbd = makeAudioDescription(
            sampleRate: 16_000,
            channels: 2,
            bitsPerChannel: 16,
            flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            bytesPerFrame: 2
        )
        let expectedLeft = left.map { Float($0) / Float(Int16.max) }
        let expectedRight = right.map { Float($0) / Float(Int16.max) }

        let result = try left.withUnsafeMutableBytes { leftBytes in
            try right.withUnsafeMutableBytes { rightBytes in
                try withAudioBufferList([
                    .init(channels: 1, byteSize: UInt32(leftBytes.count), data: leftBytes.baseAddress),
                    .init(channels: 1, byteSize: UInt32(rightBytes.count), data: rightBytes.baseAddress),
                ]) { bufferList in
                    try SystemAudioSampleProcessor.process(
                        audioBufferList: bufferList,
                        asbd: asbd,
                        transcriptionSampleRate: 16_000
                    )
                }
            }
        }

        XCTAssertEqual(result.frameCount, 4)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![0], count: 4)), expectedLeft)
        XCTAssertFloats(Array(UnsafeBufferPointer(start: result.pcmBuffer.floatChannelData![1], count: 4)), expectedRight)
        XCTAssertFloats(result.transcriptionSamples, [
            (expectedLeft[0] + expectedRight[0]) * 0.5,
            0,
            -0.5,
            (expectedLeft[3] + expectedRight[3]) * 0.5,
        ])
    }

    func testSystemAudioDiagnosticsWarnsWhenNoUsableAudioArrivesAfterGracePeriod() {
        var diagnostics = SystemAudioCaptureDiagnostics()
        let startedAt = Date(timeIntervalSince1970: 10)
        diagnostics.beginSession(startedAt: startedAt)

        XCTAssertNil(diagnostics.noAudioWarningIfNeeded(now: startedAt.addingTimeInterval(1), gracePeriod: 2))
        XCTAssertEqual(
            diagnostics.noAudioWarningIfNeeded(now: startedAt.addingTimeInterval(3), gracePeriod: 2),
            AudioRecorderService.noSystemAudioDetectedWarning
        )

        diagnostics.recordProcessedBuffer(frameCount: 256, rms: 0.000001, nonSilentThreshold: 0.0001)
        XCTAssertEqual(
            diagnostics.noAudioWarningIfNeeded(now: startedAt.addingTimeInterval(4), gracePeriod: 2),
            AudioRecorderService.noSystemAudioDetectedWarning
        )

        diagnostics.recordProcessedBuffer(frameCount: 256, rms: 0.01, nonSilentThreshold: 0.0001)
        XCTAssertNil(diagnostics.noAudioWarningIfNeeded(now: startedAt.addingTimeInterval(5), gracePeriod: 2))
    }
}

private struct TestAudioBuffer {
    let channels: UInt32
    let byteSize: UInt32
    let data: UnsafeMutableRawPointer?
}

private func withAudioBufferList<T>(
    _ buffers: [TestAudioBuffer],
    _ body: (UnsafeMutableAudioBufferListPointer) throws -> T
) rethrows -> T {
    let byteCount = MemoryLayout<AudioBufferList>.size
        + max(0, buffers.count - 1) * MemoryLayout<AudioBuffer>.size
    let rawPointer = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawPointer.deallocate() }
    rawPointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

    let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
    audioBufferList.pointee.mNumberBuffers = UInt32(buffers.count)
    let mutableList = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for index in buffers.indices {
        mutableList[index] = AudioBuffer(
            mNumberChannels: buffers[index].channels,
            mDataByteSize: buffers[index].byteSize,
            mData: buffers[index].data
        )
    }

    return try body(mutableList)
}

private func makeAudioDescription(
    sampleRate: Double,
    channels: UInt32,
    bitsPerChannel: UInt32,
    flags: AudioFormatFlags,
    bytesPerFrame: UInt32
) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channels,
        mBitsPerChannel: bitsPerChannel,
        mReserved: 0
    )
}

private func rms<T: BinaryFloatingPoint>(_ values: [T]) -> Float {
    let sum = values.reduce(Float(0)) { partial, value in
        let sample = Float(value)
        return partial + sample * sample
    }
    return sqrt(sum / Float(values.count))
}

private func XCTAssertFloats(
    _ actual: [Float],
    _ expected: [Float],
    accuracy: Float = 0.0001,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (actual, expected) in zip(actual, expected) {
        XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line)
    }
}
