import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenRouterPlugin

final class OpenRouterPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testTranscriptionCapabilitiesAndFallbackModels() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.providerId, "openrouter")
        XCTAssertEqual(plugin.providerDisplayName, "OpenRouter")
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
        XCTAssertEqual(plugin.selectedModelId, "openai/whisper-1")
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.id),
            [
                "openai/whisper-1",
                "openai/gpt-4o-mini-transcribe",
                "openai/gpt-4o-transcribe",
                "openai/whisper-large-v3",
            ]
        )
    }

    func testSelectedTranscriptionModelPersistsAcrossActivation() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        plugin.selectModel("openai/gpt-4o-transcribe")
        plugin.deactivate()

        let reloaded = OpenRouterPlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai/gpt-4o-transcribe")
        XCTAssertEqual(reloaded.selectedModelId, "openai/gpt-4o-transcribe")
    }

    func testInvalidPersistedModelSelectionsFallbackAndPersistValidDefaults() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": " retired-stt-model ",
            "selectedLLMModel": "retired-llm-model",
        ])
        let plugin = OpenRouterPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "openai/whisper-1")
        XCTAssertEqual(plugin.selectedLLMModelId, "openai/gpt-4o")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai/whisper-1")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "openai/gpt-4o")
    }

    func testProcessSendsLocalChatRequestAndParsesText() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.setLLMTemperatureMode(.custom)
        plugin.setLLMTemperatureValue(0.7)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":" hello from chat \n"}}]}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(
            systemPrompt: "System prompt",
            userText: "User text",
            model: nil
        )

        XCTAssertEqual(result, "hello from chat")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openrouter-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "openai/gpt-4o")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)

        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [
            ["role": "system", "content": "System prompt"],
            ["role": "user", "content": "User text"],
        ])
    }

    func testChatHTTPErrorMapping() {
        XCTAssertThrowsError(try OpenRouterPlugin.validateChatResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateChatResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateChatResponse(
            data: Data(#"{"error":{"message":"server failed"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 500)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "server failed")
        }
    }

    func testLLMAndTranscriptionModelFetchesUseSeparateEndpointsAndCaches() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "data": [
                            {
                              "id": "openai/whisper-1",
                              "name": "OpenAI: Whisper 1",
                              "architecture": { "modality": "audio->transcription" }
                            },
                            {
                              "id": "openai/gpt-4o",
                              "name": "OpenAI: GPT-4o",
                              "pricing": { "prompt": "0.0000025", "completion": "0.00001" },
                              "architecture": { "modality": "text->text" }
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/models", statusCode: 200)
                ),
                .success(
                    Data(
                        """
                        {
                          "data": [
                            {
                              "id": "z-provider/z-stt",
                              "name": "Zulu STT",
                              "pricing": { "prompt": "0.40", "completion": "0" },
                              "architecture": { "modality": "audio->transcription" }
                            },
                            {
                              "id": "a-provider/a-stt",
                              "name": "Alpha STT",
                              "pricing": { "prompt": "0.20", "completion": "0" },
                              "architecture": { "modality": "audio->transcription" }
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/models?output_modalities=transcription", statusCode: 200)
                ),
            ])
        }

        let llmModels = await plugin.fetchLLMModels()
        let transcriptionModels = await plugin.fetchTranscriptionModels()
        plugin.setFetchedLLMModels(llmModels)
        plugin.setFetchedTranscriptionModels(transcriptionModels)

        XCTAssertEqual(llmModels.map(\.id), ["openai/gpt-4o"])
        XCTAssertEqual(transcriptionModels.map(\.id), ["a-provider/a-stt", "z-provider/z-stt"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["openai/gpt-4o"])
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["a-provider/a-stt", "z-provider/z-stt"])

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/models", "/api/v1/models"])
        XCTAssertEqual(requests.map { $0.url?.query }, [nil, "output_modalities=transcription"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer openrouter-key",
            "Bearer openrouter-key",
        ])
        XCTAssertNotNil(host.userDefault(forKey: "fetchedModels") as? Data)
        XCTAssertNotNil(host.userDefault(forKey: "fetchedTranscriptionModels") as? Data)
    }

    func testTranscribeFailsWithoutAPIKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(
                audio: Self.audio(),
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

    func testTranscribeRejectsTranslateRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(
                audio: Self.audio(),
                language: nil,
                translate: true,
                prompt: nil
            )
            XCTFail("Expected apiError")
        } catch let error as PluginTranscriptionError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "OpenRouter speech-to-text does not support translation.")
        }
    }

    func testTranscriptionRequestUsesJSONBase64AndLanguage() throws {
        let request = try OpenRouterPlugin.makeTranscriptionRequest(
            audio: Self.audio(),
            apiKey: "openrouter-key",
            modelId: "openai/whisper-1",
            language: " de ",
            timeout: 120
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openrouter-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "openai/whisper-1")
        XCTAssertEqual(body["language"] as? String, "de")

        let inputAudio = try XCTUnwrap(body["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "wav")
        XCTAssertEqual(inputAudio["data"] as? String, Data("wav".utf8).base64EncodedString())
    }

    func testTranscriptionRequestOmitsEmptyLanguageAndPrompt() throws {
        let request = try OpenRouterPlugin.makeTranscriptionRequest(
            audio: Self.audio(),
            apiKey: "openrouter-key",
            modelId: "openai/whisper-1",
            language: " ",
            timeout: 120
        )

        let body = try Self.jsonBody(from: request)
        XCTAssertNil(body["language"])
        XCTAssertNil(body["prompt"])
    }

    func testTranscribeSendsJSONRequestAndParsesText() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "openai/whisper-1"],
            secrets: ["api-key": "openrouter-key"]
        )
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello from openrouter","usage":{"cost":0.01}}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "de",
            translate: false,
            prompt: "ignored dictionary terms"
        )

        XCTAssertEqual(result.text, "hello from openrouter")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "openai/whisper-1")
        XCTAssertEqual(body["language"] as? String, "de")
        XCTAssertNil(body["prompt"])
    }

    func testTranscriptionHTTPErrorMapping() {
        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"server failed"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 500)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "HTTP 500: server failed")
        }
    }

    private static func audio() -> AudioData {
        AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1)
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
