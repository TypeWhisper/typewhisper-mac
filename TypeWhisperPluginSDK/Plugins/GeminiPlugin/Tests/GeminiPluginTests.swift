import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GeminiPlugin

final class GeminiPluginTests: XCTestCase {
    private static let cachedLLMModelsKey = "fetchedLLMModels.v2"
    private static let cachedTranscriptionModelsKey = "fetchedTranscriptionModels.v1"
    private static let modelCatalogRefreshDateKey = "modelCatalogRefreshDate.v1"
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

    private static func cachedTranscriptionModelsData() throws -> Data {
        try JSONEncoder().encode([
            GeminiFetchedTranscriptionModel(
                id: "gemini-3.5-transcribe",
                displayName: "Gemini 3.5 Transcribe",
                liveModelId: "gemini-3.5-transcribe-live"
            ),
        ])
    }

    private static func configuredDefaults(selectedModel: String? = nil) throws -> [String: Any] {
        var defaults: [String: Any] = [
            Self.cachedLLMModelsKey: try Self.cachedModelsData(),
            Self.cachedTranscriptionModelsKey: try Self.cachedTranscriptionModelsData(),
            Self.modelCatalogRefreshDateKey: Date(),
        ]
        if let selectedModel {
            defaults["selectedModel"] = selectedModel
        }
        return defaults
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
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(plugin.dictionaryTermsBudget.maxTerms, 1_000)
        XCTAssertEqual(plugin.selectedModelId, "gemini-3.5-transcribe")
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["gemini-3.5-transcribe"])
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-3.5-transcribe")
    }

    func testUnsupportedFlashSelectionFallsBackAndPersistsDefault() throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
        plugin.activate(host: host)

        plugin.selectModel("gemini-2.5-flash")

        XCTAssertEqual(plugin.selectedModelId, "gemini-3.5-transcribe")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-3.5-transcribe")
    }

    func testUnsupportedFlashSelectionCannotDisableDedicatedStreaming() throws {
        let host = try PluginTestHostServices()
        let plugin = GeminiPlugin()
        plugin.activate(host: host)
        let notificationsBeforeSelection = host.capabilitiesChangedCount

        XCTAssertTrue(plugin.supportsStreaming)
        plugin.selectModel("gemini-flash-lite-latest")
        XCTAssertEqual(plugin.selectedModelId, "gemini-3.5-transcribe")
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertEqual(host.capabilitiesChangedCount, notificationsBeforeSelection + 1)
    }

    func testKnownTranscriptionModelKeepsLivePairWhenCatalogOmitsLiveEntry() throws {
        let cachedTranscriptionModels = try JSONEncoder().encode([
            GeminiFetchedTranscriptionModel(
                id: "gemini-3.5-transcribe",
                displayName: "Gemini 3.5 Transcribe"
            ),
        ])
        let host = try PluginTestHostServices(defaults: [
            Self.cachedTranscriptionModelsKey: cachedTranscriptionModels,
        ])
        let plugin = GeminiPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "gemini-3.5-transcribe")
        XCTAssertTrue(plugin.supportsStreaming)
    }

    func testInvalidStoredTranscriptionModelFallsBackAndPersistsDefault() throws {
        let host = try PluginTestHostServices(defaults: ["selectedModel": "retired-gemini-stt"])
        let plugin = GeminiPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "gemini-3.5-transcribe")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-3.5-transcribe")
    }

    func testCachedFlashModelsAreRemovedAndStoredSelectionMigrates() throws {
        let cachedModels = try JSONEncoder().encode([
            GeminiFetchedTranscriptionModel(
                id: "gemini-3.5-transcribe",
                displayName: "Gemini 3.5 Transcribe",
                liveModelId: "gemini-3.5-transcribe-live"
            ),
            GeminiFetchedTranscriptionModel(
                id: "gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash"
            ),
        ])
        let host = try PluginTestHostServices(defaults: [
            Self.cachedTranscriptionModelsKey: cachedModels,
            "selectedModel": "gemini-2.5-flash",
            Self.modelCatalogRefreshDateKey: Date(),
        ])
        let plugin = GeminiPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["gemini-3.5-transcribe"])
        XCTAssertEqual(plugin.selectedModelId, "gemini-3.5-transcribe")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gemini-3.5-transcribe")
        let cleanedCache = try XCTUnwrap(
            host.userDefault(forKey: Self.cachedTranscriptionModelsKey) as? Data
        )
        XCTAssertEqual(
            try JSONDecoder().decode([GeminiFetchedTranscriptionModel].self, from: cleanedCache)
                .map(\.id),
            ["gemini-3.5-transcribe"]
        )
    }

    func testNativeModelCatalogSeparatesChatAndTranscriptionModels() throws {
        let response = Data(
            """
            {
              "models": [
                {
                  "name": "models/gemini-2.5-pro",
                  "displayName": "Gemini 2.5 Pro",
                  "supportedGenerationMethods": ["generateContent"]
                },
                {
                  "name": "models/gemini-3.5-transcribe",
                  "displayName": "Gemini 3.5 Transcribe"
                },
                {
                  "name": "models/gemini-3.5-transcribe-live",
                  "displayName": "Gemini 3.5 Transcribe Live"
                },
                {
                  "name": "models/gemini-2.5-flash-image",
                  "displayName": "Gemini Image",
                  "supportedGenerationMethods": ["generateContent"]
                }
              ]
            }
            """.utf8
        )

        let catalog = try GeminiPlugin.decodeModelCatalog(from: response)

        XCTAssertEqual(catalog.llmModels.map(\.id), ["gemini-2.5-pro"])
        XCTAssertEqual(catalog.transcriptionModels.map(\.id), ["gemini-3.5-transcribe"])
        XCTAssertEqual(
            catalog.transcriptionModels.first?.liveModelId,
            "gemini-3.5-transcribe-live"
        )
    }

    func testModelCatalogFetchFollowsPagination() async throws {
        let host = try PluginTestHostServices(
            defaults: try Self.configuredDefaults(),
            secrets: ["api-key": "gemini-key"]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "models": [{
                            "name": "models/gemini-2.5-pro",
                            "displayName": "Gemini 2.5 Pro",
                            "supportedGenerationMethods": ["generateContent"]
                          }],
                          "nextPageToken": "page-two"
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models", statusCode: 200)
                ),
                .success(
                    Data(
                        """
                        {
                          "models": [
                            { "name": "models/gemini-3.5-transcribe", "displayName": "Gemini 3.5 Transcribe" },
                            { "name": "models/gemini-3.5-transcribe-live", "displayName": "Gemini 3.5 Transcribe Live" }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models", statusCode: 200)
                ),
            ])
        }

        let catalog = await plugin.fetchModelCatalog()

        XCTAssertEqual(catalog.llmModels.map(\.id), ["gemini-2.5-pro"])
        XCTAssertEqual(catalog.transcriptionModels.map(\.id), ["gemini-3.5-transcribe"])
        let requests = try XCTUnwrap(store.sessions.first).requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageSize" })?.value,
            "1000"
        )
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "pageToken" })?.value,
            "page-two"
        )
    }

    func testModelCatalogFetchRejectsRepeatedPaginationToken() async throws {
        let host = try PluginTestHostServices(
            defaults: try Self.configuredDefaults(),
            secrets: ["api-key": "gemini-key"]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        let page = Data(
            """
            {
              "models": [{
                "name": "models/gemini-2.5-pro",
                "displayName": "Gemini 2.5 Pro",
                "supportedGenerationMethods": ["generateContent"]
              }],
              "nextPageToken": "repeated-page"
            }
            """.utf8
        )
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    page,
                    Self.httpResponse(
                        url: "https://generativelanguage.googleapis.com/v1beta/models",
                        statusCode: 200
                    )
                ),
                .success(
                    page,
                    Self.httpResponse(
                        url: "https://generativelanguage.googleapis.com/v1beta/models",
                        statusCode: 200
                    )
                ),
            ])
        }

        let catalog = await plugin.fetchModelCatalog()

        XCTAssertTrue(catalog.isEmpty)
        XCTAssertEqual(try XCTUnwrap(store.sessions.first).requestedRequests.count, 2)
    }

    func testActivationAutomaticallyRefreshesAndCachesModelCatalog() async throws {
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "models": [
                            {
                              "name": "models/gemini-2.5-pro",
                              "displayName": "Gemini 2.5 Pro",
                              "supportedGenerationMethods": ["generateContent"]
                            },
                            { "name": "models/gemini-3.5-transcribe", "displayName": "Gemini 3.5 Transcribe" },
                            { "name": "models/gemini-3.5-transcribe-live", "displayName": "Gemini 3.5 Transcribe Live" }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/models", statusCode: 200)
                ),
            ])
        }

        let host = try PluginTestHostServices(secrets: ["api-key": "gemini-key"])
        let plugin = GeminiPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        for _ in 0..<40 where host.userDefault(forKey: Self.modelCatalogRefreshDateKey) == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        let llmData = try XCTUnwrap(host.userDefault(forKey: Self.cachedLLMModelsKey) as? Data)
        let transcriptionData = try XCTUnwrap(
            host.userDefault(forKey: Self.cachedTranscriptionModelsKey) as? Data
        )
        XCTAssertEqual(
            try JSONDecoder().decode([GeminiFetchedModel].self, from: llmData).map(\.id),
            ["gemini-2.5-pro"]
        )
        XCTAssertEqual(
            try JSONDecoder().decode([GeminiFetchedTranscriptionModel].self, from: transcriptionData)
                .map(\.id),
            ["gemini-3.5-transcribe"]
        )
        XCTAssertEqual(store.sessions.first?.requestedRequests.first?.url?.path, "/v1beta/models")
    }

    func testDedicatedTranscriptionRequestsUseFilesAndInteractionsAPIs() throws {
        let upload = Self.m4aUpload()
        let startRequest = try GeminiPlugin.makeFileUploadStartRequest(
            uploadFile: upload,
            apiKey: "gemini-key"
        )

        XCTAssertEqual(startRequest.url?.path, "/upload/v1beta/files")
        XCTAssertEqual(startRequest.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-key")
        XCTAssertEqual(startRequest.value(forHTTPHeaderField: "X-Goog-Upload-Protocol"), "resumable")
        XCTAssertEqual(startRequest.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "start")
        XCTAssertEqual(
            (try Self.jsonBody(from: startRequest)["file"] as? [String: String])?["display_name"],
            "audio.m4a"
        )

        let uploadRequest = GeminiPlugin.makeFileUploadRequest(
            uploadFile: upload,
            uploadURL: URL(string: "https://upload.example.test/session")!
        )
        XCTAssertEqual(uploadRequest.httpBody, upload.data)
        XCTAssertEqual(uploadRequest.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")

        let interactionRequest = try GeminiPlugin.makeDedicatedTranscriptionRequest(
            uploadedFile: GeminiUploadedFile(
                name: "files/audio-123",
                uri: "https://generativelanguage.googleapis.com/v1beta/files/audio-123",
                mimeType: "audio/mp4"
            ),
            apiKey: "gemini-key",
            modelId: "gemini-3.5-transcribe",
            language: " de ",
            prompt: "TypeWhisper, Gemini",
            timeout: 900
        )

        XCTAssertEqual(interactionRequest.url?.path, "/v1beta/interactions")
        XCTAssertEqual(interactionRequest.timeoutInterval, 900)
        let body = try Self.jsonBody(from: interactionRequest)
        XCTAssertEqual(body["model"] as? String, "gemini-3.5-transcribe")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["type"] as? String, "audio")
        XCTAssertEqual(input.first?["mime_type"] as? String, "audio/mp4")
        let generationConfig = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let transcriptionConfig = try XCTUnwrap(
            generationConfig["transcription_config"] as? [String: Any]
        )
        XCTAssertEqual(transcriptionConfig["mode"] as? String, "smart")
        XCTAssertEqual(transcriptionConfig["language_codes"] as? [String], ["de-DE"])
        XCTAssertEqual(transcriptionConfig["custom_vocabulary"] as? [String], ["TypeWhisper", "Gemini"])
    }

    func testTranscriptionLanguageCodesUseGeminiBCP47Locales() {
        let codes = GeminiPlugin.resolvedLanguageCodes(
            from: PluginLanguageSelection(
                requestedLanguage: " de ",
                languageHints: ["en_GB", "no", "de-DE", "auto"]
            )
        )

        XCTAssertEqual(codes, ["de-DE", "en-GB", "nb-NO"])
        XCTAssertNil(GeminiPlugin.resolvedTranscriptionLanguageCode("auto"))
        XCTAssertEqual(
            GeminiPlugin.resolvedTranscriptionLanguageCode("zh"),
            "cmn-Hans-CN"
        )
    }

    func testDedicatedTranscriptionResponseParsesOutputText() throws {
        let data = Data(#"{"status":"completed","output_text":" hello from transcribe \n"}"#.utf8)
        XCTAssertEqual(try GeminiPlugin.parseDedicatedTranscriptionResponse(data), "hello from transcribe")
    }

    func testDedicatedTranscribeUploadsRunsInteractionAndDeletesFile() async throws {
        let host = try PluginTestHostServices(
            defaults: try Self.configuredDefaults(selectedModel: "gemini-3.5-transcribe"),
            secrets: ["api-key": "gemini-key"]
        )
        let plugin = GeminiPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            switch store.sessions.count {
            case 0:
                return store.makeSession(outcomes: [
                    .success(
                        Data(),
                        Self.httpResponse(
                            url: "https://generativelanguage.googleapis.com/upload/v1beta/files",
                            statusCode: 200,
                            headers: ["x-goog-upload-url": "https://upload.example.test/session-123"]
                        )
                    ),
                    .success(
                        Data(#"{}"#.utf8),
                        Self.httpResponse(
                            url: "https://generativelanguage.googleapis.com/v1beta/files/audio-123",
                            statusCode: 200
                        )
                    ),
                ])
            case 1:
                return store.makeSession(outcomes: [
                    .success(
                        Data(
                            #"{"file":{"name":"files/audio-123","uri":"https://generativelanguage.googleapis.com/v1beta/files/audio-123","mimeType":"audio/mp4"}}"#.utf8
                        ),
                        Self.httpResponse(url: "https://upload.example.test/session-123", statusCode: 200)
                    ),
                ])
            default:
                return store.makeSession(outcomes: [
                    .success(
                        Data(#"{"output_text":"dedicated transcript"}"#.utf8),
                        Self.httpResponse(
                            url: "https://generativelanguage.googleapis.com/v1beta/interactions",
                            statusCode: 200
                        )
                    ),
                ])
            }
        }

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "en-US",
            translate: false,
            prompt: "TypeWhisper"
        )

        XCTAssertEqual(result.text, "dedicated transcript")
        XCTAssertEqual(result.detectedLanguage, "en-US")
        XCTAssertEqual(store.sessions.count, 3)
        XCTAssertEqual(
            store.sessions[0].requestedRequests.map { $0.url?.path },
            ["/upload/v1beta/files", "/v1beta/files/audio-123"]
        )
        XCTAssertEqual(store.sessions[1].requestedRequests.first?.url?.host, "upload.example.test")
        XCTAssertEqual(store.sessions[2].requestedRequests.first?.url?.path, "/v1beta/interactions")
    }

    func testLiveSetupAudioEncodingAndTranscriptReconciliation() throws {
        let setupMessage = try GeminiLiveTranscriptionSession.makeSetupMessage(
            modelId: "gemini-3.5-transcribe-live",
            languageCodes: ["de-DE", "en-US"],
            customVocabulary: ["TypeWhisper", "Gemini"]
        )
        let setupBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(setupMessage.utf8)) as? [String: Any]
        )
        let setup = try XCTUnwrap(setupBody["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        let transcriptionConfig = try XCTUnwrap(
            setup["inputAudioTranscription"] as? [String: Any]
        )
        XCTAssertEqual(transcriptionConfig["mode"] as? String, "SMART")
        XCTAssertEqual(transcriptionConfig["languageCodes"] as? [String], ["de-DE", "en-US"])
        XCTAssertEqual(
            transcriptionConfig["customVocabulary"] as? [String],
            ["TypeWhisper", "Gemini"]
        )

        let pcm = GeminiLiveTranscriptionSession.pcm16Data(from: [-1, 0, 1][...])
        XCTAssertEqual(pcm.count, 6)
        let audioMessage = try GeminiLiveTranscriptionSession.makeRealtimeAudioMessage(pcm)
        let audioBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(audioMessage.utf8)) as? [String: Any]
        )
        let realtimeInput = try XCTUnwrap(audioBody["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtimeInput["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(audio["data"] as? String, pcm.base64EncodedString())

        var collector = GeminiLiveTranscriptCollector()
        XCTAssertFalse(collector.hasUncommittedInterimText)
        XCTAssertEqual(collector.apply(interimText: "Hello", finalText: nil), "Hello")
        XCTAssertTrue(collector.hasUncommittedInterimText)
        XCTAssertEqual(collector.apply(interimText: nil, finalText: "Hello"), "Hello")
        XCTAssertFalse(collector.hasUncommittedInterimText)
        XCTAssertEqual(collector.apply(interimText: "world", finalText: nil), "Hello world")
        XCTAssertEqual(collector.apply(interimText: nil, finalText: "world"), "Hello world")
        XCTAssertEqual(collector.resultText, "Hello world")
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
            defaults: try Self.configuredDefaults(),
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

    func testTranscriptionHTTPErrorMapping() {
        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/interactions", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"too large"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/interactions", statusCode: 413)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .fileTooLarge = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/interactions", statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try GeminiPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"server failed"}}"#.utf8),
            response: Self.httpResponse(url: "https://generativelanguage.googleapis.com/v1beta/interactions", statusCode: 500)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "HTTP 500: server failed")
        }
    }

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

    private static func httpResponse(
        url: String,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}
