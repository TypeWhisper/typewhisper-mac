import os
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import Reson8Plugin

final class Reson8PluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testAdvertisesMultiLanguageHintCapability() {
        let engine: any TranscriptionEnginePlugin = Reson8Plugin()

        XCTAssertTrue(engine is LanguageHintTranscriptionEnginePlugin)
    }

    func testResolveLanguagePrefersRequestedLanguage() {
        let selection = PluginLanguageSelection(
            requestedLanguage: "nl",
            languageHints: ["de", "en"]
        )

        XCTAssertEqual(Reson8Plugin.resolveLanguage(selection: selection), "nl")
    }

    func testResolveLanguageListsMultipleHints() {
        let selection = PluginLanguageSelection(languageHints: ["de", "", "en"])

        XCTAssertEqual(Reson8Plugin.resolveLanguage(selection: selection), "de,en")
    }

    func testDetectedLanguagePrefersReson8ThenAPinnedLanguage() {
        XCTAssertEqual(Reson8Plugin.detectedLanguage("en", requested: "nl,en"), "en")
        XCTAssertEqual(Reson8Plugin.detectedLanguage("", requested: "nl"), "nl")
        XCTAssertNil(Reson8Plugin.detectedLanguage("", requested: "nl,en"))
        XCTAssertNil(Reson8Plugin.detectedLanguage(nil, requested: nil))
    }

    func testLanguageHintsAreSentAsListAndDetectedLanguageIsReported() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"hello","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000), wavData: Data(), duration: 1),
            languageSelection: PluginLanguageSelection(languageHints: ["nl", "en"]),
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.detectedLanguage, "en")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let query = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "language", value: "nl,en")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "include_language", value: "true")))
    }

    func testResolveLanguageFallsBackToAutoDetectWithoutUsableLanguage() {
        XCTAssertNil(Reson8Plugin.resolveLanguage(selection: PluginLanguageSelection()))
        XCTAssertNil(Reson8Plugin.resolveLanguage(selection: PluginLanguageSelection(languageHints: [""])))
    }

    func testOnlyRecordingsThatFitOneRequestAreStreamed() {
        XCTAssertTrue(Reson8Plugin.streamsAudio(ofDuration: 60))
        XCTAssertTrue(Reson8Plugin.streamsAudio(ofDuration: Reson8Plugin.maximumRequestDuration))
        XCTAssertFalse(Reson8Plugin.streamsAudio(ofDuration: Reson8Plugin.maximumRequestDuration + 1))
    }

    func testTranscriptionSplitsLongRecordingsIntoFiveMinuteRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "reson8-key"])
        let plugin = Reson8Plugin()
        plugin.activate(host: host)

        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"first"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(#"{"text":"second"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Just over five minutes, more than one chunk.
        let samples = [Float](repeating: 0.3, count: 16_000 * 301)
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: Data(), duration: 301),
            language: "nl",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "first second")
        XCTAssertEqual(result.detectedLanguage, "nl")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            // Five minutes of 16 kHz 16-bit PCM.
            XCTAssertLessThanOrEqual(try XCTUnwrap(request.httpBody).count, 300 * 32_000)
            XCTAssertEqual(request.url?.path, "/v1/speech-to-text/prerecorded")
            XCTAssertTrue(request.url?.query?.contains("language=nl") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "ApiKey reson8-key")
        }
    }

    func testListsTheDefaultModelFirstThenOtherModelsThenCustomModels() throws {
        let plugin = try Self.pluginWithFetchedModels()

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["__default__", "rumble-2-flash", "custom-1"])
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.displayName),
            ["Resonant-1", "Rumble-2-Flash", "Cardiology"]
        )
    }

    func testLanguagesAndStreamingFollowTheSelectedModel() throws {
        let plugin = try Self.pluginWithFetchedModels()

        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: "rumble-2-flash"))
        XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)
        XCTAssertEqual(plugin.supportedLanguages, ["nl", "en", "fy"])

        plugin.selectModel("rumble-2-flash")
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        // Without live sessions, the host may preview the recording in batches.
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)
        XCTAssertEqual(plugin.supportedLanguages, ["nl", "en", "ja"])

        // Custom models run on the default model.
        plugin.selectModel("custom-1")
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertEqual(plugin.supportedLanguages, ["nl", "en", "fy"])
        XCTAssertEqual(plugin.supportedLanguages(forModelId: "rumble-2-flash"), ["nl", "en", "ja"])
    }

    func testWithoutFetchedModelsOffersOnlyTheStreamingDefaultModel() throws {
        let plugin = Reson8Plugin()
        plugin.activate(host: try PluginTestHostServices(secrets: ["api-key": "test-key"]))

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["__default__"])
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertEqual(plugin.supportedLanguages, ["nl", "en", "fr", "de", "it", "pl", "pt", "es", "sv"])
    }

    func testListedModelIsSentAsModel() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        plugin.selectModel("rumble-2-flash")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertEqual(query["model"], "rumble-2-flash")
        XCTAssertNil(query["custom_model_id"])
    }

    func testCustomModelIsSentWithoutModel() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        plugin.selectModel("custom-1")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertEqual(query["custom_model_id"], "custom-1")
        XCTAssertNil(query["model"])
    }

    func testDefaultModelIsSentWithoutModelOrCustomModel() async throws {
        let plugin = try Self.pluginWithFetchedModels()

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertNil(query["model"])
        XCTAssertNil(query["custom_model_id"])
    }

    func testFetchModelsReadsTheModelList() async throws {
        let plugin = Reson8Plugin()
        plugin.activate(host: try PluginTestHostServices(secrets: ["api-key": "test-key"]))
        let url = "https://api.reson8.dev/v1/model"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(Self.modelListJSON.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        let fetched = await plugin.fetchModels()
        let models = try XCTUnwrap(fetched)

        XCTAssertEqual(models.map(\.id), ["resonant-1", "rumble-2-flash"])
        XCTAssertEqual(models.map(\.endpoints), [["prerecorded", "realtime", "turns"], ["prerecorded"]])
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/model")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "ApiKey test-key")
    }

    func testFetchModelsReturnsNilWhenTheListIsUnavailable() async throws {
        let plugin = Reson8Plugin()
        plugin.activate(host: try PluginTestHostServices(secrets: ["api-key": "test-key"]))
        let url = "https://api.reson8.dev/v1/model"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data("404 page not found".utf8), Self.httpResponse(url: url, statusCode: 404)),
            ])
        }

        let models = await plugin.fetchModels()

        XCTAssertNil(models)
    }

    func testNaturalFillerModeSendsNoFillerMode() async throws {
        let plugin = try Self.pluginWithFetchedModels(fillerMode: "natural")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertNil(query["filler_mode"])
    }

    func testChosenFillerModeIsSent() async throws {
        let plugin = try Self.pluginWithFetchedModels(fillerMode: "clean")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertEqual(query["filler_mode"], "clean")
    }

    func testCustomModelGetsFillerModeOfTheDefaultModel() async throws {
        let plugin = try Self.pluginWithFetchedModels(fillerMode: "verbatim")
        plugin.selectModel("custom-1")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertEqual(query["filler_mode"], "verbatim")
        XCTAssertEqual(query["custom_model_id"], "custom-1")
    }

    // Rumble-2-Flash rejects filler_mode with 400 invalid_query_parameter.
    func testFillerModeIsLeftOutForAModelThatRejectsIt() async throws {
        let plugin = try Self.pluginWithFetchedModels(fillerMode: "clean")
        plugin.selectModel("rumble-2-flash")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertEqual(query["model"], "rumble-2-flash")
        XCTAssertNil(query["filler_mode"])
    }

    func testBiasStrengthIsLeftOutWithoutCustomModelOrPhrases() async throws {
        let plugin = try Self.pluginWithFetchedModels(biasStrength: 0.7)

        let defaultQuery = try await Self.queryItems(ofTranscriptionWith: plugin)
        plugin.selectModel("custom-1")
        let customQuery = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertNil(defaultQuery["bias_strength"])
        XCTAssertEqual(customQuery["bias_strength"], "0.70")
    }

    // MARK: - Dictionary terms

    func testDictionaryTermsGoAsPhrasesWithBiasStrength() async throws {
        let plugin = try Self.pluginWithFetchedModels(biasStrength: 0.6)

        let request = try await Self.request(
            ofTranscriptionWith: plugin,
            prompt: "Reson8, C++, Café"
        )

        let query = Self.queryItems(of: request)
        XCTAssertEqual(query["phrases"], "Reson8,C++,Café")
        XCTAssertEqual(query["bias_strength"], "0.60")
        // A literal "+" would reach Reson8 as a space.
        let encodedQuery = try XCTUnwrap(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        })
        XCTAssertTrue(encodedQuery.contains("C%2B%2B"))
    }

    func testPhrasesStayBelowReson8sURLLimit() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        let prompt = (0..<250).map { "Überprüfungsausschuss \($0)" }.joined(separator: ", ")

        let request = try await Self.request(ofTranscriptionWith: plugin, prompt: prompt)

        let phrases = try XCTUnwrap(Self.queryItems(of: request)["phrases"])
        let encodedQuery = try XCTUnwrap(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        })
        let encodedPhrases = try XCTUnwrap(encodedQuery.split(separator: "&").first { $0.hasPrefix("phrases=") })
        XCTAssertGreaterThan(phrases.split(separator: ",").count, 10)
        XCTAssertLessThanOrEqual(encodedPhrases.dropFirst("phrases=".count).count, 2_500)
    }

    func testModelThatRejectsPhrasesGetsNoDictionaryTermsOrWordTimings() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)

        plugin.selectModel("rumble-2-flash")
        let query = Self.queryItems(of: try await Self.request(ofTranscriptionWith: plugin, prompt: "Reson8"))

        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
        XCTAssertEqual(plugin.supportsDictionaryTerms(forModelId: "rumble-2-flash"), false)
        XCTAssertEqual(plugin.supportsDictionaryTerms(forModelId: "custom-1"), true)
        XCTAssertNil(query["phrases"])
        XCTAssertNil(query["include_words"])
        XCTAssertNil(query["include_timestamps"])
    }

    // MARK: - Word timings and speakers

    func testWordTimingsAreReportedAndSplitIntoSentences() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        let response = """
            {"text":"Goedemorgen allemaal. Welkom bij het overleg. We beginnen nu.","language":"nl",
             "words":[\(Self.wordsJSON("Goedemorgen allemaal. Welkom bij het overleg.", startMs: 0)),
                      \(Self.wordsJSON("We beginnen nu.", startMs: 5_000))]}
            """
        let collector = PluginWordTimingCollector()

        let result = try await PluginWordTimings.$collector.withValue(collector) {
            try await Self.structuredTranscription(with: plugin, response: response)
        }

        XCTAssertEqual(collector.words.count, 9)
        XCTAssertEqual(collector.words.first, PluginWordTiming(text: "Goedemorgen", start: 0, end: 0.4))
        // A sentence of two words does not close a segment; the pause before the last one does.
        XCTAssertEqual(result.segments.map(\.text), ["Goedemorgen allemaal. Welkom bij het overleg.", "We beginnen nu."])
        XCTAssertEqual(result.segments.last?.start, 5)
        XCTAssertNil(result.segments.first?.speakerLabel)
    }

    func testDiarizationLabelsSpeakersAndTurnsStreamingOff() async throws {
        let plugin = try Self.pluginWithFetchedModels(diarizationEnabled: true, maxSpeakers: 2)
        let response = """
            {"text":"Waar doet het pijn? In mijn borst.","segments":[
              {"text":"Waar doet het pijn?","speaker_id":0,"language":"nl",
               "words":[\(Self.wordsJSON("Waar doet het pijn?", startMs: 0))]},
              {"text":"In mijn borst.","speaker_id":1,"language":"nl",
               "words":[\(Self.wordsJSON("In mijn borst.", startMs: 2_000))]}]}
            """

        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        let result = try await Self.structuredTranscription(with: plugin, response: response) { query in
            XCTAssertEqual(query["diarize"], "true")
            XCTAssertEqual(query["max_speakers"], "2")
        }

        // Dictated text must not start with "Speaker 1:"; the labels stay on the segments.
        XCTAssertEqual(result.text, "Waar doet het pijn? In mijn borst.")
        XCTAssertEqual(result.detectedLanguage, "nl")
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result.segments.map(\.start), [0, 2])
    }

    func testDiarizationIsLeftOutForAModelThatRejectsIt() async throws {
        let plugin = try Self.pluginWithFetchedModels(diarizationEnabled: true)
        plugin.selectModel("rumble-2-flash")

        let query = try await Self.queryItems(ofTranscriptionWith: plugin)

        XCTAssertNil(query["diarize"])
    }

    func testDiarizedLongRecordingKeepsSpeakerLabelsOutOfTheText() async throws {
        let plugin = try Self.pluginWithFetchedModels(diarizationEnabled: true)
        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let first = """
            {"text":"Eerste zin hier. Tweede zin hier.","segments":[{"text":"Eerste zin hier. Tweede zin hier.",
             "speaker_id":0,"words":[\(Self.wordsJSON("Eerste zin hier. Tweede zin hier.", startMs: 0))]}]}
            """
        let second = """
            {"text":"Derde zin hier.","segments":[{"text":"Derde zin hier.",
             "speaker_id":0,"words":[\(Self.wordsJSON("Derde zin hier.", startMs: 0))]}]}
            """
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(first.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(second.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Just over five minutes, more than one chunk.
        let result = try await plugin.transcribeStructured(
            audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000 * 301), wavData: Data(), duration: 301),
            language: "nl",
            translate: false,
            prompt: nil
        )

        // Every request numbers its speakers anew, so the second chunk's speaker gets a new number.
        // PluginAudioChunking writes the labels into a chunked text; the plugin takes them out again.
        XCTAssertEqual(result.text, "Eerste zin hier. Tweede zin hier. Derde zin hier.")
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker 1", "Speaker 2"])
    }

    // MARK: - Realtime

    func testRealtimeSessionsSendTheSettingsAndAskForInterimTranscripts() throws {
        let plugin = try Self.pluginWithFetchedModels(fillerMode: "clean")

        let path = try XCTUnwrap(plugin.realtimePath(language: "de,en", prompt: "Reson8"))
        let query = Self.queryItems(of: URLRequest(url: try XCTUnwrap(URL(string: "wss://api.reson8.dev\(path)"))))

        XCTAssertTrue(path.hasPrefix("/v1/speech-to-text/realtime?"))
        XCTAssertEqual(query["include_interim"], "true")
        XCTAssertEqual(query["language"], "de,en")
        XCTAssertEqual(query["phrases"], "Reson8")
        XCTAssertEqual(query["filler_mode"], "clean")
        XCTAssertEqual(query["include_words"], "true")
    }

    func testLiveSessionReportsTranscriptsAndFinishesAfterTheFlush() async throws {
        let firstWords = Self.wordsJSON("Das ist der erste Satz.", startMs: 0)
        let secondWords = Self.wordsJSON("And this is the second sentence.", startMs: 4_000)
        let socket = FakeRealtimeSocket(flushAnswers: [
            #"{"type":"transcript","text":"And this is the second sentence.","language":"en","is_final":true,"words":[\#(secondWords)]}"#,
            #"{"type":"flush_confirmation","id":"typewhisper"}"#,
        ])
        let progress = OSAllocatedUnfairLock<[String]>(initialState: [])
        let session = try await Reson8RealtimeSession.connect(socket: socket, language: "de,en") { text in
            progress.withLock { $0.append(text) }
            return true
        }

        // One second of audio, sent in frames below Reson8's 64 KiB limit.
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 16_000))
        socket.deliver(#"{"type":"transcript","text":"Das ist","language":"","is_final":false}"#)
        socket.deliver(#"{"type":"transcript","text":"Das ist der erste Satz.","language":"de","is_final":true,"words":[\#(firstWords)]}"#)
        socket.deliver(#"{"type":"transcript","text":"And this","language":"","is_final":false}"#)
        let collector = PluginWordTimingCollector()
        let result = try await PluginWordTimings.$collector.withValue(collector) {
            try await session.finish()
        }

        XCTAssertEqual(socket.audioFrameSizes, [8_192, 8_192, 8_192, 7_424])
        XCTAssertEqual(socket.sentTexts, [#"{"type":"flush_request","id":"typewhisper"}"#])
        XCTAssertTrue(socket.isClosed)
        // Each update covers the whole recording so far.
        XCTAssertEqual(progress.withLock { $0 }, [
            "Das ist",
            "Das ist der erste Satz.",
            "Das ist der erste Satz. And this",
            "Das ist der erste Satz. And this is the second sentence.",
        ])
        XCTAssertEqual(result.text, "Das ist der erste Satz. And this is the second sentence.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.map(\.text), ["Das ist der erste Satz.", "And this is the second sentence."])
        XCTAssertEqual(result.segments.last?.start, 4)
        XCTAssertEqual(collector.words.count, 11)
    }

    // TypeWhisper then transcribes the whole recording instead of keeping a transcript
    // whose end may be missing.
    func testLiveSessionThatClosesBeforeTheFlushIsConfirmedFails() async throws {
        let socket = FakeRealtimeSocket(flushAnswers: [], closesOnFlush: true)
        let session = try await Reson8RealtimeSession.connect(socket: socket, language: "nl") { _ in true }

        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 1_600))
        socket.deliver(#"{"type":"transcript","text":"Hallo.","language":"nl","is_final":true}"#)

        do {
            _ = try await session.finish()
            XCTFail("Expected the session to fail")
        } catch PluginTranscriptionError.networkError {
            XCTAssertTrue(socket.isClosed)
        }
    }

    // MARK: - Turn ends

    func testLiveSessionsUseTheTurnsEndpointOnlyWithTheSettingAndAHostHandler() throws {
        let plugin = try Self.pluginWithFetchedModels(extraDefaults: ["endsDictationAtTurnEnd": true])
        guard case .realtime = plugin.liveSessionMode(forModelId: nil) else {
            return XCTFail("Without a handler from the host, live sessions stay on realtime")
        }

        // The host hands the handler over through the Objective-C runtime.
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let block: @convention(block) () -> Void = { calls.withLock { $0 += 1 } }
        let selector = NSSelectorFromString("setLiveTranscriptionTurnEndHandler:")
        plugin.perform(selector, with: unsafeBitCast(block, to: AnyObject.self))
        guard case .turns(let onTurnEnd) = plugin.liveSessionMode(forModelId: nil) else {
            return XCTFail("With the setting and a handler, live sessions report turn ends")
        }
        onTurnEnd()
        XCTAssertEqual(calls.withLock { $0 }, 1)

        let path = try XCTUnwrap(plugin.turnsPath(language: "en", prompt: nil))
        let query = Self.queryItems(of: URLRequest(url: try XCTUnwrap(URL(string: "wss://api.reson8.dev\(path)"))))
        XCTAssertTrue(path.hasPrefix("/v1/speech-to-text/turns?"))
        XCTAssertEqual(query["eager_turn_probability"], "0.05")
        XCTAssertNil(query["include_interim"])

        let withoutSetting = try Self.pluginWithFetchedModels()
        withoutSetting.perform(selector, with: unsafeBitCast(block, to: AnyObject.self))
        guard case .realtime = withoutSetting.liveSessionMode(forModelId: nil) else {
            return XCTFail("Without the setting, live sessions stay on realtime")
        }
    }

    func testTurnsSessionReportsTurnEndsAndFinishesAtOnceWithoutAnOpenTurn() async throws {
        let socket = FakeRealtimeSocket(flushAnswers: [])
        let turnEnds = OSAllocatedUnfairLock(initialState: 0)
        let session = try await Reson8RealtimeSession.connect(
            socket: socket,
            mode: .turns(onTurnEnd: { turnEnds.withLock { $0 += 1 } }),
            language: "en"
        ) { _ in true }

        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 16_000))
        socket.deliver(#"{"type":"turn_start"}"#)
        socket.deliver(#"{"type":"turn_end_candidate","text":"Please send the report.","language":"en","words":[\#(Self.wordsJSON("Please send the report.", startMs: 0))]}"#)
        socket.deliver(#"{"type":"turn_end"}"#)
        try await Self.waitUntil { turnEnds.withLock { $0 } == 1 }
        try await session.appendAudio(samples: [Float](repeating: 0, count: 16_000))
        let result = try await session.finish()

        // Every turn ended and the silence after it holds no speech, so nothing is flushed.
        XCTAssertEqual(socket.sentTexts, [])
        XCTAssertEqual(result.text, "Please send the report.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.map(\.text), ["Please send the report."])
        XCTAssertTrue(socket.isClosed)
    }

    func testTurnsSessionFlushesAnOpenTurnWithoutReportingItsEnd() async throws {
        let socket = FakeRealtimeSocket(flushAnswers: [
            #"{"type":"turn_end_candidate","text":"Add the numbers.","language":"en"}"#,
            #"{"type":"turn_end"}"#,
        ])
        let turnEnds = OSAllocatedUnfairLock(initialState: 0)
        let progress = OSAllocatedUnfairLock<[String]>(initialState: [])
        let session = try await Reson8RealtimeSession.connect(
            socket: socket,
            mode: .turns(onTurnEnd: { turnEnds.withLock { $0 += 1 } }),
            language: "en"
        ) { text in
            progress.withLock { $0.append(text) }
            return true
        }

        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 8_000))
        socket.deliver(#"{"type":"turn_start"}"#)
        socket.deliver(#"{"type":"turn_end_candidate","text":"Add the","language":"en"}"#)
        try await Self.waitUntil { progress.withLock { $0 } == ["Add the"] }
        let result = try await session.finish()

        XCTAssertEqual(socket.sentTexts, [#"{"type":"flush_request"}"#])
        XCTAssertEqual(result.text, "Add the numbers.")
        // The host stopped this dictation itself.
        XCTAssertEqual(turnEnds.withLock { $0 }, 0)
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition not reached")
    }

    // MARK: - Recordings and files

    func testFinishedAudioGoesToThePrerecordedEndpointUnlessRealtimeIsChosen() throws {
        let plugin = try Self.pluginWithFetchedModels()
        XCTAssertFalse(plugin.transcribesThroughRealtime(duration: 10))
        // Dictations still stream live.
        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: nil))

        let realtimePlugin = try Self.pluginWithFetchedModels(extraDefaults: ["recordingEndpoint": "realtime"])
        XCTAssertTrue(realtimePlugin.transcribesThroughRealtime(duration: 10))
        XCTAssertFalse(realtimePlugin.transcribesThroughRealtime(duration: Reson8Plugin.maximumRequestDuration + 1))
        realtimePlugin.selectModel("rumble-2-flash")
        XCTAssertFalse(realtimePlugin.transcribesThroughRealtime(duration: 10))
    }

    // MARK: - Dictionary custom model

    func testDictionaryGoesIntoItsCustomModelAndOnlyChangesAreSynced() async throws {
        let customModels = #"[{"id":"custom-1","name":"Cardiology","description":null,"phraseCount":3},"# +
            #"{"id":"dictionary-1","name":"TypeWhisper Dictionary","description":null,"phraseCount":2}]"#
        let plugin = try Self.pluginWithFetchedModels(extraDefaults: [
            "dictionaryModelEnabled": true,
            "fetchedCustomModels": Data(customModels.utf8),
        ])
        let api = FakeCustomModelAPI()
        plugin.useCustomModelAPI(api)

        let first = Self.queryItems(of: try await Self.request(ofTranscriptionWith: plugin, prompt: "Reson8, TypeWhisper"))
        let second = Self.queryItems(of: try await Self.request(ofTranscriptionWith: plugin, prompt: "Reson8, Parakeet"))
        let third = Self.queryItems(of: try await Self.request(ofTranscriptionWith: plugin, prompt: "Parakeet, Reson8"))

        XCTAssertEqual(plugin.dictionaryTermsBudget.maxTerms, 50_000)
        XCTAssertEqual([first, second, third].map { $0["custom_model_id"] }, ["dictionary-1", "dictionary-1", "dictionary-1"])
        XCTAssertNil(first["phrases"])
        let calls = await api.calls
        XCTAssertEqual(calls, [
            "create dictionary-1: Reson8, TypeWhisper",
            "delete dictionary-1: TypeWhisper",
            "add dictionary-1: Parakeet",
        ])
        // The model that holds the dictionary is no model to choose.
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["__default__", "rumble-2-flash", "custom-1"])

        // A custom model the user selected keeps the terms as phrases.
        plugin.selectModel("custom-1")
        let withCustomModel = Self.queryItems(of: try await Self.request(ofTranscriptionWith: plugin, prompt: "Reson8"))
        XCTAssertEqual(withCustomModel["custom_model_id"], "custom-1")
        XCTAssertEqual(withCustomModel["phrases"], "Reson8")
    }

    func testDictionaryModelDeletedAtReson8IsCreatedAgain() async throws {
        let plugin = try Self.pluginWithFetchedModels(extraDefaults: ["dictionaryModelEnabled": true])
        let api = FakeCustomModelAPI()
        plugin.useCustomModelAPI(api)
        _ = try await Self.request(ofTranscriptionWith: plugin, prompt: "Reson8")

        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"status":400,"detail":"Unknown vocabulary: dictionary-1","code":"session_rejected"}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 400)
                ),
                .success(Data(#"{"text":"hallo"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }
        let result = try await plugin.transcribe(
            audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000), wavData: Data(), duration: 1),
            language: "nl",
            translate: false,
            prompt: "Reson8"
        )

        XCTAssertEqual(result.text, "hallo")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map { Self.queryItems(of: $0)["custom_model_id"] }, ["dictionary-1", "dictionary-2"])
        let calls = await api.calls
        XCTAssertEqual(calls, ["create dictionary-1: Reson8", "create dictionary-2: Reson8"])
    }

    // MARK: - Patterns

    func testPatternSetIsAModelThatSendsPatternsInsteadOfDictionaryTerms() async throws {
        let sets = #"[{"id":"orders","name":"Orders","patterns":["AMZ[0-9]{6}"," ","(INV)?[0-9]{4,5}"]}]"#
        let plugin = try Self.pluginWithFetchedModels(extraDefaults: [
            "patternSets": Data(sets.utf8),
            "dictionaryModelEnabled": true,
        ])
        let api = FakeCustomModelAPI()
        plugin.useCustomModelAPI(api)

        XCTAssertEqual(plugin.transcriptionModels.last?.id, "patterns:orders")
        XCTAssertEqual(plugin.transcriptionModels.last?.displayName, "Orders (patterns)")
        plugin.selectModel("patterns:orders")
        let query = Self.queryItems(of: try await Self.request(ofTranscriptionWith: plugin, prompt: "Reson8"))

        // Reson8 rejects patterns together with phrases or a custom model.
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
        XCTAssertEqual(plugin.supportsDictionaryTerms(forModelId: "patterns:orders"), false)
        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        XCTAssertEqual(query["patterns"], "AMZ[0-9]{6},(INV)?[0-9]{4,5}")
        XCTAssertNil(query["phrases"])
        XCTAssertNil(query["custom_model_id"])
        XCTAssertNil(query["model"])
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Model catalog

    func testFailedRefreshKeepsTheModelsAndTheSelection() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        plugin.selectModel("custom-1")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .failure(URLError(.timedOut)),
                .failure(URLError(.timedOut)),
            ])
        }

        await plugin.refreshModels()

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["__default__", "rumble-2-flash", "custom-1"])
        XCTAssertEqual(plugin.selectedModelId, "custom-1")
    }

    func testRefreshFallsBackToTheDefaultModelWhenTheSelectionIsGone() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        plugin.selectModel("custom-1")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(Self.modelListJSON.utf8), Self.httpResponse(url: "https://api.reson8.dev/v1/model", statusCode: 200)),
                .success(Data("[]".utf8), Self.httpResponse(url: "https://api.reson8.dev/v1/custom-model", statusCode: 200)),
            ])
        }

        await plugin.refreshModels()

        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["__default__", "rumble-2-flash"])
        XCTAssertEqual(plugin.selectedModelId, "__default__")
    }

    func testModelsReportTheirLanguageCount() throws {
        let plugin = try Self.pluginWithFetchedModels()

        // Custom models run on the default model.
        XCTAssertEqual(plugin.transcriptionModels.map(\.languageCount), [3, 3, 3])
    }

    // MARK: - Errors

    func testCreditLimitAndConcurrencyLimitShowReson8sMessage() async throws {
        let plugin = try Self.pluginWithFetchedModels()
        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"status":402,"detail":"Credit limit exceeded","code":"session_rejected"}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 402)
                ),
                .success(
                    Data(#"{"status":429,"detail":"Concurrent connection limit exceeded","code":"session_rejected"}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 429)
                ),
            ])
        }

        for expected in ["Credit limit exceeded", "Concurrent connection limit exceeded"] {
            do {
                _ = try await plugin.transcribe(
                    audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000), wavData: Data(), duration: 1),
                    language: "nl",
                    translate: false,
                    prompt: nil
                )
                XCTFail("Expected \(expected)")
            } catch PluginTranscriptionError.apiError(let message) {
                XCTAssertTrue(message.contains(expected), message)
            }
        }
    }

    /// Words of `sentence`, 400 ms each with 100 ms between them.
    private static func wordsJSON(_ sentence: String, startMs: Int) -> String {
        sentence.split(separator: " ").enumerated().map { index, word in
            #"{"text":"\#(word)","start_ms":\#(startMs + index * 500),"duration_ms":400}"#
        }.joined(separator: ",")
    }

    private static func structuredTranscription(
        with plugin: Reson8Plugin,
        response: String,
        checkQuery: ([String: String]) -> Void = { _ in }
    ) async throws -> PluginStructuredTranscriptionResult {
        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(response.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        let result = try await plugin.transcribeStructured(
            audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000 * 8), wavData: Data(), duration: 8),
            language: "nl",
            translate: false,
            prompt: nil
        )

        checkQuery(queryItems(of: try XCTUnwrap(store.sessions.first?.requestedRequests.first)))
        return result
    }

    private static let modelListJSON = """
        [
          {"id":"resonant-1","displayName":"Resonant-1","description":"Our streaming speech-to-text model.",
           "endpoints":["prerecorded","realtime","turns"],"languages":["nl","en","fy"],"isDefault":true},
          {"id":"rumble-2-flash","displayName":"Rumble-2-Flash","description":"Fast plain transcripts of prerecorded audio.",
           "endpoints":["prerecorded"],"languages":["nl","en","ja"],"isDefault":false}
        ]
        """

    private static func pluginWithFetchedModels(
        fillerMode: String? = nil,
        biasStrength: Double? = nil,
        diarizationEnabled: Bool? = nil,
        maxSpeakers: Int? = nil,
        extraDefaults: [String: Any] = [:]
    ) throws -> Reson8Plugin {
        let customModels = #"[{"id":"custom-1","name":"Cardiology","description":null,"phraseCount":3}]"#
        var defaults: [String: Any] = [
            "fetchedModels": Data(modelListJSON.utf8),
            "fetchedCustomModels": Data(customModels.utf8),
        ]
        defaults["fillerMode"] = fillerMode
        defaults["biasStrength"] = biasStrength
        defaults["speakerDiarizationEnabled"] = diarizationEnabled
        defaults["maxSpeakers"] = maxSpeakers
        defaults.merge(extraDefaults) { _, extra in extra }
        let host = try PluginTestHostServices(defaults: defaults, secrets: ["api-key": "test-key"])
        let plugin = Reson8Plugin()
        plugin.activate(host: host)
        return plugin
    }

    private static func queryItems(ofTranscriptionWith plugin: Reson8Plugin) async throws -> [String: String] {
        queryItems(of: try await request(ofTranscriptionWith: plugin, prompt: nil))
    }

    private static func request(ofTranscriptionWith plugin: Reson8Plugin, prompt: String?) async throws -> URLRequest {
        let url = "https://api.reson8.dev/v1/speech-to-text/prerecorded"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"hallo"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [Float](repeating: 0.3, count: 16_000), wavData: Data(), duration: 1),
            language: "nl",
            translate: false,
            prompt: prompt
        )

        XCTAssertEqual(result.text, "hallo")
        return try XCTUnwrap(store.sessions.first?.requestedRequests.first)
    }

    private static func queryItems(of request: URLRequest) -> [String: String] {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
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

/// Reson8's custom model endpoints, numbering the models it creates.
private actor FakeCustomModelAPI: Reson8CustomModelAPI {
    private(set) var calls: [String] = []
    private var createdModelCount = 0

    func createModel(name: String, description: String, phrases: [String]) -> String {
        createdModelCount += 1
        let modelId = "dictionary-\(createdModelCount)"
        calls.append("create \(modelId): \(phrases.joined(separator: ", "))")
        return modelId
    }

    func addPhrases(_ phrases: [String], toModel modelId: String) {
        calls.append("add \(modelId): \(phrases.joined(separator: ", "))")
    }

    func deletePhrases(_ phrases: [String], fromModel modelId: String) {
        calls.append("delete \(modelId): \(phrases.joined(separator: ", "))")
    }
}

/// Records what a realtime session sends and answers its flush request.
private final class FakeRealtimeSocket: Reson8RealtimeSocket, @unchecked Sendable {
    private struct State {
        var audioFrameSizes: [Int] = []
        var sentTexts: [String] = []
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let messages: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let flushAnswers: [String]
    private let closesOnFlush: Bool

    init(flushAnswers: [String], closesOnFlush: Bool = false) {
        (messages, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        self.flushAnswers = flushAnswers
        self.closesOnFlush = closesOnFlush
    }

    var audioFrameSizes: [Int] { state.withLock { $0.audioFrameSizes } }
    var sentTexts: [String] { state.withLock { $0.sentTexts } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    /// A message as Reson8 would send it.
    func deliver(_ message: String) {
        continuation.yield(message)
    }

    func connect() async throws {}

    func sendAudio(_ data: Data) async throws {
        state.withLock { $0.audioFrameSizes.append(data.count) }
    }

    func sendText(_ text: String) async throws {
        state.withLock { $0.sentTexts.append(text) }
        if closesOnFlush {
            continuation.finish(throwing: URLError(.networkConnectionLost))
        } else {
            flushAnswers.forEach { continuation.yield($0) }
        }
    }

    func receive() async throws -> String {
        var iterator = messages.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw URLError(.cancelled) }
        return message
    }

    func close() {
        state.withLock { $0.isClosed = true }
        continuation.finish()
    }
}
