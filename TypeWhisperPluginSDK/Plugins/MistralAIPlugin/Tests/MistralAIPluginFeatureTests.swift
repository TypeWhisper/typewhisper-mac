import XCTest
import os
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import MistralAIPlugin

final class MistralAIPluginFeatureTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    // MARK: - Model Catalog

    /// A shortened `GET /v1/models` answer with the cases the catalog has to sort out.
    static let modelListJSON = #"""
    {"object":"list","data":[
      {"id":"mistral-small-2603","name":"mistral-small-2603","description":"Mistral Small 4.","aliases":["mistral-small-latest","magistral-small-latest"],"capabilities":{"completion_chat":true,"reasoning":true}},
      {"id":"mistral-small-latest","name":"mistral-small-2603","description":"Mistral Small 4.","aliases":["mistral-small-2603","magistral-small-latest"],"capabilities":{"completion_chat":true,"reasoning":true}},
      {"id":"mistral-large-4-0","name":"mistral-large-4","description":"Mistral Large 4.0","aliases":["mistral-large-4"],"capabilities":{"completion_chat":true,"reasoning":true}},
      {"id":"mistral-medium-latest","name":"mistral-medium-latest","aliases":["mistral-medium-2604","mistral-medium-3-5"],"capabilities":{"completion_chat":true,"reasoning":true}},
      {"id":"mistral-medium-2604","name":"mistral-medium-latest","aliases":["mistral-medium-latest","mistral-medium-3-5"],"capabilities":{"completion_chat":true,"reasoning":true}},
      {"id":"ministral-8b-2512","name":"ministral-8b-2512","aliases":["ministral-8b-latest"],"capabilities":{"completion_chat":true}},
      {"id":"mistral-new-2701","name":"mistral-new-2701","description":"Mistral New 1.","aliases":["mistral-new-latest"],"capabilities":{"completion_chat":true}},
      {"id":"mistral-old-2401","name":"mistral-old-2401","deprecation":"2020-01-01T00:00:00Z","capabilities":{"completion_chat":true}},
      {"id":"codestral-2508","name":"codestral-2508","capabilities":{"completion_chat":true,"completion_fim":true}},
      {"id":"labs-leanstral-1-5-1","name":"labs-leanstral-1-5-1","capabilities":{"completion_chat":true}},
      {"id":"mistral-ocr-2512","name":"Mistral OCR 3.0","capabilities":{"ocr":true,"vision":true}},
      {"id":"voxtral-small-2507","name":"Voxtral Small Transcribe","aliases":["voxtral-small-latest"],"capabilities":{"completion_chat":true,"audio":true}},
      {"id":"mistral-embed","name":"mistral-embed","capabilities":{}},
      {"id":"voxtral-mini-2602","name":"Voxtral Mini Transcribe","aliases":["voxtral-mini-latest"],"capabilities":{"audio_transcription":true},"audio_transcription_capabilities":{"modes":["offline"],"diarization":true,"context_bias":true,"languages":["en","de"]}},
      {"id":"voxtral-mini-transcribe-3-0","name":"Voxtral Mini Transcribe 3.0","aliases":["voxtral-mini-transcribe-3"],"capabilities":{"audio_transcription":true},"audio_transcription_capabilities":{"modes":["offline"],"diarization":true,"context_bias":true,"languages":["en","de","fr"]}},
      {"id":"voxtral-small-transcribe-3-0","name":"Voxtral Small Transcribe 3.0","aliases":["voxtral-small-transcribe-3"],"capabilities":{"audio_transcription":true},"audio_transcription_capabilities":{"modes":["offline"],"diarization":true,"context_bias":true,"languages":["en","de","fr","mt"]}},
      {"id":"voxtral-future-4","name":"Voxtral Future Transcribe 4","capabilities":{"audio_transcription":true},"audio_transcription_capabilities":{"modes":["offline"],"diarization":false,"context_bias":false,"languages":["en"]}},
      {"id":"voxtral-mini-transcribe-realtime-2602","name":"Voxtral Mini Transcribe Realtime","aliases":["voxtral-mini-realtime-latest"],"capabilities":{"audio_transcription_realtime":true},"audio_transcription_capabilities":{"modes":["realtime"],"languages":["en"]}},
      {"id":"voxtral-mini-transcribe-realtime-3-0","name":"Voxtral Mini Transcribe Realtime 3.0","aliases":["voxtral-mini-transcribe-realtime-3"],"capabilities":{"audio_transcription_realtime":true},"audio_transcription_capabilities":{"modes":["realtime"],"diarization":true,"context_bias":true,"languages":["en","de","fr"]}}
    ]}
    """#

    static func fixtureCatalog() throws -> MistralModelCatalog {
        struct ModelsResponse: Decodable { let data: [MistralCatalogEntry] }
        let entries = try JSONDecoder().decode(ModelsResponse.self, from: Data(modelListJSON.utf8)).data
        return MistralModelCatalog.from(entries: entries)
    }

    func testCatalogKeepsOneEntryPerModelAndDropsReplacedAndSpecialModels() throws {
        let catalog = try Self.fixtureCatalog()

        XCTAssertEqual(catalog.llmModels.map(\.id), [
            "mistral-large-4",
            "mistral-medium-2604",
            "mistral-small-2603",
            "ministral-8b-2512",
            "mistral-new-2701",
        ])
        XCTAssertEqual(catalog.llmModels.map(\.displayName), [
            "Mistral Large 4",
            "Mistral Medium 3.5",
            "Mistral Small 4",
            "Ministral 3 8B",
            "Mistral New 1",
        ])
        XCTAssertEqual(catalog.llmModel("mistral-medium-latest")?.id, "mistral-medium-2604")
        XCTAssertEqual(catalog.resolvedLLMModelId("magistral-small-latest"), "mistral-small-2603")
        XCTAssertEqual(catalog.resolvedLLMModelId("mistral-new-latest"), "mistral-new-2701")

        XCTAssertEqual(catalog.transcriptionModels.map(\.id), [
            "voxtral-mini-transcribe-3-0",
            "voxtral-small-transcribe-3-0",
            "voxtral-future-4",
        ])
        XCTAssertEqual(catalog.transcriptionModels.map(\.displayName), [
            "Voxtral Mini Transcribe 3",
            "Voxtral Small Transcribe 3",
            "Voxtral Future Transcribe 4",
        ])
        XCTAssertEqual(catalog.transcriptionModels[0].languages, ["en", "de", "fr"])
        XCTAssertFalse(catalog.transcriptionModels[2].supportsContextBias)
        XCTAssertEqual(catalog.realtimeModels.map(\.id), ["voxtral-mini-transcribe-realtime-3-0"])
        XCTAssertEqual(catalog.resolvedTranscriptionModelId("voxtral-mini-latest"), "voxtral-mini-transcribe-3-0")
    }

    func testANewModelThatTakesOverALatestAliasStaysInTheList() throws {
        struct ModelsResponse: Decodable { let data: [MistralCatalogEntry] }
        let json = #"""
        {"data":[
          {"id":"mistral-small-2603","name":"mistral-small-2603","description":"Mistral Small 4.","aliases":["magistral-small-latest"],"capabilities":{"completion_chat":true,"reasoning":true}},
          {"id":"mistral-small-2701","name":"mistral-small-2701","description":"Mistral Small 4.1.","aliases":["mistral-small-latest"],"capabilities":{"completion_chat":true,"reasoning":true}},
          {"id":"voxtral-mini-transcribe-3-0","name":"Voxtral Mini Transcribe 3.0","capabilities":{"audio_transcription":true},"audio_transcription_capabilities":{"modes":["offline"],"languages":["en"]}},
          {"id":"voxtral-mini-transcribe-4-0","name":"Voxtral Mini Transcribe 4.0","aliases":["voxtral-mini-latest","voxtral-mini-transcribe-latest"],"capabilities":{"audio_transcription":true},"audio_transcription_capabilities":{"modes":["offline"],"languages":["en"]}}
        ]}
        """#
        let entries = try JSONDecoder().decode(ModelsResponse.self, from: Data(json.utf8)).data
        let catalog = MistralModelCatalog.from(entries: entries)

        XCTAssertEqual(catalog.llmModels.map(\.id), ["mistral-small-2603", "mistral-small-2701"])
        XCTAssertEqual(catalog.llmModels.last?.displayName, "Mistral Small 4.1")
        XCTAssertEqual(catalog.resolvedLLMModelId("mistral-small-latest"), "mistral-small-2701")
        XCTAssertEqual(catalog.transcriptionModels.map(\.id), ["voxtral-mini-transcribe-3-0", "voxtral-mini-transcribe-4-0"])
    }

    func testModelListIsFetchedWithTheKey() async throws {
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(Self.modelListJSON.utf8), Self.httpResponse(url: "https://api.mistral.ai/v1/models", statusCode: 200)),
            ])
        }

        let catalog = try await MistralAPIClient(apiKey: "mistral-key").fetchModelCatalog()

        XCTAssertEqual(catalog.llmModels.first?.id, "mistral-large-4")
        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.mistral.ai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mistral-key")
    }

    func testFetchedModelListReplacesTheBuiltInListAndIsCached() async throws {
        let catalog = try Self.fixtureCatalog()
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin(catalogFetcher: { _ in catalog })
        plugin.activate(host: host)
        XCTAssertFalse(plugin.hasFetchedCatalog)
        XCTAssertFalse(plugin.supportedModels.map(\.id).contains("mistral-medium-2604"))

        XCTAssertFalse(plugin.applyFetchedCatalog(catalog, fetchedWith: "replaced-key"))
        let fetched = try await plugin.fetchCatalog(for: "mistral-key")
        XCTAssertTrue(plugin.applyFetchedCatalog(fetched, fetchedWith: "mistral-key"))

        XCTAssertTrue(plugin.supportedModels.map(\.id).contains("mistral-medium-2604"))
        XCTAssertEqual(plugin.transcriptionModels.map(\.id).last, "voxtral-future-4")
        XCTAssertNotNil(host.userDefault(forKey: MistralAIPlugin.modelCatalogDateKey) as? Date)

        let reloaded = MistralAIPlugin(catalogFetcher: { _ in XCTFail("A fresh cached list is not fetched again"); return catalog })
        reloaded.activate(host: host)
        XCTAssertTrue(reloaded.hasFetchedCatalog)
        XCTAssertEqual(reloaded.catalog, catalog)
        XCTAssertNil(reloaded.pendingCatalogRefresh)
    }

    func testStaleCachedModelListIsRefreshedOnActivation() async throws {
        let fixture = try Self.fixtureCatalog()
        let cached = MistralModelCatalog.builtIn
        let host = try PluginTestHostServices(
            defaults: [
                MistralAIPlugin.modelCatalogKey: try JSONEncoder().encode(cached),
                MistralAIPlugin.modelCatalogDateKey: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60),
            ],
            secrets: ["api-key": "mistral-key"]
        )
        let plugin = MistralAIPlugin(catalogFetcher: { key in
            XCTAssertEqual(key, "mistral-key")
            return fixture
        })
        plugin.activate(host: host)

        let refresh = try XCTUnwrap(plugin.pendingCatalogRefresh)
        await refresh.value
        XCTAssertEqual(plugin.catalog, fixture)
    }

    func testTranscriptionModelsComeFromTheSelectedModel() async throws {
        let catalog = try Self.fixtureCatalog()
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin(catalogFetcher: { _ in catalog })
        plugin.activate(host: host)
        plugin.applyFetchedCatalog(catalog, fetchedWith: "mistral-key")

        plugin.selectModel("voxtral-small-transcribe-3")
        XCTAssertEqual(plugin.selectedModelId, "voxtral-small-transcribe-3-0")
        XCTAssertEqual(plugin.supportedLanguages, ["en", "de", "fr", "mt"])
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)

        plugin.selectModel("voxtral-future-4")
        XCTAssertEqual(plugin.supportedLanguages, ["en"])
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
    }

    // MARK: - Dictionary Terms And Speakers

    func testDictionaryTermsAreSentAsContextBias() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        let store = Self.transcriptionStore(answers: [#"{"text":"Saoirse Ronan nutzt TypeWhisper.","language":"de"}"#])

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "de",
            translate: false,
            prompt: "Saoirse Ronan, TypeWhisper, saoirse ronan, Greta Gerwig"
        )

        XCTAssertEqual(result.text, "Saoirse Ronan nutzt TypeWhisper.")
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        let body = try Self.body(of: store, at: 0)
        XCTAssertEqual(Self.fieldValues("context_bias", in: body), ["Saoirse Ronan", "TypeWhisper", "Greta Gerwig"])
        XCTAssertEqual(Self.fieldValues("language", in: body), ["de"])
        XCTAssertFalse(body.contains("name=\"diarize\""))
    }

    func testSpeakerLabelsRequestSegmentsAndLabelTheText() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.setSpeakerDiarizationEnabled(true)
        XCTAssertEqual(host.userDefault(forKey: MistralAIPlugin.speakerDiarizationEnabledKey) as? Bool, true)
        let store = Self.transcriptionStore(answers: [#"""
        {"text":"Hello. Hi there.","language":"en","segments":[
          {"text":" Hello.","start":0.0,"end":1.2,"speaker_id":"speaker_1"},
          {"text":"How are you?","start":1.3,"end":2.0,"speaker_id":"speaker_1"},
          {"text":"Hi there.","start":2.4,"end":3.5,"speaker_id":"speaker_2"}
        ]}
        """#])

        let result = try await plugin.transcribeStructured(audio: Self.audio(), language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "Speaker 1: Hello. How are you?\nSpeaker 2: Hi there.")
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker 1", "Speaker 1", "Speaker 2"])
        XCTAssertEqual(result.segments.map(\.start), [0.0, 1.3, 2.4])
        XCTAssertEqual(result.detectedLanguage, "en")
        let body = try Self.body(of: store, at: 0)
        XCTAssertEqual(Self.fieldValues("diarize", in: body), ["true"])
        XCTAssertEqual(Self.fieldValues("timestamp_granularities", in: body), ["segment"])
        XCTAssertEqual(Self.fieldValues("return_language", in: body), ["true"])
    }

    func testRejectedRequestsShowMistralsMessage() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"object":"error","message":{"detail":[{"type":"assertion_error","loc":[],"msg":"Assertion failed, Cannot do language prediction if language is already set"}]},"type":"invalid_request_error","raw_status_code":422}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 422)
                ),
                .success(
                    Data(#"{"object":"error","message":"Rate limit exceeded","type":"rate_limited","code":"1300"}"#.utf8),
                    Self.httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 429)
                ),
            ])
        }

        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
            XCTFail("A 422 is an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "API Error: Cannot do language prediction if language is already set")
        }
        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
            XCTFail("A 429 is an error")
        } catch {
            XCTAssertTrue(error is PluginTranscriptionError, "\(error)")
        }
    }

    // MARK: - Modes

    func testModesDecideAboutLiveSessionsAndPreviews() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.transcriptionMode, .live)
        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: "voxtral-small-transcribe-3-0"))
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)
        XCTAssertEqual(plugin.liveTranscriptionProgressMode, .completeSnapshot)

        plugin.setSpeakerDiarizationEnabled(true)
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)

        plugin.setSpeakerDiarizationEnabled(false)
        plugin.setTranscriptionMode(.batch)
        XCTAssertEqual(host.userDefault(forKey: MistralAIPlugin.transcriptionModeKey) as? String, "batch")
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)

        let reloaded = MistralAIPlugin()
        reloaded.activate(host: host)
        XCTAssertEqual(reloaded.transcriptionMode, .batch)
    }

    // MARK: - Live Sessions

    func testLiveSessionSendsSettingsBeforeAudioAndTakesTheFinalTextFromTheUpload() async throws {
        let socket = FakeMistralRealtimeSocket(answers: [
            "session.update": [#"{"type":"session.updated","session":{}}"#],
            "input_audio.append": [#"{"type":"transcription.text.delta","text":"Servus"}"#, #"{"type":"transcription.text.delta","text":" Ronan"}"#],
            "input_audio.end": [#"{"type":"transcription.done","text":" Servus Ronan spielte.","language":"de"}"#],
        ])
        let requests = RequestRecorder()
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin(
            catalogFetcher: { _ in MistralModelCatalog.builtIn },
            realtimeSocketFactory: { request in
                requests.append(request)
                return socket
            }
        )
        plugin.activate(host: host)
        let store = Self.transcriptionStore(answers: [#"{"text":"Saoirse Ronan spielte."}"#])
        let progress = LiveProgressRecorder()

        let session = try await plugin.createLiveTranscriptionSession(
            language: "de",
            translate: false,
            prompt: "Saoirse Ronan, TypeWhisper",
            onProgress: { progress.append($0); return true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 4_000))
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Saoirse Ronan spielte.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(progress.values.last, "Servus Ronan")

        let request = try XCTUnwrap(requests.values.first)
        XCTAssertEqual(request.url?.absoluteString, "wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=voxtral-mini-transcribe-realtime-3-0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mistral-key")

        let messages = socket.sentMessages
        XCTAssertEqual(messages.map { $0["type"] as? String }, [
            "session.update", "input_audio.append", "input_audio.append", "input_audio.append", "input_audio.end",
        ])
        let settings = try XCTUnwrap(messages[0]["session"] as? [String: Any])
        XCTAssertEqual(settings["language"] as? String, "de")
        XCTAssertEqual(settings["context_bias"] as? [String], ["Saoirse Ronan", "TypeWhisper"])
        let format = try XCTUnwrap(settings["audio_format"] as? [String: Any])
        XCTAssertEqual(format["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(format["sample_rate"] as? Int, 16_000)
        let audioByteCounts = messages.compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0)?.count } }
        XCTAssertEqual(audioByteCounts, [3_200, 3_200, 1_600])
        XCTAssertTrue(socket.isClosed)

        // The whole recording goes to the transcription model with the same settings.
        let body = try Self.body(of: store, at: 0)
        XCTAssertEqual(Self.fieldValues("model", in: body), ["voxtral-mini-transcribe-3-0"])
        XCTAssertEqual(Self.fieldValues("language", in: body), ["de"])
        XCTAssertEqual(Self.fieldValues("context_bias", in: body), ["Saoirse Ronan", "TypeWhisper"])
    }

    func testLiveSessionKeepsTheRealtimeTextWhenTheUploadFails() async throws {
        let socket = FakeMistralRealtimeSocket(answers: [
            "session.update": [#"{"type":"session.updated","session":{}}"#],
            "input_audio.append": [#"{"type":"transcription.text.delta","text":"Hallo"}"#],
            "input_audio.end": [#"{"type":"transcription.done","text":"Hallo Welt.","language":"de"}"#],
        ])
        let session = try await MistralLiveTranscriptionSession.connect(
            socket: socket,
            language: nil,
            contextBias: [],
            finalTranscriber: { _ in throw PluginTranscriptionError.networkError("offline") },
            onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 1_600))
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hallo Welt.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionWithoutUploadReturnsTheRealtimeText() async throws {
        let socket = FakeMistralRealtimeSocket(answers: [
            "session.update": [#"{"type":"session.updated","session":{}}"#],
            "input_audio.end": [#"{"type":"transcription.done","text":" Hello there. "}"#],
        ])
        let session = try await MistralLiveTranscriptionSession.connect(
            socket: socket,
            language: "en",
            contextBias: [],
            onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 800))
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testLiveSessionLeavesOutLanguagesTheModelDoesNotList() async throws {
        let socket = FakeMistralRealtimeSocket(answers: [
            "session.update": [#"{"type":"session.updated","session":{}}"#],
        ])
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin(catalogFetcher: { _ in MistralModelCatalog.builtIn }, realtimeSocketFactory: { _ in socket })
        plugin.activate(host: host)

        let session = try await plugin.createLiveTranscriptionSession(language: "yue", translate: false, prompt: nil, onProgress: { _ in true })
        await session.cancel()

        let settings = try XCTUnwrap(socket.sentMessages.first?["session"] as? [String: Any])
        XCTAssertNil(settings["language"])
        XCTAssertNil(settings["context_bias"])
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionFailsWhenMistralRejectsTheSettings() async throws {
        let socket = FakeMistralRealtimeSocket(answers: [
            "session.update": [#"{"type":"error","error":{"message":"Invalid language alpha2 code","code":3051}}"#],
        ])

        do {
            _ = try await MistralLiveTranscriptionSession.connect(
                socket: socket,
                language: "de",
                contextBias: [],
                onProgress: { _ in true }
            )
            XCTFail("A rejected setting fails the session")
        } catch {
            XCTAssertEqual(error.localizedDescription, PluginTranscriptionError.apiError("Invalid language alpha2 code").localizedDescription)
        }
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionClosesTheSocketWhenTheSettingsCannotBeSent() async throws {
        let socket = FakeMistralRealtimeSocket(answers: [:], failsSending: true)

        do {
            _ = try await MistralLiveTranscriptionSession.connect(
                socket: socket,
                language: nil,
                contextBias: [],
                onProgress: { _ in true }
            )
            XCTFail("Settings that cannot be sent fail the session")
        } catch {
            XCTAssertTrue(error is PluginTranscriptionError, "\(error)")
        }
        XCTAssertTrue(socket.isClosed)
    }

    func testLiveSessionFailsWhenTheConnectionEndsBeforeTheTranscript() async throws {
        let socket = FakeMistralRealtimeSocket(
            answers: ["session.update": [#"{"type":"session.updated","session":{}}"#]],
            closesOnEnd: true
        )
        let session = try await MistralLiveTranscriptionSession.connect(
            socket: socket,
            language: nil,
            contextBias: [],
            onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 1_600))

        do {
            _ = try await session.finish()
            XCTFail("Without transcription.done the session has no final text")
        } catch {
            XCTAssertTrue(error is PluginTranscriptionError, "\(error)")
        }
    }

    // MARK: - Reasoning

    func testReasoningLevelsDependOnTheModel() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedEfforts(for: "mistral-large-4").map(\.id), ["low", "medium", "high"])
        XCTAssertEqual(plugin.supportedEfforts(for: "mistral-small-2603").map(\.id), ["none", "high"])
        XCTAssertEqual(plugin.supportedEfforts(for: "mistral-medium-2604").map(\.id), ["none", "high"])
        XCTAssertEqual(plugin.supportedEfforts(for: "ministral-14b-2512").map(\.id), [])
        XCTAssertEqual(plugin.supportedEfforts(for: nil).map(\.id), ["none", "high"])
        XCTAssertEqual(plugin.defaultEffortId(for: "mistral-large-4"), "low")
        XCTAssertEqual(plugin.defaultEffortId(for: "mistral-small-2603"), "none")
        XCTAssertNil(plugin.defaultEffortId(for: "ministral-14b-2512"))

        plugin.setReasoningEffort("high", forModelId: "mistral-small-2603")
        XCTAssertEqual(plugin.defaultEffortId(for: "mistral-small-latest"), "high")
        XCTAssertEqual(plugin.defaultEffortId(for: "mistral-large-4"), "low")
        XCTAssertEqual(
            host.userDefault(forKey: MistralAIPlugin.reasoningEffortsKey) as? [String: String],
            ["mistral-small-2603": "high"]
        )
    }

    func testReasoningEffortSentPerModel() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        plugin.setReasoningEffort("high", forModelId: "mistral-small-2603")
        let url = "https://api.mistral.ai/v1/chat/completions"
        let reply = #"{"choices":[{"message":{"content":"ok"}}]}"#
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: (0..<5).map { _ in .success(Data(reply.utf8), Self.httpResponse(url: url, statusCode: 200)) })
        }

        _ = try await plugin.process(systemPrompt: "s", userText: "u", model: "mistral-small-2603")
        _ = try await plugin.process(systemPrompt: "s", userText: "u", model: "mistral-small-2603", effort: "none")
        _ = try await plugin.process(systemPrompt: "s", userText: "u", model: "mistral-large-4", effort: "medium")
        _ = try await plugin.process(systemPrompt: "s", userText: "u", model: "ministral-3b-2512", effort: "high")
        _ = try await plugin.process(
            systemPrompt: "s",
            userText: "u",
            model: "mistral-large-4",
            temperatureDirective: PluginLLMTemperatureDirective(mode: .custom, value: 0.2),
            effort: nil
        )

        let bodies = try store.sessions[0].requestedRequests.map { request in
            try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        }
        XCTAssertEqual(bodies.map { $0["reasoning_effort"] as? String }, ["high", nil, "medium", nil, "low"])
        XCTAssertEqual(bodies[4]["temperature"] as? Double, 0.2)
    }

    func testRejectedKeyIsReportedForChat() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "mistral-key"])
        let plugin = MistralAIPlugin()
        plugin.activate(host: host)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"message":"Unauthorized"}"#.utf8), Self.httpResponse(url: "https://api.mistral.ai/v1/chat/completions", statusCode: 401)),
            ])
        }

        do {
            _ = try await plugin.process(systemPrompt: "s", userText: "u", model: nil)
            XCTFail("A 401 is an error")
        } catch PluginChatError.invalidApiKey {
        }
    }

    // MARK: - Helpers

    private static func audio() -> AudioData {
        let samples = [Float](repeating: 0.1, count: 16_000)
        return AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
    }

    private static func transcriptionStore(answers: [String]) -> PluginHTTPClientSessionStore {
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: answers.map {
                .success(Data($0.utf8), httpResponse(url: "https://api.mistral.ai/v1/audio/transcriptions", statusCode: 200))
            })
        }
        return store
    }

    private static func body(of store: PluginHTTPClientSessionStore, at index: Int) throws -> String {
        String(decoding: try XCTUnwrap(store.sessions[0].requestedRequests[index].httpBody), as: UTF8.self)
    }

    /// The values of every multipart field called `name`, in order.
    private static func fieldValues(_ name: String, in body: String) -> [String] {
        let marker = "name=\"\(name)\"\r\n\r\n"
        return body.components(separatedBy: marker).dropFirst().compactMap { part in
            part.components(separatedBy: "\r\n").first
        }
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

/// Plays Mistral's realtime API: opens with `session.created` and answers each sent
/// message type with scripted messages.
private final class FakeMistralRealtimeSocket: MistralRealtimeSocket, @unchecked Sendable {
    private struct State {
        var sent: [String] = []
        var answers: [String: [String]]
        var closesOnEnd: Bool
        var failsSending: Bool
        var isClosed = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(answers: [String: [String]], closesOnEnd: Bool = false, failsSending: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(answers: answers, closesOnEnd: closesOnEnd, failsSending: failsSending))
        (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(#"{"type":"session.created","session":{}}"#)
    }

    var sentMessages: [[String: Any]] {
        state.withLock { $0.sent }.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    var isClosed: Bool { state.withLock { $0.isClosed } }

    func send(text: String) async throws {
        if state.withLock({ $0.failsSending }) {
            throw URLError(.networkConnectionLost)
        }
        let type = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["type"] as? String ?? ""
        let (answers, closes) = state.withLock { state -> ([String], Bool) in
            state.sent.append(text)
            // Each scripted answer goes out once: deltas follow the first audio messages.
            var answers: [String] = []
            if var queued = state.answers[type], !queued.isEmpty {
                answers.append(queued.removeFirst())
                state.answers[type] = queued
            }
            return (answers, type == "input_audio.end" && state.closesOnEnd)
        }
        answers.forEach { continuation.yield($0) }
        if closes {
            continuation.finish(throwing: URLError(.networkConnectionLost))
        }
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

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var values: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }
}
