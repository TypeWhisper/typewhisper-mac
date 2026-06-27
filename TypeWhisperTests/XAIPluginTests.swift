import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class XAIPluginTests: XCTestCase {
    func testResponsesParserExtractsOutputTextContent() throws {
        let data = Data(
            """
            {
              "id": "resp_123",
              "output": [
                {
                  "type": "reasoning",
                  "status": "completed"
                },
                {
                  "type": "message",
                  "role": "assistant",
                  "content": [
                    {
                      "type": "output_text",
                      "text": "Cleaned transcript"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )

        XCTAssertEqual(try XAIResponsesClient.parseResponse(data), "Cleaned transcript")
    }

    func testStreamingSTTRequestUsesExpectedEndpointAndQuery() throws {
        let request = try XAIPlugin.makeSTTStreamingRequest(
            apiKey: "xai_test",
            language: "de",
            interimResults: true
        )

        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.x.ai")
        XCTAssertEqual(request.url?.path, "/v1/stt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xai_test")

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["encoding"], "pcm")
        XCTAssertEqual(query["interim_results"], "true")
        XCTAssertEqual(query["language"], "de")
    }

    func testTranscriptCollectorPublishesInterimFinalAndDoneText() async throws {
        let collector = XAITranscriptCollector()

        let interim = try await collector.applyEvent(Data(#"{"type":"transcript.partial","text":"hello","is_final":false,"speech_final":false}"#.utf8))
        XCTAssertEqual(interim, "hello")
        let currentText = await collector.currentText()
        XCTAssertEqual(currentText, "hello")

        let final = try await collector.applyEvent(Data(#"{"type":"transcript.partial","text":"hello world","is_final":true,"speech_final":true}"#.utf8))
        XCTAssertEqual(final, "hello world")

        _ = try await collector.applyEvent(Data(#"{"type":"transcript.done","text":"hello world","duration":1.25}"#.utf8))
        let result = await collector.finalResult(fallbackLanguage: "en")
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testTTSPlaybackSessionStopIsIdempotentAndStopsAudio() {
        let audio = MockXAIAudioPlayback()
        let session = XAITTSPlaybackSession(webSocketTask: nil, receiveTask: nil, audioPlayback: audio)
        let finishCounter = FinishCounter()
        session.onFinish = { finishCounter.increment() }

        XCTAssertTrue(session.isActive)
        session.stop()
        session.stop()

        XCTAssertFalse(session.isActive)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(finishCounter.value, 1)
    }

    func testXAIManifestDeclaresCloudAPIKeyPlugin() throws {
        let manifestURL = TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins/XAIPlugin/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)

        XCTAssertEqual(manifest.id, "com.typewhisper.xai")
        XCTAssertEqual(manifest.minHostVersion, "1.5.0")
        XCTAssertEqual(manifest.category, "transcription")
        XCTAssertEqual(manifest.categories, ["transcription", "llm", "tts"])
        XCTAssertEqual(manifest.resolvedCategoryIdentifiers, ["transcription", "llm", "tts"])
        XCTAssertEqual(manifest.hosting, .cloud)
        XCTAssertEqual(manifest.requiresAPIKey, true)
        XCTAssertEqual(manifest.sdkCompatibilityVersion, PluginSDKCompatibility.currentVersion)
    }
}

private final class FinishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class MockXAIAudioPlayback: XAITTSAudioPlayback, @unchecked Sendable {
    var onDrained: (@Sendable () -> Void)?
    private(set) var stopCount = 0

    func start(sampleRate: Int) throws {}
    func appendPCM16(_ data: Data) throws {}
    func finishInput() {}

    func stop() {
        stopCount += 1
    }
}
