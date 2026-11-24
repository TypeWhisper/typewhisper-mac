import AVFoundation
import XCTest
@testable import TypeWhisper

final class RecorderMicrophoneRepetitionDetectorTests: XCTestCase {
    private let sampleRate = 16_000

    /// #1863: from minute 16 the mic channel held the same short piece of audio to the end.
    func testFindsAFrozenLoopAndWhereItStarted() {
        var noise = TestNoise(seed: 0x1863)
        var samples = speechLikeAudio(seconds: 10, noise: &noise)
        let loop = Array(samples.suffix(5_920))
        for index in 0..<(20 * sampleRate) {
            // A loop that went through voice processing is not bit-exact anymore.
            samples.append(loop[index % loop.count] + noise.next() * 1e-5)
        }

        let lag = samples.withUnsafeBufferPointer {
            RecorderMicrophoneRepetitionDetector.repeatingLag(in: $0)
        }
        XCTAssertEqual(lag, loop.count)

        let repeatingCount = samples.withUnsafeBufferPointer {
            RecorderMicrophoneRepetitionDetector.repeatingSampleCount(in: $0, lag: loop.count)
        }
        XCTAssertEqual(samples.count - repeatingCount, 10 * sampleRate)
    }

    func testSpeechAndSilenceDoNotRepeat() {
        var noise = TestNoise(seed: 7)
        let speech = speechLikeAudio(seconds: 30, noise: &noise)
        let silence = [Float](repeating: 0, count: 30 * sampleRate)

        for samples in [speech, silence] {
            let lag = samples.withUnsafeBufferPointer {
                RecorderMicrophoneRepetitionDetector.repeatingLag(in: $0)
            }
            XCTAssertNil(lag)
        }
    }

    /// A ringtone that plays again through loudspeakers repeats, but the room noise between its
    /// repeats is new each time, so it never repeats long enough to count as a frozen capture.
    func testSoundRepeatedThroughLoudspeakersIsNotAFrozenCapture() {
        var noise = TestNoise(seed: 42)
        let burst = (0..<sampleRate).map { index in
            noise.next() * 0.2 * Float(sin(Double.pi * Double(index) / Double(sampleRate)))
        }
        var samples: [Float] = []
        for _ in 0..<10 {
            samples += [Float](repeating: 0, count: 2 * sampleRate)
            samples += burst
        }
        for index in samples.indices {
            samples[index] += noise.next() * 1e-3
        }

        let lag = samples.withUnsafeBufferPointer {
            RecorderMicrophoneRepetitionDetector.repeatingLag(in: $0)
        }
        XCTAssertEqual(lag, 3 * sampleRate, "the burst itself repeats closely enough")

        let repeatingCount = samples.withUnsafeBufferPointer {
            RecorderMicrophoneRepetitionDetector.repeatingSampleCount(in: $0, lag: 3 * sampleRate)
        }
        XCTAssertLessThan(
            Double(repeatingCount) / Double(sampleRate),
            RecorderMicrophoneWatchdogPolicy.repetitionDuration / 10
        )
    }

    /// Noise shaped like speech: bursts and pauses that never repeat.
    private func speechLikeAudio(seconds: Int, noise: inout TestNoise) -> [Float] {
        (0..<(seconds * sampleRate)).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = 0.15 * abs(sin(2 * .pi * 2.3 * time) * sin(2 * .pi * 0.7 * time)) + 0.000_5
            return noise.next() * Float(envelope)
        }
    }
}

final class RecorderMicrophoneSilencedFinalizationTests: XCTestCase {
    /// The finished recording keeps silence where the microphone repeated frozen audio; the
    /// system audio track is untouched.
    func testSeparateTracksSilenceTheRepeatedMicrophoneFrames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderMicrophoneSilencedFinalizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let outputURL = directory.appendingPathComponent("Recording.wav")
        try writeConstantWAV(to: micURL, value: 0.5, channels: 1, frameCount: 48_000)
        try writeConstantWAV(to: systemURL, value: 0.25, channels: 2, frameCount: 48_000)

        let service = AudioRecorderService()
        let finishedURL = await service.finalizeRecording(AudioRecorderService.StoppedRecording(
            finalOutputURL: outputURL,
            micTempURL: micURL,
            systemTempURL: systemURL,
            outputFormat: .wav,
            trackMode: .separate,
            micDuckingMode: .off,
            transcriptionSamples: [],
            usesFinalizationOverride: false,
            micSilencedFrameRanges: [12_000..<36_000]
        ))
        XCTAssertEqual(finishedURL, outputURL)

        let file = try AVAudioFile(forReading: outputURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(buffer.frameLength, 48_000)
        for frame in [0, 11_999, 36_000, 47_999] {
            XCTAssertEqual(channels[0][frame], 0.5, accuracy: 0.001, "mic frame \(frame)")
        }
        for frame in [12_000, 24_000, 35_999] {
            XCTAssertEqual(channels[0][frame], 0, "mic frame \(frame)")
        }
        for frame in [0, 24_000, 47_999] {
            XCTAssertEqual(channels[1][frame], 0.25, accuracy: 0.001, "system frame \(frame)")
        }
    }

    private func writeConstantWAV(to url: URL, value: Float, channels: AVAudioChannelCount, frameCount: Int) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            channelData[channel].update(repeating: value, count: frameCount)
        }
        try file.write(from: buffer)
    }
}

/// Repeatable white noise in -1...1 (xorshift).
private struct TestNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Float(state >> 40) / Float(1 << 23) - 1
    }
}
