import Foundation
import os
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ElevenLabsPlugin

final class ElevenLabsPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testScreenshotAutomationSkipsAutomaticKeyValidation() {
        XCTAssertFalse(
            ElevenLabsAutomaticValidationPolicy.allowsValidationOnAppear(
                arguments: ["TypeWhisper", "--store-screenshots"]
            )
        )
        XCTAssertTrue(
            ElevenLabsAutomaticValidationPolicy.allowsValidationOnAppear(arguments: ["TypeWhisper"])
        )
    }

    func testAPIKeyValidationAcceptsSuccessfulUserResponse() {
        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 200, data: Data()),
            .valid
        )
    }

    func testAPIKeyValidationAcceptsKeyWithoutUserReadPermission() {
        let data = Data(#"""
        {
            "detail": {
                "type": "authentication_error",
                "code": "unauthorized",
                "message": "The API key you used is missing the permission user_read to execute this operation.",
                "status": "missing_permissions"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .valid
        )
    }

    func testAPIKeyValidationRejectsInvalidKeyWithProviderMessage() {
        let data = Data(#"""
        {
            "detail": {
                "type": "authentication_error",
                "code": "invalid_api_key",
                "message": "Invalid API key",
                "status": "invalid_api_key"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .invalid(message: "Invalid API key")
        )
    }

    func testTranscriptionUnauthorizedKeepsQuotaMessageAndReportsWrongKeys() {
        // ElevenLabs answers a used-up per-key credit quota with HTTP 401 too.
        let quota = Data(#"{"detail":{"type":"invalid_request","code":"quota_exceeded","message":"This request exceeds your API key (win-prod) quota of 1000.","status":"quota_exceeded"}}"#.utf8)
        let wrongKey = Data(#"{"detail":{"message":"Invalid API key","status":"invalid_api_key"}}"#.utf8)

        guard case .apiError(let message) = ElevenLabsPlugin.unauthorizedError(from: quota) else {
            return XCTFail("A used-up key quota is not a wrong key")
        }
        XCTAssertEqual(message, "This request exceeds your API key (win-prod) quota of 1000.")
        guard case .invalidApiKey = ElevenLabsPlugin.unauthorizedError(from: wrongKey) else {
            return XCTFail("Expected invalidApiKey for a wrong key")
        }
        guard case .invalidApiKey = ElevenLabsPlugin.unauthorizedError(from: Data()) else {
            return XCTFail("Expected invalidApiKey without a body")
        }
    }

    func testAPIKeyValidationRejectsUnrelatedMissingPermission() {
        let data = Data(#"""
        {
            "detail": {
                "message": "The API key is missing the permission speech_to_text.",
                "status": "missing_permissions"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .invalid(message: "The API key is missing the permission speech_to_text.")
        )
    }

    func testAPIKeyValidationRejectsMultipleMissingPermissions() {
        let message = "The API key you used is missing the permissions user_read and speech_to_text."
        let data = Data(#"""
        {
            "detail": {
                "message": "\#(message)",
                "status": "missing_permissions"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .invalid(message: message)
        )
    }

    func testTranscriptionModeDefaultsToAutomaticForMissingOrUnknownValue() throws {
        let defaultHost = try PluginTestHostServices()
        let defaultPlugin = ElevenLabsPlugin()
        defaultPlugin.activate(host: defaultHost)

        XCTAssertEqual(defaultPlugin.transcriptionMode, .automatic)
        XCTAssertTrue(defaultPlugin.supportsStreaming)

        let unknownHost = try PluginTestHostServices(
            defaults: [ElevenLabsPlugin.transcriptionModeKey: "realtimeOnly"]
        )
        let unknownPlugin = ElevenLabsPlugin()
        unknownPlugin.activate(host: unknownHost)

        XCTAssertEqual(unknownPlugin.transcriptionMode, .automatic)
        XCTAssertTrue(unknownPlugin.supportsStreaming)
    }

    func testTranscriptionOptionsUseDictationDefaultsAndInvalidValuesFallbackSafely() throws {
        let defaultHost = try PluginTestHostServices()
        let defaultPlugin = ElevenLabsPlugin()
        defaultPlugin.activate(host: defaultHost)

        XCTAssertFalse(defaultPlugin.tagAudioEvents)
        XCTAssertTrue(defaultPlugin.noVerbatim)
        XCTAssertEqual(defaultPlugin.speakerCount, ElevenLabsPlugin.defaultSpeakerCount)
        XCTAssertTrue(defaultPlugin.useDictionaryTerms)
        XCTAssertEqual(defaultPlugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(
            defaultPlugin.dictionaryTermsBudget,
            DictionaryTermsBudget(maxTerms: 1_000, maxCharsPerTerm: 49, maxWordsPerTerm: 5)
        )

        let invalidHost = try PluginTestHostServices(defaults: [
            ElevenLabsPlugin.tagAudioEventsKey: "true",
            ElevenLabsPlugin.noVerbatimKey: 1,
            ElevenLabsPlugin.speakerCountKey: 33,
            ElevenLabsPlugin.useDictionaryTermsKey: "false",
        ])
        let invalidPlugin = ElevenLabsPlugin()
        invalidPlugin.activate(host: invalidHost)

        XCTAssertFalse(invalidPlugin.tagAudioEvents)
        XCTAssertTrue(invalidPlugin.noVerbatim)
        XCTAssertEqual(invalidPlugin.speakerCount, ElevenLabsPlugin.defaultSpeakerCount)
        XCTAssertTrue(invalidPlugin.useDictionaryTerms)
    }

    func testTranscriptionOptionsPersistAndRestoreExplicitAndAutomaticSpeakerCounts() throws {
        let host = try PluginTestHostServices()
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        plugin.setTagAudioEvents(true)
        plugin.setNoVerbatim(false)
        plugin.setSpeakerCount(12)
        plugin.setUseDictionaryTerms(false)

        XCTAssertEqual(host.userDefault(forKey: ElevenLabsPlugin.tagAudioEventsKey) as? Bool, true)
        XCTAssertEqual(host.userDefault(forKey: ElevenLabsPlugin.noVerbatimKey) as? Bool, false)
        XCTAssertEqual(host.userDefault(forKey: ElevenLabsPlugin.speakerCountKey) as? Int, 12)
        XCTAssertEqual(host.userDefault(forKey: ElevenLabsPlugin.useDictionaryTermsKey) as? Bool, false)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        let reloaded = ElevenLabsPlugin()
        reloaded.activate(host: host)
        XCTAssertTrue(reloaded.tagAudioEvents)
        XCTAssertFalse(reloaded.noVerbatim)
        XCTAssertEqual(reloaded.speakerCount, 12)
        XCTAssertFalse(reloaded.useDictionaryTerms)
        XCTAssertEqual(reloaded.dictionaryTermsSupport, .requiresPluginSetting)

        reloaded.setSpeakerCount(ElevenLabsPlugin.automaticSpeakerCount)
        let automaticReload = ElevenLabsPlugin()
        automaticReload.activate(host: host)
        XCTAssertEqual(automaticReload.speakerCount, ElevenLabsPlugin.automaticSpeakerCount)
    }

    func testTranscriptionModePersistsAndUpdatesStreamingCapability() throws {
        let host = try PluginTestHostServices()
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        plugin.setTranscriptionMode(.restOnly)

        XCTAssertEqual(plugin.transcriptionMode, .restOnly)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(
            host.userDefault(forKey: ElevenLabsPlugin.transcriptionModeKey) as? String,
            ElevenLabsTranscriptionMode.restOnly.rawValue
        )
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setTranscriptionMode(.restOnly)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        let reloadedPlugin = ElevenLabsPlugin()
        reloadedPlugin.activate(host: host)
        XCTAssertEqual(reloadedPlugin.transcriptionMode, .restOnly)
        XCTAssertFalse(reloadedPlugin.supportsStreaming)
    }

    func testRESTOnlyProgressTranscriptionUsesBatchEndpointAndReportsFinalText() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedModel": "scribe_v2",
                ElevenLabsPlugin.transcriptionModeKey: ElevenLabsTranscriptionMode.restOnly.rawValue,
            ],
            secrets: ["api-key": "elevenlabs-key"]
        )
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"REST transcript","language_code":"de"}"#.utf8),
                    Self.httpResponse(url: "https://api.elevenlabs.io/v1/speech-to-text", statusCode: 200)
                )
            ])
        }

        let progressRecorder = StringRecorder()
        let samples = [Float](repeating: 0.1, count: 16_000)
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1),
            language: "de",
            translate: false,
            prompt: "TypeWhisper, Scribe",
            onProgress: { text in
                progressRecorder.append(text)
                return true
            }
        )

        XCTAssertEqual(result.text, "REST transcript")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(progressRecorder.values, ["REST transcript"])

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "elevenlabs-key")

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nde\r\n"))
        XCTAssertTrue(body.contains("name=\"tag_audio_events\"\r\n\r\nfalse\r\n"))
        XCTAssertTrue(body.contains("name=\"no_verbatim\"\r\n\r\ntrue\r\n"))
        XCTAssertTrue(body.contains("name=\"num_speakers\"\r\n\r\n1\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterms\"\r\n\r\nTypeWhisper\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterms\"\r\n\r\nScribe\r\n"))
    }

    func testRESTRequestEncodesCustomBooleanAndSpeakerOptions() async throws {
        let request = try await captureRESTRequest { plugin in
            plugin.setTagAudioEvents(true)
            plugin.setNoVerbatim(false)
            plugin.setSpeakerCount(12)
        }

        XCTAssertEqual(try Self.multipartValues(named: "model_id", in: request), ["scribe_v2"])
        XCTAssertEqual(try Self.multipartValues(named: "language_code", in: request), ["en"])
        XCTAssertEqual(try Self.multipartValues(named: "tag_audio_events", in: request), ["true"])
        XCTAssertEqual(try Self.multipartValues(named: "no_verbatim", in: request), ["false"])
        XCTAssertEqual(try Self.multipartValues(named: "num_speakers", in: request), ["12"])
    }

    func testMedicalModelTranscribesInBatchWithKeytermsAndRetiredModelsMoveToScribeV2() async throws {
        let legacyHost = try PluginTestHostServices(defaults: ["selectedModel": "scribe_v1"])
        let legacyPlugin = ElevenLabsPlugin()
        legacyPlugin.activate(host: legacyHost)
        XCTAssertEqual(legacyPlugin.selectedModelId, "scribe_v2")

        let request = try await captureRESTRequest(
            dictionaryTermHints: [PluginDictionaryTermHint(text: "Metoprolol")]
        ) { plugin in
            plugin.selectModel(ElevenLabsPlugin.medicalModelId)
            XCTAssertFalse(plugin.supportsStreaming)
            XCTAssertEqual(plugin.transcriptionTransport(prompt: nil, dictionaryTermHints: []), .rest)
        }

        XCTAssertEqual(try Self.multipartValues(named: "model_id", in: request), ["scribe_v2_medical"])
        XCTAssertEqual(try Self.multipartValues(named: "keyterms", in: request), ["Metoprolol"])
    }

    func testRESTRequestOmitsAutomaticSpeakerCount() async throws {
        let request = try await captureRESTRequest { plugin in
            plugin.setSpeakerCount(ElevenLabsPlugin.automaticSpeakerCount)
        }

        XCTAssertTrue(try Self.multipartValues(named: "num_speakers", in: request).isEmpty)
    }

    func testRESTTranscriptionReportsWordTimingsAndBuildsSegmentsFromScribeWords() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "scribe_v2"],
            secrets: ["api-key": "elevenlabs-key"]
        )
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        // "Ja." is too short for a segment of its own; the 1.5 s silence
        // before "Danke" starts one; spacing and audio events stay in the text.
        let words: [(String, String, Double, Double)] = [
            ("word", "Ja.", 0.0, 0.3), ("spacing", " ", 0.3, 0.4),
            ("word", "Das", 0.4, 0.6), ("spacing", " ", 0.6, 0.6),
            ("word", "stimmt.", 0.6, 1.0), ("spacing", " ", 1.0, 1.1),
            ("word", "Wir", 1.1, 1.3), ("spacing", " ", 1.3, 1.3),
            ("audio_event", "(lacht)", 1.3, 1.8), ("spacing", " ", 1.8, 1.9),
            ("word", "gehen", 1.9, 2.2), ("spacing", " ", 2.2, 2.2),
            ("word", "jetzt", 2.2, 2.5), ("spacing", " ", 2.5, 4.0),
            ("word", "Danke", 4.0, 4.4),
        ]
        let entries = words.map { #"{"type":"\#($0.0)","text":"\#($0.1)","start":\#($0.2),"end":\#($0.3),"speaker_id":"speaker_0","logprob":0}"# }
        let response = #"{"text":"Ja. Das stimmt. Wir (lacht) gehen jetzt Danke","language_code":"deu","words":[\#(entries.joined(separator: ","))]}"#

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(response.utf8),
                    Self.httpResponse(url: "https://api.elevenlabs.io/v1/speech-to-text", statusCode: 200)
                )
            ])
        }

        let collector = PluginWordTimingCollector()
        let samples = [Float](repeating: 0.1, count: 16_000 * 5)
        let result = try await PluginWordTimings.$collector.withValue(collector) {
            try await plugin.transcribe(
                audio: AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 5),
                language: "de",
                translate: false,
                prompt: nil,
                dictionaryTermHints: []
            )
        }

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(try Self.multipartValues(named: "timestamps_granularity", in: request), ["word"])
        XCTAssertEqual(collector.words, [
            PluginWordTiming(text: "Ja.", start: 0.0, end: 0.3),
            PluginWordTiming(text: "Das", start: 0.4, end: 0.6),
            PluginWordTiming(text: "stimmt.", start: 0.6, end: 1.0),
            PluginWordTiming(text: "Wir", start: 1.1, end: 1.3),
            PluginWordTiming(text: "gehen", start: 1.9, end: 2.2),
            PluginWordTiming(text: "jetzt", start: 2.2, end: 2.5),
            PluginWordTiming(text: "Danke", start: 4.0, end: 4.4),
        ])
        XCTAssertEqual(result.text, "Ja. Das stimmt. Wir (lacht) gehen jetzt Danke")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.map(\.text), ["Ja. Das stimmt.", "Wir (lacht) gehen jetzt", "Danke"])
        XCTAssertEqual(result.segments.map(\.start), [0.0, 1.1, 4.0])
        XCTAssertEqual(result.segments.map(\.end), [1.0, 2.5, 4.4])
    }

    func testRESTRequestFiltersAndNormalizesDictionaryKeyterms() async throws {
        let validFortyNineCharacterTerm = String(repeating: "a", count: 49)
        let invalidFiftyCharacterTerm = String(repeating: "b", count: 50)
        let request = try await captureRESTRequest(dictionaryTermHints: [
            PluginDictionaryTermHint(text: " TypeWhisper "),
            PluginDictionaryTermHint(text: "typewhisper"),
            PluginDictionaryTermHint(text: validFortyNineCharacterTerm),
            PluginDictionaryTermHint(text: invalidFiftyCharacterTerm),
            PluginDictionaryTermHint(text: "one two three four five"),
            PluginDictionaryTermHint(text: "one two three four five six"),
            PluginDictionaryTermHint(text: "bad<term"),
            PluginDictionaryTermHint(text: "Second"),
        ])

        XCTAssertEqual(
            try Self.multipartValues(named: "keyterms", in: request),
            ["TypeWhisper", validFortyNineCharacterTerm, "one two three four five", "Second"]
        )
    }

    func testRESTRequestLimitsDictionaryKeytermsToOneThousand() async throws {
        let hints = (1...1_005).map { PluginDictionaryTermHint(text: "Term\($0)") }
        let request = try await captureRESTRequest(dictionaryTermHints: hints)

        let keyterms = try Self.multipartValues(named: "keyterms", in: request)
        XCTAssertEqual(keyterms.count, 1_000)
        XCTAssertEqual(keyterms.first, "Term1")
        XCTAssertEqual(keyterms.last, "Term1000")
        XCTAssertFalse(keyterms.contains("Term1001"))
    }

    func testRESTRequestExcludesDictionaryKeytermsWhenDisabled() async throws {
        let request = try await captureRESTRequest(
            prompt: "LegacyPromptTerm",
            dictionaryTermHints: [PluginDictionaryTermHint(text: "TypeWhisper")]
        ) { plugin in
            plugin.setUseDictionaryTerms(false)
        }

        XCTAssertTrue(try Self.multipartValues(named: "keyterms", in: request).isEmpty)
    }

    func testRealtimeURLAppliesNoVerbatimWithoutRESTOnlyOptions() throws {
        let cleanURL = try ElevenLabsPlugin.realtimeURL(
            language: "zh",
            noVerbatim: true
        )
        let verbatimURL = try ElevenLabsPlugin.realtimeURL(
            language: nil,
            noVerbatim: false
        )

        let cleanItems = Self.queryItems(in: cleanURL)
        XCTAssertEqual(cleanURL.scheme, "wss")
        XCTAssertEqual(cleanURL.host, "api.elevenlabs.io")
        XCTAssertEqual(cleanItems["model_id"], "scribe_v2_realtime")
        XCTAssertEqual(cleanItems["audio_format"], "pcm_16000")
        XCTAssertEqual(cleanItems["commit_strategy"], "manual")
        XCTAssertEqual(cleanItems["language_code"], "zh")
        XCTAssertEqual(cleanItems["no_verbatim"], "true")
        XCTAssertEqual(cleanItems["include_timestamps"], "true")
        XCTAssertNil(cleanItems["include_language_detection"])
        XCTAssertNil(cleanItems["tag_audio_events"])
        XCTAssertNil(cleanItems["num_speakers"])
        XCTAssertNil(cleanItems["keyterms"])

        let verbatimItems = Self.queryItems(in: verbatimURL)
        XCTAssertEqual(verbatimItems["no_verbatim"], "false")
        XCTAssertNil(verbatimItems["language_code"])
        XCTAssertEqual(verbatimItems["include_language_detection"], "true")
    }

    func testRealtimeSessionErrorsAndScribeLanguageCodesMapToTypeWhisper() {
        // Scribe ends a realtime session for an unknown language with `invalid_request`.
        XCTAssertTrue(ElevenLabsPlugin.isRealtimeError("invalid_request"))
        XCTAssertTrue(ElevenLabsPlugin.isRealtimeError("quota_exceeded"))
        XCTAssertTrue(ElevenLabsPlugin.isRealtimeError("auth_error"))
        XCTAssertFalse(ElevenLabsPlugin.isRealtimeError("warning"))
        XCTAssertFalse(ElevenLabsPlugin.isRealtimeError("partial_transcript"))

        XCTAssertEqual(ElevenLabsLanguageCode.appCode("deu"), "de")
        XCTAssertEqual(ElevenLabsLanguageCode.appCode("nor"), "no")
        XCTAssertEqual(ElevenLabsLanguageCode.appCode("cmn"), "zh")
        XCTAssertEqual(ElevenLabsLanguageCode.appCode("yue"), "yue")
        XCTAssertEqual(ElevenLabsLanguageCode.appCode("en"), "en")
        XCTAssertNil(ElevenLabsLanguageCode.appCode(""))
    }

    func testRoutingPreservesModesAndUsesOnlyEnabledValidDictionaryKeyterms() throws {
        let host = try PluginTestHostServices()
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)
        let validHints = [PluginDictionaryTermHint(text: "TypeWhisper")]
        let invalidHints = [PluginDictionaryTermHint(text: "bad<term")]

        XCTAssertEqual(
            plugin.transcriptionTransport(prompt: nil, dictionaryTermHints: []),
            .realtime
        )
        XCTAssertEqual(
            plugin.transcriptionTransport(prompt: nil, dictionaryTermHints: validHints),
            .rest
        )
        XCTAssertEqual(
            plugin.transcriptionTransport(prompt: nil, dictionaryTermHints: invalidHints),
            .realtime
        )

        plugin.setUseDictionaryTerms(false)
        XCTAssertEqual(
            plugin.transcriptionTransport(prompt: "LegacyPromptTerm", dictionaryTermHints: validHints),
            .realtime
        )

        plugin.setTranscriptionMode(.restOnly)
        XCTAssertEqual(
            plugin.transcriptionTransport(prompt: nil, dictionaryTermHints: []),
            .rest
        )
        XCTAssertFalse(plugin.supportsStreaming)
    }

    func testRealtimeFailurePreservesRESTFallbackBehavior() async throws {
        let calls = StringRecorder()
        let result = try await ElevenLabsPlugin.transcribeWithRESTFallback(
            realtime: {
                calls.append("realtime")
                throw URLError(.cannotConnectToHost)
            },
            rest: {
                calls.append("rest")
                return PluginTranscriptionResult(text: "Fallback transcript", detectedLanguage: "en")
            },
            onRealtimeFailure: { _ in
                calls.append("failure")
            }
        )

        XCTAssertEqual(result.text, "Fallback transcript")
        XCTAssertEqual(calls.values, ["realtime", "failure", "rest"])
    }

    func testLiveSessionsStreamScribeV2InAutoModeOnlyAndNeverFallBackToBatchPreviews() throws {
        let host = try PluginTestHostServices(defaults: ["selectedModel": "scribe_v2"])
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        XCTAssertNotNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: ElevenLabsPlugin.medicalModelId))
        XCTAssertFalse(plugin.allowsTranscriptPreviewFallback)
        XCTAssertEqual(plugin.liveTranscriptionProgressMode, .completeSnapshot)

        plugin.selectModel(ElevenLabsPlugin.medicalModelId)
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)

        plugin.selectModel(ElevenLabsPlugin.defaultModelId)
        plugin.setTranscriptionMode(.restOnly)
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertTrue(plugin.allowsTranscriptPreviewFallback)
    }

    func testLiveSessionStreamsWhileRecordingAndFinishesWithTheAnswerToTheLastCommit() async throws {
        let socket = FakeRealtimeSocket(commitAnswers: [
            (#"{"message_type":"committed_transcript","text":"Hello there."}"#, Self.committedWithTimestamps(
                "Hello there.", language: "de", words: [("Hello", 0.1, 0.4), ("there.", 0.5, 0.9)]
            )),
        ])
        let progress = StringRecorder()
        let session = try await ElevenLabsLiveTranscriptionSession.connect(
            socket: socket,
            language: nil,
            finalTranscriber: nil,
            onProgress: { progress.append($0); return true }
        )

        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 12_000))
        XCTAssertEqual(socket.audioChunks.map(\.sampleCount), [8_000, 4_000])
        XCTAssertEqual(socket.audioChunks.filter(\.commit).count, 0)

        await session.handle(#"{"message_type":"partial_transcript","text":"Hello"}"#)
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hello there.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.map(\.text), ["Hello there."])
        XCTAssertEqual(progress.values, ["Hello", "Hello there."])
        let chunks = socket.audioChunks
        XCTAssertEqual(chunks.filter(\.commit).count, 1)
        XCTAssertEqual(chunks.map(\.sampleCount), [8_000, 4_000, 0])
        XCTAssertTrue(socket.isClosed)
    }

    func testLongLiveSessionCommitsInPausesAndBeforeElevenLabsWouldCommitOnItsOwn() async throws {
        let socket = FakeRealtimeSocket(commitAnswers: [
            (nil, Self.committedWithTimestamps("First part.", words: [("First", 0.5, 1), ("part.", 1, 1.5)])),
            (nil, Self.committedWithTimestamps("Second part.", words: [("Second", 21, 22), ("part.", 22, 23)])),
            (nil, Self.committedWithTimestamps("", words: [])),
        ])
        let session = try await ElevenLabsLiveTranscriptionSession.connect(
            socket: socket,
            language: "en",
            finalTranscriber: nil,
            onProgress: { _ in true }
        )

        // 20.5 s of speech, then a pause: the session commits in the pause.
        for _ in 0..<41 {
            try await session.appendAudio(samples: [Float](repeating: 0.2, count: 8_000))
        }
        XCTAssertEqual(socket.audioChunks.filter(\.commit).count, 0)
        try await session.appendAudio(samples: [Float](repeating: 0, count: 8_000))
        XCTAssertEqual(socket.audioChunks.filter(\.commit).count, 1)

        // 30 s of speech without a pause: the session commits before ElevenLabs would.
        for _ in 0..<60 {
            try await session.appendAudio(samples: [Float](repeating: 0.2, count: 8_000))
        }
        XCTAssertEqual(socket.audioChunks.filter(\.commit).count, 2)

        // A tail shorter than ElevenLabs' minimum is padded with silence before the last commit.
        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 1_600))
        let result = try await session.finish()
        XCTAssertEqual(socket.audioChunks.suffix(3).map(\.sampleCount), [1_600, 4_800, 0])
        XCTAssertEqual(socket.audioChunks.filter(\.commit).count, 3)
        XCTAssertEqual(result.text, "First part. Second part.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.map(\.text), ["First part.", "Second part."])
    }

    func testLiveSessionWithDictionaryTermsTakesTheFinalTextFromTheBatchAPI() async throws {
        let socket = FakeRealtimeSocket(commitAnswers: [
            (nil, Self.committedWithTimestamps("type whisper", words: [])),
        ])
        let batchCalls = TimeoutRecorder()
        let batchFails = OSAllocatedUnfairLock(initialState: false)
        let connect = {
            try await ElevenLabsLiveTranscriptionSession.connect(
                socket: socket,
                language: "en",
                finalTranscriber: { audio in
                    batchCalls.append(audio.duration)
                    if batchFails.withLock({ $0 }) { throw URLError(.timedOut) }
                    return PluginTranscriptionResult(text: "TypeWhisper", detectedLanguage: "en")
                },
                onProgress: { _ in true }
            )
        }

        let session = try await connect()
        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 16_000))
        let result = try await session.finish()
        XCTAssertEqual(result.text, "TypeWhisper")
        XCTAssertEqual(batchCalls.values, [1])

        // Without the batch result, the realtime transcript is the final text.
        batchFails.withLock { $0 = true }
        socket.reset(commitAnswers: [(nil, Self.committedWithTimestamps("type whisper", words: []))])
        let fallbackSession = try await connect()
        try await fallbackSession.appendAudio(samples: [Float](repeating: 0.2, count: 16_000))
        let fallback = try await fallbackSession.finish()
        XCTAssertEqual(fallback.text, "type whisper")
    }

    func testLiveSessionFailsWhenElevenLabsEndsItOrLeavesTheLastCommitUnanswered() async throws {
        let failingSocket = FakeRealtimeSocket(commitAnswers: [])
        let failingSession = try await ElevenLabsLiveTranscriptionSession.connect(
            socket: failingSocket,
            language: nil,
            finalTranscriber: nil,
            onProgress: { _ in true }
        )
        await failingSession.handle(#"{"message_type":"session_time_limit_exceeded","error":"Maximum session time reached"}"#)
        do {
            try await failingSession.appendAudio(samples: [Float](repeating: 0.2, count: 1_600))
            XCTFail("Appending after a session error should fail")
        } catch {
            XCTAssertEqual(error.localizedDescription, PluginTranscriptionError.apiError("Maximum session time reached").localizedDescription)
        }
        XCTAssertTrue(failingSocket.isClosed)

        // The socket closes without answering the final commit.
        let silentSocket = FakeRealtimeSocket(commitAnswers: [], closesOnCommit: true)
        let silentSession = try await ElevenLabsLiveTranscriptionSession.connect(
            socket: silentSocket,
            language: nil,
            finalTranscriber: nil,
            onProgress: { _ in true }
        )
        try await silentSession.appendAudio(samples: [Float](repeating: 0.2, count: 16_000))
        do {
            _ = try await silentSession.finish()
            XCTFail("A session without the answer to its last commit should fail")
        } catch {}
    }

    func testAutomaticModeStreamsOnlyRecordingsThatFitIntoOneCommit() {
        // The realtime API commits on its own after about 36 seconds.
        XCTAssertEqual(
            ElevenLabsPlugin.transcriptionTransport(mode: .automatic, keyterms: [], audioDuration: 30),
            .realtime
        )
        XCTAssertEqual(
            ElevenLabsPlugin.transcriptionTransport(mode: .automatic, keyterms: [], audioDuration: 31),
            .rest
        )
        XCTAssertEqual(
            ElevenLabsPlugin.transcriptionTransport(mode: .restOnly, keyterms: [], audioDuration: 1),
            .rest
        )
    }

    func testRESTTimeoutsGrowWithAudioDuration() {
        let short = ElevenLabsPlugin.restTimeouts(forAudioDuration: 60)
        XCTAssertEqual(short.request, 120)
        XCTAssertEqual(short.resource, 600)

        let twoHours = ElevenLabsPlugin.restTimeouts(forAudioDuration: 2 * 3_600)
        XCTAssertEqual(twoHours.request, 480)
        XCTAssertEqual(twoHours.resource, 960)

        let fourHours = ElevenLabsPlugin.restTimeouts(forAudioDuration: 4 * 3_600)
        XCTAssertEqual(fourHours.request, 960)
        XCTAssertEqual(fourHours.resource, 1_920)

        let beyondLimit = ElevenLabsPlugin.restTimeouts(forAudioDuration: 20 * 3_600)
        XCTAssertEqual(beyondLimit.request, 2_400)
        XCTAssertEqual(beyondLimit.resource, 7_200)
    }

    func testShortRESTRequestKeepsDefaultTimeouts() async throws {
        let resourceTimeouts = TimeoutRecorder()
        let request = try await captureRESTRequest(resourceTimeouts: resourceTimeouts)

        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(resourceTimeouts.values, [600])
    }

    func testLongRecordingInAutomaticModeUsesBatchEndpointWithLongTimeouts() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "scribe_v2"],
            secrets: ["api-key": "elevenlabs-key"]
        )
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)
        XCTAssertTrue(plugin.supportsStreaming)

        let store = PluginHTTPClientSessionStore()
        let resourceTimeouts = TimeoutRecorder()
        PluginHTTPClientTestHarness.configure { configuration in
            resourceTimeouts.append(configuration.timeoutIntervalForResource)
            return store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"Long transcript","language_code":"de"}"#.utf8),
                    Self.httpResponse(url: "https://api.elevenlabs.io/v1/speech-to-text", statusCode: 200)
                )
            ])
        }

        // The duration drives routing and timeouts; one second of samples keeps encoding fast.
        let samples = [Float](repeating: 0.3, count: 16_000)
        let progressRecorder = StringRecorder()
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: Data(), duration: 2 * 3_600),
            language: "de",
            translate: false,
            prompt: nil,
            onProgress: { text in
                progressRecorder.append(text)
                return true
            }
        )

        XCTAssertEqual(result.text, "Long transcript")
        XCTAssertEqual(progressRecorder.values, ["Long transcript"])
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text")
        XCTAssertEqual(request.timeoutInterval, 480)
        XCTAssertEqual(resourceTimeouts.values, [960])
    }

    func testSettingsUIExposesLocalizedOptionsAndStableAccessibilityIdentifiers() throws {
        let source = try String(
            contentsOf: Self.pluginRoot.appendingPathComponent("ElevenLabsPlugin.swift"),
            encoding: .utf8
        )
        let catalogData = try Data(
            contentsOf: Self.pluginRoot.appendingPathComponent("Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let requiredKeys = [
            "Transcription options",
            "Clean transcript",
            "Removes filler words, false starts, and other speech disfluencies using ElevenLabs' native non-verbatim mode.",
            "Audio events",
            "Include non-speech events such as [laughter] or [background music]. Applies to REST transcription only.",
            "Audio events and Clean transcript can be enabled together.",
            "Speaker count",
            "Choose Automatic or the maximum number of speakers (1–32). Applies to REST transcription only.",
            "Use TypeWhisper dictionary terms",
            "Sends active TypeWhisper dictionary terms to ElevenLabs as recognition keyterms. ElevenLabs adds a 20% keyterm surcharge.",
            "Tuned for clinical audio, at the Scribe v2 price. Batch only, without realtime streaming.",
            "Auto streams while you dictate, so the live preview and the final text come from one realtime session, and falls back to batch REST. With active dictionary terms, the final text comes from batch REST, so dictations with a live preview are billed for both. REST only avoids realtime concurrency limits and bills the batch rate.",
        ]

        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing localization key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["de", "ja", "zh-Hans"] {
                XCTAssertNotNil(localizations[language], "Missing \(language) localization for \(key)")
            }
            XCTAssertTrue(source.contains(key), "Settings UI should use \(key)")
        }

        XCTAssertTrue(source.contains(".accessibilityIdentifier(ElevenLabsSettingsAccessibility.cleanTranscript)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(ElevenLabsSettingsAccessibility.audioEvents)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(ElevenLabsSettingsAccessibility.speakerCount)"))
        XCTAssertTrue(source.contains(".accessibilityIdentifier(ElevenLabsSettingsAccessibility.useDictionaryTerms)"))
        XCTAssertEqual(ElevenLabsSettingsAccessibility.cleanTranscript, "ElevenLabsCleanTranscript")
        XCTAssertEqual(ElevenLabsSettingsAccessibility.audioEvents, "ElevenLabsAudioEvents")
        XCTAssertEqual(ElevenLabsSettingsAccessibility.speakerCount, "ElevenLabsSpeakerCount")
        XCTAssertEqual(ElevenLabsSettingsAccessibility.useDictionaryTerms, "ElevenLabsUseDictionaryTerms")
    }

    private func captureRESTRequest(
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        resourceTimeouts: TimeoutRecorder = TimeoutRecorder(),
        configure: (ElevenLabsPlugin) -> Void = { _ in }
    ) async throws -> URLRequest {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "scribe_v2"],
            secrets: ["api-key": "elevenlabs-key"]
        )
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)
        configure(plugin)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { configuration in
            resourceTimeouts.append(configuration.timeoutIntervalForResource)
            return store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"REST transcript","language_code":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.elevenlabs.io/v1/speech-to-text", statusCode: 200)
                )
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        _ = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1),
            language: "en",
            translate: false,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints
        )

        return try XCTUnwrap(store.sessions.first?.requestedRequests.first)
    }

    private static func multipartValues(named name: String, in request: URLRequest) throws -> [String] {
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let marker = "name=\"\(name)\"\r\n\r\n"
        return body.components(separatedBy: marker).dropFirst().compactMap { remainder in
            remainder.components(separatedBy: "\r\n").first
        }
    }

    private static func queryItems(in url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private static var pluginRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func committedWithTimestamps(
        _ text: String,
        language: String? = nil,
        words: [(String, Double, Double)]
    ) -> String {
        var entries: [[String: Any]] = []
        for (index, word) in words.enumerated() {
            if index > 0 {
                entries.append(["text": " ", "type": "spacing", "start": word.1, "end": word.1])
            }
            entries.append(["text": word.0, "type": "word", "start": word.1, "end": word.2])
        }
        var json: [String: Any] = [
            "message_type": "committed_transcript_with_timestamps",
            "text": text,
            "words": entries,
        ]
        json["language_code"] = language
        let data = try! JSONSerialization.data(withJSONObject: json)
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

    func testRealtimeCommitsInJapaneseJoinWithoutASpace() {
        let entries = ElevenLabsTimedTranscriptParser.appending(
            ElevenLabsTimedTranscriptParser.entries(from: [["text": "です", "type": "word", "start": 0.6, "end": 0.9]]),
            to: ElevenLabsTimedTranscriptParser.entries(from: [["text": "学校", "type": "word", "start": 0.0, "end": 0.5]])
        )

        let transcript = ElevenLabsTimedTranscriptParser.transcript(text: "学校です", detectedLanguage: "ja", entries: entries)

        XCTAssertEqual(transcript.result.segments.map(\.text), ["学校です"])
    }

    func testRealtimeCommitTextsJoinWithASpaceOnlyBetweenSpacedScripts() {
        XCTAssertEqual(ElevenLabsTimedTranscriptParser.joinedText(["Hello there.", "How are you?"]), "Hello there. How are you?")
        XCTAssertEqual(ElevenLabsTimedTranscriptParser.joinedText(["学校", "です", ""]), "学校です")
        XCTAssertEqual(ElevenLabsTimedTranscriptParser.joinedText(["ใช้", "ChatGPT"]), "ใช้ ChatGPT")
    }

    func testRealtimeCommitsKeepASpaceBetweenTheirWords() {
        let first = ElevenLabsTimedTranscriptParser.entries(from: [
            ["text": "the", "type": "word", "start": 0.0, "end": 0.3],
        ])
        let second = ElevenLabsTimedTranscriptParser.entries(from: [
            ["text": "cat", "type": "word", "start": 0.8, "end": 1.1],
        ])
        let entries = ElevenLabsTimedTranscriptParser.appending(
            second,
            to: ElevenLabsTimedTranscriptParser.appending(first, to: [])
        )

        let transcript = ElevenLabsTimedTranscriptParser.transcript(text: "the cat", detectedLanguage: "en", entries: entries)

        XCTAssertEqual(transcript.result.segments.map(\.text), ["the cat"])
        XCTAssertEqual(transcript.words.map(\.text), ["the", "cat"])
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let valuesLock = OSAllocatedUnfairLock(initialState: [String]())

    var values: [String] {
        valuesLock.withLock { $0 }
    }

    func append(_ value: String) {
        valuesLock.withLock { $0.append(value) }
    }
}

private final class TimeoutRecorder: @unchecked Sendable {
    private let valuesLock = OSAllocatedUnfairLock(initialState: [TimeInterval]())

    var values: [TimeInterval] {
        valuesLock.withLock { $0 }
    }

    func append(_ value: TimeInterval) {
        valuesLock.withLock { $0.append(value) }
    }
}

/// Plays the realtime API: starts the session, records the audio chunks and answers
/// each commit with the next scripted messages.
private final class FakeRealtimeSocket: ElevenLabsRealtimeSocket, @unchecked Sendable {
    struct AudioChunk {
        let sampleCount: Int
        let commit: Bool
    }

    private struct State {
        var chunks: [AudioChunk] = []
        var commitAnswers: [(String?, String)] = []
        var closesOnCommit = false
        var isClosed = false
        var stream: AsyncThrowingStream<String, Error>?
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(commitAnswers: [(String?, String)], closesOnCommit: Bool = false) {
        reset(commitAnswers: commitAnswers, closesOnCommit: closesOnCommit)
    }

    func reset(commitAnswers: [(String?, String)], closesOnCommit: Bool = false) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.yield(#"{"message_type":"session_started","session_id":"test","config":{}}"#)
        state.withLock {
            $0 = State(commitAnswers: commitAnswers, closesOnCommit: closesOnCommit, stream: stream, continuation: continuation)
        }
    }

    var audioChunks: [AudioChunk] { state.withLock { $0.chunks } }
    var isClosed: Bool { state.withLock { $0.isClosed } }

    func send(_ text: String) async throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let audio = try XCTUnwrap(Data(base64Encoded: json["audio_base_64"] as? String ?? ""))
        let commit = json["commit"] as? Bool ?? false
        let (answers, continuation, closes) = state.withLock { state -> ([String], AsyncThrowingStream<String, Error>.Continuation?, Bool) in
            state.chunks.append(AudioChunk(sampleCount: audio.count / 2, commit: commit))
            guard commit else { return ([], nil, false) }
            if state.closesOnCommit { return ([], state.continuation, true) }
            guard !state.commitAnswers.isEmpty else { return ([], nil, false) }
            let answer = state.commitAnswers.removeFirst()
            return ([answer.0, answer.1].compactMap { $0 }, state.continuation, false)
        }
        if closes {
            continuation?.finish(throwing: URLError(.networkConnectionLost))
        }
        answers.forEach { continuation?.yield($0) }
    }

    func receive() async throws -> String {
        let stream = state.withLock { $0.stream }
        guard var iterator = stream?.makeAsyncIterator() else { throw URLError(.cancelled) }
        guard let message = try await iterator.next() else { throw URLError(.cancelled) }
        return message
    }

    func close() {
        let continuation = state.withLock { state -> AsyncThrowingStream<String, Error>.Continuation? in
            state.isClosed = true
            return state.continuation
        }
        continuation?.finish()
    }

}
