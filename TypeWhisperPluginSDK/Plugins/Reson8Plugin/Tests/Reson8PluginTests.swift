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
        XCTAssertEqual(plugin.supportedLanguages, ["nl", "en", "fy"])

        plugin.selectModel("rumble-2-flash")
        XCTAssertFalse(plugin.supportsStreaming)
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
        maxSpeakers: Int? = nil
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
