import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import MicrosoftAIPlugin

final class MicrosoftAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testPluginMetadataAndFallbackModels() throws {
        let host = try PluginTestHostServices()
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(MicrosoftAIPlugin.pluginId, "com.typewhisper.microsoft-ai")
        XCTAssertEqual(plugin.providerId, "microsoft-ai")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertEqual(plugin.selectedModelId, MicrosoftAIPlugin.defaultModelId)
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), [
            MicrosoftAIPlugin.defaultModelId,
            MicrosoftAIPlugin.legacyModelId,
        ])
        XCTAssertEqual(plugin.transcriptionModels.map(\.languageCount), [60, 43])
        XCTAssertEqual(plugin.supportedLanguages.count, 60)
        XCTAssertTrue(plugin.supportedLanguages.contains("de"))
        XCTAssertTrue(plugin.supportedLanguages.contains("nl"))
        XCTAssertTrue(plugin.supportedLanguages.contains("yue"))
        XCTAssertFalse(plugin.supportedLanguages.contains("ka"))
        XCTAssertEqual(plugin.dictionaryTermsBudget.maxTerms, 500)
    }

    func testEndpointNormalizationSupportsResourceNamesAndDocumentedAzureHosts() throws {
        XCTAssertEqual(
            MicrosoftAIEndpoint.normalize("typewhisper-speech")?.absoluteString,
            "https://typewhisper-speech.cognitiveservices.azure.com"
        )
        XCTAssertEqual(
            MicrosoftAIEndpoint.normalize("https://eastus.api.cognitive.microsoft.com/")?.absoluteString,
            "https://eastus.api.cognitive.microsoft.com"
        )
        XCTAssertEqual(
            MicrosoftAIEndpoint.normalize("https://example.services.ai.azure.com")?.absoluteString,
            "https://example.services.ai.azure.com"
        )
    }

    func testEndpointNormalizationRejectsUnsafeOrMalformedValues() {
        XCTAssertNil(MicrosoftAIEndpoint.normalize("http://example.cognitiveservices.azure.com"))
        XCTAssertNil(MicrosoftAIEndpoint.normalize("https://example.com"))
        XCTAssertNil(MicrosoftAIEndpoint.normalize("https://example.cognitiveservices.azure.com/path"))
        XCTAssertNil(MicrosoftAIEndpoint.normalize("https://user@example.cognitiveservices.azure.com"))
        XCTAssertNil(MicrosoftAIEndpoint.normalize("not a resource"))
    }

    func testRegionalEndpointAvailabilityIdentifiesUnsupportedRegions() throws {
        let westEurope = try XCTUnwrap(
            MicrosoftAIEndpoint.normalize("https://westeurope.api.cognitive.microsoft.com")
        )
        let northEurope = try XCTUnwrap(
            MicrosoftAIEndpoint.normalize("https://northeurope.api.cognitive.microsoft.com")
        )
        let resourceEndpoint = try XCTUnwrap(
            MicrosoftAIEndpoint.normalize("https://speech-demo.cognitiveservices.azure.com")
        )

        XCTAssertEqual(MicrosoftAIEndpoint.regionalEndpointRegion(from: westEurope), "westeurope")
        XCTAssertEqual(MicrosoftAIEndpoint.unsupportedMAIRegion(from: westEurope), "westeurope")
        XCTAssertNil(MicrosoftAIEndpoint.unsupportedMAIRegion(from: northEurope))
        XCTAssertNil(MicrosoftAIEndpoint.regionalEndpointRegion(from: resourceEndpoint))
    }

    func testConnectionAndSettingsPersist() throws {
        let host = try PluginTestHostServices()
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)

        plugin.setEndpoint("speech-demo")
        plugin.setAPIKey(" azure-key ")
        plugin.setTranscriptStyle(.verbatim)
        plugin.setSpeakerDiarizationEnabled(true)
        plugin.selectModel(MicrosoftAIPlugin.legacyModelId)

        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "azure-key")
        XCTAssertEqual(host.userDefault(forKey: "endpoint") as? String, "https://speech-demo.cognitiveservices.azure.com")
        XCTAssertEqual(host.userDefault(forKey: "transcriptStyle") as? String, "verbatim")
        XCTAssertEqual(host.userDefault(forKey: "speakerDiarizationEnabled") as? Bool, true)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, MicrosoftAIPlugin.legacyModelId)

        let reloaded = MicrosoftAIPlugin()
        reloaded.activate(host: host)
        XCTAssertTrue(reloaded.isConfigured)
        XCTAssertEqual(reloaded.selectedModelId, MicrosoftAIPlugin.legacyModelId)
        XCTAssertFalse(reloaded.selectedModelSupportsDiarization)
    }

    func testLocalesUseOnlyAnExplicitOrSingleHintedLanguage() {
        XCTAssertEqual(
            MicrosoftAITranscriptionClient.locales(from: PluginLanguageSelection(
                requestedLanguage: "de_DE",
                languageHints: ["en", "DE-de", "fr"]
            )),
            ["de-DE"]
        )
        XCTAssertEqual(
            MicrosoftAITranscriptionClient.locales(from: PluginLanguageSelection(
                languageHints: ["en_US"]
            )),
            ["en-US"]
        )
        XCTAssertNil(MicrosoftAITranscriptionClient.locales(from: PluginLanguageSelection(
            languageHints: ["en", "fr"]
        )))
        XCTAssertNil(MicrosoftAITranscriptionClient.locales(from: PluginLanguageSelection()))
    }

    func testTranscriptionBuildsAzureSpeechMultipartRequest() async throws {
        let host = try configuredHost(defaults: [
            "transcriptStyle": "verbatim",
            "speakerDiarizationEnabled": true,
        ])
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.successResponseData,
                    Self.httpResponse(
                        url: "https://speech-demo.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15",
                        statusCode: 200
                    )
                ),
            ])
        }

        let result = try await plugin.transcribeStructured(
            audio: Self.audio,
            languageSelection: PluginLanguageSelection(
                requestedLanguage: "de",
                languageHints: ["en"]
            ),
            translate: false,
            prompt: "TypeWhisper, Azure",
            dictionaryTermHints: [PluginDictionaryTermHint(text: "MAI Transcribe")]
        )

        XCTAssertEqual(result.text, "Speaker 1: Hallo Welt\nSpeaker 2: Willkommen")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/speechtotext/transcriptions:transcribe")
        XCTAssertEqual(Self.queryItems(request.url)["api-version"], "2025-10-15")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key"), "azure-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"definition\""))
        XCTAssertTrue(body.contains("name=\"audio\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("\"model\":\"MAI-Transcribe-2\""))
        XCTAssertTrue(body.contains("\"modelOptions\""))
        XCTAssertTrue(body.contains("\"transcribeStyle\":\"verbatim\""))
        XCTAssertTrue(body.contains("\"timestamps\":\"segment\""))
        XCTAssertTrue(body.contains("\"locales\":[\"de\"]"))
        XCTAssertTrue(body.contains("\"diarization\":{\"enabled\":true}"))
        XCTAssertFalse(body.contains("maxSpeakers"))
        XCTAssertTrue(body.contains("\"profanityFilterMode\":\"None\""))
        XCTAssertTrue(body.contains("MAI Transcribe"))
        XCTAssertTrue(body.contains("TypeWhisper"))
        XCTAssertTrue(body.contains("Azure"))
    }

    func testCleanStyleUsesLegacyContractAndLegacyModelOmitsDiarization() async throws {
        let host = try configuredHost(defaults: [
            "selectedModel": MicrosoftAIPlugin.legacyModelId,
            "speakerDiarizationEnabled": true,
        ])
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Self.successResponseData, Self.httpResponse(statusCode: 200)),
            ])
        }

        _ = try await plugin.transcribeStructured(
            audio: Self.audio,
            language: nil,
            translate: false,
            prompt: nil
        )

        let body = String(
            decoding: try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody),
            as: UTF8.self
        )
        XCTAssertTrue(body.contains("\"model\":\"MAI-Transcribe-1.5\""))
        XCTAssertFalse(body.contains("modelOptions"))
        XCTAssertFalse(body.contains("transcribeStyle"))
        XCTAssertFalse(body.contains("diarization"))
        XCTAssertFalse(body.contains("locales"))
        XCTAssertFalse(body.contains("phraseList"))
    }

    func testCleanStyleUsesV2ModelOptions() async throws {
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: try configuredHost())

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Self.successResponseData, Self.httpResponse(statusCode: 200)),
            ])
        }

        _ = try await plugin.transcribeStructured(
            audio: Self.audio,
            language: nil,
            translate: false,
            prompt: nil
        )

        let body = String(
            decoding: try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody),
            as: UTF8.self
        )
        XCTAssertTrue(body.contains("\"model\":\"MAI-Transcribe-2\""))
        XCTAssertTrue(body.contains("\"modelOptions\""))
        XCTAssertTrue(body.contains("\"transcribeStyle\":\"clean\""))
        XCTAssertTrue(body.contains("\"timestamps\":\"segment\""))
        XCTAssertFalse(body.contains("diarization"))
    }

    func testResponseParsingPreservesLocaleTimingsAndSpeakers() throws {
        let result = try MicrosoftAITranscriptionClient.parseResponse(Self.successResponseData)

        XCTAssertEqual(result.text, "Speaker 1: Hallo Welt\nSpeaker 2: Willkommen")
        XCTAssertEqual(result.detectedLanguage, "de-DE")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "Hallo Welt")
        XCTAssertEqual(result.segments[0].start, 0.25)
        XCTAssertEqual(result.segments[0].end, 1.75)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker 1")
        XCTAssertEqual(result.segments[1].speakerLabel, "Speaker 2")
        XCTAssertNil(result.segments[0].speakerConfidence)
    }

    func testResponseParsingUsesCombinedTextWithoutSpeakers() throws {
        let data = Data(#"{"combinedPhrases":[{"text":"Clean transcript"}],"phrases":[{"offsetMilliseconds":0,"durationMilliseconds":800,"text":"Clean transcript","locale":"en-US"}]}"#.utf8)

        let result = try MicrosoftAITranscriptionClient.parseResponse(data)

        XCTAssertEqual(result.text, "Clean transcript")
        XCTAssertEqual(result.detectedLanguage, "en-US")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertNil(result.segments[0].speakerLabel)
    }

    func testModelCatalogRefreshFiltersMAIModelsAndPersistsThem() async throws {
        let host = try configuredHost()
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        let data = Data(#"{"object":"list","data":[{"id":"gpt-5","object":"model","created":0,"owned_by":"Microsoft"},{"id":"mai-transcribe-2-preview","object":"model","created":0,"owned_by":"Microsoft"},{"id":"mai-transcribe-2","object":"model","created":0,"owned_by":"Microsoft"}]}"#.utf8)
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(data, Self.httpResponse(url: "https://speech-demo.cognitiveservices.azure.com/openai/v1/models", statusCode: 200)),
            ])
        }

        let refreshed = await plugin.refreshModelCatalog()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), [
            "MAI-Transcribe-2",
            "mai-transcribe-2-preview",
            "MAI-Transcribe-1.5",
        ])
        XCTAssertEqual(host.userDefault(forKey: "cachedModels") as? [String], [
            "mai-transcribe-2",
            "mai-transcribe-2-preview",
        ])
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/openai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "azure-key")
    }

    func testUnavailableModelCatalogKeepsStaticFallbacks() async throws {
        let host = try configuredHost()
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: [
                .success(Data(#"{"error":{"message":"Not found"}}"#.utf8), Self.httpResponse(statusCode: 404)),
            ])
        }

        let refreshed = await plugin.refreshModelCatalog()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), [
            MicrosoftAIPlugin.defaultModelId,
            MicrosoftAIPlugin.legacyModelId,
        ])
    }

    func testAuthenticationAndLimitErrorsAreMapped() async throws {
        for (statusCode, expected) in [(401, "invalidApiKey"), (403, "invalidApiKey"), (413, "fileTooLarge"), (429, "rateLimited")] {
            PluginHTTPClientTestHarness.reset()
            let host = try configuredHost()
            let plugin = MicrosoftAIPlugin()
            plugin.activate(host: host)
            PluginHTTPClientTestHarness.configure { _ in
                PluginHTTPClientMockSession(outcomes: [
                    .success(Data(), Self.httpResponse(statusCode: statusCode)),
                ])
            }

            do {
                _ = try await plugin.transcribeStructured(
                    audio: Self.audio,
                    language: nil,
                    translate: false,
                    prompt: nil
                )
                XCTFail("Expected HTTP \(statusCode) to fail")
            } catch let error as PluginTranscriptionError {
                switch (error, expected) {
                case (.invalidApiKey, "invalidApiKey"),
                     (.fileTooLarge, "fileTooLarge"),
                     (.rateLimited, "rateLimited"):
                    break
                default:
                    XCTFail("Unexpected error for HTTP \(statusCode): \(error)")
                }
            }
        }
    }

    func testUnsupportedRegionalEndpointReturnsActionableError() async throws {
        let host = try PluginTestHostServices(
            defaults: ["endpoint": "https://westeurope.api.cognitive.microsoft.com"],
            secrets: ["api-key": "azure-key"]
        )
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: host)
        let unsupportedMessage = String(repeating: "x", count: 1_100)
            + " Enhanced mode with model is currently not supported yet."
        let responseData = try JSONEncoder().encode([
            "code": "InvalidRequest",
            "message": unsupportedMessage,
        ])

        PluginHTTPClientTestHarness.configure { _ in
            PluginHTTPClientMockSession(outcomes: [
                .success(
                    responseData,
                    Self.httpResponse(statusCode: 400)
                ),
            ])
        }

        do {
            _ = try await plugin.transcribeStructured(
                audio: Self.audio,
                language: "de",
                translate: false,
                prompt: nil
            )
            XCTFail("Expected unsupported Azure region to fail")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertTrue(message.contains("westeurope"))
            XCTAssertTrue(message.contains("northeurope"))
            XCTAssertFalse(message.contains("azure-key"))
        }
    }

    func testErrorSummaryHandlesAzureShapesAndBoundsFallbackText() {
        XCTAssertEqual(
            MicrosoftAITranscriptionClient.errorSummary(
                from: Data(#"{"message":"  Root\nmessage  "}"#.utf8)
            ),
            "Root message"
        )
        XCTAssertEqual(
            MicrosoftAITranscriptionClient.errorSummary(
                from: Data(#"{"error":{"message":"Nested message"}}"#.utf8)
            ),
            "Nested message"
        )
        XCTAssertEqual(
            MicrosoftAITranscriptionClient.errorSummary(from: Data()),
            "No response body."
        )
        XCTAssertEqual(
            MicrosoftAITranscriptionClient.errorSummary(
                from: Data(String(repeating: "x", count: 5_000).utf8)
            ).count,
            1_000
        )
    }

    func testRequiresConfigurationAndRejectsTranslation() async throws {
        let unconfigured = MicrosoftAIPlugin()
        unconfigured.activate(host: try PluginTestHostServices())

        do {
            _ = try await unconfigured.transcribeStructured(
                audio: Self.audio,
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected missing configuration to fail")
        } catch PluginTranscriptionError.notConfigured {
        }

        let configured = MicrosoftAIPlugin()
        configured.activate(host: try configuredHost())
        do {
            _ = try await configured.transcribeStructured(
                audio: Self.audio,
                language: nil,
                translate: true,
                prompt: nil
            )
            XCTFail("Expected translation to fail")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertTrue(message.contains("does not support translation"))
        }
    }

    func testRejectsAudioBeyondMAIModelCardDurationLimitBeforeNetworking() async throws {
        let plugin = MicrosoftAIPlugin()
        plugin.activate(host: try configuredHost())
        let oversized = AudioData(
            samples: [],
            wavData: Data(),
            duration: MicrosoftAITranscriptionClient.maximumAudioDuration + 1
        )

        do {
            _ = try await plugin.transcribeStructured(
                audio: oversized,
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected file limit error")
        } catch PluginTranscriptionError.fileTooLarge {
        }
    }

    func testManifestAndLocalizationAreValid() throws {
        let pluginDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manifestData = try Data(contentsOf: pluginDirectory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["id"] as? String, MicrosoftAIPlugin.pluginId)
        XCTAssertEqual(manifest["principalClass"] as? String, "MicrosoftAIPlugin")
        XCTAssertEqual(manifest["hosting"] as? String, "cloud")
        XCTAssertEqual(manifest["iconResourceName"] as? String, "azure.svg")
        XCTAssertEqual(manifest["minHostVersion"] as? String, "1.7.0")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pluginDirectory.appendingPathComponent("azure.svg").path
            )
        )

        let catalogData = try Data(contentsOf: pluginDirectory.appendingPathComponent("Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for key in [
            "Azure Speech connection",
            "Endpoint or resource name",
            "MAI Transcribe is not available in the Azure region %@. Use a Speech resource in one of these regions: %@.",
            "Transcript style",
            "Speaker diarization",
            "Refresh models",
        ] {
            XCTAssertNotNil(strings[key], "Missing localization key: \(key)")
        }
    }

    private static let audio = AudioData(
        samples: Array(repeating: 0, count: 16_000),
        wavData: Data("RIFF-test-wav".utf8),
        duration: 1
    )

    private static let successResponseData = Data(
        #"{"durationMilliseconds":2750,"combinedPhrases":[{"channel":0,"text":"Hallo Welt Willkommen"}],"phrases":[{"channel":0,"offsetMilliseconds":250,"durationMilliseconds":1500,"text":"Hallo Welt","locale":"de-DE","confidence":0,"speaker":1,"words":[{"text":"Hallo","offsetMilliseconds":250,"durationMilliseconds":500}]},{"channel":0,"offsetMilliseconds":1750,"durationMilliseconds":1000,"text":"Willkommen","locale":"de-DE","confidence":0,"speaker":"2"}]}"#.utf8
    )

    private func configuredHost(defaults: [String: Any] = [:]) throws -> PluginTestHostServices {
        var configuredDefaults = defaults
        configuredDefaults["endpoint"] = "https://speech-demo.cognitiveservices.azure.com"
        return try PluginTestHostServices(
            defaults: configuredDefaults,
            secrets: ["api-key": "azure-key"]
        )
    }

    private static func httpResponse(
        url: String = "https://speech-demo.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15",
        statusCode: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func queryItems(_ url: URL?) -> [String: String] {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
    }
}
