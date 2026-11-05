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
        XCTAssertEqual(models.map(\.id), [
            "voxtral-mini-transcribe-3-0",
            "voxtral-small-transcribe-3-0",
        ])
        XCTAssertEqual(models.map(\.displayName), [
            "Voxtral Mini Transcribe 3",
            "Voxtral Small Transcribe 3",
        ])
    }

    func testMistralAILLMModelsIncludeMistralSmall() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        let models = plugin.supportedModels
        XCTAssertEqual(models.map(\.id), [
            "mistral-large-4",
            "mistral-small-2603",
            "ministral-14b-2512",
            "ministral-8b-2512",
            "ministral-3b-2512",
        ])
        XCTAssertEqual(models.map(\.displayName), [
            "Mistral Large 4",
            "Mistral Small 4",
            "Ministral 3 14B",
            "Ministral 3 8B",
            "Ministral 3 3B",
        ])
    }

    func testMistralAISelectsModels() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        
        plugin.selectLLMModel("mistral-large-4")
        plugin.selectModel("voxtral-mini-transcribe-3-0")
        
        XCTAssertEqual(plugin.selectedLLMModelId, "mistral-large-4")
        XCTAssertEqual(plugin.selectedModelId, "voxtral-mini-transcribe-3-0")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "mistral-large-4")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "voxtral-mini-transcribe-3-0")
    }

    func testPersistedVoxtral2TranscriptionModelsMigrateToTranscribe3() throws {
        let cases = [
            ("voxtral-mini-latest", "voxtral-mini-transcribe-3-0"),
            ("voxtral-mini-2602", "voxtral-mini-transcribe-3-0"),
            ("voxtral-mini-transcribe-3", "voxtral-mini-transcribe-3-0"),
            ("  voxtral-small-latest  ", "voxtral-small-transcribe-3-0"),
            ("voxtral-small-2507", "voxtral-small-transcribe-3-0"),
            ("voxtral-small-transcribe-3", "voxtral-small-transcribe-3-0"),
            ("voxtral-small-transcribe-latest", "voxtral-small-transcribe-3-0"),
        ]
        for (stored, expected) in cases {
            let host = try PluginTestHostServices(
                defaults: ["selectedModel": stored],
                secrets: ["api-key": "test-key"]
            )
            let plugin = MistralAIPlugin()
            plugin.activate(host: host)

            XCTAssertEqual(plugin.selectedModelId, expected, stored)
            XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, expected, stored)
        }
    }

    func testCurrentAndCustomTranscriptionModelIdsAreKept() throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "voxtral-small-transcribe-3-0"],
            secrets: ["api-key": "test-key"]
        )
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "voxtral-small-transcribe-3-0")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "voxtral-small-transcribe-3-0")

        plugin.selectModel("voxtral-mini-latest")
        XCTAssertEqual(plugin.selectedModelId, "voxtral-mini-transcribe-3-0")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "voxtral-mini-transcribe-3-0")

        plugin.selectModel("custom-transcription-model")
        XCTAssertEqual(plugin.selectedModelId, "custom-transcription-model")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "custom-transcription-model")
    }

    func testMistralAIProviderContractAndIdentity() throws {
        let plugin = MistralAIPlugin()
        
        // Identity checks
        XCTAssertEqual(plugin.providerId, "mistral", "Stable provider ID should be 'mistral'")
        XCTAssertEqual(plugin.providerDisplayName, "Mistral AI")
        
        // LLMModelSelectable checks
        let selectable: any LLMModelSelectable = plugin
        XCTAssertEqual(selectable.defaultModelId, "mistral-small-2603")
        XCTAssertNil(selectable.preferredModelId ?? nil)
        
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        plugin.activate(host: host)
        plugin.selectLLMModel("ministral-3b-2512")
        
        XCTAssertEqual(selectable.preferredModelId ?? nil, "ministral-3b-2512")
    }

    func testPersistedLLMModelsMigrateToTheCurrentLineup() throws {
        let cases = [
            ("mistral-large-latest", "mistral-large-4"),
            ("mistral-large-2512", "mistral-large-4"),
            ("mistral-large-2402", "mistral-large-4"),
            ("mistral-large-custom", "mistral-large-4"),
            ("mistral-small-latest", "mistral-small-2603"),
            ("mistral-small-2506", "mistral-small-2603"),
            ("mistral-small-2402", "mistral-small-2603"),
            ("pixtral-12b-2409", "ministral-14b-2512"),
            ("pixtral-large-2411", "ministral-14b-2512"),
            ("pixtral-large-latest", "ministral-14b-2512"),
            ("pixtral-large-9999", "ministral-14b-2512"),
            ("ministral-8b-latest", "ministral-8b-2512"),
            ("ministral-8b-2410", "ministral-8b-2512"),
            ("ministral-3b-latest", "ministral-3b-2512"),
            ("ministral-3b-2410", "ministral-3b-2512"),
        ]
        for (stored, expected) in cases {
            let host = try PluginTestHostServices(
                defaults: ["selectedLLMModel": stored],
                secrets: ["api-key": "test-key"]
            )
            let plugin = MistralAIPlugin()
            plugin.activate(host: host)

            XCTAssertEqual(plugin.selectedLLMModelId, expected, stored)
            XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, expected, stored)
        }
    }

    func testCurrentLLMModelIdsAreKept() throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedLLMModel": "mistral-small-2603"],
            secrets: ["api-key": "test-key"]
        )
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedLLMModelId, "mistral-small-2603")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "mistral-small-2603")

        plugin.selectLLMModel("custom-llm")
        XCTAssertEqual(plugin.selectedLLMModelId, "custom-llm")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "custom-llm")
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
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nvoxtral-mini-transcribe-3-0\r\n"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nfr"))
        XCTAssertTrue(retryBody.contains("name=\"return_language\"\r\n\r\ntrue"))
        XCTAssertFalse(retryBody.contains("voxtral-mini-latest"))
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

        // End-to-end through the provider: the custom mode/value must be
        // resolved and sent as the request's temperature field.
        let output = try await plugin.process(systemPrompt: "s", userText: "u", model: nil)
        XCTAssertEqual(output, "ok")

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.mistral.ai/v1/chat/completions")
        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "mistral-small-2603")
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
    }

    func testExplicitRetiredLLMModelIsSentAsItsReplacement() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        _ = try await plugin.process(systemPrompt: "s", userText: "u", model: "pixtral-12b-2409")

        let body = try XCTUnwrap(store.sessions[0].requestedRequests.first?.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "ministral-14b-2512")
    }

    func testProviderDefaultTemperatureOmitsField() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.setLLMTemperatureMode(.providerDefault)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        // End-to-end through the provider: provider-default mode must omit the
        // temperature field entirely from the request.
        _ = try await plugin.process(systemPrompt: "s", userText: "u", model: nil)

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests[0].httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["temperature"])
    }

    func testTranscriptionSplitsLongRecordingsIntoTenMinuteRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        let url = "https://api.mistral.ai/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"first","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(#"{"text":"second","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Eleven minutes, more than one chunk.
        let samples = [Float](repeating: 0.3, count: 16_000 * 660)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 660)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second")
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 2)
    }

    func testVoxtralSmallUsesTheTranscriptionEndpointAndTenMinuteChunks() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.selectModel("voxtral-small-transcribe-3-0")

        let url = "https://api.mistral.ai/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"first","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(#"{"text":"second","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Eleven minutes, the same two chunks Mini uses. Small no longer takes
        // the five-minute chat path.
        let samples = [Float](repeating: 0.3, count: 16_000 * 660)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 660)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.compactMap { $0.url?.absoluteString }, [url, url])
        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains("name=\"model\"\r\n\r\nvoxtral-small-transcribe-3-0\r\n"))
    }

    func testVoxtralSmallTranscribesViaAudioTranscriptions() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.selectModel("voxtral-small-latest")

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
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.detectedLanguage, "en")

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/audio/transcriptions")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nvoxtral-small-transcribe-3-0\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertFalse(body.contains("input_audio"))
    }

    func testSupportedLanguagesStayThePreviouslyOfferedSet() {
        let plugin = MistralAIPlugin()
        // A non-empty list is what makes the app expose a language picker, so the
        // user can force a language instead of relying on auto-detection. Assert
        // the exact set so an extra code can't silently slip into the picker.
        // Transcribe 3 documents 50 languages, but the languages page does not
        // list the codes, so the picker keeps the eight it already offered.
        XCTAssertEqual(Set(plugin.supportedLanguages), ["en", "fr", "de", "es", "it", "pt", "nl", "hi"])
    }

    func testVoxtralSmallSendsTheLanguageCodeToTheTranscriptionEndpoint() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.selectModel("voxtral-small-transcribe-3-0")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"ciao","language":null}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "it", translate: false, prompt: nil)

        // A pinned language still wins when Transcribe 3 omits `language`.
        XCTAssertEqual(result.text, "ciao")
        XCTAssertEqual(result.detectedLanguage, "it")
        let body = String(decoding: try XCTUnwrap(store.sessions[0].requestedRequests.first?.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nit"))
        XCTAssertFalse(body.contains("Italian"))
    }

    // MARK: - Usage reporting

    func testProcessReportsTheChatUsage() async throws {
        let reports = try await Self.processCollectingUsage(body: #"""
        {"model":"mistral-small-2603","choices":[{"message":{"content":"ok"}}],
         "usage":{"prompt_tokens":88,"completion_tokens":7,"total_tokens":95}}
        """#)

        XCTAssertEqual(reports, [PluginLLMUsage(inputTokens: 88, outputTokens: 7, model: "mistral-small-2603")])
    }

    func testProcessWithoutUsageReportsNothing() async throws {
        let reports = try await Self.processCollectingUsage(body: #"{"choices":[{"message":{"content":"ok"}}]}"#)

        XCTAssertEqual(reports, [])
    }

    /// Runs one chat request answered with `body` and returns the usage reported meanwhile.
    private static func processCollectingUsage(body: String) async throws -> [PluginLLMUsage] {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(body.utf8), httpResponse(url: "https://api.mistral.ai/v1/chat/completions", statusCode: 200)),
            ])
        }
        let collector = PluginLLMUsageCollector()
        let output = try await PluginLLMUsageReporting.$collector.withValue(collector) {
            try await plugin.process(systemPrompt: "s", userText: "u", model: nil)
        }
        XCTAssertEqual(output, "ok")
        return collector.reports
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
