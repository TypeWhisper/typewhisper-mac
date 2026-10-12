import AVFoundation
import os
import XCTest
@testable import TypeWhisper

final class SpeechOnlyAudioTests: XCTestCase {
    private let sampleRate = AudioRecorderService.transcriptionSampleRate

    // MARK: - Speech regions

    func testRecordingWithoutAConfidentSpeechWindowHasNoSpeech() {
        let windows = [
            window(2, 3, confidence: 0.05),
            window(10, 11, confidence: 0.04),
        ]

        XCTAssertEqual(SpeechRegionPolicy.regions(from: windows, duration: 60), [])
    }

    func testShortPausesStayInsideOneRegion() {
        let windows = [
            window(10, 11, confidence: 0.9),
            window(14, 15, confidence: 0.8),
        ]

        XCTAssertEqual(SpeechRegionPolicy.regions(from: windows, duration: 60), [8.5...16.5])
    }

    func testLongStretchWithoutSpeechIsLeftOut() {
        let windows = [
            window(10, 11, confidence: 0.9),
            window(11, 12, confidence: 0.01),
            window(30, 31, confidence: 0.9),
        ]

        XCTAssertEqual(
            SpeechRegionPolicy.regions(from: windows, duration: 60),
            [8.5...12.5, 28.5...32.5]
        )
    }

    func testFaintSpeechNextToClearSpeechIsKept() {
        let windows = [
            window(10, 11, confidence: 0.9),
            window(30, 31, confidence: 0.03),
        ]

        XCTAssertEqual(
            SpeechRegionPolicy.regions(from: windows, duration: 60),
            [8.5...12.5, 28.5...32.5]
        )
    }

    func testRegionsCloseToTheRecordingEdgesReachTheEdges() {
        let windows = [
            window(1, 2, confidence: 0.9),
            window(56, 57, confidence: 0.9),
        ]

        XCTAssertEqual(SpeechRegionPolicy.regions(from: windows, duration: 60), [0...3.5, 54.5...60])
    }

    // MARK: - Speech-only audio

    func testRegionsCoveringTheWholeRecordingNeedNoChange() {
        let samples = [Float](repeating: 0.25, count: Int(10 * sampleRate))

        XCTAssertNil(SpeechOnlyAudio(samples: samples, sampleRate: sampleRate, speechRegions: [0...10]))
        XCTAssertNil(SpeechOnlyAudio(samples: samples, sampleRate: sampleRate, speechRegions: [0...6, 5...12]))
    }

    func testSpeechOnlyAudioKeepsTheRegionsWithAPauseBetweenThem() throws {
        let samples = (0..<Int(60 * sampleRate)).map { Float($0 / Int(sampleRate)) }

        let audio = try XCTUnwrap(SpeechOnlyAudio(
            samples: samples,
            sampleRate: sampleRate,
            speechRegions: [40...45, 10...20]
        ))

        XCTAssertEqual(audio.samples.count, Int(15.5 * sampleRate))
        XCTAssertEqual(audio.originalDuration, 60)
        XCTAssertEqual(audio.parts, [
            SpeechOnlyAudio.Part(originalStart: 10, start: 0, duration: 10),
            SpeechOnlyAudio.Part(originalStart: 40, start: 10.5, duration: 5),
        ])
        // Each sample holds the second it came from.
        XCTAssertEqual(audio.samples[Int(5 * sampleRate)], 15)
        XCTAssertEqual(audio.samples[Int(10.25 * sampleRate)], 0)
        XCTAssertEqual(audio.samples[Int(12 * sampleRate)], 41)
        XCTAssertEqual(audio.samples.first, 0, "A part that starts after a cut fades in")
    }

    func testTimesInAPauseBelongToTheNeighbouringSpeech() throws {
        let samples = [Float](repeating: 0.25, count: Int(60 * sampleRate))
        let audio = try XCTUnwrap(SpeechOnlyAudio(
            samples: samples,
            sampleRate: sampleRate,
            speechRegions: [10...20, 40...45]
        ))

        XCTAssertEqual(audio.originalStart(5), 15)
        XCTAssertEqual(audio.originalStart(10.2), 40)
        XCTAssertEqual(audio.originalEnd(10.2), 20)
        XCTAssertEqual(audio.originalEnd(12), 41.5)
        XCTAssertEqual(audio.originalStart(99), 45)
        XCTAssertEqual(audio.originalEnd(-1), 10)
    }

    func testRestoringTimesMovesSegmentsAndWordsBackToTheRecording() throws {
        let samples = [Float](repeating: 0.25, count: Int(60 * sampleRate))
        let audio = try XCTUnwrap(SpeechOnlyAudio(
            samples: samples,
            sampleRate: sampleRate,
            speechRegions: [10...20, 40...45]
        ))
        var result = TranscriptionResult(
            text: "One. Two. Three.",
            detectedLanguage: "en",
            duration: 15.5,
            processingTime: 1,
            engineUsed: "groq",
            segments: [
                TranscriptionSegment(text: "One.", start: 1, end: 9, speakerLabel: "A", speakerConfidence: 0.8),
                TranscriptionSegment(text: "Two.", start: 10.1, end: 10.4),
                TranscriptionSegment(text: "Three.", start: 9.5, end: 12),
            ]
        )
        result.words = [TranscriptionWord(text: "Three.", start: 11, end: 12)]

        let restored = audio.restoringOriginalTimes(of: result)

        XCTAssertEqual(restored.text, result.text)
        XCTAssertEqual(restored.detectedLanguage, "en")
        XCTAssertEqual(restored.duration, 60)
        XCTAssertEqual(restored.segments.map(\.start), [11, 40, 19.5])
        XCTAssertEqual(restored.segments.map(\.end), [19, 40, 41.5])
        XCTAssertEqual(restored.segments.first?.speakerLabel, "A")
        XCTAssertEqual(restored.segments.first?.speakerConfidence, 0.8)
        XCTAssertEqual(restored.words, [TranscriptionWord(text: "Three.", start: 40.5, end: 41.5)])
    }

