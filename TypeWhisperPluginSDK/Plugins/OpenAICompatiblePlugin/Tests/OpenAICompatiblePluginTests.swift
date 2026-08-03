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
                "apiVersion": " preview\n",
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
        XCTAssertEqual(profile.apiVersion, "preview")
        XCTAssertEqual(profile.selectedModelId, "whisper-legacy")
        XCTAssertEqual(profile.selectedLLMModelId, "chat-legacy")
        XCTAssertEqual(profile.llmTemperatureModeRaw, PluginLLMTemperatureMode.custom.rawValue)
        XCTAssertEqual(profile.llmTemperatureValue, 0.7)
        XCTAssertFalse(profile.thinkingEnabled)
        XCTAssertEqual(profile.fetchedModels.map(\.id), ["legacy-model"])
        XCTAssertEqual(plugin.apiKey(for: profile.id), "legacy-token")
        XCTAssertNotNil(host.userDefault(forKey: "profiles") as? Data)
    }

    func testMissingDefaultProfileRestoresTrimmedLegacyAPIVersion() throws {
        let savedProfiles = try JSONEncoder().encode([
            OpenAICompatibleProfile(
                id: "openai-compatible:custom",
                name: "Custom Server",
                baseURL: "https://custom.test",
                apiVersion: "custom-version"
            )
        ])
        let host = try PluginTestHostServices(
            defaults: [
                "profiles": savedProfiles,
                "baseURL": "https://legacy.test/openai",
                "apiVersion": " preview\n",
            ]
        )
        let plugin = OpenAICompatiblePlugin()

        plugin.activate(host: host)

        let defaultProfile = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))
        XCTAssertEqual(defaultProfile.apiVersion, "preview")
        XCTAssertEqual(host.userDefault(forKey: "apiVersion") as? String, "preview")
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
        XCTAssertEqual(profile.apiVersion, "")
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
        XCTAssertNil(store.sessions[0].requestedRequests.first?.url?.query)
        XCTAssertEqual(
            store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-token"
        )
        XCTAssertNil(store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "api-key"))
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
        XCTAssertNil(store.sessions[0].requestedRequests.first?.url?.query)
    }

    func testConfiguredAPIVersionPreservesExistingQueryForModelRequests() async throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test/openai?tenant=contoso"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.setApiVersion(" preview ", for: plugin.providerId)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[{"id":"gpt-live-transcribe"}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://example.test/openai/v1/models?tenant=contoso&api-version=preview",
                        statusCode: 200
                    )
                ),
                .success(
                    Data(),
                    Self.httpResponse(
                        url: "https://example.test/openai/v1/models?tenant=contoso&api-version=preview",
                        statusCode: 200
                    )
                ),
            ])
        }

        let models = await plugin.fetchModels()
        let isConnected = await plugin.validateConnection()

        XCTAssertEqual(models.map(\.id), ["gpt-live-transcribe"])
        XCTAssertTrue(isConnected)
        XCTAssertEqual(plugin.profileSnapshot(for: plugin.providerId)?.apiVersion, "preview")
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 2)
        for request in store.sessions[0].requestedRequests {
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.path, "/openai/v1/models")
            XCTAssertEqual(
                components.queryItems,
                [
                    URLQueryItem(name: "tenant", value: "contoso"),
                    URLQueryItem(name: "api-version", value: "preview"),
                ]
            )
        }
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
        XCTAssertNil(store.sessions[0].requestedRequests.first?.url?.query)
        XCTAssertEqual(store.sessions[0].requestedRequests.first?.timeoutInterval, 600)
        let body = String(decoding: try XCTUnwrap(store.sessions[0].requestedRequests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
    }

    func testConfiguredAPIVersionAppliesToTranscriptionTranslationAndChat() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://example.test/openai?tenant=contoso",
                "selectedModel": "gpt-transcribe",
                "selectedLLMModel": "gpt-chat",
            ]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.setApiVersion("preview", for: plugin.providerId)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"transcribed"}"#.utf8),
                    Self.httpResponse(
                        url: "https://example.test/openai/v1/audio/transcriptions?tenant=contoso&api-version=preview",
                        statusCode: 200
                    )
                ),
                .success(
                    Data(#"{"text":"translated"}"#.utf8),
                    Self.httpResponse(
                        url: "https://example.test/openai/v1/audio/translations?tenant=contoso&api-version=preview",
                        statusCode: 200
                    )
                ),
                .success(
                    Data(#"{"choices":[{"message":{"content":"completed"}}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://example.test/openai/v1/chat/completions?tenant=contoso&api-version=preview",
                        statusCode: 200
                    )
                ),
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let transcription = try await plugin.transcribe(
            audio: audio,
            language: nil,
            translate: false,
            prompt: nil
        )
        let translation = try await plugin.transcribe(
            audio: audio,
            language: nil,
            translate: true,
            prompt: nil
        )
        let chat = try await plugin.process(systemPrompt: "Fix", userText: "hello", model: nil)

        XCTAssertEqual(transcription.text, "transcribed")
        XCTAssertEqual(translation.text, "translated")
        XCTAssertEqual(chat, "completed")
        XCTAssertEqual(
            store.sessions[0].requestedRequests.compactMap(\.url).map(\.path),
            [
                "/openai/v1/audio/transcriptions",
                "/openai/v1/audio/translations",
                "/openai/v1/chat/completions",
            ]
        )
        for url in store.sessions[0].requestedRequests.compactMap(\.url) {
            XCTAssertEqual(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                [
                    URLQueryItem(name: "tenant", value: "contoso"),
                    URLQueryItem(name: "api-version", value: "preview"),
                ]
            )
        }
    }

    func testAzureEndpointsSendAPIKeyHeaderAlongsideBearerAuthentication() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://foundry-example.services.ai.azure.com/openai",
                "selectedModel": "gpt-transcribe",
                "selectedLLMModel": "gpt-chat",
            ],
            secrets: ["api-key": "azure-key"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.setApiVersion("preview", for: plugin.providerId)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[{"id":"gpt-transcribe"}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://foundry-example.services.ai.azure.com/openai/v1/models?api-version=preview",
                        statusCode: 200
                    )
                ),
                .success(
                    Data(),
                    Self.httpResponse(
                        url: "https://foundry-example.services.ai.azure.com/openai/v1/models?api-version=preview",
                        statusCode: 200
                    )
                ),
                .success(
                    Data(
                        #"{"text":"transcribed","language":"en","segments":[{"start":0.0,"end":1.0,"text":"transcribed"}]}"#.utf8
                    ),
                    Self.httpResponse(
                        url: "https://foundry-example.services.ai.azure.com/openai/v1/audio/transcriptions?api-version=preview",
                        statusCode: 200
                    )
                ),
                .success(
                    Data(#"{"choices":[{"message":{"content":"completed"}}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://foundry-example.services.ai.azure.com/openai/v1/chat/completions?api-version=preview",
                        statusCode: 200
                    )
                ),
            ])
        }

        _ = await plugin.fetchModels()
        let isConnected = await plugin.validateConnection()
        XCTAssertTrue(isConnected)
        let transcription = try await plugin.transcribe(
            audio: AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0),
            language: nil,
            translate: false,
            prompt: nil
        )
        _ = try await plugin.process(systemPrompt: "Fix", userText: "hello", model: nil)

        XCTAssertEqual(store.sessions[0].requestedRequests.count, 4)
        for request in store.sessions[0].requestedRequests {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer " + "azure-key"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "azure-key")
        }
        let segment = try XCTUnwrap(transcription.segments.first)
        XCTAssertEqual(transcription.segments.count, 1)
        XCTAssertEqual(segment.text, "transcribed")
        XCTAssertEqual(segment.start, 0)
        XCTAssertEqual(segment.end, 1)
    }

    func testAzureSovereignEndpointUsesAzureAuthenticationHeaders() async throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://resource.openai.azure.us"],
            secrets: ["api-key": "sovereign-key"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"data":[]}"#.utf8),
                    Self.httpResponse(url: "https://resource.openai.azure.us/v1/models", statusCode: 200)
                )
            ])
        }

        _ = await plugin.fetchModels()

        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer " + "sovereign-key"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "sovereign-key")
    }

    func testTranscribeRetriesWithWavWhenCompatibleServerRejectsM4A() async throws {
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
                    Data(#"{"error":"unsupported audio format"}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/audio/transcriptions", statusCode: 415)
                ),
                .success(
                    Data(#"{"text":"fallback hello"}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "fallback hello")
        let requests = store.sessions[0].requestedRequests
        XCTAssertTrue(requests.allSatisfy { $0.url?.query == nil })
        XCTAssertEqual(requests.count, 2)
        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nlarge-v3"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
    }

    func testTranscribeRetriesWithWavWhenCompatibleServerReportsFfprobeFailure() async throws {
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
                    Data(#"{"error":"ffprobe failed: moov atom not found"}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/audio/transcriptions", statusCode: 500)
                ),
                .success(
                    Data(#"{"text":"fallback hello"}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "fallback hello")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))
        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nlarge-v3"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
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
        plugin.selectLLMModel("inception-chat", for: inception.id)
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
        XCTAssertTrue(requests.allSatisfy { $0.url?.query == nil })
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
        XCTAssertEqual(inceptionJSON["model"] as? String, "inception-chat")
        XCTAssertEqual(inceptionJSON["max_tokens"] as? Int, 4096)
        XCTAssertNil(inceptionJSON["max_completion_tokens"])
        XCTAssertEqual(inceptionJSON["temperature"] as? Double, 0.9)
        let inceptionThinking = try XCTUnwrap(inceptionJSON["thinking"] as? [String: String])
        XCTAssertEqual(inceptionThinking["type"], "enabled")
    }

    func testProcessRetriesWithMaxCompletionTokensWhenProviderRequestsIt() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://example.test",
                "selectedLLMModel": "future-chat",
            ],
            secrets: ["api-key": "secret-token"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        plugin.setLLMTemperatureMode(.custom)
        plugin.setLLMTemperatureValue(0.4)
        plugin.setThinkingEnabled(true)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        #"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}"#.utf8
                    ),
                    Self.httpResponse(url: "https://example.test/v1/chat/completions", statusCode: 400)
                ),
                .success(
                    Data(#"{"choices":[{"message":{"content":"processed"}}]}"#.utf8),
                    Self.httpResponse(url: "https://example.test/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(
            systemPrompt: "Fix",
            userText: "hello",
            model: nil,
            temperatureDirective: .inheritProviderSetting
        )

        XCTAssertEqual(result, "processed")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)

        let firstBody = try XCTUnwrap(requests[0].httpBody)
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        XCTAssertEqual(firstJSON["model"] as? String, "future-chat")
        XCTAssertEqual(firstJSON["max_tokens"] as? Int, 4096)
        XCTAssertNil(firstJSON["max_completion_tokens"])

        let retryBody = try XCTUnwrap(requests[1].httpBody)
        let retryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: retryBody) as? [String: Any])
        XCTAssertEqual(retryJSON["model"] as? String, "future-chat")
        XCTAssertEqual(retryJSON["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(retryJSON["max_tokens"])
        XCTAssertEqual(retryJSON["temperature"] as? Double, 0.4)
        let retryThinking = try XCTUnwrap(retryJSON["thinking"] as? [String: String])
        XCTAssertEqual(retryThinking["type"], "enabled")
    }

    func testFallbackOutputTokenParameterRequiresBothParameterNames() {
        XCTAssertEqual(
            OpenAICompatiblePlugin.fallbackOutputTokenParameter(
                after: .maxTokens,
                errorMessage: "Unsupported parameter: 'max_tokens'. Use 'max_completion_tokens' instead."
            ),
            .maxCompletionTokens
        )
        XCTAssertEqual(
            OpenAICompatiblePlugin.fallbackOutputTokenParameter(
                after: .maxCompletionTokens,
                errorMessage: "Unsupported parameter: 'max_completion_tokens'. Use 'max_tokens' instead."
            ),
            .maxTokens
        )
        XCTAssertNil(
            OpenAICompatiblePlugin.fallbackOutputTokenParameter(
                after: .maxTokens,
                errorMessage: "model not found"
            )
        )
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

    // MARK: - Realtime Transport: Migration & Defaults

    func testSavedProfilesWithoutTransportDecodeAsAuto() throws {
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
                "fetchedModels": []
              }
            ]
            """.utf8
        )
        let host = try PluginTestHostServices(defaults: ["profiles": savedProfiles])
        let plugin = OpenAICompatiblePlugin()

        plugin.activate(host: host)

        let profile = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))
        XCTAssertEqual(profile.transcriptionTransport, .auto)
        XCTAssertNoThrow(try JSONEncoder().encode(plugin.profileSnapshots))
    }

    func testLegacyConfigurationMigratesWithAutoTransport() throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://legacy.test", "selectedModel": "whisper-legacy"]
        )
        let plugin = OpenAICompatiblePlugin()

        plugin.activate(host: host)

        let profile = try XCTUnwrap(plugin.profileSnapshots.first)
        XCTAssertEqual(profile.transcriptionTransport, .auto)
    }

    // MARK: - Realtime Transport: Auto Resolution

    func testAutoTransportResolvesKnownRealtimeModelIDsToRealtime() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        for modelId in ["gpt-live-transcribe", "gpt-realtime-whisper", "GPT-Live-Transcribe"] {
            plugin.selectModel(modelId, for: plugin.providerId)
            XCTAssertEqual(
                plugin.resolvedTranscriptionTransport(for: plugin.providerId),
                .realtime,
                "Expected \(modelId) to auto-resolve to realtime"
            )
            XCTAssertTrue(plugin.supportsStreaming(for: plugin.providerId))
        }
    }

    func testAutoTransportResolvesUnknownModelIDsToBatch() throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        for modelId in ["whisper-1", "gpt-4o-transcribe", "my-custom-azure-deployment"] {
            plugin.selectModel(modelId, for: plugin.providerId)
            XCTAssertEqual(
                plugin.resolvedTranscriptionTransport(for: plugin.providerId),
                .batch,
                "Expected \(modelId) to auto-resolve to batch"
            )
            XCTAssertFalse(plugin.supportsStreaming(for: plugin.providerId))
        }
    }

    // MARK: - Realtime Transport: Explicit Override

    func testExplicitBatchTransportOverridesKnownRealtimeModelID() throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test", "selectedModel": "gpt-live-transcribe"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.setTranscriptionTransport(.batch, for: plugin.providerId)

        XCTAssertEqual(plugin.resolvedTranscriptionTransport(for: plugin.providerId), .batch)
        XCTAssertFalse(plugin.supportsStreaming(for: plugin.providerId))
    }

    func testExplicitRealtimeTransportOverridesCustomAzureDeploymentAlias() throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://foundry-example.services.ai.azure.com/openai",
                "selectedModel": "my-gpt-live-transcribe-deployment",
            ]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        plugin.setTranscriptionTransport(.realtime, for: plugin.providerId)

        XCTAssertEqual(plugin.resolvedTranscriptionTransport(for: plugin.providerId), .realtime)
        XCTAssertTrue(plugin.supportsStreaming(for: plugin.providerId))
    }

    func testAdditionalProfileTransportIsIndependentFromDefaultProfile() throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test", "selectedModel": "gpt-live-transcribe"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let alter = plugin.addProfile(named: "Alter")
        plugin.setBaseURL("https://alter.test", for: alter.id)
        plugin.selectModel("whisper-1", for: alter.id)

        // Default profile auto-resolves to realtime (gpt-live-transcribe), the
        // additional profile auto-resolves to batch (whisper-1) — independent state.
        XCTAssertTrue(plugin.supportsStreaming(for: plugin.providerId))
        XCTAssertFalse(plugin.supportsStreaming(for: alter.id))

        let engine = try XCTUnwrap(plugin.additionalTranscriptionEngines.first)
        XCTAssertFalse(engine.supportsStreaming)
    }

    // MARK: - Realtime URL Construction

    func testRealtimeURLConvertsHTTPSToWSSAndAppendsRealtimePathAndIntent() throws {
        let url = try XCTUnwrap(
            OpenAICompatiblePlugin.realtimeRequestURL(
                baseURL: "https://foundry-example.services.ai.azure.com/openai",
                apiVersion: ""
            )
        )

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "foundry-example.services.ai.azure.com")
        XCTAssertEqual(url.path, "/openai/v1/realtime")

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "intent", value: "transcription")])
    }

    func testRealtimeURLConvertsHTTPToWS() throws {
        let url = try XCTUnwrap(
            OpenAICompatiblePlugin.realtimeRequestURL(baseURL: "http://localhost:11434", apiVersion: "")
        )

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.path, "/v1/realtime")
    }

    func testRealtimeURLPreservesConfiguredBasePathAndExistingQuery() throws {
        let url = try XCTUnwrap(
            OpenAICompatiblePlugin.realtimeRequestURL(
                baseURL: "https://example.test/openai?tenant=contoso",
                apiVersion: ""
            )
        )

        XCTAssertEqual(url.path, "/openai/v1/realtime")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "tenant", value: "contoso"),
                URLQueryItem(name: "intent", value: "transcription"),
            ]
        )
    }

    func testRealtimeURLAppliesConfiguredAPIVersionWithoutDuplication() throws {
        let url = try XCTUnwrap(
            OpenAICompatiblePlugin.realtimeRequestURL(
                baseURL: "https://foundry-example.services.ai.azure.com/openai",
                apiVersion: "preview"
            )
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "api-version", value: "preview"),
                URLQueryItem(name: "intent", value: "transcription"),
            ]
        )
    }

    func testRealtimeURLReturnsNilForInvalidBaseURL() {
        XCTAssertNil(OpenAICompatiblePlugin.realtimeRequestURL(baseURL: "http://[::1", apiVersion: ""))
    }

    // MARK: - Realtime Auth

    func testRealtimeRequestAppliesBearerAuthenticationForNonAzureEndpoints() throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test"],
            secrets: ["api-key": "sk-test"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let profile = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))

        let request = try XCTUnwrap(plugin.realtimeRequest(for: profile, profileId: plugin.providerId))

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
    }

    func testRealtimeRequestAppliesAzureAPIKeyHeaderAlongsideBearer() throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://foundry-example.services.ai.azure.com/openai",
                "apiVersion": "preview",
            ],
            secrets: ["api-key": "azure-key"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let profile = try XCTUnwrap(plugin.profileSnapshot(for: plugin.providerId))

        let request = try XCTUnwrap(plugin.realtimeRequest(for: profile, profileId: plugin.providerId))

        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer azure-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "azure-key")
    }

    // MARK: - Live Session: Batch/Translate Guardrails

    func testCreateLiveTranscriptionSessionThrowsForBatchResolvedModelSoHostCanFallBack() async throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test", "selectedModel": "whisper-1"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.createLiveTranscriptionSession(
                language: nil,
                translate: false,
                prompt: nil,
                onProgress: { _ in true }
            )
            XCTFail("Expected batch-routed models to throw so the host preview-loop fallback engages")
        } catch let error as PluginTranscriptionError {
            guard case .apiError = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCreateLiveTranscriptionSessionThrowsWithoutSelectedModel() async throws {
        let host = try PluginTestHostServices(defaults: ["baseURL": "https://example.test"])
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.createLiveTranscriptionSession(
                language: nil,
                translate: false,
                prompt: nil,
                onProgress: { _ in true }
            )
            XCTFail("Expected noModelSelected")
        } catch let error as PluginTranscriptionError {
            guard case .noModelSelected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCreateLiveTranscriptionSessionRejectsTranslationForRealtimeModels() async throws {
        let host = try PluginTestHostServices(
            defaults: ["baseURL": "https://example.test", "selectedModel": "gpt-live-transcribe"]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.createLiveTranscriptionSession(
                language: nil,
                translate: true,
                prompt: nil,
                onProgress: { _ in true }
            )
            XCTFail("Expected realtime translation to be rejected")
        } catch let error as PluginTranscriptionError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("translat"))
        }
    }

    func testRegularTranscriptionStreamsRealtimeAudioWithoutLivePreview() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "baseURL": "https://example.test",
                "selectedModel": "gpt-live-transcribe",
            ]
        )
        let plugin = OpenAICompatiblePlugin()
        plugin.activate(host: host)
        let session = RealtimeSessionSpy(
            result: PluginTranscriptionResult(text: "Direct realtime result", detectedLanguage: "en")
        )
        let connector = RealtimeSessionConnectorSpy(session: session)
        plugin.realtimeSessionConnector = connector
        let samples = Array(repeating: Float(0.25), count: 16_001)

        let result = try await plugin.transcribe(
            audio: AudioData(
                samples: samples,
                wavData: PluginWavEncoder.encode(samples),
                duration: Double(samples.count) / 16_000
            ),
            language: "en",
            translate: false,
            prompt: "Direct transcription"
        )

        let recordedConnection = await connector.snapshot()
        let connection = try XCTUnwrap(recordedConnection)
        let sessionSnapshot = await session.snapshot()
        XCTAssertEqual(connection.request.url?.path, "/v1/realtime")
        XCTAssertEqual(connection.configuration.modelID, "gpt-live-transcribe")
        XCTAssertEqual(connection.configuration.languageSelection.requestedLanguage, "en")
        XCTAssertEqual(connection.configuration.prompt, "Direct transcription")
        XCTAssertEqual(sessionSnapshot.chunkSizes, [16_000, 1])
        XCTAssertEqual(sessionSnapshot.samples, samples)
        XCTAssertEqual(sessionSnapshot.finishCount, 1)
        XCTAssertEqual(sessionSnapshot.cancelCount, 0)
        XCTAssertEqual(result.text, "Direct realtime result")
    }

    func testRealtimeHelperIsCompiledIntoPluginModule() {
        XCTAssertTrue(
            String(reflecting: PluginOpenAIRealtimeTranscriptionSession.self)
                .hasPrefix("OpenAICompatiblePlugin.")
        )
    }

    func testTransportSettingsHaveGermanAndJapaneseLocalizations() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Localizable.xcstrings")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let helpText = "Auto uses realtime streaming only for known realtime model IDs (gpt-live-transcribe, gpt-realtime-whisper) and batch upload otherwise. Choose Realtime to force streaming for any OpenAI-compatible server that supports the /v1/realtime WebSocket API, including custom deployment aliases (e.g. an Azure OpenAI or Microsoft Foundry gpt-live-transcribe deployment) — some providers, including Azure, require a preview API version for realtime transcription. Choose Batch to always use /v1/audio/transcriptions."

        for key in ["Transcription Transport", "Auto", "Batch", "Realtime", helpText] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertNotNil(localizations["de"], "Missing German localization for \(key)")
            XCTAssertNotNil(localizations["ja"], "Missing Japanese localization for \(key)")
        }
    }

    // MARK: - Realtime Session Configuration Payload

    func testContextAwareRealtimeSessionPayloadIncludesLanguagesKeywordsAndDelay() throws {
        let configuration = PluginOpenAIRealtimeTranscriptionConfiguration(
            modelID: "my-gpt-live-transcribe-deployment",
            languageSelection: PluginLanguageSelection(languageHints: ["de", "en"]),
            prompt: "Interview about TypeWhisper.",
            keywords: PluginOpenAIRealtimeTranscriptionConfiguration.normalizedRealtimeKeywords(
                from: [PluginDictionaryTermHint(text: "TypeWhisper"), PluginDictionaryTermHint(text: "<bad>")]
            ),
            delay: .low,
            usesContextAwareHints: true
        )

        let payload = PluginOpenAIRealtimeTranscriptionSession.sessionUpdatePayload(configuration: configuration)

        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])

        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, PluginOpenAIRealtimeTranscriptionSession.targetSampleRate)
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual(transcription["model"] as? String, "my-gpt-live-transcribe-deployment")
        XCTAssertEqual(transcription["languages"] as? [String], ["de", "en"])
        XCTAssertEqual(transcription["prompt"] as? String, "Interview about TypeWhisper.")
        XCTAssertEqual(transcription["keywords"] as? [String], ["TypeWhisper"])
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertNil(transcription["language"])
    }

    func testLegacyRealtimeSessionPayloadUsesSingularLanguageAndOmitsHints() throws {
        let configuration = PluginOpenAIRealtimeTranscriptionConfiguration(
            modelID: "gpt-realtime-whisper",
            languageSelection: PluginLanguageSelection(requestedLanguage: "de"),
            prompt: "Ignored for legacy protocol",
            keywords: [],
            delay: nil,
            usesContextAwareHints: false
        )

        let payload = PluginOpenAIRealtimeTranscriptionSession.sessionUpdatePayload(configuration: configuration)

        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])

        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "de")
        XCTAssertNil(transcription["languages"])
        XCTAssertNil(transcription["prompt"])
        XCTAssertNil(transcription["keywords"])
        XCTAssertNil(transcription["delay"])
    }

    func testRealtimeTranscriptCollectorAndSessionAssembleTranscript() async throws {
        let collector = PluginOpenAIRealtimeTranscriptCollector()
        _ = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Guten Tag"}"#.utf8
        ))
        let session = PluginOpenAIRealtimeTranscriptionSession(
            webSocketTask: nil,
            receiveTask: nil,
            collector: collector,
            language: "de",
            onProgress: { _ in true }
        )

        let result = try await session.finish()
        await session.cancel()

        XCTAssertEqual(result.text, "Guten Tag")
        XCTAssertEqual(result.detectedLanguage, "de")
    }

    func testRealtimeTranscriptCollectorUsesStableFallbackForMissingItemID() async throws {
        let collector = PluginOpenAIRealtimeTranscriptCollector()

        _ = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"Guten "}"#.utf8
        ))
        _ = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.delta","delta":"Tag"}"#.utf8
        ))
        _ = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Guten Tag"}"#.utf8
        ))

        let currentText = await collector.currentText()
        XCTAssertEqual(currentText, "Guten Tag")
    }

    func testRealtimeSocketOpenWaiterResumesWhenCancelled() async throws {
        let waiter = PluginOpenAIRealtimeWebSocketOpenWaiter()
        let waitTask = Task {
            try await waiter.waitForOpen()
        }

        await Task.yield()
        waitTask.cancel()

        do {
            try await waitTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    private actor RealtimeSessionConnectorSpy: OpenAICompatibleRealtimeSessionConnecting {
        struct Connection: Sendable {
            let request: URLRequest
            let configuration: PluginOpenAIRealtimeTranscriptionConfiguration
        }

        private let session: any LiveTranscriptionSession
        private var connection: Connection?

        init(session: any LiveTranscriptionSession) {
            self.session = session
        }

        func connect(
            request: URLRequest,
            configuration: PluginOpenAIRealtimeTranscriptionConfiguration,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> any LiveTranscriptionSession {
            connection = Connection(request: request, configuration: configuration)
            return session
        }

        func snapshot() -> Connection? {
            connection
        }
    }

    private actor RealtimeSessionSpy: LiveTranscriptionSession {
        struct Snapshot: Sendable {
            let samples: [Float]
            let chunkSizes: [Int]
            let finishCount: Int
            let cancelCount: Int
        }

        private let result: PluginTranscriptionResult
        private var chunks: [[Float]] = []
        private var finishCount = 0
        private var cancelCount = 0

        init(result: PluginTranscriptionResult) {
            self.result = result
        }

        func appendAudio(samples: [Float]) async throws {
            chunks.append(samples)
        }

        func finish() async throws -> PluginTranscriptionResult {
            finishCount += 1
            return result
        }

        func cancel() async {
            cancelCount += 1
        }

        func snapshot() -> Snapshot {
            Snapshot(
                samples: chunks.flatMap { $0 },
                chunkSizes: chunks.map(\.count),
                finishCount: finishCount,
                cancelCount: cancelCount
            )
        }
    }
}
