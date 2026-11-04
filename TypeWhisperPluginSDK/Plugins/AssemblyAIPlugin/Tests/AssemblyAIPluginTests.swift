import XCTest
import os
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

    func testFallsBackToAsyncUploadOfCompressedM4AWhenSyncFails() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                Self.syncUnavailableOutcome,
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
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.first?.url?.host, "sync.assemblyai.com")
        let uploadRequest = requests[1]
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
                Self.syncUnavailableOutcome,
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
            "/v1/transcribe",
            "/v2/upload",
            "/v2/upload",
            "/v2/transcript",
            "/v2/transcript/transcript_123",
        ])

        let firstUploadBody = try XCTUnwrap(requests[1].httpBody)
        XCTAssertTrue(String(decoding: firstUploadBody.prefix(64), as: UTF8.self).contains("ftyp"))
        let retryUploadBody = try XCTUnwrap(requests[2].httpBody)
        XCTAssertEqual(retryUploadBody, audio.wavData)

        let submitBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(requests[3].httpBody)) as? [String: Any]
        )
        XCTAssertEqual(submitBody["audio_url"] as? String, "https://cdn.example.test/audio.wav")
        XCTAssertEqual(submitBody["language_code"] as? String, "de")
        XCTAssertEqual(submitBody["keyterms_prompt"] as? [String], ["TypeWhisper"])
        XCTAssertEqual(
            submitBody["speech_models"] as? [String],
            [AssemblyAIPlugin.universal35ProModelId]
        )
    }

    func testFinishedRecordingUsesSyncAPIWithExplicitLanguageAndKeyterms() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"Hallo TypeWhisper","words":[],"confidence":0.9,"audio_duration_ms":1000,"session_id":"s"}"#.utf8),
                    Self.httpResponse(url: "https://sync.assemblyai.com/v1/transcribe", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
        let result = try await plugin.transcribeStructured(
            audio: audio,
            language: "de",
            translate: false,
            prompt: "TypeWhisper"
        )

        XCTAssertEqual(result.text, "Hallo TypeWhisper")
        XCTAssertEqual(result.detectedLanguage, "de")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 1)
        let request = requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://sync.assemblyai.com/v1/transcribe")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "assembly-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-AAI-Model"), "universal-3-5-pro")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="audio"; filename="audio.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(body.contains(#"{"keyterms_prompt":["TypeWhisper"],"language_codes":["de"]}"#))
    }

    func testSyncAPIIsSkippedWhenTheAsyncAPIKeepsMoreOfTheRequest() {
        let model = AssemblyAIPlugin.universal35ProModelId
        func request(
            modelId: String = model,
            language: String? = "de",
            prompt: String? = nil,
            speakerLabels: Bool = false,
            duration: TimeInterval = 10
        ) -> AssemblyAIPlugin.SyncRequest? {
            AssemblyAIPlugin.makeSyncRequest(
                modelId: modelId,
                language: language,
                prompt: prompt,
                speakerDiarizationEnabled: speakerLabels,
                audioDuration: duration
            )
        }

        XCTAssertEqual(request()?.language, "de")
        XCTAssertEqual(request(language: nil)?.language, .some(nil))
        XCTAssertNotNil(request(duration: 20 * 60))
        XCTAssertNil(request(modelId: AssemblyAIPlugin.universal2ModelId))
        XCTAssertNil(request(speakerLabels: true))
        XCTAssertNil(request(duration: 20 * 60 + 1))
        XCTAssertNil(request(language: "pl"))
        let manyTerms = (1...101).map { "Term\($0)" }.joined(separator: ", ")
        XCTAssertNil(request(prompt: manyTerms))
    }

    func testLiveSessionsStreamUniversal35ProWithoutSpeakerLabelsOnly() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        XCTAssertNotNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: AssemblyAIPlugin.universal2ModelId))
        XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)
        XCTAssertEqual(plugin.liveTranscriptionProgressMode, .completeSnapshot)

        XCTAssertTrue(plugin.supportsStreaming)

        plugin.setSpeakerDiarizationEnabled(true)
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)
        plugin.setSpeakerDiarizationEnabled(false)

        // Sync and async cost what their price says: no live session and no preview.
        for mode in [AssemblyAITranscriptionMode.sync, .async] {
            plugin.setTranscriptionMode(mode)
            XCTAssertEqual(host.userDefault(forKey: AssemblyAIPlugin.transcriptionModeKey) as? String, mode.rawValue)
            XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
            XCTAssertFalse(plugin.supportsStreaming)
            XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)
        }

        // Universal-2 has only the async API and keeps its preview in every mode.
        plugin.selectModel(AssemblyAIPlugin.universal2ModelId)
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)
        plugin.setTranscriptionMode(.live)
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)
    }

    func testAsyncModeTranscribesRecordingsWithoutTheSyncAPI() async throws {
        let host = try PluginTestHostServices(
            defaults: [AssemblyAIPlugin.transcriptionModeKey: "async"],
            secrets: ["api-key": "assembly-key"]
        )
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)
        XCTAssertEqual(plugin.transcriptionMode, .async)

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
        let progress = LiveProgressRecorder()
        let result = try await plugin.transcribe(
            audio: audio,
            language: "en",
            translate: false,
            prompt: nil,
            onProgress: { progress.append($0); return true }
        )

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(progress.values, ["hello"])
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/v2/upload", "/v2/transcript", "/v2/transcript/transcript_123"])
    }

    func testLiveSessionStreamsFramesAndFinishesWithTheTurnsBeforeTermination() async throws {
        let socket = FakeAssemblyAIRealtimeSocket(terminateAnswers: [
            Self.turn(1, "Danke euch!", final: true, words: [("Danke", 2_100, 2_400), ("euch!", 2_450, 2_800)]),
            #"{"type":"Termination","audio_duration_seconds":3,"session_duration_seconds":4}"#,
        ])
        let progress = LiveProgressRecorder()
        let session = try await AssemblyAILiveTranscriptionSession.connect(
            socket: socket,
            language: "de",
            finalTranscriber: nil,
            onProgress: { progress.append($0); return true }
        )

        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 20_000))
        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 500))
        XCTAssertEqual(socket.audioFrameSampleCounts, [16_000, 4_000])

        await session.handle(Self.turn(0, "Hallo Team", final: false))
        await session.handle(Self.turn(0, "Hallo Team.", final: true, words: [("Hallo", 100, 400), ("Team.", 450, 900)]))
        await session.handle(Self.turn(1, "Danke", final: false))
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hallo Team. Danke euch!")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.map(\.text), ["Hallo Team.", "Danke euch!"])
        XCTAssertEqual(result.segments.map(\.start), [0.1, 2.1])
        XCTAssertEqual(progress.values, ["Hallo Team", "Hallo Team.", "Hallo Team. Danke", "Hallo Team. Danke euch!"])
        // The rest of the audio goes out padded to the shortest frame, then Terminate.
        XCTAssertEqual(socket.audioFrameSampleCounts, [16_000, 4_000, 800])
        XCTAssertEqual(socket.textMessages, [#"{"type":"Terminate"}"#])
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionFailsWhenAssemblyAIReportsAnErrorOrNeverEndsTheSession() async throws {
        let failing = FakeAssemblyAIRealtimeSocket(terminateAnswers: [])
        let failingSession = try await AssemblyAILiveTranscriptionSession.connect(
            socket: failing,
            language: nil,
            finalTranscriber: nil,
            onProgress: { _ in true }
        )
        await failingSession.handle(#"{"type":"Error","error_code":3005,"error":"Input duration violation"}"#)
        do {
            try await failingSession.appendAudio(samples: [Float](repeating: 0.2, count: 1_600))
            XCTFail("Expected the session to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Input duration violation (3005)"))
        }
        XCTAssertTrue(failing.isClosed)

        // The server closes without Termination: the end of the speech may be missing.
        let closing = FakeAssemblyAIRealtimeSocket(terminateAnswers: [], closesOnTerminate: true)
        let closingSession = try await AssemblyAILiveTranscriptionSession.connect(
            socket: closing,
            language: nil,
            finalTranscriber: nil,
            onProgress: { _ in true }
        )
        await closingSession.handle(Self.turn(0, "Partial words", final: false))
        do {
            _ = try await closingSession.finish()
            XCTFail("Expected the session to fail")
        } catch {
            XCTAssertTrue(closing.isClosed)
        }
    }

    func testLiveSessionFinishesWithoutTerminationOnlyWhenTheAudioAfterTheLastWordIsQuiet() async throws {
        func finish(
            loud: Int,
            quiet: Int,
            lastWordEndMs: Int,
            turnBeforeTerminate: Bool = false
        ) async throws -> (String?, FakeAssemblyAIRealtimeSocket) {
            let turn = Self.turn(0, "Hello there.", final: true, words: [("Hello", 100, 400), ("there.", 450, lastWordEndMs)])
            let socket = FakeAssemblyAIRealtimeSocket(
                terminateAnswers: turnBeforeTerminate ? [] : [turn],
                closesOnTerminate: true
            )
            let session = try await AssemblyAILiveTranscriptionSession.connect(
                socket: socket,
                language: "en",
                finalTranscriber: nil,
                onProgress: { _ in true }
            )
            try await session.appendAudio(samples: [Float](repeating: 0.2, count: loud) + [Float](repeating: 0, count: quiet))
            if turnBeforeTerminate {
                await session.handle(turn)
            }
            // The socket closes right after its answer and never sends Termination.
            let text = try? await session.finish().text
            return (text, socket)
        }

        // The last word ends where the speech ends: nothing else can follow.
        var (text, socket) = try await finish(loud: 16_000, quiet: 0, lastWordEndMs: 900)
        XCTAssertEqual(text, "Hello there.")
        XCTAssertTrue(socket.isClosed)

        // A long pause before the stop is quiet, whichever message ended the turn.
        (text, _) = try await finish(loud: 8_000, quiet: 16_000, lastWordEndMs: 500, turnBeforeTerminate: true)
        XCTAssertEqual(text, "Hello there.")

        // Sound after the last word may be a short word whose turn is still on its way,
        // so only Termination completes the transcript, and a closed socket fails it.
        (text, socket) = try await finish(loud: 16_000, quiet: 0, lastWordEndMs: 700)
        XCTAssertNil(text)
        XCTAssertTrue(socket.isClosed)
        (text, _) = try await finish(loud: 16_000, quiet: 0, lastWordEndMs: 400, turnBeforeTerminate: true)
        XCTAssertNil(text)
    }

    func testLiveSessionWithMoreDictionaryTermsThanTheRealtimeAPITakesUsesTheRecording() async throws {
        let terms = (1...101).map { "Term\($0)" }
        let keyterms = AssemblyAIPlugin.streamingKeyterms(
            fromPrompt: (terms + [String(repeating: "x", count: 51)]).joined(separator: ", "),
            modelId: AssemblyAIPlugin.universal35ProModelId
        )
        XCTAssertEqual(keyterms.terms, Array(terms.prefix(100)))
        XCTAssertEqual(keyterms.droppedCount, 2)

        let socket = FakeAssemblyAIRealtimeSocket(terminateAnswers: [
            Self.turn(0, "realtime text", final: true),
            #"{"type":"Termination"}"#,
        ])
        let recordedSampleCount = SampleCountRecorder()
        let session = try await AssemblyAILiveTranscriptionSession.connect(
            socket: socket,
            language: "en",
            finalTranscriber: { audio in
                recordedSampleCount.set(audio.samples.count)
                return PluginTranscriptionResult(text: "Term101 from the recording", detectedLanguage: "en")
            },
            onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 1_000))
        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 1_000))
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Term101 from the recording")
        XCTAssertEqual(recordedSampleCount.value, 2_000)
        XCTAssertEqual(socket.textMessages, [#"{"type":"Terminate"}"#])
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionJoinsChineseAndJapaneseTurnsWithoutSpaces() {
        XCTAssertEqual(AssemblyAILiveTranscriptionSession.joinedText(["你好。", "谢谢。"]), "你好。谢谢。")
        XCTAssertEqual(AssemblyAILiveTranscriptionSession.joinedText(["Hello.", "", "  Thanks. "]), "Hello. Thanks.")
    }

    func testPollingBudgetGrowsWithTheRecordingUpToAnHour() {
        XCTAssertEqual(AssemblyAIPlugin.pollAttempts(forAudioDuration: 1), 300)
        XCTAssertEqual(AssemblyAIPlugin.pollAttempts(forAudioDuration: 20 * 60), 300)
        XCTAssertEqual(AssemblyAIPlugin.pollAttempts(forAudioDuration: 2 * 3_600), 1_800)
        XCTAssertEqual(AssemblyAIPlugin.pollAttempts(forAudioDuration: 4 * 3_600), 3_600)
        XCTAssertEqual(AssemblyAIPlugin.pollAttempts(forAudioDuration: 10 * 3_600), 3_600)
    }

    func testLargeUploadRunsOnADedicatedSessionWithTheLongerTimeout() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "assembly-key"])
        let plugin = AssemblyAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        let resourceTimeouts = TimeIntervalRecorder()
        PluginHTTPClientTestHarness.configure { configuration in
            resourceTimeouts.append(configuration.timeoutIntervalForResource)
            guard configuration.timeoutIntervalForResource > 600 else {
                return store.makeSession(outcomes: [
                    Self.syncUnavailableOutcome,
                    .success(
                        Data(#"{"error":{"message":"could not process file - is it a valid media file?"}}"#.utf8),
                        Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 400)
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
            return store.makeSession(outcomes: [
                .success(
                    Data(#"{"upload_url":"https://cdn.example.test/audio.wav"}"#.utf8),
                    Self.httpResponse(url: "https://api.assemblyai.com/v2/upload", statusCode: 200)
                ),
            ])
        }

        // The WAV fallback uploads `wavData` as it is, so 20 MB of it stand in
        // for a long recording without encoding one.
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: Data(count: 20_000_000), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello")
        let sessions = store.sessions
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.requestedPaths, ["/v1/transcribe", "/v2/upload", "/v2/transcript", "/v2/transcript/transcript_123"])
        let uploadSession = try XCTUnwrap(sessions.last)
        XCTAssertEqual(uploadSession.requestedPaths, ["/v2/upload"])
        XCTAssertTrue(uploadSession.didInvalidate)
        XCTAssertEqual(resourceTimeouts.values, [600, 925])
    }

    private static func queryItems(in url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    /// A sync failure that is neither an auth error nor an audio format problem, so the
    /// plugin moves straight on to the async API. A 522 is one the HTTP client would
    /// otherwise send again; the tests' request paths show the Sync POST goes out once.
    private static var syncUnavailableOutcome: PluginHTTPClientTestOutcome {
        .success(
            Data(#"{"status":522,"title":"Connection timed out"}"#.utf8),
            httpResponse(url: "https://sync.assemblyai.com/v1/transcribe", statusCode: 522)
        )
    }

    private static func turn(
        _ order: Int,
        _ transcript: String,
        final: Bool,
        words: [(String, Int, Int)] = []
    ) -> String {
        let wordObjects: [[String: Any]] = words.map { ["text": $0.0, "start": $0.1, "end": $0.2, "confidence": 0.9, "word_is_final": final] }
        let json: [String: Any] = [
            "type": "Turn",
            "turn_order": order,
            "transcript": transcript,
            "end_of_turn": final,
            "turn_is_formatted": final,
            "words": wordObjects,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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

private final class TimeIntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.withLock { storage }
    }

    func append(_ value: TimeInterval) {
        lock.withLock {
            storage.append(value)
        }
    }
}

/// Plays AssemblyAI's realtime API: begins the session, records the audio frames and
/// text messages, and answers `Terminate` with the scripted messages.
private final class FakeAssemblyAIRealtimeSocket: AssemblyAIRealtimeSocket, @unchecked Sendable {
    private struct State {
        var frameSampleCounts: [Int] = []
        var textMessages: [String] = []
        var terminateAnswers: [String]
        var closesOnTerminate: Bool
        var isClosed = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(terminateAnswers: [String], closesOnTerminate: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(
            terminateAnswers: terminateAnswers,
            closesOnTerminate: closesOnTerminate
        ))
        (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(#"{"type":"Begin","id":"test","expires_at":0}"#)
    }

    var audioFrameSampleCounts: [Int] { state.withLock { $0.frameSampleCounts } }
    var textMessages: [String] { state.withLock { $0.textMessages } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    func send(text: String) async throws {
        let (answers, closes) = state.withLock { state -> ([String], Bool) in
            state.textMessages.append(text)
            guard text.contains("Terminate") else { return ([], false) }
            return (state.terminateAnswers, state.closesOnTerminate)
        }
        answers.forEach { continuation.yield($0) }
        if closes {
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
    }

    func send(audio: Data) async throws {
        state.withLock { $0.frameSampleCounts.append(audio.count / 2) }
    }

    func receive() async throws -> String {
        var iterator = stream.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw URLError(.cancelled) }
        return message
    }

    func close() {
        state.withLock { $0.isClosed = true }
        continuation.finish()
    }
}

private final class LiveProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class SampleCountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int?

    var value: Int? { lock.withLock { storage } }

    func set(_ value: Int) {
        lock.withLock { storage = value }
    }
}

private extension AssemblyAIPlugin {
    static var universal35ProModelId: String { AssemblyAIModelCatalog.universal35Pro.id }
    static var universal2ModelId: String { AssemblyAIModelCatalog.universal2.id }
    static var legacyUniversal3ProModelId: String { AssemblyAIModelCatalog.legacyUniversal3ProModelId }
}
