import Foundation
import XCTest
@_spi(Testing) import TypeWhisperPluginSDK
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

    func testOnlyRecordingsUpToFiveMinutesUseTheStream() {
        XCTAssertTrue(XAIPlugin.streamsAudio(ofDuration: 10))
        XCTAssertTrue(XAIPlugin.streamsAudio(ofDuration: 5 * 60))
        XCTAssertFalse(XAIPlugin.streamsAudio(ofDuration: 5 * 60 + 1))
        XCTAssertFalse(XAIPlugin.streamsAudio(ofDuration: 2 * 3_600))
    }

    func testRESTTimeoutsGrowWithAudioDuration() {
        let short = XAIPlugin.restTimeouts(forAudioDuration: 60)
        XCTAssertEqual(short.request, 120)
        XCTAssertEqual(short.resource, 600)

        let twoHours = XAIPlugin.restTimeouts(forAudioDuration: 2 * 3_600)
        XCTAssertEqual(twoHours.request, 240)
        XCTAssertEqual(twoHours.resource, 720)

        let fourHours = XAIPlugin.restTimeouts(forAudioDuration: 4 * 3_600)
        XCTAssertEqual(fourHours.request, 480)
        XCTAssertEqual(fourHours.resource, 1_440)

        let twentyHours = XAIPlugin.restTimeouts(forAudioDuration: 20 * 3_600)
        XCTAssertEqual(twentyHours.request, 1_200)
        XCTAssertEqual(twentyHours.resource, 7_200)
    }

    func testLongFileTranscriptionUsesRESTWithLongTimeouts() async throws {
        let session = MockXAIHTTPSession(
            body: Data(#"{"text":"Long transcript","language":"de","words":[]}"#.utf8)
        )
        let resourceTimeouts = XAITimeoutRecorder()
        PluginHTTPClient.configureForTesting { configuration in
            resourceTimeouts.append(configuration.timeoutIntervalForResource)
            return session
        }
        defer { PluginHTTPClient.resetTestingHooks() }

        let plugin = XAIPlugin()
        plugin.activate(host: XAITestHostServices(apiKey: "xai_test"))

        // The duration drives routing and timeouts; one second of samples keeps encoding fast.
        let result = try await plugin.transcribe(
            audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000), wavData: Data(), duration: 2 * 3_600),
            language: "de",
            translate: false,
            prompt: nil,
            onProgress: { _ in true }
        )

        XCTAssertEqual(result.text, "Long transcript")
        XCTAssertEqual(session.requests.map { $0.url?.absoluteString }, ["https://api.x.ai/v1/stt"])
        XCTAssertEqual(session.requests.first?.timeoutInterval, 240)
        XCTAssertEqual(resourceTimeouts.values, [720])
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
        XCTAssertEqual(manifest.minHostVersion, "1.8.0")
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

private final class XAITimeoutRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.withLock { storage }
    }

    func append(_ value: TimeInterval) {
        lock.withLock { storage.append(value) }
    }
}

private final class MockXAIHTTPSession: PluginHTTPClientSession, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var storage: [URLRequest] = []

    init(body: Data) {
        self.body = body
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { storage.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    func finishTasksAndInvalidate() {}
}

private final class XAITestHostServices: HostServices, @unchecked Sendable {
    private let apiKey: String

    let pluginDataDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XAIPluginTests-\(UUID().uuidString)", isDirectory: true)
    let eventBus: EventBusProtocol = XAITestEventBus()
    let activeAppBundleId: String? = nil
    let activeAppName: String? = nil
    let availableRuleNames: [String] = []
    let availableWorkflows: [PluginWorkflowInfo] = []

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func storeSecret(key: String, value: String) throws {}
    func loadSecret(key: String) -> String? { key == "api-key" ? apiKey : nil }
    func userDefault(forKey key: String) -> Any? { nil }
    func setUserDefault(_ value: Any?, forKey key: String) {}
    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

private final class XAITestEventBus: EventBusProtocol, @unchecked Sendable {
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        UUID()
    }

    func unsubscribe(id: UUID) {}
}
