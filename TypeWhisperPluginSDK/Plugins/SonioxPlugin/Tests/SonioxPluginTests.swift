import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import SonioxPlugin

final class SonioxPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testDefaultRealtimeModelUsesRTV5AndPersistsSelection() throws {
        let host = try PluginTestHostServices()
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "stt-rt-v5")
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["stt-rt-v5"])
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "automatic")
    }

    func testRetiredRealtimeModelMigratesToRTV5() throws {
        let host = try PluginTestHostServices(defaults: ["selectedModel": "stt-rt-v4"])
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "stt-rt-v5")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "automatic")
    }

    func testFetchedRealtimeModelsDriveAutomaticLatestSelection() throws {
        let models = [
            SonioxFetchedModel(
                id: "stt-rt-v5",
                aliasedModelId: nil,
                name: "STT RT v5",
                transcriptionMode: "real_time",
                languages: []
            ),
            SonioxFetchedModel(
                id: "stt-rt-v6",
                aliasedModelId: nil,
                name: "STT RT v6",
                transcriptionMode: "real_time",
                languages: []
            ),
            SonioxFetchedModel(
                id: "stt-async-v6",
                aliasedModelId: nil,
                name: "STT Async v6",
                transcriptionMode: "async",
                languages: []
            ),
        ]
        let data = try JSONEncoder().encode(models)
        let host = try PluginTestHostServices(defaults: ["fetchedModels": data])
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "stt-rt-v6")
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["stt-rt-v5", "stt-rt-v6"])
    }

    func testDefaultRegionUsesUSAndPersistsSelection() throws {
        let host = try PluginTestHostServices()
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedRegion") as? String, "us")
    }

    func testInvalidStoredRegionMigratesToUS() throws {
        let host = try PluginTestHostServices(defaults: ["selectedRegion": "moon"])
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedRegion") as? String, "us")
    }

    func testSelectedRegionPersistsAcrossPluginActivation() async throws {
        let host = try PluginTestHostServices()
        let plugin = SonioxPlugin()
        plugin.activate(host: host)

        plugin.selectRegion("eu")

        XCTAssertEqual(host.userDefault(forKey: "selectedRegion") as? String, "eu")

        let restartedPlugin = SonioxPlugin()
        restartedPlugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data("{}".utf8),
                    Self.httpResponse(url: "https://api.eu.soniox.com/v1/files", statusCode: 200)
                ),
            ])
        }

        let isValid = await restartedPlugin.validateApiKey("soniox-key")

        XCTAssertTrue(isValid)
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.eu.soniox.com/v1/files")
    }

    func testSonioxPluginAdvertisesTTSProtocolAndDefaultVoice() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "soniox-key"])
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedVoiceId, "Maya")
        XCTAssertTrue(plugin.availableVoices.contains { $0.id == "Adrian" })
        XCTAssertTrue(plugin.authStatus(for: .tts).isAvailable)
    }

    func testCreateTranscriptionRequestUsesAsyncV5Model() throws {
        let request = try SonioxPlugin.makeCreateTranscriptionRequest(
            fileId: "file_123",
            language: "de",
            languageHints: ["en", "de"],
            translate: true,
            apiKey: "soniox-key",
            prompt: nil
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.soniox.com/v1/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["file_id"] as? String, "file_123")
        XCTAssertEqual(body["model"] as? String, "stt-async-v5")
        XCTAssertEqual(body["language_hints"] as? [String], ["en", "de"])

        let translation = try XCTUnwrap(body["translation"] as? [String: Any])
        XCTAssertEqual(translation["type"] as? String, "one_way")
        XCTAssertEqual(translation["target_language"] as? String, "en")
    }

    func testCreateTranscriptionRequestUsesEURegionWhenSelected() throws {
        let request = try SonioxPlugin.makeCreateTranscriptionRequest(
            fileId: "file_123",
            language: "de",
            translate: false,
            apiKey: "soniox-key",
            prompt: nil,
            regionID: "eu"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.eu.soniox.com/v1/transcriptions")
    }

    func testCreateTranscriptionRequestAcceptsDynamicAsyncModel() throws {
        let request = try SonioxPlugin.makeCreateTranscriptionRequest(
            fileId: "file_123",
            language: "de",
            translate: false,
            apiKey: "soniox-key",
            prompt: nil,
            modelID: "stt-async-v6",
            regionID: "eu"
        )

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "stt-async-v6")
    }

    func testTTSRequestUsesJapanRegionAndPCMOutput() throws {
        let request = try SonioxPlugin.makeTTSRequest(
            apiKey: "soniox-key",
            text: "Hello",
            voiceId: "Adrian",
            language: "de-DE",
            modelID: "tts-rt-v2",
            regionID: "jp"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://tts-rt.jp.soniox.com/tts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "tts-rt-v2")
        XCTAssertEqual(body["language"] as? String, "de")
        XCTAssertEqual(body["voice"] as? String, "Adrian")
        XCTAssertEqual(body["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(body["text"] as? String, "Hello")
        XCTAssertEqual(body["sample_rate"] as? Int, 24_000)
    }

    func testSourceProgressTranscriptionUsesAsyncV5RESTPathAndEmitsFinalProgress() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "soniox-key"])
        let plugin = SonioxPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"id":"file_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/files", statusCode: 201)
                ),
                .success(
                    Data(#"{"id":"transcription_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/transcriptions", statusCode: 201)
                ),
                .success(
                    Data(#"{"status":"completed"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/transcriptions/transcription_123", statusCode: 200)
                ),
                .success(
                    Data(#"{"text":"Async file transcript"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/transcriptions/transcription_123/transcript", statusCode: 200)
                ),
            ])
        }

        let progressRecorder = StringRecorder()
        let sourceProgressRecorder = SourceProgressRecorder()

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            languageSelection: PluginLanguageSelection(languageHints: ["en", "de"]),
            translate: false,
            prompt: nil,
            onProgress: { text in
                progressRecorder.append(text)
                return true
            },
            onSourceProgress: { progress in
                sourceProgressRecorder.append(progress)
                return true
            }
        )

        XCTAssertEqual(result.text, "Async file transcript")
        XCTAssertEqual(progressRecorder.values, ["Async file transcript"])
        XCTAssertEqual(sourceProgressRecorder.count, 0)

        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(
            session.requestedPaths,
            [
                "/v1/files",
                "/v1/transcriptions",
                "/v1/transcriptions/transcription_123",
                "/v1/transcriptions/transcription_123/transcript",
            ]
        )

        let uploadRequest = try XCTUnwrap(session.requestedRequests.first { $0.url?.path == "/v1/files" })
        let uploadBody = String(decoding: try XCTUnwrap(uploadRequest.httpBody), as: UTF8.self)
        XCTAssertTrue(uploadBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(uploadBody.contains("Content-Type: audio/mp4"))

        let createRequest = try XCTUnwrap(session.requestedRequests.first { $0.url?.path == "/v1/transcriptions" })
        let body = try Self.jsonBody(from: createRequest)
        XCTAssertEqual(body["model"] as? String, "stt-async-v5")
        XCTAssertEqual(body["language_hints"] as? [String], ["en", "de"])
    }

    func testSourceProgressTranscriptionRetriesUploadWithWavWhenM4ARejected() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "soniox-key"])
        let plugin = SonioxPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"could not process file - is it a valid media file?"}}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/files", statusCode: 400)
                ),
                .success(
                    Data(#"{"id":"file_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/files", statusCode: 201)
                ),
                .success(
                    Data(#"{"id":"transcription_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/transcriptions", statusCode: 201)
                ),
                .success(
                    Data(#"{"status":"completed"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/transcriptions/transcription_123", statusCode: 200)
                ),
                .success(
                    Data(#"{"text":"WAV retry transcript"}"#.utf8),
                    Self.httpResponse(url: "https://api.soniox.com/v1/transcriptions/transcription_123/transcript", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(
            audio: audio,
            languageSelection: PluginLanguageSelection(languageHints: ["en", "de"]),
            translate: false,
            prompt: "TypeWhisper",
            onProgress: { _ in true },
            onSourceProgress: { _ in true }
        )

        XCTAssertEqual(result.text, "WAV retry transcript")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v1/files",
            "/v1/files",
            "/v1/transcriptions",
            "/v1/transcriptions/transcription_123",
            "/v1/transcriptions/transcription_123/transcript",
        ])

        let firstUploadBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstUploadBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstUploadBody.contains("Content-Type: audio/mp4"))

        let retryUploadBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryUploadBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryUploadBody.contains("Content-Type: audio/wav"))

        let createBody = try Self.jsonBody(from: requests[2])
        XCTAssertEqual(createBody["file_id"] as? String, "file_123")
        XCTAssertEqual(createBody["model"] as? String, "stt-async-v5")
        XCTAssertEqual(createBody["language_hints"] as? [String], ["en", "de"])
        let context = try XCTUnwrap(createBody["context"] as? [String: Any])
        XCTAssertEqual(context["terms"] as? [String], ["TypeWhisper"])
    }

    func testSourceProgressTranscriptionUsesSelectedRegionalRESTPath() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedRegion": "eu"],
            secrets: ["api-key": "soniox-key"]
        )
        let plugin = SonioxPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"id":"file_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.eu.soniox.com/v1/files", statusCode: 201)
                ),
                .success(
                    Data(#"{"id":"transcription_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.eu.soniox.com/v1/transcriptions", statusCode: 201)
                ),
                .success(
                    Data(#"{"status":"completed"}"#.utf8),
                    Self.httpResponse(url: "https://api.eu.soniox.com/v1/transcriptions/transcription_123", statusCode: 200)
                ),
                .success(
                    Data(#"{"text":"EU transcript"}"#.utf8),
                    Self.httpResponse(url: "https://api.eu.soniox.com/v1/transcriptions/transcription_123/transcript", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            languageSelection: PluginLanguageSelection(languageHints: ["en"]),
            translate: false,
            prompt: nil,
            onProgress: { _ in true },
            onSourceProgress: { _ in true }
        )

        XCTAssertEqual(result.text, "EU transcript")
        let session = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(
            session.requestedRequests.map { $0.url?.absoluteString },
            [
                "https://api.eu.soniox.com/v1/files",
                "https://api.eu.soniox.com/v1/transcriptions",
                "https://api.eu.soniox.com/v1/transcriptions/transcription_123",
                "https://api.eu.soniox.com/v1/transcriptions/transcription_123/transcript",
            ]
        )
    }

    func testValidateAPIKeyUsesSelectedRegion() async throws {
        let host = try PluginTestHostServices(defaults: ["selectedRegion": "jp"])
        let plugin = SonioxPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data("{}".utf8),
                    Self.httpResponse(url: "https://api.jp.soniox.com/v1/files", statusCode: 200)
                ),
            ])
        }

        let isValid = await plugin.validateApiKey("soniox-key")

        XCTAssertTrue(isValid)
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.jp.soniox.com/v1/files")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
    }

    func testAPIKeyValidationRequestUsesEURegion() throws {
        let request = try SonioxPlugin.makeAPIKeyValidationRequest(
            apiKey: "soniox-key",
            regionID: "eu"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.eu.soniox.com/v1/files")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testModelCatalogRequestsUseSelectedRegion() throws {
        let sttRequest = try SonioxPlugin.makeSTTModelsRequest(apiKey: "soniox-key", regionID: "eu")
        let ttsRequest = try SonioxPlugin.makeTTSModelsRequest(apiKey: "soniox-key", regionID: "jp")

        XCTAssertEqual(sttRequest.url?.absoluteString, "https://api.eu.soniox.com/v1/models")
        XCTAssertEqual(ttsRequest.url?.absoluteString, "https://api.jp.soniox.com/v1/tts-models")
        XCTAssertEqual(sttRequest.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
        XCTAssertEqual(ttsRequest.value(forHTTPHeaderField: "Authorization"), "Bearer soniox-key")
    }

    func testParseTTSModelsExposesFetchedVoices() throws {
        let data = Data(
            #"""
            {
              "models": [
                {
                  "id": "tts-rt-v2",
                  "aliased_model_id": null,
                  "name": "TTS v2",
                  "languages": [{ "code": "de", "name": "German" }],
                  "voices": [{ "id": "NewVoice", "description": "Fresh", "gender": "female" }]
                }
              ]
            }
            """#.utf8
        )
        let host = try PluginTestHostServices(defaults: [
            "fetchedTTSModels": try JSONEncoder().encode(SonioxPlugin.parseTTSModelsResponse(data)),
        ])
        let plugin = SonioxPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.ttsModels.map(\.id), ["tts-rt-v2"])
        XCTAssertEqual(plugin.availableVoices.map(\.id), ["NewVoice"])
        XCTAssertEqual(plugin.selectedVoiceId, "NewVoice")
    }

    func testValidateAPIKeyReturnsFalseForUnauthorizedResponse() async throws {
        let host = try PluginTestHostServices(defaults: ["selectedRegion": "eu"])
        let plugin = SonioxPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error_type":"unauthenticated"}"#.utf8),
                    Self.httpResponse(url: "https://api.eu.soniox.com/v1/files", statusCode: 401)
                ),
            ])
        }

        let isValid = await plugin.validateApiKey("bad-key")

        XCTAssertFalse(isValid)
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.eu.soniox.com/v1/files")
    }

    func testSourceProgressUsesFinalOriginalTokenTiming() {
        let progress = SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "hello", "is_final": true, "end_ms": 1500],
                ["text": "hola", "is_final": true, "end_ms": 9000, "translation_status": "translation"],
                ["text": "draft", "is_final": false, "end_ms": 8000],
            ],
            totalDuration: 10
        )

        XCTAssertEqual(progress?.processedDuration, 1.5)
        XCTAssertEqual(progress?.totalDuration, 10)
        XCTAssertEqual(progress?.fractionCompleted, 0.15)
    }

    func testSourceProgressRequiresTimedFinalOriginalTokens() {
        XCTAssertNil(SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "translated", "is_final": true, "end_ms": 2000, "translation_status": "translation"],
                ["text": "untimed", "is_final": true],
            ],
            totalDuration: 10
        ))

        let clampedProgress = SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "late", "is_final": true, "end_ms": "12000"],
            ],
            totalDuration: 10
        )
        XCTAssertEqual(clampedProgress?.processedDuration, 10)
        XCTAssertNil(SonioxPlugin.sourceProgress(
            fromTokens: [
                ["text": "hello", "is_final": true, "end_ms": 1000],
            ],
            totalDuration: 0
        ))
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private final class SourceProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PluginTranscriptionSourceProgress] = []

    var count: Int {
        lock.withLock { storage.count }
    }

    func append(_ value: PluginTranscriptionSourceProgress) {
        lock.withLock {
            storage.append(value)
        }
    }
}
