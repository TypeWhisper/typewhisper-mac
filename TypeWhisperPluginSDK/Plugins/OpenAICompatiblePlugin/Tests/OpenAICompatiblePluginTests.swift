import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAICompatiblePlugin

final class OpenAICompatiblePluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testSetBaseURLNormalizesTrailingSlashAndV1Suffix() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.setBaseURL("http://localhost:11434/v1/")

        XCTAssertEqual(host.userDefault(forKey: "baseURL") as? String, "http://localhost:11434")
        XCTAssertTrue(host.capabilitiesChangedCount >= 1)
    }

    func testModelSelectionsPersistAcrossActivation() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "http://localhost:11434"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.selectModel("whisper-1")
        plugin.selectLLMModel("gpt-4.1-mini")
        plugin.setThinkingEnabled(true)
        plugin.deactivate()

        let reloaded = OpenAICompatiblePlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(reloaded.selectedModelId, "whisper-1")
        XCTAssertEqual(reloaded.selectedLLMModelId, "gpt-4.1-mini")
        XCTAssertEqual(reloaded.profileSnapshot(for: reloaded.providerId)?.thinkingEnabled, true)
    }

    func testLegacyConfigurationMigratesIntoDefaultProfile() throws {
        let cachedModels = try JSONEncoder().encode([
            FetchedModel(id: "legacy-model")
        ])
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://legacy.test/v1/",
                "selectedModel": "whisper-legacy",
                "selectedLLMModel": "chat-legacy",
                "llmTemperatureMode": PluginLLMTemperatureMode.custom.rawValue,
                "llmTemperatureValue": 0.7,
                "fetchedModels": cachedModels,
            ],
            secrets: ["api-key": "legacy-token"]
        )
        let plugin = OpenAICompatiblePlugin()

        plugin.activate(host: host)

        let profile = try XCTUnwrap(plugin.profileSnapshots.first)
        XCTAssertEqual(plugin.profileSnapshots.count, 1)
        XCTAssertEqual(profile.id, "openai-compatible")
        XCTAssertEqual(profile.displayName, "OpenAI Compatible")
        XCTAssertEqual(profile.baseURL, "https://legacy.test")
        XCTAssertEqual(profile.selectedModelId, "whisper-legacy")
        XCTAssertEqual(profile.selectedLLMModelId, "chat-legacy")
        XCTAssertEqual(profile.llmTemperatureModeRaw, PluginLLMTemperatureMode.custom.rawValue)
        XCTAssertEqual(profile.llmTemperatureValue, 0.7)
        XCTAssertFalse(profile.thinkingEnabled)
        XCTAssertEqual(profile.fetchedModels.map(\.id), ["legacy-model"])
        XCTAssertEqual(plugin.apiKey(for: profile.id), "legacy-token")
        XCTAssertNotNil(host.userDefault(forKey: "profiles") as? Data)
    }

    func testSavedProfilesWithoutThinkingModeDecodeAsDisabled() throws {
        let savedProfiles = Data(
            """
            [
              {
                "id": "openai-compatible",
                "name": "OpenAI Compatible",
                "baseURL": "https://legacy-profile.test",
                "selectedModelId": "whisper-legacy",
                "selectedLLMModelId": "chat-legacy",
                "llmTemperatureModeRaw": "providerDefault",
                "llmTemperatureValue": 0.3,
                "fetchedModels": [],
                "chatRequestTimeoutSeconds": 45
              }
            ]
            """.utf8
        )
        let host = try PluginTestHostServices(defaults: ["profiles": savedProfiles])
        let plugin = OpenAICompatiblePlugin()

        plugin.activate(host: host)

        let profile = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))
        XCTAssertFalse(profile.thinkingEnabled)
        XCTAssertEqual(profile.resolvedChatRequestTimeout, 45)
        XCTAssertNoThrow(try JSONEncoder().encode(plugin.profileSnapshots))
    }

    func testAdditionalProfilesExposeIndependentTranscriptionAndLLMRoles() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://default.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let alter = plugin.addProfile(named: "Alter")
        plugin.setBaseURL("https://alter.test/v1/", for: alter.id)
        plugin.selectModel("alter-whisper", for: alter.id)
        plugin.selectLLMModel("alter-chat", for: alter.id)

        let engine = try XCTUnwrap(plugin.additionalTranscriptionEngines.first)
        let provider = try XCTUnwrap(plugin.additionalLLMProviders.first)

        XCTAssertEqual(engine.providerId, alter.id)
        XCTAssertEqual(engine.providerDisplayName, "Alter")
        XCTAssertEqual(engine.selectedModelId, "alter-whisper")
        XCTAssertEqual(provider.llmProviderId, alter.id)
        XCTAssertEqual(provider.llmProviderDisplayName, "Alter")
        XCTAssertEqual((provider as? LLMModelSelectable)?.preferredModelId, "alter-chat")
        XCTAssertEqual(plugin.providerId, "openai-compatible")
        XCTAssertEqual(plugin.providerDisplayName, "OpenAI Compatible")
    }

    func testDeletingProfileRemovesAdditionalRoles() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let profile = plugin.addProfile(named: "Inception")

        XCTAssertEqual(plugin.additionalLLMProviders.count, 1)
        XCTAssertEqual(plugin.additionalTranscriptionEngines.count, 1)

        plugin.deleteProfile(profile.id)

        XCTAssertTrue(plugin.additionalLLMProviders.isEmpty)
        XCTAssertTrue(plugin.additionalTranscriptionEngines.isEmpty)
    }

    func testFetchModelsSendsBearerTokenAndSortsIDs() async throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test"],
            secrets: ["api-key": "secret-token"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[{"id":"z-model"},{"id":"a-model"}]}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/models", statusCode: 200)
                )
            ])
        }

        let models = await plugin.fetchModels()

        XCTAssertEqual(models.map(\.id), ["a-model", "z-model"])
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(
            store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-token"
        )
    }

    func testValidateConnectionReturnsTrueForHTTP200() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(),
                    Self.httpResponse(url: "https://example.test/v1/models", statusCode: 200)
                )
            ])
        }

        let result = await plugin.validateConnection()

        XCTAssertTrue(result)
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/models"])
    }

    func testTranscribeUsesLongTimeoutForLocalCompatibleServers() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://example.test",
                "selectedModel": "large-v3",
            ]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello"}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/audio/transcriptions", statusCode: 200)
                )
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/audio/transcriptions"])
        XCTAssertEqual(store.sessions[0].requestedRequests.first?.timeoutInterval, 600)
    }

    func testProfileSpecificTranscriptionUsesSeparateCredentialsAndURLs() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://default.test",
                "selectedModel": "default-whisper",
            ],
            secrets: ["api-key": "default-token"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let alter = plugin.addProfile(named: "Alter")
        plugin.setBaseURL("https://alter.test", for: alter.id)
        plugin.setApiKey("alter-token", for: alter.id)
        plugin.selectModel("alter-whisper", for: alter.id)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"default text"}"#.utf8),
                    Self.httpResponse(url: "https://default.test/v1/audio/transcriptions", statusCode: 200)
                ),
                .success(
                    Data(#"{"text":"alter text"}"#.utf8),
                    Self.httpResponse(url: "https://alter.test/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let defaultResult = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        let alterEngine = try XCTUnwrap(plugin.additionalTranscriptionEngines.first)
        let alterResult = try await alterEngine.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(defaultResult.text, "default text")
        XCTAssertEqual(alterResult.text, "alter text")
        XCTAssertEqual(store.sessions[0].requestedRequests.map { $0.url?.host }, ["default.test", "alter.test"])
        XCTAssertEqual(
            store.sessions[0].requestedRequests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer default-token", "Bearer alter-token"]
        )
    }

    func testProfileSpecificLLMUsesSeparateCredentialModelAndTemperature() async throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.setBaseURL("https://default-llm.test")
        plugin.setApiKey("default-llm-token")
        plugin.selectLLMModel("default-chat")
        plugin.setLLMTemperatureMode(.custom)
        plugin.setLLMTemperatureValue(0.2)

        let inception = plugin.addProfile(named: "Inception")
        plugin.setBaseURL("https://inception.test", for: inception.id)
        plugin.setApiKey("inception-token", for: inception.id)
        plugin.selectLLMModel("gpt-5.5", for: inception.id)
        plugin.setLLMTemperatureMode(.custom, for: inception.id)
        plugin.setLLMTemperatureValue(0.9, for: inception.id)
        plugin.setThinkingEnabled(true, for: inception.id)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"default processed"}}]}"#.utf8),
                    Self.httpResponse(url: "https://default-llm.test/v1/chat/completions", statusCode: 200)
                ),
                .success(
                    Data(#"{"choices":[{"message":{"content":"inception processed"}}]}"#.utf8),
                    Self.httpResponse(url: "https://inception.test/v1/chat/completions", statusCode: 200)
                )
            ])
        }

        let defaultResult = try await plugin.process(
            systemPrompt: "Fix",
            userText: "hello",
            model: nil,
            temperatureDirective: .inheritProviderSetting
        )
        let provider = try XCTUnwrap(plugin.additionalLLMProviders.first as? any LLMTemperatureControllableProvider)
        let inceptionResult = try await provider.process(
            systemPrompt: "Fix",
            userText: "hello",
            model: nil,
            temperatureDirective: .inheritProviderSetting
        )

        XCTAssertEqual(defaultResult, "default processed")
        XCTAssertEqual(inceptionResult, "inception processed")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.map { $0.url?.host }, ["default-llm.test", "inception.test"])
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer default-llm-token", "Bearer inception-token"]
        )

        let defaultBody = try XCTUnwrap(requests[0].httpBody)
        let defaultJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: defaultBody) as? [String: Any])
        XCTAssertEqual(defaultJSON["model"] as? String, "default-chat")
        XCTAssertEqual(defaultJSON["max_tokens"] as? Int, 4096)
        XCTAssertEqual(defaultJSON["temperature"] as? Double, 0.2)
        let defaultThinking = try XCTUnwrap(defaultJSON["thinking"] as? [String: String])
        XCTAssertEqual(defaultThinking["type"], "disabled")

        let inceptionBody = try XCTUnwrap(requests[1].httpBody)
        let inceptionJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: inceptionBody) as? [String: Any])
        XCTAssertEqual(inceptionJSON["model"] as? String, "gpt-5.5")
        XCTAssertEqual(inceptionJSON["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(inceptionJSON["max_tokens"])
        XCTAssertEqual(inceptionJSON["temperature"] as? Double, 0.9)
        let inceptionThinking = try XCTUnwrap(inceptionJSON["thinking"] as? [String: String])
        XCTAssertEqual(inceptionThinking["type"], "enabled")
    }

    func testOutputTokenParameterUsesMaxCompletionTokensForReasoningFamilies() {
        XCTAssertEqual(OpenAICompatiblePlugin.outputTokenParameter(for: "gpt-5.5"), "max_completion_tokens")
        XCTAssertEqual(OpenAICompatiblePlugin.outputTokenParameter(for: "o1-preview"), "max_completion_tokens")
        XCTAssertEqual(OpenAICompatiblePlugin.outputTokenParameter(for: "o3-mini"), "max_completion_tokens")
        XCTAssertEqual(OpenAICompatiblePlugin.outputTokenParameter(for: "o4-mini"), "max_completion_tokens")
        XCTAssertEqual(OpenAICompatiblePlugin.outputTokenParameter(for: "gpt-4o"), "max_tokens")
    }

    func testProcessSurfacesOpenAICompatibleErrorMessage() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.selectLLMModel("missing-model")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"[{"error":{"message":"model not found"}}]"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/chat/completions", statusCode: 404)
                )
            ])
        }

        do {
            _ = try await plugin.process(systemPrompt: "Fix", userText: "hello", model: nil)
            XCTFail("Expected apiError")
        } catch let error as PluginChatError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "model not found")
        }

        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/chat/completions"])
    }

    func testSetChatRequestTimeoutIgnoresNonFiniteValues() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.setChatRequestTimeout(600, for: plugin.providerId)
        XCTAssertEqual(plugin.profileSnapshot(for: plugin.providerId)?.chatRequestTimeoutSeconds, 600)

        plugin.setChatRequestTimeout(.nan, for: plugin.providerId)
        plugin.setChatRequestTimeout(.infinity, for: plugin.providerId)

        let stored = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))
        XCTAssertEqual(stored.chatRequestTimeoutSeconds, 600)
        XCTAssertTrue(stored.resolvedChatRequestTimeout.isFinite)
        XCTAssertNoThrow(try JSONEncoder().encode(plugin.profileSnapshots))
    }

    func testProcessFailsWithoutSelectedModel() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.process(systemPrompt: "Fix", userText: "hello", model: nil)
            XCTFail("Expected noModelSelected")
        } catch let error as PluginChatError {
            guard case .noModelSelected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTranscribeFailsWithoutSelectedModel() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let audio = AudioData(samples: [0, 0, 0], wavData: Data(), duration: 0.1)

        do {
            _ = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
            XCTFail("Expected noModelSelected")
        } catch let error as PluginTranscriptionError {
            guard case .noModelSelected = error else {
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
