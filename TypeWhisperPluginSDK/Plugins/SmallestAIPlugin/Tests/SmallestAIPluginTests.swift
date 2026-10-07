import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import SmallestAIPlugin

final class SmallestAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testRequestUsesRawWAVUploadWithBearerAuthAndLanguage() throws {
        let request = try SmallestAIPlugin.makePreRecordedRequest(
            wavData: Data("wav".utf8),
            apiKey: "smallest-key",
            requestedLanguage: "de",
            selectedLanguageMode: "multi"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.smallest.ai")
        XCTAssertEqual(request.url?.path, "/waves/v1/pulse/get_text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer smallest-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(request.httpBody, Data("wav".utf8))
        XCTAssertEqual(request.timeoutInterval, 120)

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["language"], "de")
        XCTAssertEqual(query["word_timestamps"], "true")
    }

    func testRequestFallsBackToSelectedLanguageModeAndDefault() throws {
        XCTAssertEqual(
            SmallestAIPlugin.resolvedLanguageParameter(
                requestedLanguage: nil,
                selectedLanguageMode: "multi-asian"
            ),
            "multi-asian"
        )
        XCTAssertEqual(
            SmallestAIPlugin.resolvedLanguageParameter(
                requestedLanguage: " ",
                selectedLanguageMode: nil
            ),
            "multi-eu"
        )
    }

    func testTranscribeFailsWithoutAPIKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = SmallestAIPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(
                audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected notConfigured")
        } catch let error as PluginTranscriptionError {
            guard case .notConfigured = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTranscribeSendsRequestAndParsesUtteranceSegments() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "multi"],
            secrets: ["api-key": "smallest-key"]
        )
        let plugin = SmallestAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "status": "success",
                          "transcription": "Hello from Pulse.",
                          "language": "en",
                          "utterances": [
                            { "start": 0.48, "end": 3.76, "text": "Hello from Pulse." }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://api.smallest.ai/waves/v1/pulse/get_text", statusCode: 200)
                )
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            language: nil,
            translate: false,
            prompt: "ignored dictionary terms"
        )

        XCTAssertEqual(result.text, "Hello from Pulse.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].text, "Hello from Pulse.")
        XCTAssertEqual(result.segments[0].start, 0.48)
        XCTAssertEqual(result.segments[0].end, 3.76)

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["language"], "multi")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer smallest-key")
    }

    func testTranscribeSplitsRecordingsLongerThanTenMinutes() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "smallest-key"])
        let plugin = SmallestAIPlugin()
        plugin.activate(host: host)

        let url = "https://api.smallest.ai/waves/v1/pulse/get_text"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"status":"success","transcription":"first","language":"en","utterances":[{"start":1,"end":2,"text":"first"}]}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 200)
                ),
                .success(
                    Data(#"{"status":"success","transcription":"second","language":"en","utterances":[{"start":1,"end":2,"text":"second"}]}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 200)
                ),
            ])
        }

        // Just over ten minutes, more than one chunk.
        let samples = [Float](repeating: 0.3, count: 16_000 * 601)
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: Data(), duration: 601),
            language: "en",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "first second")
        XCTAssertEqual(result.segments.map(\.text), ["first", "second"])
        XCTAssertEqual(result.segments.first?.start, 1)
        let secondChunkStart = try XCTUnwrap(result.segments.last?.start)
        XCTAssertGreaterThan(secondChunkStart, 271, "shifted by the first chunk's length")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            // Ten minutes of 16 kHz 16-bit WAV.
            XCTAssertLessThanOrEqual(try XCTUnwrap(request.httpBody).count, 44 + 600 * 32_000)
        }
    }

    func testLongRecordingKeepsTheTranscriptWhenAChunkIsSilent() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "smallest-key"])
        let plugin = SmallestAIPlugin()
        plugin.activate(host: host)

        let url = "https://api.smallest.ai/waves/v1/pulse/get_text"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"status":"success","transcription":"first"}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 200)
                ),
                .success(
                    Data(#"{"status":"success","transcription":""}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.3, count: 16_000 * 601)
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: Data(), duration: 601),
            language: "en",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "first")
        XCTAssertEqual(store.sessions.first?.requestedRequests.count, 2)
    }

    func testParseResponseRejectsFailedStatus() {
        XCTAssertThrowsError(try SmallestAIPlugin.parsePreRecordedResponse(
            Data(#"{"status":"error","message":"bad request"}"#.utf8)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "bad request")
        }
    }

    func testHTTP401MapsToInvalidAPIKey() {
        XCTAssertThrowsError(try SmallestAIPlugin.validateHTTPResponse(
            data: Data(#"{"message":"unauthorized"}"#.utf8),
            response: Self.httpResponse(url: "https://api.smallest.ai/waves/v1/pulse/get_text", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testValidateAPIKeyDistinguishesInvalidKeyFromTransientFailures() async {
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"message":"unauthorized"}"#.utf8),
                    Self.httpResponse(url: "https://api.smallest.ai/waves/v1/pulse/get_text", statusCode: 401)
                ),
                .success(
                    Data(#"{"message":"server unavailable"}"#.utf8),
                    Self.httpResponse(url: "https://api.smallest.ai/waves/v1/pulse/get_text", statusCode: 503)
                )
            ])
        }

        let plugin = SmallestAIPlugin()
        let invalidKeyResult = await plugin.validateApiKey("bad-key")
        let serverErrorResult = await plugin.validateApiKey("maybe-valid-key")

        XCTAssertEqual(invalidKeyResult, .invalidKey)
        XCTAssertEqual(serverErrorResult, .transientError)

        PluginHTTPClientTestHarness.reset()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [.failure(URLError(.timedOut))])
        }
        let timeoutResult = await plugin.validateApiKey("timeout-key")
        XCTAssertEqual(timeoutResult, .transientError)
    }

    func testSetAPIKeyKeepsStateUnchangedWhenSecretStoreFails() throws {
        let host = FailingSecretHost()
        let plugin = SmallestAIPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertThrowsError(try plugin.setApiKey("smallest-key"))
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
        XCTAssertNil(host.loadSecret(key: "api-key"))
    }

    func testRemoveAPIKeyKeepsStateUnchangedWhenSecretStoreFails() throws {
        let host = FailingSecretHost(secrets: ["api-key": "existing-key"])
        let plugin = SmallestAIPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.isConfigured)
        XCTAssertThrowsError(try plugin.removeApiKey())
        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "existing-key")
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

private final class FailingSecretHost: HostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]
    private var capabilitiesChangedCountStorage = 0

    let pluginDataDirectory = FileManager.default.temporaryDirectory
    let eventBus: EventBusProtocol = PluginTestEventBus()
    var activeAppBundleId: String?
    var activeAppName: String?
    var availableRuleNames: [String] = []
    var availableWorkflows: [PluginWorkflowInfo] = []

    init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func storeSecret(key: String, value: String) throws {
        throw NSError(domain: "SmallestAIPluginTests", code: 1)
    }

    func loadSecret(key: String) -> String? {
        lock.withLock { secrets[key] }
    }

    func userDefault(forKey key: String) -> Any? {
        nil
    }

    func setUserDefault(_ value: Any?, forKey key: String) {}

    func notifyCapabilitiesChanged() {
        lock.withLock {
            capabilitiesChangedCountStorage += 1
        }
    }

    func setStreamingDisplayActive(_ active: Bool) {}

    var capabilitiesChangedCount: Int {
        lock.withLock { capabilitiesChangedCountStorage }
    }
}
