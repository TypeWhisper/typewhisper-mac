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

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