    // MARK: - Sound classifier

    func testSoundClassifierHearsNoSpeechInNoiseChimesAndSilence() async throws {
        let regions = try await SoundAnalysisSpeechRegionDetector().speechRegions(in: noiseScene(duration: 20))

        XCTAssertEqual(regions, [])
    }

    func testSoundClassifierFindsSpeechAfterAQuietCallStart() async throws {
        let speech = try await synthesizedSpeech(
            "Okay, let's start. First item, the deployment went fine on Monday."
        )
        var samples = noiseScene(duration: 24)
        let speechStart = Int(16 * sampleRate)
        samples += [Float](repeating: 0, count: max(0, speechStart + speech.count - samples.count))
        for (offset, value) in speech.enumerated() {
            samples[speechStart + offset] += value
        }

        let regions = try await SoundAnalysisSpeechRegionDetector().speechRegions(in: samples)

        let speechEnd = Double(speechStart + speech.count) / sampleRate
        XCTAssertEqual(regions.count, 1, "\(regions)")
        let region = try XCTUnwrap(regions.first)
        XCTAssertGreaterThan(region.lowerBound, 12, "The noise before the speech is left out: \(region)")
        XCTAssertLessThanOrEqual(region.lowerBound, 16)
        XCTAssertGreaterThanOrEqual(region.upperBound, speechEnd - 0.5)
    }

    func testSoundClassifierKeepsAudioShorterThanOneWindow() async throws {
        let samples = [Float](repeating: 0, count: Int(0.8 * sampleRate))

        let regions = try await SoundAnalysisSpeechRegionDetector().speechRegions(in: samples)

        XCTAssertEqual(regions, [0...0.8])
    }

    func testSoundClassifierCoversLongRecordingsAcrossParts() async throws {
        let duration = SoundAnalysisSpeechRegionDetector.partDuration * 2 + 20
        let windows = try await SoundAnalysisSpeechRegionDetector.windows(
            in: [Float](repeating: 0, count: Int(duration * sampleRate)),
            sampleRate: sampleRate
        )

        XCTAssertEqual(windows.first?.start ?? -1, 0, accuracy: 0.001)
        // The last window is stretched to the end, so check where it starts.
        XCTAssertGreaterThanOrEqual(
            windows.last?.start ?? 0,
            duration - 2 * SoundAnalysisSpeechRegionDetector.windowDuration
        )
        let gaps = zip(windows, windows.dropFirst()).filter { $1.start > $0.end + 0.001 }
        XCTAssertTrue(gaps.isEmpty, "Windows leave gaps: \(gaps.prefix(3))")
    }

    // MARK: - Helpers

    private func window(_ start: TimeInterval, _ end: TimeInterval, confidence: Double) -> SpeechActivityWindow {
        SpeechActivityWindow(start: start, end: end, speechConfidence: confidence)
    }

    /// Silence, then room noise with call join chimes, then silence again.
    private func noiseScene(duration: TimeInterval) -> [Float] {
        var generator = SeededRandomNumberGenerator(state: 42)
        var samples = [Float](repeating: 0, count: Int(duration * sampleRate))
        let noiseRange = Int(2 * sampleRate)..<Int((duration - 4) * sampleRate)
        var brown: Float = 0
        for index in noiseRange {
            let white = Float.random(in: -1...1, using: &generator)
            brown = 0.98 * brown + 0.02 * white
            samples[index] = brown * 0.3 + white * 0.005
        }
        for chimeStart in stride(from: 3.0, to: duration - 5, by: 6) {
            for offset in 0..<Int(0.5 * sampleRate) {
                let time = Double(offset) / sampleRate
                samples[Int(chimeStart * sampleRate) + offset] += Float(0.4 * exp(-6 * time) * sin(2 * .pi * 880 * time))
            }
        }
        return samples
    }

    private func synthesizedSpeech(_ text: String) async throws -> [Float] {
        let collector = SynthesizedSpeechCollector(sampleRate: sampleRate)
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            collector.finish()
        }
        let samples = await withCheckedContinuation { continuation in
            collector.onFinish = { continuation.resume(returning: $0) }
            synthesizer.write(utterance) { collector.append($0) }
        }
        timeout.cancel()
        guard samples.count > Int(sampleRate) else {
            throw XCTSkip("Speech synthesis produced no audio on this machine")
        }
        return samples
    }
}

/// Converts synthesizer buffers to 16 kHz mono and hands them over once.
private final class SynthesizedSpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var finished = false
    var onFinish: (([Float]) -> Void)?

    init(sampleRate: Double) {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func append(_ buffer: AVAudioBuffer) {
        guard let buffer = buffer as? AVAudioPCMBuffer, buffer.frameLength > 0 else {
            finish()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        let capacity = AVAudioFrameCount(
            Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate
        ) + 64
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var delivered = false
        converter.convert(to: output, error: nil) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        if let channel = output.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let samples = samples
        let onFinish = onFinish
        lock.unlock()
        onFinish?(samples)
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
