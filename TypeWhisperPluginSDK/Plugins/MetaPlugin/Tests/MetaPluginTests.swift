import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import MetaPlugin

final class MetaPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testNewInstallProvidesVoiceAndSparkFallbacks() throws {
        let host = try PluginTestHostServices()
        let plugin = MetaPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "muse-voice-transcribe-1.0")
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["muse-voice-transcribe-1.0"])
        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertFalse(plugin.isSpeakerDiarizationEnabled)
        XCTAssertEqual(plugin.preferredModelId, "muse-spark-1.2")
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["muse-spark-1.2", "muse-spark-1.1", "muse-spark-1.2-contributor"]
        )
    }

    func testCatalogSeparatesVoiceAndSparkModels() {
        let catalog = MetaModelCatalog.categorize([
            MetaFetchedModel(id: "muse-image-1.0", ownedBy: "meta"),
            MetaFetchedModel(id: "muse-spark-1.1", ownedBy: "meta"),
            MetaFetchedModel(id: "muse-voice-transcribe-1.0", ownedBy: "meta"),
            MetaFetchedModel(id: "muse-spark-1.2-contributor", ownedBy: "meta"),
            MetaFetchedModel(id: "muse-spark-1.2", ownedBy: "meta"),
        ])

        XCTAssertEqual(catalog.transcriptionModels.map(\.id), ["muse-voice-transcribe-1.0"])
        XCTAssertEqual(
            catalog.llmModels.map(\.id),
            ["muse-spark-1.2", "muse-spark-1.1", "muse-spark-1.2-contributor"]
        )
    }

    func testRefreshLoadsAndCachesBothModelRoles() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "meta-key"])
        let plugin = MetaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"object":"list","data":[{"id":"muse-image-1.0","owned_by":"meta"},{"id":"muse-voice-transcribe-1.0","owned_by":"meta"},{"id":"muse-spark-1.2","owned_by":"meta"}]}"#.utf8),
                    Self.httpResponse(url: "https://api.meta.ai/v1/models", statusCode: 200)
                ),
            ])
        }

        let refreshedCatalog = await plugin.refreshModelCatalog()
        let catalog = try XCTUnwrap(refreshedCatalog)

        XCTAssertEqual(catalog.transcriptionModels.map(\.id), ["muse-voice-transcribe-1.0"])
        XCTAssertEqual(catalog.llmModels.map(\.id), ["muse-spark-1.2"])
        XCTAssertNotNil(host.userDefault(forKey: "fetchedTranscriptionModels") as? Data)
        XCTAssertNotNil(host.userDefault(forKey: "fetchedLLMModels") as? Data)
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer meta-key")
    }

    func testResponsesRequestUsesSelectedSparkModelAndInstructions() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedLLMModel": "muse-spark-1.1"],
            secrets: ["api-key": "meta-key"]
        )
        let plugin = MetaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Cleaned text"}]}]}"#.utf8),
                    Self.httpResponse(url: "https://api.meta.ai/v1/responses", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(
            systemPrompt: "Correct the transcript.",
            userText: "raw text",
            model: nil
        )

        XCTAssertEqual(result, "Cleaned text")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer meta-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "muse-spark-1.1")
        XCTAssertEqual(json["instructions"] as? String, "Correct the transcript.")
        XCTAssertEqual(json["input"] as? String, "raw text")
        XCTAssertEqual(json["store"] as? Bool, false)
    }

    func testTranscriptionUploadsWavWithGermanBiasAndKeywords() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "meta-key"])
        let plugin = MetaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"sessionId":"session","transcript":"Hallo TypeWhisper","audioDurationMs":1000,"turns":[]}"#.utf8),
                    Self.httpResponse(url: "https://api.meta.ai/v1/asr/transcribe", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1
        )
        let result = try await plugin.transcribe(
            audio: audio,
            languageSelection: PluginLanguageSelection(requestedLanguage: "de-DE", languageHints: ["en"]),
            translate: false,
            prompt: "TypeWhisper, M1 Pro",
            dictionaryTermHints: [PluginDictionaryTermHint(text: "Muse Voice")]
        )

        XCTAssertEqual(result.text, "Hallo TypeWhisper")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/asr/transcribe")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        // The multipart body contains binary WAV data; lossy decoding is intentional for header assertions.
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"request\""))
        XCTAssertTrue(body.contains("Content-Type: application/json"))
        XCTAssertTrue(body.contains("name=\"audio\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains(#""model":"muse-voice-transcribe-1.0""#))
        XCTAssertTrue(body.contains(#""audioEncoding":"WAV""#))
        XCTAssertTrue(body.contains(#""mode":"PUSH_TO_TALK""#))
        XCTAssertTrue(body.contains(#""languageBias":["German","English"]"#))
        XCTAssertTrue(body.contains("Muse Voice"))
        XCTAssertTrue(body.contains("TypeWhisper"))
        XCTAssertTrue(body.contains("M1 Pro"))
    }

    func testTranscriptionTurnsBecomeSegments() throws {
        let result = try MetaTranscriptionClient.parseResponse(Data(#"""
        {
          "sessionId":"session",
          "transcript":"Hallo. Welt.",
          "audioDurationMs":3000,
          "turns":[
            {"turnId":1,"startMs":250,"endMs":1250,"transcript":"Hallo.","speaker":"A"},
            {"turnId":2,"startMs":1500,"endMs":2800,"transcript":"Welt.","speaker":"B"}
          ]
        }
        """#.utf8))

        XCTAssertEqual(result.text, "Speaker A: Hallo.\nSpeaker B: Welt.")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].start, 0.25)
        XCTAssertEqual(result.segments[1].end, 2.8)
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker A", "Speaker B"])
    }

    func testSpeakerDiarizationPersistsAndUsesDiarizationMode() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "meta-key"])
        let plugin = MetaPlugin()
        plugin.activate(host: host)
        plugin.setSpeakerDiarizationEnabled(true)

        XCTAssertTrue(plugin.isSpeakerDiarizationEnabled)
        XCTAssertEqual(host.userDefault(forKey: "speakerDiarizationEnabled") as? Bool, true)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"sessionId":"session","transcript":"Hallo","audioDurationMs":1000,"turns":[{"turnId":1,"startMs":0,"endMs":1000,"transcript":"Hallo","speaker":"A"}]}"#.utf8),
                    Self.httpResponse(url: "https://api.meta.ai/v1/asr/transcribe", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        _ = try await plugin.transcribeStructured(
            audio: AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1),
            language: "de",
            translate: false,
            prompt: nil
        )

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        // The multipart body contains binary WAV data; lossy decoding is intentional for header assertions.
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#""mode":"DIARIZATION""#))
    }

    func testRealtimeHandshakeUsesPCM16HintsKeywordsAndHandshakeAuthentication() throws {
        let message = try MetaLiveTranscriptionSession.handshakeMessage(
            apiKey: "meta-key",
            model: "muse-voice-transcribe-1.0",
            mode: .diarization,
            languageHints: ["German", "English"],
            keywords: ["TypeWhisper"]
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        let authorization = try XCTUnwrap(json["authorization"] as? [String: Any])

        XCTAssertEqual(authorization["accessToken"] as? String, "Bearer meta-key")
        XCTAssertEqual(json["audioEncoding"] as? String, "PCM_16KHZ")
        XCTAssertEqual(json["model"] as? String, "muse-voice-transcribe-1.0")
        XCTAssertEqual(json["mode"] as? String, "DIARIZATION")
        XCTAssertEqual(json["partialMode"] as? String, "CUMULATIVE")
        XCTAssertEqual(json["emitAudioProgress"] as? Bool, false)
        XCTAssertEqual(json["languageBias"] as? [String], ["German", "English"])
        XCTAssertEqual(json["keywords"] as? [String], ["TypeWhisper"])
    }

    func testRealtimePCMConversionIsSignedLittleEndian16Bit() {
        XCTAssertEqual(
            MetaLiveTranscriptionSession.pcm16Data(from: [-1, 0, 1]),
            Data([0x01, 0x80, 0x00, 0x00, 0xFF, 0x7F])
        )
    }

    func testGracefulTLSClosureIsAcceptedOnlyWhileFinishing() {
        let gracefulClosure = NSError(domain: NSOSStatusErrorDomain, code: -9805)

        XCTAssertTrue(MetaLiveTranscriptionSession.isExpectedReceiveTermination(
            gracefulClosure,
            finishRequested: true,
            closeCode: .invalid
        ))
        XCTAssertFalse(MetaLiveTranscriptionSession.isExpectedReceiveTermination(
            gracefulClosure,
            finishRequested: false,
            closeCode: .invalid
        ))
    }

    func testGracefulTLSClosureCanBeWrapped() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: -9805)
        let wrapped = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertTrue(MetaLiveTranscriptionSession.isExpectedReceiveTermination(
            wrapped,
            finishRequested: true,
            closeCode: .invalid
        ))
    }

    func testUnrelatedReceiveFailureStillFailsWhileFinishing() {
        let failure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        XCTAssertFalse(MetaLiveTranscriptionSession.isExpectedReceiveTermination(
            failure,
            finishRequested: true,
            closeCode: .invalid
        ))
    }

    func testScreenshotAutomationBlocksRealtimeNetworkAccessLocally() {
        XCTAssertThrowsError(
            try MetaNetworkAccessPolicy.ensureAccessIsAllowed(arguments: ["TypeWhisper", "--store-screenshots"])
        )
        XCTAssertNoThrow(try MetaNetworkAccessPolicy.ensureAccessIsAllowed(arguments: ["TypeWhisper"]))
    }

    func testRealtimeDiarizationCollectorBuildsSpeakerTurnsAndCompleteSnapshots() async throws {
        let collector = MetaRealtimeTranscriptCollector(mode: .diarization)

        let speechStart = await collector.applyEvent(Data(#"{"type":"speechStart","turnId":1,"audioProcessedMs":200}"#.utf8))
        XCTAssertNil(speechStart)
        let partial = await collector.applyEvent(Data(#"{"type":"transcript","transcript":"Hallo","final":false,"audioProcessedMs":600}"#.utf8))
        XCTAssertEqual(partial, "Hallo")
        let speaker = await collector.applyEvent(Data(#"{"type":"speaker","label":"A","audioProcessedMs":700}"#.utf8))
        XCTAssertEqual(speaker, "Speaker A: Hallo")
        _ = await collector.applyEvent(Data(#"{"type":"speechEnd","turnId":1,"audioProcessedMs":1200}"#.utf8))
        await collector.prepareForFinish()
        let finalizedBeforeComplete = await collector.hasFinalizedAfterFinish
        XCTAssertFalse(finalizedBeforeComplete)
        let complete = await collector.applyEvent(Data(#"{"type":"speechComplete","turnId":1,"transcript":"Hallo zusammen.","audioProcessedMs":1250}"#.utf8))
        XCTAssertEqual(complete, "Speaker A: Hallo zusammen.")
        let finalizedAfterComplete = await collector.hasFinalizedAfterFinish
        XCTAssertTrue(finalizedAfterComplete)

        let result = await collector.finalResult(fallbackLanguage: "de")
        XCTAssertEqual(result.text, "Speaker A: Hallo zusammen.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.map(\.text), ["Speaker A: Hallo zusammen."])
        XCTAssertEqual(result.segments.first?.start, 0.2)
        XCTAssertEqual(result.segments.first?.end, 1.2)
    }

    func testRealtimePushToTalkFinalEventCompletesRequestedFinish() async {
        let collector = MetaRealtimeTranscriptCollector(mode: .pushToTalk)

        await collector.prepareForFinish()
        _ = await collector.applyEvent(Data(#"{"type":"transcript","transcript":"Hallo","final":false}"#.utf8))
        let finalizedAfterPartial = await collector.hasFinalizedAfterFinish
        XCTAssertFalse(finalizedAfterPartial)

        _ = await collector.applyEvent(Data(#"{"type":"transcript","transcript":"Hallo Welt","final":true}"#.utf8))
        let finalizedAfterFinal = await collector.hasFinalizedAfterFinish
        XCTAssertTrue(finalizedAfterFinal)
    }

    func testLanguageBiasDropsUnsupportedAndDuplicateHints() {
        XCTAssertEqual(
            MetaPlugin.languageBias(from: PluginLanguageSelection(
                requestedLanguage: "de-DE",
                languageHints: ["de", "en-US", "xx"]
            )),
            ["German", "English"]
        )
    }

    func testMissingKeyDisablesTranscriptionAndLLM() throws {
        let host = try PluginTestHostServices()
        let plugin = MetaPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertFalse(plugin.isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .llm).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .tts).isAvailable)
    }

    func testRemovingAPIKeyClearsKeychainCredential() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "meta-key"])
        let plugin = MetaPlugin()
        plugin.activate(host: host)

        plugin.setAPIKey("")

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "")
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
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
