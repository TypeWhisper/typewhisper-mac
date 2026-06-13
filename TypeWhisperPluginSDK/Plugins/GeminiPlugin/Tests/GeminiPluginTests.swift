import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GeminiPlugin

final class GeminiPluginTests: XCTestCase {
    private static let cachedLLMModelsKey = "fetchedLLMModels.v2"
    private static let selectedLLMModelKey = "selectedLLMModel"

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    private static func cachedModelsData() throws -> Data {
        try JSONEncoder().encode([
            GeminiFetchedModel(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash"),
            GeminiFetchedModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            GeminiFetchedModel(id: "gemini-flash-latest", displayName: "Gemini Flash Latest"),
        ])
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "preferredModelId must be nil until the user selects a model"
        )

        let target = try XCTUnwrap(plugin.supportedModels.first?.id)
        plugin.selectLLMModel(target)

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId
        XCTAssertEqual(preferred, target)
    }

    func testFreshActivationDoesNotExposeOrPersistOldestFetchedModel() throws {
        let host = try PluginTestHostServices(
            defaults: [Self.cachedLLMModelsKey: try Self.cachedModelsData()]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.first?.id, "gemini-2.0-flash")
        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "fresh activation must not expose the alphabetically-oldest fetched model as a preference"
        )
        XCTAssertNil(
            host.userDefault(forKey: Self.selectedLLMModelKey),
            "fresh activation must not persist a model the user never selected"
        )
    }

    func testInvalidStoredSelectionIsNotReplacedByOldestFetchedModel() throws {
        let host = try PluginTestHostServices(
            defaults: [
                Self.cachedLLMModelsKey: try Self.cachedModelsData(),
                Self.selectedLLMModelKey: "gemini-removed-model",
            ]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "a stale selection must not be normalized into a fallback preference"
        )
        XCTAssertEqual(
            host.userDefault(forKey: Self.selectedLLMModelKey) as? String,
            "gemini-removed-model",
            "the stored selection is kept so it can re-validate if the model reappears"
        )
    }

    func testDefaultModelIdPrefersCuratedAliasOverOldestFetchedModel() throws {
        let host = try PluginTestHostServices(
            defaults: [Self.cachedLLMModelsKey: try Self.cachedModelsData()]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            (plugin as? LLMModelSelectable)?.defaultModelId,
            "gemini-flash-latest",
            "the host-visible default must be the curated alias, not the retired alphabetically-first model"
        )
    }

    func testValidStoredSelectionSurvivesActivation() throws {
        let host = try PluginTestHostServices(
            defaults: [
                Self.cachedLLMModelsKey: try Self.cachedModelsData(),
                Self.selectedLLMModelKey: "gemini-2.5-flash",
            ]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            (plugin as? LLMModelSelectable)?.preferredModelId,
            "gemini-2.5-flash"
        )
    }

    func testTranscriptionCapabilitiesAndDefaultModels() throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.providerId, "gemini")
        XCTAssertEqual(plugin.providerDisplayName, "Gemini")
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(plugin.selectedModelId, "gemini-3.1-flash-lite")
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.id),
            [
                "gemini-3.1-flash-lite",
                "gemini-2.5-flash-lite",
                "gemini-2.5-flash",
                "gemini-3.5-flash",
            ]
        )
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-3.1-flash-lite")
    }

    func testSelectedTranscriptionModelPersistsAcrossActivation() throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        plugin.selectModel("gemini-2.5-flash")
        plugin.deactivate()

        let reloaded = GeminiPlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-2.5-flash")
        XCTAssertEqual(reloaded.selectedModelId, "gemini-2.5-flash")
    }

    func testInvalidStoredTranscriptionModelFallsBackAndPersistsDefault() throws {
        let host = try PluginTestHostServices(defaults: ["selectedModel": "retired-gemini-stt"])
        let plugin = GeminiPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "gemini-3.1-flash-lite")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-3.1-flash-lite")
    }

    func testTranscriptionRequestUsesGenerateContentJSONAudioPromptAndLanguage() throws {
        let request = try GeminiPlugin.makeTranscriptionRequest(
            audio: Self.audio(),
            apiKey: "gemini-key",
            modelId: "gemini-3.1-flash-lite",
            language: " de ",
            prompt: "Qwen3, MLX, proxy_read_timeout",
            timeout: 60
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 60)

        let body = try Self.jsonBody(from: request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["role"] as? String, "user")

        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let promptText = try XCTUnwrap(parts.first?["text"] as? String)
        XCTAssertTrue(promptText.contains("technical dictation"))
        XCTAssertTrue(promptText.contains("Qwen3, MLX, proxy_read_timeout"))
        XCTAssertTrue(promptText.contains("Language hint: de"))

        let inlineData = try XCTUnwrap(parts.last?["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "audio/wav")
        XCTAssertEqual(inlineData["data"] as? String, Data("wav".utf8).base64EncodedString())

        let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(generationConfig["temperature"] as? Double, 0.2)
        XCTAssertEqual(generationConfig["maxOutputTokens"] as? Int, 2048)
        XCTAssertEqual(generationConfig["responseMimeType"] as? String, "text/plain")
        XCTAssertEqual(
            (generationConfig["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String,
            "MINIMAL"
        )
    }

    func testTranscriptionRequestOmitsEmptyLanguageAndDictionaryTerms() throws {
        let request = try GeminiPlugin.makeTranscriptionRequest(
            audio: Self.audio(),
            apiKey: "gemini-key",
            modelId: "gemini-2.5-flash",
            language: " ",
            prompt: " ",
            timeout: 60
        )

        let body = try Self.jsonBody(from: request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let promptText = try XCTUnwrap(parts.first?["text"] as? String)
        XCTAssertFalse(promptText.contains("User dictionary terms:"))
        XCTAssertFalse(promptText.contains("Language hint:"))

        let generationConfig = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(
            (generationConfig["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int,
            0
        )
    }

    func testTranscribeFailsWithoutAPIKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
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
        let host = try PluginTestHostServices(
            defaults: [Self.cachedLLMModelsKey: try Self.cachedModelsData()],
            secrets: ["api-key": "gemini-key"]
        )
        let plugin = GeminiPlugin()
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
            XCTAssertEqual(message, "Gemini speech transcription does not support translation yet.")
        }
    }

    func testTranscribeSendsGenerateContentRequestAndParsesText() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                Self.cachedLLMModelsKey: try Self.cachedModelsData(),
                "selectedModel": "gemini-3.1-flash-lite",
            ],
            secrets: ["api-key": "gemini-key"]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "candidates": [
                            {
                              "content": {
                                "parts": [
                                  { "text": " hello from gemini \\n" }
                                ]
                              }
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "en",
            translate: false,
            prompt: "TypeWhisper, Qwen3"
        )

        XCTAssertEqual(result.text, "hello from gemini")
        XCTAssertEqual(result.detectedLanguage, "en")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-3.1-flash-lite:generateContent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-key")

        let body = try Self.jsonBody(from: request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let promptText = try XCTUnwrap(parts.first?["text"] as? String)
        XCTAssertTrue(promptText.contains("TypeWhisper, Qwen3"))
    }

    func testTranscriptionHTTPErrorMapping() {
        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"too large"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent", statusCode: 413)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .fileTooLarge = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent", statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"server failed"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent", statusCode: 500)
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
