import XCTest
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
@testable import AssemblyAIPlugin

final class AssemblyAIPluginTests: XCTestCase {
    func testSpeakerDiarizationSettingPersistsAndNotifies() throws {
        let host = try PluginTestHostServices()
        let plugin = AssemblyAIPlugin()

        plugin.activate(host: host)

        XCTAssertFalse(plugin.isSpeakerDiarizationEnabled)

        plugin.setSpeakerDiarizationEnabled(true)

        XCTAssertTrue(plugin.isSpeakerDiarizationEnabled)
        XCTAssertEqual(host.userDefault(forKey: AssemblyAIPlugin.speakerDiarizationEnabledKey) as? Bool, true)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testSubmitBodyIncludesSpeakerLabelsOnlyWhenEnabled() {
        var disabledBody = AssemblyAIPlugin.makeSubmitTranscriptionBody(
            audioURL: "https://example.test/audio.wav",
            modelId: "universal-3-pro",
            language: nil,
            prompt: nil,
            speakerDiarizationEnabled: false
        )
        XCTAssertNil(disabledBody["speaker_labels"])

        var enabledBody = AssemblyAIPlugin.makeSubmitTranscriptionBody(
            audioURL: "https://example.test/audio.wav",
            modelId: "universal-3-pro",
            language: "en",
            prompt: nil,
            speakerDiarizationEnabled: true
        )
        XCTAssertEqual(enabledBody["speaker_labels"] as? Bool, true)
        XCTAssertEqual(enabledBody["language_code"] as? String, "en")

        AssemblyAIPlugin.applyDictionaryTerms(prompt: "TypeWhisper", modelId: "universal-3-pro", to: &disabledBody)
        AssemblyAIPlugin.applyDictionaryTerms(prompt: "TypeWhisper", modelId: "universal-3-pro", to: &enabledBody)
        XCTAssertEqual(disabledBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
        XCTAssertEqual(enabledBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
    }

    func testCompletedResponseBuildsSpeakerLabeledStructuredSegments() {
        let json: [String: Any] = [
            "text": "fallback text",
            "language_code": "en",
            "utterances": [
                [
                    "speaker": "A",
                    "text": "Hello",
                    "start": 250,
                    "end": 1500,
                    "confidence": 0.93,
                ],
                [
                    "speaker": "B",
                    "text": "Hi",
                    "start": 1500,
                    "end": 2750,
                ],
            ],
        ]

        let result = AssemblyAIPlugin.parseCompletedTranscriptionResponse(json)

        XCTAssertEqual(result.text, "Speaker A: Hello\nSpeaker B: Hi")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "Hello")
        XCTAssertEqual(result.segments[0].start, 0.25)
        XCTAssertEqual(result.segments[0].end, 1.5)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker A")
        XCTAssertEqual(result.segments[0].speakerConfidence, 0.93)
        XCTAssertEqual(result.segments[1].speakerLabel, "Speaker B")
        XCTAssertNil(result.segments[1].speakerConfidence)
    }

    func testCompletedResponseFallsBackToPlainTextWithoutUtterances() {
        let result = AssemblyAIPlugin.parseCompletedTranscriptionResponse([
            "text": "plain transcript",
            "language_code": "de",
        ])

        XCTAssertEqual(result.text, "plain transcript")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertTrue(result.segments.isEmpty)
    }
}
