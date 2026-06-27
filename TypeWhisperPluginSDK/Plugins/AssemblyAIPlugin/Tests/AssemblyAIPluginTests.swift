import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import AssemblyAIPlugin

final class AssemblyAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

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

    func testRESTTranscriptionUploadsCompressedM4A() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"upload_url":"https://cdn.example.test/audio.m4a"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 200)
                ),
                .success(
                    Data(#"{"id":"transcript_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript", statusCode: 200)
                ),
                .success(
                    Data(#"{"status":"completed","text":"hello","language_code":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript/transcript_123", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello")
        let uploadRequest = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(uploadRequest.url?.path, "/v2/upload")
        XCTAssertEqual(uploadRequest.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        let uploadBody = try XCTUnwrap(uploadRequest.httpBody)
        XCTAssertTrue(String(decoding: uploadBody.prefix(64), as: UTF8.self).contains("ftyp"))
        XCTAssertNotEqual(uploadBody, audio.wavData)
    }

    func testRESTTranscriptionRetriesUploadWithWavWhenM4ARejected() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"could not process file - is it a valid media file?"}}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 400)
                ),
                .success(
                    Data(#"{"upload_url":"https://cdn.example.test/audio.wav"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 200)
                ),
                .success(
                    Data(#"{"id":"transcript_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript", statusCode: 200)
                ),
                .success(
                    Data(#"{"status":"completed","text":"hello wav","language_code":"de"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript/transcript_123", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello wav")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v2/upload",
            "/v2/upload",
            "/v2/transcript",
            "/v2/transcript/transcript_123",
        ])

        let firstUploadBody = try XCTUnwrap(requests[0].httpBody)
        XCTAssertTrue(String(decoding: firstUploadBody.prefix(64), as: UTF8.self).contains("ftyp"))
        let retryUploadBody = try XCTUnwrap(requests[1].httpBody)
        XCTAssertEqual(retryUploadBody, audio.wavData)

        let submitBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].httpBody)) as? [String: Any]
        )
        XCTAssertEqual(submitBody["audio_url"] as? String, "https://cdn.example.test/audio.wav")
        XCTAssertEqual(submitBody["language_code"] as? String, "de")
        XCTAssertEqual(submitBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
