import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import VercelAIGatewayPlugin

final class VercelAIGatewayPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testCapabilitiesAndFallbackModels() throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.providerId, "vercel-ai-gateway")
        XCTAssertEqual(plugin.providerDisplayName, "Vercel AI Gateway")
        XCTAssertEqual(plugin.providerName, "Vercel AI Gateway")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertFalse(plugin.isAvailable)
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
        XCTAssertEqual(plugin.selectedModelId, "openai/whisper-1")
        XCTAssertEqual(plugin.selectedLLMModelId, "openai/gpt-4o-mini")
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.id),
            [
                "openai/whisper-1",
                "openai/gpt-4o-mini-transcribe",
                "openai/gpt-4o-transcribe",
                "google/gemini-3.5-transcribe",
            ]
        )
        XCTAssertEqual(plugin.supportedModels.first?.id, "openai/gpt-4o-mini")
    }

    func testSelectedModelsPersistAcrossActivation() throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        plugin.selectModel("openai/gpt-4o-transcribe")
        plugin.selectLLMModel("anthropic/claude-sonnet-5")
        plugin.deactivate()

        let reloaded = VercelAIGatewayPlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai/gpt-4o-transcribe")
        XCTAssertEqual(reloaded.selectedModelId, "openai/gpt-4o-transcribe")
        XCTAssertEqual(reloaded.selectedLLMModelId, "anthropic/claude-sonnet-5")
    }

    func testInvalidPersistedModelSelectionsFallbackAndPersistValidDefaults() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": " retired-stt-model ",
            "selectedLLMModel": "retired-llm-model",
        ])
        let plugin = VercelAIGatewayPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "openai/whisper-1")
        XCTAssertEqual(plugin.selectedLLMModelId, "openai/gpt-4o-mini")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai/whisper-1")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "openai/gpt-4o-mini")
    }

    // MARK: - Chat

    func testProcessSendsOpenAICompatibleChatRequestAndParsesText() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "vck_test"])
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)
        plugin.setLLMTemperatureMode(.custom)
        plugin.setLLMTemperatureValue(0.7)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"id":"gen_01","choices":[{"message":{"content":" hello from gateway \n"}}]}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(
            systemPrompt: "System prompt",
            userText: "User text",
            model: nil
        )

        XCTAssertEqual(result, "hello from gateway")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer vck_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "openai/gpt-4o-mini")
        XCTAssertEqual(body["temperature"] as? Double, 0.7)

        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [
            ["role": "system", "content": "System prompt"],
            ["role": "user", "content": "User text"],
        ])
    }

    func testProcessFailsWithoutAPIKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.process(systemPrompt: "s", userText: "u", model: nil)
            XCTFail("Expected notConfigured")
        } catch let error as PluginChatError {
            guard case .notConfigured = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testProcessMapsInvalidAPIKeyResponse() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "vck_bad"])
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"Invalid API key","type":"authentication_error"}}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/chat/completions", statusCode: 401)
                ),
            ])
        }

        do {
            _ = try await plugin.process(systemPrompt: "s", userText: "u", model: "openai/gpt-4o-mini")
            XCTFail("Expected invalidApiKey")
        } catch let error as PluginChatError {
            guard case .invalidApiKey = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Model catalogue

    func testModelCatalogSplitsLanguageAndTranscriptionModelsAndCaches() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "vck_test"])
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "object": "list",
                          "data": [
                            {
                              "id": "openai/whisper-1",
                              "name": "Whisper",
                              "type": "transcription",
                              "pricing": { "input": "0.0000000001", "transcription_duration_cost_per_second": "0.0001" }
                            },
                            {
                              "id": "openai/gpt-realtime-whisper",
                              "name": "gpt-realtime-whisper",
                              "type": "transcription",
                              "tags": ["websocket-realtime", "websocket-transcription"]
                            },
                            {
                              "id": "google/gemini-3.5-transcribe-live",
                              "name": "Gemini 3.5 Transcribe Live",
                              "type": "transcription",
                              "tags": ["websocket-transcription"]
                            },
                            {
                              "id": "spacexai/grok-stt",
                              "name": "Grok STT",
                              "type": "transcription",
                              "tags": ["websocket-transcription"]
                            },
                            {
                              "id": "anthropic/claude-sonnet-5",
                              "name": "Claude Sonnet 5",
                              "type": "language",
                              "pricing": { "input": "0.000002", "output": "0.00001" }
                            },
                            {
                              "id": "openai/gpt-4o-mini",
                              "name": "GPT-4o mini",
                              "type": "language",
                              "pricing": { "input": "0.00000015", "output": "0.0000006" }
                            },
                            {
                              "id": "openai/text-embedding-3-small",
                              "name": "Embedding 3 Small",
                              "type": "embedding",
                              "pricing": { "input": "0.00000002" }
                            },
                            {
                              "id": "openai/tts-1",
                              "name": "TTS-1",
                              "type": "speech"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/models", statusCode: 200)
                ),
            ])
        }

        let catalog = await plugin.fetchModelCatalog()
        plugin.setFetchedLLMModels(catalog.llmModels)
        plugin.setFetchedTranscriptionModels(catalog.transcriptionModels)

        XCTAssertEqual(catalog.llmModels.map(\.id), ["anthropic/claude-sonnet-5", "openai/gpt-4o-mini"])
        XCTAssertEqual(catalog.transcriptionModels.map(\.id), ["spacexai/grok-stt", "openai/whisper-1"])
        XCTAssertEqual(catalog.llmModels[0].formattedPricing, "$2.00/$10.00 per 1M")
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["anthropic/claude-sonnet-5", "openai/gpt-4o-mini"])
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["spacexai/grok-stt", "openai/whisper-1"])

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer vck_test")
        XCTAssertNotNil(host.userDefault(forKey: "fetchedModels") as? Data)
        XCTAssertNotNil(host.userDefault(forKey: "fetchedTranscriptionModels") as? Data)

        let reloaded = VercelAIGatewayPlugin()
        reloaded.activate(host: host)
        XCTAssertEqual(reloaded.supportedModels.map(\.id), ["anthropic/claude-sonnet-5", "openai/gpt-4o-mini"])
        XCTAssertEqual(reloaded.transcriptionModels.map(\.id), ["spacexai/grok-stt", "openai/whisper-1"])
    }

    func testModelCatalogReturnsEmptyOnHTTPError() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"down"}}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/models", statusCode: 503)
                ),
            ])
        }

        let catalog = await plugin.fetchModelCatalog()
        XCTAssertTrue(catalog.llmModels.isEmpty)
        XCTAssertTrue(catalog.transcriptionModels.isEmpty)
        XCTAssertEqual(plugin.supportedModels.first?.id, "openai/gpt-4o-mini")
    }

    func testPricingLabelsDistinguishFreeFromUnknown() {
        let free = VercelAIGatewayFetchedModel(id: "x/free", name: "Free", inputPrice: "0", outputPrice: "0")
        XCTAssertEqual(free.formattedPricing, "Free")

        let paid = VercelAIGatewayFetchedModel(id: "x/paid", name: "Paid", inputPrice: "0.00000015", outputPrice: "0.0000006")
        XCTAssertEqual(paid.formattedPricing, "$0.15/$0.60 per 1M")

        let unknown = VercelAIGatewayFetchedModel(id: "x/unknown", name: "Unknown")
        XCTAssertEqual(unknown.formattedPricing, "Pricing unavailable")

        let partial = VercelAIGatewayFetchedModel(id: "x/partial", name: "Partial", inputPrice: "0.000001", outputPrice: nil)
        XCTAssertEqual(partial.formattedPricing, "Pricing unavailable")
    }

    func testFallbackModelsNeverClaimToBeFree() throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        // No catalogue fetched and nothing cached: every picker entry comes
        // from the static fallback list and must not read as free.
        for model in VercelAIGatewayPlugin.fallbackLLMModels + VercelAIGatewayPlugin.fallbackTranscriptionModels {
            XCTAssertNil(model.inputPrice, model.id)
            XCTAssertNil(model.outputPrice, model.id)
            XCTAssertEqual(model.formattedPricing, "Pricing unavailable", model.id)
        }
    }

    func testCatalogModelWithoutPricingIsUnknownNotFree() throws {
        let catalog = try VercelAIGatewayPlugin.parseModelCatalog(Data(
            #"{"data":[{"id":"x/no-price","name":"No Price","type":"language"},{"id":"x/zero","name":"Zero","type":"language","pricing":{"input":"0","output":"0"}}]}"#.utf8
        ))
        XCTAssertEqual(catalog.llmModels.map(\.formattedPricing), ["Pricing unavailable", "Free"])
    }

    // MARK: - Credits and key validation

    func testValidateAPIKeyUsesCreditsEndpoint() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"balance":"95.50","total_used":"4.50"}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/credits", statusCode: 200)
                ),
            ])
        }

        let isValid = await plugin.validateApiKey("vck_test")
        XCTAssertTrue(isValid)

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v1/credits")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer vck_test")
    }

    func testValidateAPIKeyRejectsUnauthorized() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"Unauthorized"}}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/credits", statusCode: 401)
                ),
            ])
        }

        let isValid = await plugin.validateApiKey("vck_bad")
        XCTAssertFalse(isValid)
        let isEmptyValid = await plugin.validateApiKey("")
        XCTAssertFalse(isEmptyValid)
    }

    func testParseCreditBalance() {
        XCTAssertEqual(
            VercelAIGatewayPlugin.parseCreditBalance(Data(#"{"balance":"95.50","total_used":"4.50"}"#.utf8)),
            95.5
        )
        XCTAssertEqual(
            VercelAIGatewayPlugin.parseCreditBalance(Data(#"{"balance":12.25}"#.utf8)),
            12.25
        )
        XCTAssertNil(VercelAIGatewayPlugin.parseCreditBalance(Data(#"{"total_used":"4.50"}"#.utf8)))
    }

    // MARK: - Transcription

    func testTranscribeFailsWithoutAPIKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
            XCTFail("Expected notConfigured")
        } catch let error as PluginTranscriptionError {
            guard case .notConfigured = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTranscribeRejectsTranslateRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "vck_test"])
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: true, prompt: nil)
            XCTFail("Expected apiError")
        } catch let error as PluginTranscriptionError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Vercel AI Gateway speech-to-text does not support translation.")
        }
    }

    func testTranscriptionRequestUsesGatewayProtocolHeadersAndBase64JSON() throws {
        let request = try VercelAIGatewayPlugin.makeTranscriptionRequest(
            uploadFile: Self.m4aUpload(),
            apiKey: "vck_test",
            modelId: "openai/whisper-1",
            language: " de ",
            timeout: 120
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ai-gateway.vercel.sh/v4/ai/transcription-model")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer vck_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-gateway-protocol-version"), "0.0.1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-transcription-model-specification-version"), "4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-model-id"), "openai/whisper-1")
        XCTAssertEqual(request.timeoutInterval, 120)

        let body = try Self.jsonBody(from: request)
        XCTAssertNil(body["model"])
        XCTAssertEqual(body["mediaType"] as? String, "audio/mp4")
        XCTAssertEqual(body["audio"] as? String, Data("m4a".utf8).base64EncodedString())
        let providerOptions = try XCTUnwrap(body["providerOptions"] as? [String: Any])
        let openAIOptions = try XCTUnwrap(providerOptions["openai"] as? [String: Any])
        XCTAssertEqual(openAIOptions["language"] as? String, "de")
    }

    func testTranscriptionRequestOmitsProviderOptionsWithoutLanguageOrForOtherCreators() throws {
        let noLanguage = try VercelAIGatewayPlugin.makeTranscriptionRequest(
            uploadFile: Self.m4aUpload(),
            apiKey: "vck_test",
            modelId: "openai/whisper-1",
            language: " ",
            timeout: 120
        )
        XCTAssertNil(try Self.jsonBody(from: noLanguage)["providerOptions"])

        let otherCreator = try VercelAIGatewayPlugin.makeTranscriptionRequest(
            uploadFile: Self.m4aUpload(),
            apiKey: "vck_test",
            modelId: "google/gemini-3.5-transcribe",
            language: "de",
            timeout: 120
        )
        XCTAssertNil(try Self.jsonBody(from: otherCreator)["providerOptions"])
        XCTAssertEqual(otherCreator.value(forHTTPHeaderField: "ai-model-id"), "google/gemini-3.5-transcribe")
    }

    func testTranscribeParsesAISDKResultShape() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "openai/whisper-1"],
            secrets: ["api-key": "vck_test"]
        )
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        #"{"text":"hello from gateway","segments":[{"text":"hello from","startSecond":0.0,"endSecond":1.25},{"text":"gateway","startSecond":1.25,"endSecond":2.5}],"language":"en","durationInSeconds":2.5,"warnings":[]}"#.utf8
                    ),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v4/ai/transcription-model", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "en",
            translate: false,
            prompt: "ignored dictionary terms"
        )

        XCTAssertEqual(result.text, "hello from gateway")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "hello from")
        XCTAssertEqual(result.segments[0].start, 0.0)
        XCTAssertEqual(result.segments[0].end, 1.25)
        XCTAssertEqual(result.segments[1].text, "gateway")
        XCTAssertEqual(result.segments[1].start, 1.25)
        XCTAssertEqual(result.segments[1].end, 2.5)

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v4/ai/transcription-model")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ai-model-id"), "openai/whisper-1")
        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["mediaType"] as? String, "audio/mp4")
    }

    func testTranscribeRetriesWithWavWhenM4AIsRejected() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "openai/whisper-1"],
            secrets: ["api-key": "vck_test"]
        )
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"unsupported audio format"}}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v4/ai/transcription-model", statusCode: 415)
                ),
                .success(
                    Data(#"{"text":"fallback transcript","segments":[],"language":"de","durationInSeconds":1,"warnings":[]}"#.utf8),
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v4/ai/transcription-model", statusCode: 200)
                ),
            ])
        }

        let audio = Self.audio()
        let result = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "fallback transcript")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try Self.jsonBody(from: requests[0])["mediaType"] as? String, "audio/mp4")
        let retryBody = try Self.jsonBody(from: requests[1])
        XCTAssertEqual(retryBody["mediaType"] as? String, "audio/wav")
        let encodedAudio = try XCTUnwrap(retryBody["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: encodedAudio), PluginAudioUploadEncoder.wavUpload(from: audio).data)
    }

    func testExplicitRequestErrorsDoNotTriggerWavRetry() async throws {
        for (status, message) in [(400, "Model not found"), (401, "Invalid API key"), (402, "Insufficient credits"), (429, "Rate limited")] {
            PluginHTTPClientTestHarness.reset()
            let host = try PluginTestHostServices(secrets: ["api-key": "vck_test"])
            let plugin = VercelAIGatewayPlugin()
            plugin.activate(host: host)
            let store = PluginHTTPClientSessionStore()
            let responseData = try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
            PluginHTTPClientTestHarness.configure { _ in
                store.makeSession(outcomes: [.success(
                    responseData,
                    Self.httpResponse(url: "https://ai-gateway.vercel.sh/v4/ai/transcription-model", statusCode: status)
                )])
            }
            do {
                _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
                XCTFail("Expected HTTP \(status)")
            } catch {
                XCTAssertTrue(error is PluginTranscriptionError, "HTTP \(status)")
            }
            XCTAssertEqual(store.sessions.flatMap(\.requestedRequests).count, 1, "HTTP \(status)")
        }
    }

    func testTranscriptionHTTPErrorMapping() {
        let url = "https://ai-gateway.vercel.sh/v4/ai/transcription-model"

        XCTAssertThrowsError(try VercelAIGatewayPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: url, statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try VercelAIGatewayPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: url, statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try VercelAIGatewayPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"No credit balance","type":"payment_required"}}"#.utf8),
            response: Self.httpResponse(url: url, statusCode: 402)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "HTTP 402: No credit balance")
        }

        XCTAssertThrowsError(try VercelAIGatewayPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":"Model not available for this team"}"#.utf8),
            response: Self.httpResponse(url: url, statusCode: 403)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "HTTP 403: Model not available for this team")
        }
    }

    func testTranscriptionRejectsHTMLSuccessBody() {
        let data = Data("<html><head><title>Proxy failure</title></head><body>secret</body></html>".utf8)

        XCTAssertThrowsError(try VercelAIGatewayPlugin.validateTranscriptionResponse(
            data: data,
            response: Self.httpResponse(url: "https://ai-gateway.vercel.sh/v4/ai/transcription-model", statusCode: 200)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("upstream returned an HTML error page"))
            XCTAssertTrue(message.contains("Proxy failure"))
            XCTAssertFalse(message.contains("secret"))
        }
    }

    func testTranscriptionParseFallsBackToTextOnlyBody() throws {
        let result = try VercelAIGatewayPlugin.parseTranscriptionResponse(Data(#"{"text":"only text"}"#.utf8))
        XCTAssertEqual(result.text, "only text")
        XCTAssertTrue(result.segments.isEmpty)

        XCTAssertThrowsError(try VercelAIGatewayPlugin.parseTranscriptionResponse(Data(#"{"warnings":[]}"#.utf8)))
    }

    func testConcurrentSettingsMutationsDoNotCorruptState() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "vck_test"])
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        // Hammer writers and readers from many tasks at once. With unguarded
        // state this trips the Swift runtime's exclusivity checks or tears the
        // model arrays; with the lock every read sees a whole value.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    let models = [
                        VercelAIGatewayFetchedModel(id: "x/model-\(index)", name: "Model \(index)"),
                    ]
                    plugin.setFetchedLLMModels(models)
                    plugin.selectLLMModel("x/model-\(index)")
                    plugin.setLLMTemperatureValue(Double(index % 20) / 10)
                    plugin.setApiKey(index.isMultiple(of: 2) ? "vck_even" : "vck_odd")
                }
                group.addTask {
                    _ = plugin.supportedModels
                    _ = plugin.selectedLLMModelId
                    _ = plugin.llmTemperatureValue
                    _ = plugin.isAvailable
                    _ = plugin.transcriptionModels
                }
            }
        }

        XCTAssertEqual(plugin.supportedModels.count, 1)
        XCTAssertTrue(plugin.isAvailable)
        XCTAssertTrue(plugin.selectedLLMModelId?.hasPrefix("x/model-") ?? false)
    }

    // MARK: - API key save ordering

    /// Lets a test decide when an injected validation completes, and observe
    /// when a save has reached validation (i.e. has claimed its generation).
    private final class ValidationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]
        private var pending: [String: Bool] = [:]
        private var started: Set<String> = []
        private var startWaiters: [String: CheckedContinuation<Void, Never>] = [:]

        func wait(_ key: String) async -> Bool {
            let startWaiter = lock.withLock {
                started.insert(key)
                return startWaiters.removeValue(forKey: key)
            }
            startWaiter?.resume()
            return await withCheckedContinuation { continuation in
                lock.withLock {
                    if let verdict = pending.removeValue(forKey: key) {
                        continuation.resume(returning: verdict)
                    } else {
                        continuations[key] = continuation
                    }
                }
            }
        }

        func waitUntilStarted(_ key: String) async {
            await withCheckedContinuation { continuation in
                let alreadyStarted = lock.withLock {
                    if started.contains(key) { return true }
                    startWaiters[key] = continuation
                    return false
                }
                if alreadyStarted { continuation.resume() }
            }
        }

        func release(_ key: String, isValid: Bool) {
            let continuation = lock.withLock {
                let waiting = continuations.removeValue(forKey: key)
                if waiting == nil { pending[key] = isValid }
                return waiting
            }
            continuation?.resume(returning: isValid)
        }
    }

    /// `saveApiKey` fetches the catalogue and the balance concurrently, and the
    /// mock session hands out outcomes in call order, so a single body that
    /// satisfies both parsers keeps these tests independent of scheduling.
    private static func catalogAndCreditsOutcomes(balance: String) -> [PluginHTTPClientTestOutcome] {
        let body = """
        {"data":[{"id":"x/current","name":"Current","type":"language","pricing":{"input":"0.000001","output":"0.000002"}}],"balance":"\(balance)","total_used":"0"}
        """
        return [
            .success(
                Data(body.utf8),
                Self.httpResponse(url: "https://ai-gateway.vercel.sh/v1/models", statusCode: 200)
            ),
        ]
    }

    func testSaveApiKeyDiscardsResultWhenSupersededByNewerSave() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)
        let gate = ValidationGate()

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: Self.catalogAndCreditsOutcomes(balance: "42.00"))
        }

        let saveA = Task { await plugin.saveApiKey("vck_A", validate: { await gate.wait($0) }) }
        await gate.waitUntilStarted("vck_A")
        let saveB = Task { await plugin.saveApiKey("vck_B", validate: { await gate.wait($0) }) }
        await gate.waitUntilStarted("vck_B")

        // B finishes first and wins; A completes afterwards and must be dropped
        // even though A's key was reported valid.
        gate.release("vck_B", isValid: true)
        let resultB = await saveB.value
        gate.release("vck_A", isValid: true)
        let resultA = await saveA.value

        XCTAssertNil(resultA)
        let unwrappedB = try XCTUnwrap(resultB)
        XCTAssertTrue(unwrappedB.isValid)
        XCTAssertEqual(unwrappedB.balance, 42)
        XCTAssertEqual(unwrappedB.catalog.llmModels.map(\.id), ["x/current"])
        XCTAssertTrue(plugin.isAvailable)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "vck_B")
    }

    func testStaleInvalidVerdictDoesNotOverrideNewerValidKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)
        let gate = ValidationGate()

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: Self.catalogAndCreditsOutcomes(balance: "7.50"))
        }

        let saveOld = Task { await plugin.saveApiKey("vck_old", validate: { await gate.wait($0) }) }
        await gate.waitUntilStarted("vck_old")
        let saveNew = Task { await plugin.saveApiKey("vck_new", validate: { await gate.wait($0) }) }
        await gate.waitUntilStarted("vck_new")

        gate.release("vck_new", isValid: true)
        let resultNew = await saveNew.value
        gate.release("vck_old", isValid: false)
        let resultOld = await saveOld.value

        XCTAssertNil(resultOld, "A rejected verdict for a replaced key must not be published")
        XCTAssertEqual(try XCTUnwrap(resultNew).isValid, true)
        XCTAssertTrue(plugin.isAvailable)
    }

    func testRemovingKeyDuringValidationDiscardsPendingResult() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)
        let gate = ValidationGate()

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: Self.catalogAndCreditsOutcomes(balance: "99.00"))
        }

        let save = Task { await plugin.saveApiKey("vck_A", validate: { await gate.wait($0) }) }
        await gate.waitUntilStarted("vck_A")
        plugin.removeApiKey()
        gate.release("vck_A", isValid: true)
        let result = await save.value

        XCTAssertNil(result)
        XCTAssertFalse(plugin.isAvailable)
        // The test host keeps an empty string for a deleted secret.
        XCTAssertEqual(host.loadSecret(key: "api-key") ?? "", "")
        XCTAssertEqual(plugin.supportedModels.first?.id, "openai/gpt-4o-mini", "Catalogue from the cancelled save must not be published")
        XCTAssertNil(host.userDefault(forKey: "fetchedModels"))
    }

    func testSaveApiKeyPublishesCatalogAndBalanceWhenCurrent() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: Self.catalogAndCreditsOutcomes(balance: "12.00"))
        }

        let saved = await plugin.saveApiKey("vck_A", validate: { _ in true })
        let result = try XCTUnwrap(saved)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.balance, 12)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["x/current"])
        XCTAssertNotNil(host.userDefault(forKey: "fetchedModels"))
        XCTAssertEqual(host.loadSecret(key: "api-key"), "vck_A")
    }

    func testSaveApiKeyKeepsRejectedKeyStoredButReportsInvalid() async throws {
        let host = try PluginTestHostServices()
        let plugin = VercelAIGatewayPlugin()
        plugin.activate(host: host)

        let saved = await plugin.saveApiKey("vck_bad", validate: { _ in false })
        let result = try XCTUnwrap(saved)

        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.balance)
        XCTAssertTrue(result.catalog.llmModels.isEmpty)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "vck_bad")
    }

    // MARK: - Helpers

    private static func audio() -> AudioData {
        let samples = [Float](repeating: 0.1, count: 16_000)
        return AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1)
    }

    private static func m4aUpload() -> PluginAudioUploadFile {
        PluginAudioUploadFile(
            data: Data("m4a".utf8),
            filename: "audio.m4a",
            contentType: "audio/mp4",
            format: "m4a"
        )
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
