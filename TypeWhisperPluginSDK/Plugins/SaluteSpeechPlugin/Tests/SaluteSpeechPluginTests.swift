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

    func testRecognitionLanguageMappingSupportsRussianEnglishAndDefault() {
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage(nil), "ru-RU")
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage(" "), "ru-RU")
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage("ru"), "ru-RU")
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage("ru_RU"), "ru-RU")
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage("en"), "en-US")
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage("en_GB"), "en-US")
        XCTAssertEqual(SaluteSpeechPlugin.resolvedRecognitionLanguage("de"), "ru-RU")
    }

    func testSupportedLanguagesExposeRussianAndEnglish() {
        let plugin = SaluteSpeechPlugin()

        XCTAssertEqual(plugin.supportedLanguages, ["ru", "ru-RU", "en", "en-US"])
    }

    func testSyncRecognitionRequestUsesPCMContentTypeBearerTokenAndLanguage() throws {
        let request = try SaluteSpeechPlugin.makeSyncRecognitionRequest(
            pcmData: Data([0x01, 0x02]),
            token: "access-token",
            modelId: "general",
            language: "en-US"
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
        XCTAssertEqual(query["language"], "en-US")
    }

    func testStartAsyncRequestUsesPCMOptionsAndLanguage() throws {
        let request = try SaluteSpeechPlugin.makeStartAsyncRecognitionRequest(
            requestFileId: "file-id",
            token: "access-token",
            modelId: "general",
            language: "en-US"
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
        XCTAssertEqual(options["language"] as? String, "en-US")
        XCTAssertEqual(options["audio_encoding"] as? String, "PCM_S16LE")
        XCTAssertEqual(options["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(options["channels_count"] as? Int, 1)
    }

    func testDownloadRequestUsesBearerTokenAndLongTimeout() throws {
        let request = try SaluteSpeechPlugin.makeDownloadRequest(
            responseFileId: "response-file",
            token: "access-token"
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "smartspeech.sber.ru")
        XCTAssertEqual(request.url?.path, "/rest/v1/data:download")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(request.timeoutInterval, 600)

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["response_file_id"], "response-file")
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

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["language"], "ru-RU")
    }

    func testTranscribeUsesSelectedEnglishLanguageForSyncRecognition() async throws {
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
                    Data(#"{"result":["Hello world"]}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.25, -0.25], wavData: Data(), duration: 0.2),
            language: "en",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Hello world")

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map(\.url?.path), ["/api/v2/oauth", "/rest/v1/speech:recognize"])

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["language"], "en-US")
    }

    func testTranscribeUsesSelectedEnglishLanguageForAsyncRecognition() async throws {
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
                    Data(#"{"result":{"request_file_id":"request-file"}}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/data:upload", statusCode: 200)
                ),
                .success(
                    Data(#"{"result":{"id":"task-id","status":"CREATED"}}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:async_recognize", statusCode: 200)
                ),
                .success(
                    Data(#"{"result":{"status":"DONE","response_file_id":"response-file"}}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/task:get", statusCode: 200)
                ),
                .success(
                    Data(#"{"result":["Hello async"]}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/data:download", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.25, -0.25], wavData: Data(), duration: 61),
            language: "en-US",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Hello async")

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/api/v2/oauth",
                "/rest/v1/data:upload",
                "/rest/v1/speech:async_recognize",
                "/rest/v1/task:get",
                "/rest/v1/data:download",
            ]
        )

        let body = try XCTUnwrap(requests[2].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["language"] as? String, "en-US")
    }

    func testDeactivateClearsConfigurationSnapshot() async throws {
        let host = try PluginTestHostServices(
            defaults: ["scope": SaluteSpeechPlugin.personalScope],
            secrets: ["authorization-key": "encoded-key"]
        )
        let plugin = SaluteSpeechPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.isConfigured)

        plugin.deactivate()

        XCTAssertFalse(plugin.isConfigured)
        do {
            _ = try await plugin.transcribe(
                audio: AudioData(samples: [0, 0.1], wavData: Data(), duration: 1),
                language: "ru",
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

    func testTranscribeRefreshesOAuthTokenAfterAuthorizationKeyChange() async throws {
        let host = try PluginTestHostServices(
            defaults: ["scope": SaluteSpeechPlugin.personalScope],
            secrets: ["authorization-key": "encoded-key-1"]
        )
        let plugin = SaluteSpeechPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"access_token":"access-token-1","expires_at":4102444800000}"#.utf8),
                    Self.httpResponse(url: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth", statusCode: 200)
                ),
                .success(
                    Data(#"{"result":["Первый"]}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 200)
                ),
                .success(
                    Data(#"{"access_token":"access-token-2","expires_at":4102444800000}"#.utf8),
                    Self.httpResponse(url: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth", statusCode: 200)
                ),
                .success(
                    Data(#"{"result":["Второй"]}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 200)
                ),
            ])
        }

        _ = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.1], wavData: Data(), duration: 1),
            language: "ru",
            translate: false,
            prompt: nil
        )
        try plugin.setAuthorizationKey("encoded-key-2")
        let secondResult = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.1], wavData: Data(), duration: 1),
            language: "ru",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(secondResult.text, "Второй")

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Basic encoded-key-1")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer access-token-1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Basic encoded-key-2")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer access-token-2")
    }

    func testSuccessfulTranscriptionTracksRecognitionUsageAndPersistsIt() async throws {
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
                    Data(#"{"result":["Привет"]}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 200)
                ),
            ])
        }

        _ = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.1], wavData: Data(), duration: 12.5),
            language: "ru",
            translate: false,
            prompt: nil
        )

        let snapshot = plugin.usageSnapshotForSettings
        XCTAssertEqual(snapshot.trackedSeconds, 12.5, accuracy: 0.001)
        XCTAssertNotNil(snapshot.lastTranscriptionAt)

        let reloadedPlugin = SaluteSpeechPlugin()
        reloadedPlugin.activate(host: host)
        XCTAssertEqual(reloadedPlugin.usageSnapshotForSettings.trackedSeconds, 12.5, accuracy: 0.001)
    }

    func testBalanceCorrectionEstimatesRemainingFromSubsequentUsage() async throws {
        let host = try PluginTestHostServices(
            defaults: ["scope": SaluteSpeechPlugin.personalScope],
            secrets: ["authorization-key": "encoded-key"]
        )
        let plugin = SaluteSpeechPlugin()
        plugin.activate(host: host)

        let validUntil = Date(timeIntervalSince1970: 1_783_468_800)
        try plugin.setUsageBalanceCorrection(remainingMinutes: 99, validUntil: validUntil)
        XCTAssertEqual(plugin.usageSnapshotForSettings.estimatedRemainingSeconds, 99 * 60)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"access_token":"access-token","expires_at":4102444800000}"#.utf8),
                    Self.httpResponse(url: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth", statusCode: 200)
                ),
                .success(
                    Data(#"{"result":["Проверка"]}"#.utf8),
                    Self.httpResponse(url: "https://smartspeech.sber.ru/rest/v1/speech:recognize", statusCode: 200)
                ),
            ])
        }

        _ = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0.1], wavData: Data(), duration: 60),
            language: "ru",
            translate: false,
            prompt: nil
        )

        let snapshot = plugin.usageSnapshotForSettings
        XCTAssertEqual(snapshot.spentSinceBalanceCorrectionSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot.estimatedRemainingSeconds, 98 * 60)
        XCTAssertEqual(snapshot.balanceValidUntil, validUntil)
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
