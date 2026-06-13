import Foundation
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
import XCTest
@testable import CartesiaPlugin

final class CartesiaPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testPluginAdvertisesTranscriptionAndTTSProtocols() throws {
        let cartesiaPlugin = CartesiaPlugin()
        cartesiaPlugin.activate(host: try PluginTestHostServices())
        let plugin: Any = cartesiaPlugin

        XCTAssertTrue(plugin is any TranscriptionEnginePlugin)
        XCTAssertTrue(plugin is any LanguageHintTranscriptionEnginePlugin)
        XCTAssertTrue(plugin is any TTSProviderPlugin)
        let transcriptionPlugin = try XCTUnwrap(plugin as? any TranscriptionEnginePlugin)
        XCTAssertFalse(transcriptionPlugin.supportsTranslation)
    }

    func testTranslationCapabilityIsNeverAdvertised() throws {
        let plugin = CartesiaPlugin()
        plugin.activate(host: try PluginTestHostServices(secrets: ["api-key": "sk_car_live"]))
        XCTAssertFalse(plugin.supportsTranslation)

        let pluginWithStaleTranslationDefault = CartesiaPlugin()
        pluginWithStaleTranslationDefault.activate(host: try PluginTestHostServices(
            defaults: ["englishTranslationEnabled": true],
            secrets: ["api-key": "sk_car_live"]
        ))
        XCTAssertFalse(pluginWithStaleTranslationDefault.supportsTranslation)
    }

    func testAuthRolesRequireCartesiaAPIKeyForSTTAndTTS() throws {
        let plugin = CartesiaPlugin()
        plugin.activate(host: try PluginTestHostServices())

        XCTAssertFalse(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .tts).isAvailable)

        let configuredPlugin = CartesiaPlugin()
        configuredPlugin.activate(host: try PluginTestHostServices(secrets: ["api-key": "sk_car_live"]))

        XCTAssertTrue(configuredPlugin.authStatus(for: .transcription).isAvailable)
        XCTAssertTrue(configuredPlugin.authStatus(for: .tts).isAvailable)
        XCTAssertFalse(configuredPlugin.authStatus(for: .llm).isAvailable)
    }

    func testDeactivateClearsCachedConfigurationSnapshot() async throws {
        let fetchedVoices = try JSONEncoder().encode([
            CartesiaFetchedVoice(id: "voice-x", name: "Voice X", language: "en", country: "US")
        ])
        let plugin = CartesiaPlugin()
        plugin.activate(host: try PluginTestHostServices(
            defaults: [
                "transcriptionLanguage": "en",
                "englishTranslationEnabled": true,
                "selectedVoice": "voice-x",
                "customVoiceId": "custom-voice",
                "fetchedVoices": fetchedVoices,
            ],
            secrets: ["api-key": "sk_car_live"]
        ))

        XCTAssertTrue(plugin.isConfigured)
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertEqual(plugin.selectedVoiceId, "custom-voice")
        XCTAssertEqual(plugin.availableVoices.map(\.id), ["voice-x"])

        plugin.deactivate()

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertEqual(plugin.selectedVoiceId, CartesiaPlugin.defaultVoiceId)
        XCTAssertEqual(plugin.availableVoices.map(\.id), [CartesiaPlugin.defaultVoiceId])

        do {
            _ = try await plugin.transcribe(
                audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
                language: "en-US",
                translate: false,
                prompt: nil
            )
            XCTFail("Expected deactivated plugin to require configuration")
        } catch PluginTranscriptionError.notConfigured {
            // Expected.
        }
    }

    func testLanguageResolutionUsesPrimarySubtagAndDropsUnsupportedValues() {
        XCTAssertEqual(
            CartesiaPlugin.resolvedLanguage("de-DE", supportedLanguages: CartesiaPlugin.sttSupportedLanguages),
            "de"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedLanguage("pt_BR", supportedLanguages: CartesiaPlugin.sttSupportedLanguages),
            "pt"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedLanguage("yue-HK", supportedLanguages: CartesiaPlugin.sttSupportedLanguages),
            "yue"
        )
        XCTAssertNil(CartesiaPlugin.resolvedLanguage("xx", supportedLanguages: CartesiaPlugin.sttSupportedLanguages))
        XCTAssertNil(CartesiaPlugin.resolvedLanguage("  ", supportedLanguages: CartesiaPlugin.sttSupportedLanguages))
    }

    func testTranscriptionLanguageResolutionUsesSelectedHintsAndConfiguredLanguage() {
        XCTAssertEqual(
            CartesiaPlugin.resolvedTranscriptionLanguage(
                requestedLanguage: nil,
                languageHints: [],
                configuredLanguage: "ru-RU"
            ),
            "ru"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedTranscriptionLanguage(
                requestedLanguage: " ",
                languageHints: [],
                configuredLanguage: "de-DE"
            ),
            "de"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedTranscriptionLanguage(
                requestedLanguage: nil,
                languageHints: ["en-US", "de-DE"],
                configuredLanguage: "ru"
            ),
            "en"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedTranscriptionLanguage(
                requestedLanguage: "de-DE",
                languageHints: ["en-US"],
                configuredLanguage: "ru"
            ),
            "de"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedTranscriptionLanguage(
                requestedLanguage: nil,
                languageHints: [],
                configuredLanguage: "xx-YY"
            ),
            "en"
        )
        XCTAssertEqual(
            CartesiaPlugin.resolvedTranscriptionLanguage(
                requestedLanguage: "ru-RU",
                languageHints: [],
                configuredLanguage: "ru-RU"
            ),
            "ru"
        )
    }

    func testTranscriptionRequestUsesNativeCartesiaEndpointHeadersLanguageAndWordTimestamps() throws {
        let request = try CartesiaPlugin.makeTranscriptionRequest(
            wavData: Data("wav".utf8),
            apiKey: "sk_car_test",
            modelId: CartesiaPlugin.sttModelId,
            language: "de"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.cartesia.ai")
        XCTAssertEqual(request.url?.path, "/stt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk_car_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaPlugin.apiVersion)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertEqual(request.timeoutInterval, 600)

        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains(#"name="file"; filename="audio.wav""#))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nink-whisper"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(body.contains("name=\"timestamp_granularities[]\"\r\n\r\nword"))
    }

    func testTTSRequestUsesBytesEndpointRawPCMVoiceLanguageAndVersionHeader() throws {
        let request = try CartesiaPlugin.makeTTSRequest(
            apiKey: "sk_car_test",
            text: "Hello",
            voiceId: "voice-1",
            language: "en",
            modelId: CartesiaPlugin.ttsModelId
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.cartesia.ai")
        XCTAssertEqual(request.url?.path, "/tts/bytes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk_car_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaPlugin.apiVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model_id"] as? String, "sonic-3.5")
        XCTAssertEqual(json["transcript"] as? String, "Hello")
        XCTAssertEqual(json["language"] as? String, "en")

        let voice = try XCTUnwrap(json["voice"] as? [String: Any])
        XCTAssertEqual(voice["mode"] as? String, "id")
        XCTAssertEqual(voice["id"] as? String, "voice-1")

        let outputFormat = try XCTUnwrap(json["output_format"] as? [String: Any])
        XCTAssertEqual(outputFormat["container"] as? String, "raw")
        XCTAssertEqual(outputFormat["encoding"] as? String, "pcm_s16le")
        XCTAssertEqual(outputFormat["sample_rate"] as? Int, 44_100)
    }

    func testListVoicesRequestUsesCartesiaVersionAndLimit() throws {
        let request = try CartesiaPlugin.makeListVoicesRequest(apiKey: "sk_car_test", limit: 1)

        XCTAssertEqual(request.url?.host, "api.cartesia.ai")
        XCTAssertEqual(request.url?.path, "/voices")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk_car_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaPlugin.apiVersion)

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["limit"], "1")
    }

    func testParseTranscriptionResponseBuildsWordSegments() throws {
        let result = try CartesiaPlugin.parseTranscriptionResponse(
            Data(
                """
                {
                  "type": "transcript",
                  "text": "Hello world",
                  "language": "en",
                  "words": [
                    { "word": "Hello", "start": 0.1, "end": 0.4 },
                    { "word": "world", "start": 0.5, "end": 0.9 }
                  ]
                }
                """.utf8
            ),
            fallbackLanguage: "de"
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "Hello")
        XCTAssertEqual(result.segments[0].start, 0.1)
        XCTAssertEqual(result.segments[1].text, "world")
        XCTAssertEqual(result.segments[1].end, 0.9)
    }

    func testTranscribeSendsRequestAndParsesResponse() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "sk_car_live"])
        let plugin = CartesiaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "type": "transcript",
                          "text": "Hallo Welt",
                          "language": "de",
                          "words": [
                            { "word": "Hallo", "start": 0.0, "end": 0.3 },
                            { "word": "Welt", "start": 0.4, "end": 0.7 }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 200)
                )
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            language: "de-DE",
            translate: false,
            prompt: "ignored"
        )

        XCTAssertEqual(result.text, "Hallo Welt")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.count, 2)

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/stt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cartesia-Version"), CartesiaPlugin.apiVersion)

        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde"))
    }

    func testTranscribeDefaultsToEnglishWhenNoLanguageConfigured() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "sk_car_live"])
        let plugin = CartesiaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"type":"transcript","text":"Hello, how are you?","language":"en","words":[]}"#.utf8),
                    Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 200)
                )
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            language: nil,
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Hello, how are you?")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
    }

    func testTranscribeUsesConfiguredEnglishLanguageWhenSelected() async throws {
        let host = try PluginTestHostServices(
            defaults: ["transcriptionLanguage": "en"],
            secrets: ["api-key": "sk_car_live"]
        )
        let plugin = CartesiaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"type":"transcript","text":"Hello","language":"en","words":[]}"#.utf8),
                    Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 200)
                )
            ])
        }

        _ = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            language: nil,
            translate: false,
            prompt: nil
        )

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
    }

    func testTranscribeIgnoresTranslateTaskWhenPluginTranslationIsDisabled() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "sk_car_live"])
        let plugin = CartesiaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"type":"transcript","text":"Привет, как дела?","language":"ru","words":[]}"#.utf8),
                    Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 200)
                )
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            language: "ru-RU",
            translate: true,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Привет, как дела?")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru"))
    }

    func testTranscribeIgnoresStaleEnglishTranslationDefault() async throws {
        let host = try PluginTestHostServices(
            defaults: ["englishTranslationEnabled": true],
            secrets: ["api-key": "sk_car_live"]
        )
        let plugin = CartesiaPlugin()
        plugin.activate(host: host)
        XCTAssertFalse(plugin.supportsTranslation)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"type":"transcript","text":"Привет, как дела?","language":"ru","words":[]}"#.utf8),
                    Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 200)
                )
            ])
        }

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            language: "ru-RU",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Привет, как дела?")
        XCTAssertEqual(result.detectedLanguage, "ru")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru"))
    }

    func testTranscribeUsesFirstLanguageHintWhenNoExactLanguageSelected() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "sk_car_live"])
        let plugin = CartesiaPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"type":"transcript","text":"Hello","language":"en","words":[]}"#.utf8),
                    Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 200)
                )
            ])
        }

        _ = try await plugin.transcribe(
            audio: AudioData(samples: [0], wavData: Data("wav".utf8), duration: 1),
            languageSelection: PluginLanguageSelection(languageHints: ["en-US", "de-DE"]),
            translate: false,
            prompt: nil
        )

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
    }

    func testParseVoicesResponseSortsAndBuildsLocales() throws {
        let voices = try CartesiaPlugin.parseVoicesResponse(
            Data(
                """
                {
                  "data": [
                    {
                      "id": "voice-b",
                      "name": "Zara",
                      "language": "en",
                      "country": "US"
                    },
                    {
                      "id": "voice-a",
                      "name": "Ana",
                      "language": "es",
                      "country": "ES"
                    }
                  ],
                  "has_more": false,
                  "next_page": null
                }
                """.utf8
            )
        )

        XCTAssertEqual(voices.map(\.id), ["voice-a", "voice-b"])
        XCTAssertEqual(voices[0].localeIdentifier, "es-ES")
        XCTAssertEqual(voices[1].localeIdentifier, "en-US")
    }

    func testHTTPStatusMapping() {
        XCTAssertThrowsError(try CartesiaPlugin.validateHTTPResponse(
            data: Data(#"{"message":"bad key"}"#.utf8),
            response: Self.httpResponse(url: "https://api.cartesia.ai/stt", statusCode: 403)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(
            CartesiaPlugin.apiKeyValidationResult(
                data: Data(),
                response: Self.httpResponse(url: "https://api.cartesia.ai/voices", statusCode: 401)
            ),
            .invalidKey
        )
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
