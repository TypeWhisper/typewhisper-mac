import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import MistralAIPlugin

final class MistralAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testMistralAIPluginAdvertisesProtocols() {
        let plugin: Any = MistralAIPlugin()
        
        XCTAssertTrue(plugin is any LLMProviderPlugin)
        XCTAssertTrue(plugin is any TranscriptionEnginePlugin)
        XCTAssertTrue(plugin is any LLMProviderIdentityProviding)
        XCTAssertTrue(plugin is any LLMModelSelectable)
    }

    func testMistralAIModelsAreEmptyWithoutAPIKey() {
        let plugin = MistralAIPlugin()
        XCTAssertTrue(plugin.supportedModels.isEmpty)
        XCTAssertTrue(plugin.transcriptionModels.isEmpty)
    }

    func testMistralAIIsAvailable() throws {
        let plugin = MistralAIPlugin()
        XCTAssertFalse(plugin.isAvailable)
        
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        plugin.activate(host: host)
        
        XCTAssertTrue(plugin.isAvailable)
    }

    func testMistralAITranscriptionModelsIncludeVoxtral() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        let models = plugin.transcriptionModels
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.id == "voxtral-mini-latest" })
        XCTAssertTrue(models.contains { $0.id == "voxtral-small-latest" })
    }

    func testMistralAILLMModelsIncludeMistralSmall() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        let models = plugin.supportedModels
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.contains { $0.id == "mistral-small-latest" })
        XCTAssertTrue(models.contains { $0.id == "mistral-large-latest" })
    }

    func testMistralAISelectsModels() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        plugin.selectLLMModel("mistral-large-latest")
        plugin.selectModel("voxtral-mini-latest")
        
        XCTAssertEqual(plugin.selectedLLMModelId, "mistral-large-latest")
        XCTAssertEqual(plugin.selectedModelId, "voxtral-mini-latest")
    }

    func testMistralAIProviderContractAndIdentity() throws {
        let plugin = MistralAIPlugin()
        
        // Identity checks
        XCTAssertEqual(plugin.providerId, "mistral", "Stable provider ID should be 'mistral'")
        XCTAssertEqual(plugin.providerDisplayName, "Mistral AI")
        
        // LLMModelSelectable checks
        let selectable: any LLMModelSelectable = plugin
        XCTAssertEqual(selectable.defaultModelId, "mistral-small-latest")
        XCTAssertNil(selectable.preferredModelId ?? nil)
        
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        plugin.activate(host: host)
        plugin.selectLLMModel("pixtral-12b-2409")
        
        XCTAssertEqual(selectable.preferredModelId ?? nil, "pixtral-12b-2409")
    }

    func testTranscriptionRetriesWithWavWhenM4AIsRejected() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"message":"unsupported audio format"}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 415)
                ),
                .success(
                    Data(#"{"text":"bonjour"}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "fr", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "bonjour")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.timeoutInterval), [120, 120])
        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))
        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nvoxtral-mini-latest"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nfr"))
    }

    func testTranscriptionUsesDetectedLanguageFromResponse() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello there","language":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        // Request a different language than the response detects: the detected
        // language from the response must win over the requested one.
        let result = try await plugin.transcribe(audio: audio, language: "fr", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testMistralAIConformsToTemperatureControllableProvider() {
        let plugin = MistralAIPlugin()
        XCTAssertTrue(plugin is any LLMTemperatureControllableProvider)
    }

    func testCustomTemperatureIsSentInLLMRequest() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.selectLLMModel("mistral-small-latest")
        plugin.setLLMTemperatureMode(.custom)
        plugin.setLLMTemperatureValue(0.7)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        // Route through PluginHTTPClient by using the same client the plugin uses.
        let client = MistralAPIClient(apiKey: "mistral-key")
        _ = try? await client.processChat(systemPrompt: "s", userText: "u", model: "mistral-small-latest", temperature: 0.7)
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
    }

    func testProviderDefaultTemperatureOmitsField() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.setLLMTemperatureMode(.providerDefault)

        XCTAssertEqual(plugin.llmTemperatureMode, .providerDefault)
    }

    func testVoxtralSmallTranscribesViaChatCompletions() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.selectModel("voxtral-small-latest")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"hello there"}}]}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello there")

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/chat/completions")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "voxtral-small-latest")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertTrue(content.contains { ($0["type"] as? String) == "input_audio" && ($0["input_audio"] as? String)?.isEmpty == false })
        XCTAssertTrue(content.contains { ($0["type"] as? String) == "text" })
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
