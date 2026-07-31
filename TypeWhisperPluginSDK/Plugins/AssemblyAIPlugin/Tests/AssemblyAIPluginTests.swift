import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import AssemblyAIPlugin

final class AssemblyAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testStaticModelCatalogHasUniqueIdentifiersAndUniversal35Default() {
        let models = AssemblyAIModelCatalog.all
        let canonicalIds = models.map(\.id)
        let legacyIds = models.flatMap(\.legacyIds)

        XCTAssertEqual(models, [
            AssemblyAIModelCatalog.universal35Pro,
            AssemblyAIModelCatalog.universal2,
        ])
        XCTAssertEqual(Set(canonicalIds).count, canonicalIds.count)
        XCTAssertEqual(Set(legacyIds).count, legacyIds.count)
        XCTAssertTrue(Set(canonicalIds).isDisjoint(with: legacyIds))
        XCTAssertEqual(AssemblyAIModelCatalog.defaultModel, AssemblyAIModelCatalog.universal35Pro)
    }

    func testModelCatalogResolvesCanonicalLegacyUnknownEmptyAndMissingIds() {
        XCTAssertEqual(
            AssemblyAIModelCatalog.resolve(AssemblyAIModelCatalog.universal35Pro.id),
            AssemblyAIModelCatalog.universal35Pro
        )
        XCTAssertEqual(
            AssemblyAIModelCatalog.resolve(AssemblyAIModelCatalog.universal2.id),
            AssemblyAIModelCatalog.universal2
        )
        XCTAssertEqual(
            AssemblyAIModelCatalog.resolve(AssemblyAIModelCatalog.legacyUniversal3ProModelId),
            AssemblyAIModelCatalog.universal35Pro
        )
        XCTAssertEqual(AssemblyAIModelCatalog.resolve("retired-model"), AssemblyAIModelCatalog.universal35Pro)
        XCTAssertEqual(AssemblyAIModelCatalog.resolve(""), AssemblyAIModelCatalog.universal35Pro)
        XCTAssertEqual(AssemblyAIModelCatalog.resolve(nil), AssemblyAIModelCatalog.universal35Pro)
    }

    func testUniversal35ModelDefinitionContainsCompleteMetadata() {
        let model = AssemblyAIModelCatalog.universal35Pro
        let expectedLanguages = [
            "en", "es", "fr", "de", "it", "pt", "tr", "nl", "sv",
            "no", "da", "fi", "hi", "vi", "ar", "he", "ja", "zh",
        ]

        XCTAssertEqual(model.displayName, "Universal-3.5 Pro")
        XCTAssertEqual(model.restModelId, model.id)
        XCTAssertEqual(model.supportedLanguages, expectedLanguages)
        XCTAssertEqual(
            model.dictionaryTermsBudget,
            DictionaryTermsBudget(maxTerms: 1_000, maxWordsPerTerm: 6)
        )
        XCTAssertEqual(model.dictionaryPayload, .keytermsPrompt)
        XCTAssertEqual(
            model.streamingConfiguration,
            .universal35Pro(
                speechModelId: model.id,
                supportedLanguageCodes: Set(expectedLanguages)
            )
        )
    }

    func testUniversal2ModelDefinitionContainsCompleteMetadata() {
        let model = AssemblyAIModelCatalog.universal2
        let expectedLanguages = [
            "bg", "ca", "cs", "da", "de", "el", "en", "es", "et", "fi",
            "fr", "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv",
            "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl", "sq",
            "sr", "sv", "th", "tr", "uk", "vi", "zh",
        ]

        XCTAssertEqual(model.displayName, "Universal-2")
        XCTAssertEqual(model.restModelId, model.id)
        XCTAssertEqual(model.supportedLanguages, expectedLanguages)
        XCTAssertEqual(
            model.dictionaryTermsBudget,
            DictionaryTermsBudget(maxTerms: 100, maxCharsPerTerm: 50)
        )
        XCTAssertEqual(model.dictionaryPayload, .wordBoost(boostParam: "high"))
        XCTAssertEqual(
            model.streamingConfiguration,
            .universal2(
                englishSpeechModelId: "universal-streaming-english",
                multilingualSpeechModelId: "universal-streaming-multilingual"
            )
        )
    }

    func testDefaultModelCatalogAndLanguagesUseUniversal35Pro() throws {
        let host = try PluginTestHostServices()
        let plugin = AssemblyAIPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), [
            AssemblyAIPlugin.universal35ProModelId,
            AssemblyAIPlugin.universal2ModelId,
        ])
        XCTAssertEqual(plugin.transcriptionModels.map(\.displayName), ["Universal-3.5 Pro", "Universal-2"])
        XCTAssertEqual(plugin.selectedModelId, AssemblyAIPlugin.universal35ProModelId)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, AssemblyAIPlugin.universal35ProModelId)
        XCTAssertEqual(plugin.supportedLanguages, [
            "en", "es", "fr", "de", "it", "pt", "tr", "nl", "sv",
            "no", "da", "fi", "hi", "vi", "ar", "he", "ja", "zh",
        ])
    }

    func testActivationMigratesLegacyAndUnknownModelIds() throws {
        let legacyHost = try PluginTestHostServices(defaults: [
            "selectedModel": AssemblyAIPlugin.legacyUniversal3ProModelId,
        ])
        let legacyPlugin = AssemblyAIPlugin()

        legacyPlugin.activate(host: legacyHost)

        XCTAssertEqual(legacyPlugin.selectedModelId, AssemblyAIPlugin.universal35ProModelId)
        XCTAssertEqual(
            legacyHost.userDefault(forKey: "selectedModel") as? String,
            AssemblyAIPlugin.universal35ProModelId
        )

        let unknownHost = try PluginTestHostServices(defaults: ["selectedModel": "retired-model"])
        let unknownPlugin = AssemblyAIPlugin()

        unknownPlugin.activate(host: unknownHost)

        XCTAssertEqual(unknownPlugin.selectedModelId, AssemblyAIPlugin.universal35ProModelId)
        XCTAssertEqual(
            unknownHost.userDefault(forKey: "selectedModel") as? String,
            AssemblyAIPlugin.universal35ProModelId
        )
    }

    func testSelectModelNormalizesLegacyAndUnknownModelIds() throws {
        let host = try PluginTestHostServices()
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        plugin.selectModel(AssemblyAIPlugin.legacyUniversal3ProModelId)
        XCTAssertEqual(plugin.selectedModelId, AssemblyAIPlugin.universal35ProModelId)

        plugin.selectModel("retired-model")
        XCTAssertEqual(plugin.selectedModelId, AssemblyAIPlugin.universal35ProModelId)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, AssemblyAIPlugin.universal35ProModelId)

        plugin.selectModel(AssemblyAIPlugin.universal2ModelId)
        XCTAssertEqual(plugin.selectedModelId, AssemblyAIPlugin.universal2ModelId)
        XCTAssertTrue(plugin.supportedLanguages.contains("uk"))
    }

    func testSpeakerDiarizationSettingPersistsAndNotifies() throws {
        let host = try PluginTestHostServices()
        let plugin = AssemblyAIPlugin()

        plugin.activate(host: host)

        XCTAssertFalse(plugin.isSpeakerDiarizationEnabled)
        XCTAssertTrue(plugin.supportsStreaming)

        plugin.setSpeakerDiarizationEnabled(true)

        XCTAssertTrue(plugin.isSpeakerDiarizationEnabled)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(host.userDefault(forKey: AssemblyAIPlugin.speakerDiarizationEnabledKey) as? Bool, true)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setSpeakerDiarizationEnabled(true)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        let reloadedPlugin = AssemblyAIPlugin()
        reloadedPlugin.activate(host: host)
        XCTAssertTrue(reloadedPlugin.isSpeakerDiarizationEnabled)
        XCTAssertFalse(reloadedPlugin.supportsStreaming)
    }

    func testSubmitBodyIncludesSpeakerLabelsOnlyWhenEnabled() {
        var disabledBody = AssemblyAIPlugin.makeSubmitTranscriptionBody(
            audioURL: "https://example.test/audio.wav",
            modelId: AssemblyAIPlugin.universal35ProModelId,
            language: nil,
            prompt: nil,
            speakerDiarizationEnabled: false
        )
        XCTAssertNil(disabledBody["speaker_labels"])

        var enabledBody = AssemblyAIPlugin.makeSubmitTranscriptionBody(
            audioURL: "https://example.test/audio.wav",
            modelId: AssemblyAIPlugin.universal35ProModelId,
            language: "en",
            prompt: nil,
            speakerDiarizationEnabled: true
        )
        XCTAssertEqual(enabledBody["speaker_labels"] as? Bool, true)
        XCTAssertEqual(enabledBody["language_code"] as? String, "en")
        XCTAssertEqual(
            enabledBody["speech_models"] as? [String],
            [AssemblyAIPlugin.universal35ProModelId]
        )

        AssemblyAIPlugin.applyDictionaryTerms(
            prompt: "TypeWhisper",
            modelId: AssemblyAIPlugin.universal35ProModelId,
            to: &disabledBody
        )
        AssemblyAIPlugin.applyDictionaryTerms(
            prompt: "TypeWhisper",
            modelId: AssemblyAIPlugin.universal35ProModelId,
            to: &enabledBody
        )
        XCTAssertEqual(disabledBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
        XCTAssertEqual(enabledBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
    }

    func testSubmitBodyCanonicalizesLegacyModelId() {
        let body = AssemblyAIPlugin.makeSubmitTranscriptionBody(
            audioURL: "https://example.test/audio.wav",
            modelId: AssemblyAIPlugin.legacyUniversal3ProModelId,
            language: nil,
            prompt: "TypeWhisper",
            speakerDiarizationEnabled: false
        )

        XCTAssertEqual(body["speech_models"] as? [String], [AssemblyAIPlugin.universal35ProModelId])
        XCTAssertEqual(body["keyterms_prompt"] as? [String], ["TypeWhisper"])
        XCTAssertNil(body["word_boost"])
    }

    func testUniversal2SubmitBodyUsesWordBoost() {
        let body = AssemblyAIPlugin.makeSubmitTranscriptionBody(
            audioURL: "https://example.test/audio.wav",
            modelId: AssemblyAIPlugin.universal2ModelId,
            language: "en",
            prompt: "TypeWhisper",
            speakerDiarizationEnabled: false
        )

        XCTAssertEqual(body["speech_models"] as? [String], [AssemblyAIPlugin.universal2ModelId])
        XCTAssertEqual(body["word_boost"] as? [String], ["TypeWhisper"])
        XCTAssertEqual(body["boost_param"] as? String, "high")
        XCTAssertNil(body["keyterms_prompt"])
    }

    func testUniversal35StreamingURLUsesModelLanguageAndKeyterms() throws {
        let url = try XCTUnwrap(AssemblyAIPlugin.makeStreamingURL(
            modelId: AssemblyAIPlugin.universal35ProModelId,
            language: "DE",
            keytermsPromptJSON: #"["TypeWhisper"]"#
        ))
        let query = Self.queryItems(in: url)

        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["speech_model"], AssemblyAIPlugin.universal35ProModelId)
        XCTAssertEqual(query["language_codes"], #"["de"]"#)
        XCTAssertEqual(query["keyterms_prompt"], #"["TypeWhisper"]"#)
        XCTAssertNil(query["format_turns"])
    }

    func testUniversal35StreamingURLOmitsUnsupportedOrAutomaticLanguage() throws {
        let automaticURL = try XCTUnwrap(AssemblyAIPlugin.makeStreamingURL(
            modelId: AssemblyAIPlugin.universal35ProModelId,
            language: nil,
            keytermsPromptJSON: nil
        ))
        let unsupportedURL = try XCTUnwrap(AssemblyAIPlugin.makeStreamingURL(
            modelId: AssemblyAIPlugin.universal35ProModelId,
            language: "ru",
            keytermsPromptJSON: nil
        ))

        XCTAssertNil(Self.queryItems(in: automaticURL)["language_codes"])
        XCTAssertNil(Self.queryItems(in: unsupportedURL)["language_codes"])
    }

    func testUniversal2StreamingURLPreservesEnglishAndMultilingualModels() throws {
        let englishURL = try XCTUnwrap(AssemblyAIPlugin.makeStreamingURL(
            modelId: AssemblyAIPlugin.universal2ModelId,
            language: "en",
            keytermsPromptJSON: nil
        ))
        let multilingualURL = try XCTUnwrap(AssemblyAIPlugin.makeStreamingURL(
            modelId: AssemblyAIPlugin.universal2ModelId,
            language: "de",
            keytermsPromptJSON: nil
        ))
        let englishQuery = Self.queryItems(in: englishURL)
        let multilingualQuery = Self.queryItems(in: multilingualURL)

        XCTAssertEqual(englishQuery["speech_model"], "universal-streaming-english")
        XCTAssertEqual(englishQuery["format_turns"], "true")
        XCTAssertNil(englishQuery["language_codes"])
        XCTAssertEqual(multilingualQuery["speech_model"], "universal-streaming-multilingual")
        XCTAssertEqual(multilingualQuery["format_turns"], "true")
        XCTAssertNil(multilingualQuery["language_codes"])
    }

    func testLegacyStreamingModelIdUsesUniversal35Pro() throws {
        let url = try XCTUnwrap(AssemblyAIPlugin.makeStreamingURL(
            modelId: AssemblyAIPlugin.legacyUniversal3ProModelId,
            language: "en",
            keytermsPromptJSON: nil
        ))
        let query = Self.queryItems(in: url)

        XCTAssertEqual(query["speech_model"], AssemblyAIPlugin.universal35ProModelId)
        XCTAssertNil(query["format_turns"])
    }

    func testCompletedResponseBuildsSpeakerLabeledStructuredSegments() {
        let json: [String: Any] = [
            "text": "fallback text",
            "language_code": "en",
            "utterances": [
                [
                    "speaker": "A",
                    "text": "Hello",
                    "start": 250,
                    "end": 1500,
                    "confidence": 0.93,
                ],
                [
                    "speaker": "B",
                    "text": "Hi",
                    "start": 1500,
                    "end": 2750,
                ],
            ],
        ]

        let result = AssemblyAIPlugin.parseCompletedTranscriptionResponse(json)

        XCTAssertEqual(result.text, "Speaker A: Hello\nSpeaker B: Hi")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "Hello")
        XCTAssertEqual(result.segments[0].start, 0.25)
        XCTAssertEqual(result.segments[0].end, 1.5)
        XCTAssertEqual(result.segments[0].speakerLabel, "Speaker A")
        XCTAssertEqual(result.segments[0].speakerConfidence, 0.93)
        XCTAssertEqual(result.segments[1].speakerLabel, "Speaker B")
        XCTAssertNil(result.segments[1].speakerConfidence)
    }

    func testCompletedResponseFallsBackToPlainTextWithoutUtterances() {
        let result = AssemblyAIPlugin.parseCompletedTranscriptionResponse([
            "text": "plain transcript",
            "language_code": "de",
        ])

        XCTAssertEqual(result.text, "plain transcript")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testDiarizationRESTTranscriptionPreservesMultipleSpeakers() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)
        plugin.setSpeakerDiarizationEnabled(true)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"upload_url":"https://cdn.example.test/audio.m4a"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 200)
                ),
                .success(
                    Data(#"{"id":"transcript_diarized"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript", statusCode: 200)
                ),
                .success(
                    Data(
                        #"""
                        {
                          "status": "completed",
                          "text": "fallback text",
                          "language_code": "en",
                          "utterances": [
                            {"speaker":"A","text":"Hello","start":0,"end":900,"confidence":0.97},
                            {"speaker":"B","text":"Hi","start":900,"end":1500,"confidence":0.91}
                          ]
                        }
                        """#.utf8
                    ),
                    Self.httpResponse(
                        url: "https://api.assemblyai.com/v2/transcript/transcript_diarized",
                        statusCode: 200
                    )
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribeStructured(
            audio: audio,
            language: "en",
            translate: false,
            prompt: "TypeWhisper"
        )

        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(result.text, "Speaker A: Hello\nSpeaker B: Hi")
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker A", "Speaker B"])
        XCTAssertEqual(result.segments.map(\.speakerConfidence), [0.97, 0.91])

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        let submitBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[1].httpBody)) as? [String: Any]
        )
        XCTAssertEqual(submitBody["speaker_labels"] as? Bool, true)
        XCTAssertEqual(
            submitBody["speech_models"] as? [String],
            [AssemblyAIPlugin.universal35ProModelId]
        )
    }

    func testRESTTranscriptionUploadsCompressedM4A() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"upload_url":"https://cdn.example.test/audio.m4a"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 200)
                ),
                .success(
                    Data(#"{"id":"transcript_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript", statusCode: 200)
                ),
                .success(
                    Data(#"{"status":"completed","text":"hello","language_code":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript/transcript_123", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello")
        let uploadRequest = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(uploadRequest.url?.path, "/v2/upload")
        XCTAssertEqual(uploadRequest.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        let uploadBody = try XCTUnwrap(uploadRequest.httpBody)
        XCTAssertTrue(String(decoding: uploadBody.prefix(64), as: UTF8.self).contains("ftyp"))
        XCTAssertNotEqual(uploadBody, audio.wavData)
    }

    func testRESTTranscriptionRetriesUploadWithWavWhenM4ARejected() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"could not process file - is it a valid media file?"}}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 400)
                ),
                .success(
                    Data(#"{"upload_url":"https://cdn.example.test/audio.wav"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 200)
                ),
                .success(
                    Data(#"{"id":"transcript_123"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript", statusCode: 200)
                ),
                .success(
                    Data(#"{"status":"completed","text":"hello wav","language_code":"de"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/transcript/transcript_123", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello wav")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/v2/upload",
            "/v2/upload",
            "/v2/transcript",
            "/v2/transcript/transcript_123",
        ])

        let firstUploadBody = try XCTUnwrap(requests[0].httpBody)
        XCTAssertTrue(String(decoding: firstUploadBody.prefix(64), as: UTF8.self).contains("ftyp"))
        let retryUploadBody = try XCTUnwrap(requests[1].httpBody)
        XCTAssertEqual(retryUploadBody, audio.wavData)

        let submitBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[2].httpBody)) as? [String: Any]
        )
        XCTAssertEqual(submitBody["audio_url"] as? String, "https://cdn.example.test/audio.wav")
        XCTAssertEqual(submitBody["language_code"] as? String, "de")
        XCTAssertEqual(submitBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
        XCTAssertEqual(
            submitBody["speech_models"] as? [String],
            [AssemblyAIPlugin.universal35ProModelId]
        )
    }

    private static func queryItems(in url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
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

private extension AssemblyAIPlugin {
    static var universal35ProModelId: String { AssemblyAIModelCatalog.universal35Pro.id }
    static var universal2ModelId: String { AssemblyAIModelCatalog.universal2.id }
    static var legacyUniversal3ProModelId: String { AssemblyAIModelCatalog.legacyUniversal3ProModelId }
}
