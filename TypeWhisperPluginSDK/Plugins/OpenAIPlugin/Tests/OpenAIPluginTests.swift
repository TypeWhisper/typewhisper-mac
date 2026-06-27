import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAIPlugin
import os

final class OpenAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testOpenAIPluginAdvertisesLiveSTTAndTTSProtocols() {
        let plugin: Any = OpenAIPlugin()

        XCTAssertTrue(plugin is any LiveTranscriptionCapablePlugin)
        XCTAssertTrue(plugin is any TTSProviderPlugin)
    }

    func testOpenAIFallbackModelsIncludeGPT55First() {
        let plugin = OpenAIPlugin()

        XCTAssertEqual(plugin.supportedModels.first?.id, "gpt-5.5")
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "gpt-5.5" })
    }

    func testOpenAIChatGPTLoginModelsIncludeGPT55First() throws {
        let host = try PluginTestHostServices(defaults: ["authMode": "chatgpt"])
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.first?.id, "gpt-5.5")
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-5.5")
    }

    func testOpenAIChatGPTLoginOnlyMakesLLMAuthRoleAvailable() throws {
        let host = try PluginTestHostServices(
            defaults: ["authMode": "chatgpt"],
            secrets: ["oauth-refresh-token": "refresh-token"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.authStatus(for: .llm).isAvailable)

        let transcriptionStatus = plugin.authStatus(for: .transcription)
        XCTAssertFalse(transcriptionStatus.isAvailable)
        XCTAssertEqual(transcriptionStatus.requiredCredentialLabel, "OpenAI API key")
        XCTAssertEqual(
            transcriptionStatus.unavailableReason,
            "ChatGPT Login only enables prompt processing. OpenAI transcription requires an OpenAI API key."
        )

        let ttsStatus = plugin.authStatus(for: .tts)
        XCTAssertFalse(ttsStatus.isAvailable)
        XCTAssertEqual(ttsStatus.requiredCredentialLabel, "OpenAI API key")
    }

    func testOpenAIAPIKeyMakesLLMTranscriptionAndTTSAuthRolesAvailable() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "sk-live"])
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.authStatus(for: .llm).isAvailable)
        XCTAssertTrue(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertTrue(plugin.authStatus(for: .tts).isAvailable)
    }

    func testOpenAITranscribeUploadsCompressedM4AForRESTModels() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-1"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.openai.com/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
        XCTAssertFalse(body.contains(#"filename="audio.wav""#))
    }

    func testOpenAITranscribeRetriesWithWavWhenM4AIsRejected() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-1"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":"unsupported audio format"}"#.utf8),
                    Self.httpResponse(url: "https://api.openai.com/v1/audio/transcriptions", statusCode: 415)
                ),
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.openai.com/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
    }

    func testOpenAIWithoutCredentialsMakesCloudAuthRolesUnavailable() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.authStatus(for: .llm).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .tts).isAvailable)
    }

    func testOpenAIUsesResponsesAPIForGPT5ModelsOnly() {
        XCTAssertTrue(OpenAIPlugin.usesResponsesAPI(for: "gpt-5.5"))
        XCTAssertTrue(OpenAIPlugin.usesResponsesAPI(for: "gpt-5.4-mini"))
        XCTAssertFalse(OpenAIPlugin.usesResponsesAPI(for: "gpt-4o"))
    }

    func testOpenAIRealtimeRequestUsesRealtimeWhisperEndpointAndAuth() throws {
        let request = try OpenAIRealtimeTranscriptionSession.makeRequest(apiKey: "sk-test")

        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.url?.path, "/v1/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["intent"], "transcription")
        XCTAssertNil(query["model"])
    }

    func testOpenAIRealtimeSessionUpdatePayloadUsesGATranscriptionSessionAndOmitsUnsupportedPrompt() throws {
        let payload = OpenAIRealtimeTranscriptionSession.sessionUpdatePayload(
            language: "de",
            prompt: "TypeWhisper, OpenAI"
        )

        XCTAssertEqual(payload["type"] as? String, "session.update")
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "de")
        XCTAssertNil(transcription["prompt"])

        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testOpenAIRealtimePCMConversionResamples16kTo24kPCM16() {
        let samples = [Float](repeating: 0, count: 16_000)

        let data = OpenAIRealtimeTranscriptionSession.pcm16DataForRealtime(samples)

        XCTAssertEqual(data.count, 24_000 * MemoryLayout<Int16>.size)
    }

    func testOpenAIRealtimeCollectorPublishesDeltaAndCompletedText() async throws {
        let collector = OpenAIRealtimeTranscriptCollector()

        let delta = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Hello"}"#.utf8
        ))
        XCTAssertEqual(delta, "Hello")

        let completed = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Hello world"}"#.utf8
        ))
        XCTAssertEqual(completed, "Hello world")

        let result = await collector.finalResult(fallbackLanguage: "en")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testOpenAIRealtimeCollectorTracksSessionReadyEvents() async throws {
        let collector = OpenAIRealtimeTranscriptCollector()

        _ = try await collector.applyEvent(Data(#"{"type":"session.updated"}"#.utf8))
        let isSessionReady = await collector.isSessionReady
        XCTAssertTrue(isSessionReady)
    }

    func testOpenAIRealtimeCollectorStoresConnectionFailure() async {
        let collector = OpenAIRealtimeTranscriptCollector()

        await collector.recordConnectionFailure("Socket is not connected")

        let error = await collector.error
        XCTAssertEqual(error, "Socket is not connected")
    }

    func testOpenAIRealtimeFinishAndCancelAreIdempotent() async throws {
        let collector = OpenAIRealtimeTranscriptCollector()
        _ = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Fertig"}"#.utf8
        ))
        let session = OpenAIRealtimeTranscriptionSession(
            webSocketTask: nil,
            receiveTask: nil,
            collector: collector,
            language: "de",
            onProgress: { _ in true }
        )

        let result = try await session.finish()
        await session.cancel()
        await session.cancel()

        XCTAssertEqual(result.text, "Fertig")
        XCTAssertEqual(result.detectedLanguage, "de")
    }

    func testOpenAIRealtimeSocketOpenWaiterResumesAfterDidOpen() async throws {
        let waiter = OpenAIRealtimeWebSocketOpenWaiter()

        let waitTask = Task {
            try await waiter.waitForOpen()
        }
        try await Task.sleep(for: .milliseconds(10))

        waiter.markOpened()

        try await waitTask.value
    }

    func testOpenAITTSConfigUsesMiniTTSPCMAndDefaultVoice() throws {
        XCTAssertEqual(OpenAITTSConfiguration.defaultVoiceId, "marin")
        XCTAssertEqual(OpenAITTSConfiguration.availableVoices.count, 13)
        XCTAssertTrue(OpenAITTSConfiguration.availableVoices.contains { $0.id == "cedar" })

        let body = OpenAITTSConfiguration.requestBody(
            text: "Hallo Welt",
            voice: nil,
            instructions: "Speak calmly."
        )

        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["voice"] as? String, "marin")
        XCTAssertEqual(body["input"] as? String, "Hallo Welt")
        XCTAssertEqual(body["instructions"] as? String, "Speak calmly.")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
    }

    func testOpenAITTSPlaybackSessionStopIsIdempotent() {
        let playback = MockOpenAITTSAudioPlayback()
        let session = OpenAITTSPlaybackSession(task: nil, audioPlayback: playback)
        let counter = FinishCounter()
        session.onFinish = { counter.increment() }

        session.stop()
        session.stop()

        XCTAssertFalse(session.isActive)
        XCTAssertEqual(playback.stopCount, 1)
        XCTAssertEqual(counter.value, 1)
    }

    func testOpenAIResponsesRequestBodyUsesStoreFalseAndReasoning() throws {
        let body = OpenAIResponsesClient.requestBody(
            model: "gpt-5.5",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            reasoningEffort: "medium"
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, "Fix grammar")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    func testOpenAIResponsesParserExtractsOutputText() throws {
        let data = Data(
            """
            {
              "id": "resp_123",
              "output": [
                {
                  "type": "message",
                  "content": [
                    { "type": "output_text", "text": "Cleaned transcript" }
                  ]
                }
              ]
            }
            """.utf8
        )

        XCTAssertEqual(try OpenAIResponsesClient.parseResponse(data), "Cleaned transcript")
    }

    func testOpenAIRefreshFetchedLLMModelsQueriesModelsEndpointAndPersistsCurrentChatModels() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedLLMModel": "stale-model"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "data": [
                            { "id": "whisper-1", "owned_by": "openai" },
                            { "id": "gpt-4o-mini-transcribe", "owned_by": "openai" },
                            { "id": "o4-mini", "owned_by": "openai" },
                            { "id": "gpt-4.1-mini", "owned_by": "openai" },
                            { "id": "tts-1", "owned_by": "openai" }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://api.openai.com/v1/models", statusCode: 200)
                )
            ])
        }

        let models = await plugin.refreshFetchedLLMModels()

        XCTAssertEqual(models.map(\.id), ["gpt-4.1-mini", "o4-mini"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gpt-4.1-mini", "o4-mini"])
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-4.1-mini")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gpt-4.1-mini")

        let cachedData = try XCTUnwrap(host.userDefault(forKey: "fetchedLLMModels") as? Data)
        let cachedModels = try JSONDecoder().decode([OpenAIFetchedModel].self, from: cachedData)
        XCTAssertEqual(cachedModels.map(\.id), ["gpt-4.1-mini", "o4-mini"])

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/models"])
        XCTAssertEqual(
            store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-live"
        )
    }

    func testOpenAIRefreshAvailableLLMModelsUsesChatGPTCatalogWithoutModelsEndpoint() async throws {
        let host = try PluginTestHostServices(defaults: [
            "authMode": "chatgpt",
            "selectedLLMModel": "stale-model",
        ])
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [.failure(URLError(.badURL))])
        }

        let models = await plugin.refreshAvailableLLMModels()

        XCTAssertEqual(models.first?.id, "gpt-5.5")
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-5.5")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gpt-5.5")
        XCTAssertTrue(store.sessions.isEmpty)
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

private final class FinishCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        lock.withLock { $0 }
    }

    func increment() {
        lock.withLock { $0 += 1 }
    }
}

private final class MockOpenAITTSAudioPlayback: OpenAITTSAudioPlayback, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var onDrained: (@Sendable () -> Void)?

    var stopCount: Int {
        lock.withLock { $0 }
    }

    func start(sampleRate: Int) throws {}
    func appendPCM16(_ data: Data) throws {}
    func finishInput() {}

    func stop() {
        lock.withLock { $0 += 1 }
    }
}
