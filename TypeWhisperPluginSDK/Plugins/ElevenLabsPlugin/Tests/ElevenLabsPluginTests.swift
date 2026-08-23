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

    func testRESTRequestOmitsAutomaticSpeakerCount() async throws {
        let request = try await captureRESTRequest { plugin in
            plugin.setSpeakerCount(ElevenLabsPlugin.automaticSpeakerCount)
        }

        XCTAssertTrue(try Self.multipartValues(named: "num_speakers", in: request).isEmpty)
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
            modelId: "scribe_v2",
            noVerbatim: true
        )
        let verbatimURL = try ElevenLabsPlugin.realtimeURL(
            language: nil,
            modelId: "scribe_v2",
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
        XCTAssertNil(cleanItems["tag_audio_events"])
        XCTAssertNil(cleanItems["num_speakers"])
        XCTAssertNil(cleanItems["keyterms"])

        let verbatimItems = Self.queryItems(in: verbatimURL)
        XCTAssertEqual(verbatimItems["no_verbatim"], "false")
        XCTAssertNil(verbatimItems["language_code"])
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
            "Speaker count",
            "Choose Automatic or the maximum number of speakers (1–32). Applies to REST transcription only.",
            "Use TypeWhisper dictionary terms",
            "Sends active TypeWhisper dictionary terms to ElevenLabs as recognition keyterms. ElevenLabs adds a 20% keyterm surcharge.",
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
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
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

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
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
