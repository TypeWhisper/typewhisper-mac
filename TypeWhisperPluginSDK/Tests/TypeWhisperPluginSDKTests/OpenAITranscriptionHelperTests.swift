import XCTest
@testable import TypeWhisperPluginSDK

final class OpenAITranscriptionHelperTests: XCTestCase {
    func testPluginAudioUtilsPadsShortSamplesToMinimumDuration() {
        let samples = [Float](repeating: 0.1, count: 6_400)

        let paddedSamples = PluginAudioUtils.paddedSamples(samples, minimumDuration: 1.0)

        XCTAssertEqual(paddedSamples.count, 16_000)
    }

    func testPluginAudioUtilsLeavesLongEnoughSamplesUnchanged() {
        let samples = [Float](repeating: 0.1, count: 16_000)

        let paddedSamples = PluginAudioUtils.paddedSamples(samples, minimumDuration: 1.0)

        XCTAssertEqual(paddedSamples, samples)
    }

    func testPluginAudioUtilsRejectsLowConfidenceShortClipTranscription() {
        XCTAssertFalse(
            PluginAudioUtils.shouldAcceptShortClipTranscription(
                audioDuration: 0.6,
                confidence: 0.42
            )
        )
    }

    func testPluginAudioUtilsAcceptsHighConfidenceShortClipTranscription() {
        XCTAssertTrue(
            PluginAudioUtils.shouldAcceptShortClipTranscription(
                audioDuration: 0.6,
                confidence: 0.72
            )
        )
    }

    func testPluginAudioUtilsAcceptsLongClipRegardlessOfConfidence() {
        XCTAssertTrue(
            PluginAudioUtils.shouldAcceptShortClipTranscription(
                audioDuration: 1.4,
                confidence: 0.2
            )
        )
    }

    func testNormalizedAudioForUploadPadsShortAudioToOneSecond() {
        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.com")
        let samples = [Float](repeating: 0.1, count: 8_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 0.5
        )

        let normalized = helper.normalizedAudioForUpload(audio)

        XCTAssertEqual(normalized.samples.count, 16_000)
        XCTAssertEqual(normalized.duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(String(data: normalized.wavData.prefix(4), encoding: .utf8), "RIFF")
    }

    func testNormalizedAudioForUploadLeavesOneSecondAudioUnchanged() {
        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.com")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let wavData = PluginWavEncoder.encode(samples)
        let audio = AudioData(
            samples: samples,
            wavData: wavData,
            duration: 1.0
        )

        let normalized = helper.normalizedAudioForUpload(audio)

        XCTAssertEqual(normalized.samples.count, samples.count)
        XCTAssertEqual(normalized.duration, audio.duration, accuracy: 0.0001)
        XCTAssertEqual(normalized.wavData, wavData)
    }
}
