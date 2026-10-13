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

    func testEmptyAudioHasNoSpeech() async throws {
        let regions = try await SoundAnalysisSpeechRegionDetector().speechRegions(in: [])

        XCTAssertEqual(regions, [])
    }

    func testSoundClassifierJudgesTheEndOfTheRecordingOnItsOwn() async throws {
        // 10.3 s leave 0.3 s after the last whole window at 9...10 s.
        let windows = try await SoundAnalysisSpeechRegionDetector.windows(
            in: [Float](repeating: 0, count: Int(10.3 * sampleRate)),
            sampleRate: sampleRate
        )

        let last = try XCTUnwrap(windows.last)
        XCTAssertEqual(last.start, 9.5, accuracy: 0.001)
        XCTAssertEqual(last.end, 10.3, accuracy: 0.001)
    }

    func testSoundClassifierJudgesAnEndJustAfterAPartBoundary() async throws {
        // The last part holds only 0.3 s, less than one window.
        let duration = SoundAnalysisSpeechRegionDetector.partDuration + 0.3
        let windows = try await SoundAnalysisSpeechRegionDetector.windows(
            in: [Float](repeating: 0, count: Int(duration * sampleRate)),
            sampleRate: sampleRate
        )

        let last = try XCTUnwrap(windows.last)
        XCTAssertEqual(last.start, duration - 0.8, accuracy: 0.001)
        XCTAssertEqual(last.end, duration, accuracy: 0.001)
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
        let collector = SynthesizedSpeechCollector()
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            collector.finish()
        }
        let speech = await withCheckedContinuation { continuation in
            collector.onFinish = { continuation.resume(returning: $0) }
            synthesizer.write(utterance) { collector.append($0) }
        }
        timeout.cancel()
        let samples = resampled(speech.samples, from: speech.sampleRate)
        guard samples.count > Int(sampleRate) else {
            throw XCTSkip("Speech synthesis produced no audio on this machine")
        }
        return samples
    }

    /// Linear interpolation is enough for the classifier.
    private func resampled(_ samples: [Float], from sourceRate: Double) -> [Float] {
        guard sourceRate > 0, sourceRate != sampleRate, samples.count > 1 else { return samples }
        let count = Int(Double(samples.count) * sampleRate / sourceRate)
        return (0..<count).map { index in
            let position = Double(index) * sourceRate / sampleRate
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }
}

/// Collects synthesizer output as mono samples and hands it over once.
private final class SynthesizedSpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var finished = false
    var onFinish: (((samples: [Float], sampleRate: Double)) -> Void)?

    func append(_ buffer: AVAudioBuffer) {
        guard let buffer = buffer as? AVAudioPCMBuffer, buffer.frameLength > 0 else {
            finish()
            return
        }
        let count = Int(buffer.frameLength)
        let chunk: [Float]
        if let channel = buffer.floatChannelData?[0] {
            chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        } else if let channel = buffer.int16ChannelData?[0] {
            chunk = UnsafeBufferPointer(start: channel, count: count).map { Float($0) / 32_768 }
        } else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        sampleRate = buffer.format.sampleRate
        samples.append(contentsOf: chunk)
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let speech = (samples: samples, sampleRate: sampleRate)
        let onFinish = onFinish
        lock.unlock()
        onFinish?(speech)
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
