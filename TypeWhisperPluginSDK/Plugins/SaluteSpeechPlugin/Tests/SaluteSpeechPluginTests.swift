import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import SaluteSpeechPlugin

final class SaluteSpeechPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testPCM16LEEncodingClampsAndUsesLittleEndianSamples() {
        let data = SaluteSpeechPlugin.makePCM16LEData(samples: [-1, 0, 1, 0.5])

        XCTAssertEqual(
            [UInt8](data),
            [
                0x00, 0x80,
                0x00, 0x00,
                0xff, 0x7f,
                0xff, 0x3f,
            ]
        )
    }

    func testTokenRequestUsesBasicAuthRqUIDAndFormScope() throws {
        let request = try SaluteSpeechPlugin.makeTokenRequest(
            authorizationKey: "Basic encoded-key",
            scope: SaluteSpeechPlugin.personalScope
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic encoded-key")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "RqUID"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), "scope=SALUTE_SPEECH_PERS")
    }

    func testSyncRecognitionRequestUsesPCMContentTypeAndBearerToken() throws {
        let request = try SaluteSpeechPlugin.makeSyncRecognitionRequest(
            pcmData: Data([0x01, 0x02]),
            token: "access-token",
            modelId: "general"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "smartspeech.sber.ru")
        XCTAssertEqual(request.url?.path, "/rest/v1/speech:recognize")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/x-pcm;bit=16;rate=16000")
        XCTAssertEqual(request.httpBody, Data([0x01, 0x02]))

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["model"], "general")
    }

    func testStartAsyncRequestUsesPCMOptions() throws {
        let request = try SaluteSpeechPlugin.makeStartAsyncRecognitionRequest(
            requestFileId: "file-id",
            token: "access-token",
            modelId: "general"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://smartspeech.sber.ru/rest/v1/speech:async_recognize")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(json["request_file_id"] as? String, "file-id")
        XCTAssertEqual(options["model"] as? String, "general")
        XCTAssertEqual(options["audio_encoding"] as? String, "PCM_S16LE")
        XCTAssertEqual(options["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(options["channels_count"] as? Int, 1)
    }

    func testParseTranscriptionResultPrefersNormalizedText() throws {
        let result = try SaluteSpeechPlugin.parseTranscriptionResult(
            Data(
                """
                [
                  {
                    "results": [
                      { "text": "privet", "normalized_text": "Привет" },
                      { "text": "mir", "normalized_text": "мир" }
                    ]
                  }
                ]
                """.utf8
            )
        )

        XCTAssertEqual(result.text, "Привет мир")
    }

    func testParseSyncRecognitionResultArray() throws {
        let result = try SaluteSpeechPlugin.parseTranscriptionResult(
            Data(
                """
                {
                  "result": ["Привет мир"],
                  "emotions": [{ "negative": 0, "neutral": 1, "positive": 0 }],
                  "person_identity": {
                    "age": "age_none",
                    "gender": "gender_none"
                  },
                  "status": 200
                }
                """.utf8
            )
        )

        XCTAssertEqual(result.text, "Привет мир")
    }

    func testParseSyncRecognitionDoesNotUseMetadataAsTranscript() {
        XCTAssertThrowsError(try SaluteSpeechPlugin.parseTranscriptionResult(
            Data(
                """
                {
                  "result": [""],
                  "person_identity": {
                    "age": "age_none",
                    "gender": "gender_none"
                  },
                  "status": 200
                }
                """.utf8
            )
        ))
    }

    func testParseAsyncIdsFromNestedSberResponses() throws {
        XCTAssertEqual(
            try SaluteSpeechPlugin.parseRequestFileId(
                Data(#"{"result":{"request_file_id":"request-file"}}"#.utf8)
            ),
            "request-file"
        )
        XCTAssertEqual(
            try SaluteSpeechPlugin.parseTaskId(
                Data(#"{"result":{"id":"task-id","status":"CREATED"}}"#.utf8)
            ),
            "task-id"
        )

        let status = try SaluteSpeechPlugin.parseTaskStatus(
            Data(#"{"result":{"status":"DONE","response_file_id":"response-file"}}"#.utf8)
        )
        XCTAssertTrue(status.isFinished)
        XCTAssertEqual(status.responseFileId, "response-file")
    }

    func testTranscribeFailsWithoutAuthorizationKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = SaluteSpeechPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(
                audio: AudioData(samples: [0], wavData: Data(), duration: 1),
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

    func testTranscribeUsesOAuthTokenThenSyncRecognition() async throws {
        let host = try PluginTestHostServices(
            defaults: ["scope": SaluteSpeechPlugin.personalScope],
            secrets: ["authorization-key": "encoded-key"]
        )
        let plugin = SaluteSpeechPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"access_token":"access-token","expires_at":4102444800000}"#.utf8),
                    Self.httpResponse(url: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth", statusCode: 200)
                ),
                .success(
                    Data(#"[{"results":[{"normalized_text":"Привет мир","text":"privet mir"}]}]"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.25, -0.25], wavData: Data(), duration: 0.2),
            language: "ru",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Привет мир")

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/v2/oauth")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Basic encoded-key")
        XCTAssertEqual(requests[1].url?.path, "/rest/v1/speech:recognize")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "audio/x-pcm;bit=16;rate=16000")
    }

    func testHTTP401MapsToInvalidAuthorizationKey() {
        XCTAssertThrowsError(try SaluteSpeechPlugin.validateHTTPResponse(
            data: Data(#"{"message":"unauthorized"}"#.utf8),
            response: Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 401)
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
