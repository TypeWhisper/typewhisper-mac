import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenAIPlugin
import os

final class OpenAIPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testOpenAIPluginAdvertisesLiveSTTAndTTSProtocols() {
        let plugin: Any = OpenAIPlugin()

        XCTAssertTrue(plugin is any LiveTranscriptionCapablePlugin)
        XCTAssertTrue(plugin is any LanguageHintDictionaryTermHintTranscriptionEnginePlugin)
        XCTAssertTrue(plugin is any LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin)
        XCTAssertTrue(plugin is any TTSProviderPlugin)
    }

    func testOpenAINewInstallDefaultsToGPTTranscribeAndKeepsLegacyModels() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAIPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "gpt-transcribe")
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.id),
            [
                "gpt-transcribe",
                "gpt-live-transcribe",
                "whisper-1",
                "gpt-4o-transcribe",
                "gpt-4o-mini-transcribe",
                "gpt-realtime-whisper",
            ]
        )
        XCTAssertNil(host.userDefault(forKey: "selectedModel"))
    }

    func testOpenAIActivationPreservesPersistedLegacyModelSelection() throws {
        let host = try PluginTestHostServices(defaults: ["selectedModel": "gpt-4o-mini-transcribe"])
        let plugin = OpenAIPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "gpt-4o-mini-transcribe")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "gpt-4o-mini-transcribe")
    }

    func testOpenAIContextAndLiveDelayPersistWithLowAsDefault() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.transcriptionContext, "")
        XCTAssertEqual(plugin.liveTranscriptionDelay, .low)

        plugin.setTranscriptionContext("A TypeWhisper product interview.")
        plugin.setLiveTranscriptionDelay(.high)

        XCTAssertEqual(
            host.userDefault(forKey: "transcriptionContext") as? String,
            "A TypeWhisper product interview."
        )
        XCTAssertEqual(host.userDefault(forKey: "liveTranscriptionDelay") as? String, "high")

        let restoredPlugin = OpenAIPlugin()
        restoredPlugin.activate(host: host)
        XCTAssertEqual(restoredPlugin.transcriptionContext, "A TypeWhisper product interview.")
        XCTAssertEqual(restoredPlugin.liveTranscriptionDelay, .high)
    }

    func testOpenAIFallbackModelsIncludeGPT55First() {
        let plugin = OpenAIPlugin()

        XCTAssertEqual(plugin.supportedModels.first?.id, "gpt-5.5")
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "gpt-5.5" })
    }

    func testOpenAIChatGPTLoginFallbackIncludesCurrentGPT56Models() throws {
        let host = try PluginTestHostServices(defaults: ["authMode": "chatgpt"])
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            Array(plugin.supportedModels.prefix(3).map(\.id)),
            ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        )
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-5.6-sol")
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "gpt-5.5" })
    }

    func testOpenAIChatGPTLoginOnlyMakesLLMAuthRoleAvailable() throws {
        let host = try PluginTestHostServices(
            defaults: ["authMode": "chatgpt"],
            secrets: ["oauth-refresh-token": "refresh-token"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.authStatus(for: .llm).isAvailable)

        let transcriptionStatus = plugin.authStatus(for: .transcription)
        XCTAssertFalse(transcriptionStatus.isAvailable)
        XCTAssertEqual(transcriptionStatus.requiredCredentialLabel, "OpenAI API key")
        XCTAssertEqual(
            transcriptionStatus.unavailableReason,
            "ChatGPT Login only enables prompt processing. OpenAI transcription requires an OpenAI API key."
        )

        let ttsStatus = plugin.authStatus(for: .tts)
        XCTAssertFalse(ttsStatus.isAvailable)
        XCTAssertEqual(ttsStatus.requiredCredentialLabel, "OpenAI API key")
    }

    func testOpenAIAPIKeyMakesLLMTranscriptionAndTTSAuthRolesAvailable() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "sk-live"])
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.authStatus(for: .llm).isAvailable)
        XCTAssertTrue(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertTrue(plugin.authStatus(for: .tts).isAvailable)
    }

    func testOpenAITranscribeUploadsCompressedM4AForRESTModels() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-1"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.openai.com/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
        XCTAssertFalse(body.contains(#"filename="audio.wav""#))
    }

    func testOpenAITranscribeRetriesWithWavWhenM4AIsRejected() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-1"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":"unsupported audio format"}"#.utf8),
                    Self.httpResponse(url: "https://api.openai.com/v1/audio/transcriptions", statusCode: 415)
                ),
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(url: "https://api.openai.com/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: "TypeWhisper")

        XCTAssertEqual(result.text, "hello")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
    }

    func testGPTTranscribeSendsContextKeywordsAndOrderedLanguageHints() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedModel": "gpt-transcribe",
                "transcriptionContext": "  A support call about account AC-42.  ",
            ],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"Bonjour","languages":[{"code":"fr"},{"code":"en"}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.testAudio(),
            languageSelection: PluginLanguageSelection(
                languageHints: ["de", "en", "DE", " "]
            ),
            translate: false,
            prompt: "legacy dictionary prompt",
            dictionaryTermHints: [
                PluginDictionaryTermHint(text: " TypeWhisper "),
                PluginDictionaryTermHint(text: "typewhisper"),
                PluginDictionaryTermHint(text: "AC-42"),
                PluginDictionaryTermHint(text: "bad<term"),
                PluginDictionaryTermHint(text: "bad\nterm"),
                PluginDictionaryTermHint(text: "München"),
            ]
        )

        XCTAssertEqual(result.text, "Bonjour")
        XCTAssertEqual(result.detectedLanguage, "fr")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/v1/audio/transcriptions")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains(
            "name=\"prompt\"\r\n\r\nA support call about account AC-42."
        ))
        XCTAssertFalse(body.contains("legacy dictionary prompt"))
        XCTAssertEqual(Self.formValues(named: "keywords[]", in: body), [
            "TypeWhisper",
            "AC-42",
            "München",
        ])
        XCTAssertEqual(Self.formValues(named: "languages[]", in: body), ["de", "en"])
        XCTAssertFalse(body.contains("name=\"language\"\r\n"))
    }

    func testGPTTranscribeOmitsEmptyContextKeywordsAndLanguages() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedModel": "gpt-transcribe",
                "transcriptionContext": " \n ",
            ],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"Hello","languages":[]}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.testAudio(),
            languageSelection: PluginLanguageSelection(),
            translate: false,
            prompt: nil,
            dictionaryTermHints: [
                PluginDictionaryTermHint(text: "invalid>keyword"),
                PluginDictionaryTermHint(text: "\n"),
            ]
        )

        XCTAssertNil(result.detectedLanguage)
        let body = String(
            decoding: try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody),
            as: UTF8.self
        )
        XCTAssertFalse(body.contains("name=\"prompt\"\r\n"))
        XCTAssertFalse(body.contains("name=\"keywords[]\"\r\n"))
        XCTAssertFalse(body.contains("name=\"languages[]\"\r\n"))
        XCTAssertFalse(body.contains("name=\"language\"\r\n"))
    }

    func testGPTTranscribeRetriesWithWavAndKeepsContextFields() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedModel": "gpt-transcribe",
                "transcriptionContext": "A support call.",
            ],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"unsupported audio format"}}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 415
                    )
                ),
                .success(
                    Data(#"{"text":"Hello","languages":[{"code":"en"}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.testAudio(),
            languageSelection: PluginLanguageSelection(languageHints: ["en", "de"]),
            translate: false,
            prompt: nil,
            dictionaryTermHints: [PluginDictionaryTermHint(text: "TypeWhisper")]
        )

        XCTAssertEqual(result.detectedLanguage, "en")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)

        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        for body in [firstBody, retryBody] {
            XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nA support call."))
            XCTAssertEqual(Self.formValues(named: "keywords[]", in: body), ["TypeWhisper"])
            XCTAssertEqual(Self.formValues(named: "languages[]", in: body), ["en", "de"])
        }
    }

    func testLegacyGPTTranscribeKeepsSingularLanguageAndPromptPayload() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "gpt-4o-transcribe"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"Hallo"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        _ = try await plugin.transcribe(
            audio: Self.testAudio(),
            languageSelection: PluginLanguageSelection(languageHints: ["de", "en"]),
            translate: false,
            prompt: "TypeWhisper",
            dictionaryTermHints: [PluginDictionaryTermHint(text: "ignored keyword")]
        )

        let body = String(
            decoding: try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody),
            as: UTF8.self
        )
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
        XCTAssertFalse(body.contains("name=\"languages[]\"\r\n"))
        XCTAssertFalse(body.contains("name=\"keywords[]\"\r\n"))
    }

    func testGPTTranscribeMapsAuthenticationSizeAndRateLimitErrors() async throws {
        for statusCode in [401, 413, 429] {
            PluginHTTPClientTestHarness.reset()
            let host = try PluginTestHostServices(
                defaults: ["selectedModel": "gpt-transcribe"],
                secrets: ["api-key": "sk-live"]
            )
            let plugin = OpenAIPlugin()
            plugin.activate(host: host)

            let store = PluginHTTPClientSessionStore()
            PluginHTTPClientTestHarness.configure { _ in
                store.makeSession(outcomes: [
                    .success(
                        Data(#"{"error":{"message":"request failed"}}"#.utf8),
                        Self.httpResponse(
                            url: "https://api.openai.com/v1/audio/transcriptions",
                            statusCode: statusCode
                        )
                    ),
                ])
            }

            do {
                _ = try await plugin.transcribe(
                    audio: Self.testAudio(),
                    language: nil,
                    translate: false,
                    prompt: nil
                )
                XCTFail("Expected HTTP \(statusCode) to fail")
            } catch let error as PluginTranscriptionError {
                switch (statusCode, error) {
                case (401, .invalidApiKey), (413, .fileTooLarge), (429, .rateLimited):
                    break
                default:
                    XCTFail("Unexpected mapping for HTTP \(statusCode): \(error)")
                }
            } catch {
                XCTFail("Unexpected error for HTTP \(statusCode): \(error)")
            }

            XCTAssertEqual(store.sessions.first?.requestedRequests.count, 1)
        }
    }

    func testGPTTranscribeSurfacesValidationErrorWithoutModelFallback() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "gpt-transcribe"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"prompt exceeds the model length limit"}}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 400
                    )
                ),
            ])
        }

        do {
            _ = try await plugin.transcribe(
                audio: Self.testAudio(),
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected validation error")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(message, "HTTP 400: prompt exceeds the model length limit")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(store.sessions.first?.requestedRequests.count, 1)
    }

    func testTranslateIsBlockedForEveryModelExceptWhisperOne() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "gpt-transcribe"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [.failure(URLError(.badServerResponse))])
        }

        XCTAssertTrue(plugin.transcriptionModelSupportsTranslation("whisper-1"))
        for modelID in plugin.transcriptionModels.map(\.id) where modelID != "whisper-1" {
            XCTAssertFalse(plugin.transcriptionModelSupportsTranslation(modelID))
        }

        do {
            _ = try await plugin.transcribe(
                audio: Self.testAudio(),
                language: "de",
                translate: true,
                prompt: nil
            )
            XCTFail("Expected Translate to be blocked")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(message, "Translate requires Whisper 1.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testWhisperOneTranslateUsesTranslationsEndpoint() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-1"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"Hello","language":"en"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/translations",
                        statusCode: 200
                    )
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.testAudio(),
            language: "de",
            translate: true,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/v1/audio/translations"])
        let body = String(
            decoding: try XCTUnwrap(store.sessions.first?.requestedRequests.first?.httpBody),
            as: UTF8.self
        )
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertFalse(body.contains("name=\"language\"\r\n"))
    }

    func testOpenAIWithoutCredentialsMakesCloudAuthRolesUnavailable() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.authStatus(for: .llm).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .transcription).isAvailable)
        XCTAssertFalse(plugin.authStatus(for: .tts).isAvailable)
    }

    func testOpenAIUsesResponsesAPIForGPT5ModelsOnly() {
        XCTAssertTrue(OpenAIPlugin.usesResponsesAPI(for: "gpt-5.5"))
        XCTAssertTrue(OpenAIPlugin.usesResponsesAPI(for: "gpt-5.4-mini"))
        XCTAssertFalse(OpenAIPlugin.usesResponsesAPI(for: "gpt-4o"))
    }

    func testOpenAIReasoningEffortsMatchModelCapabilities() {
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5.6-sol"),
            [.none, .low, .medium, .high, .xhigh, .max]
        )
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5.5"),
            [.none, .low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5.4-pro-2026-03-05"),
            [.medium, .high, .xhigh]
        )
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5.3-codex"),
            [.low, .medium, .high, .xhigh]
        )
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5.1"),
            [.none, .low, .medium, .high]
        )
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5"),
            [.minimal, .low, .medium, .high]
        )
        XCTAssertEqual(
            OpenAIPlugin.supportedReasoningEfforts(for: "o4-mini"),
            [.low, .medium, .high]
        )
        XCTAssertEqual(OpenAIPlugin.supportedReasoningEfforts(for: "gpt-5-chat-latest"), [])
        XCTAssertEqual(OpenAIPlugin.supportedReasoningEfforts(for: "gpt-4.1"), [])
    }

    func testOpenAIReasoningEffortFallsBackToModelDefault() {
        XCTAssertEqual(OpenAIPlugin.effectiveReasoningEffort(.max, for: "gpt-5.6-luna"), .max)
        XCTAssertEqual(OpenAIPlugin.effectiveReasoningEffort(.max, for: "gpt-5.5"), .medium)
        XCTAssertEqual(
            OpenAIPlugin.effectiveReasoningEffort(.max, for: "gpt-5.4"),
            OpenAIReasoningEffort.none
        )
        XCTAssertEqual(OpenAIPlugin.effectiveReasoningEffort(.none, for: "gpt-5.4-pro"), .medium)
        XCTAssertEqual(OpenAIPlugin.effectiveReasoningEffort(.low, for: "gpt-5-pro"), .high)
        XCTAssertNil(OpenAIPlugin.effectiveReasoningEffort(.medium, for: "gpt-4.1"))
    }

    func testOpenAIProcessNormalizesPersistedReasoningEffortForSelectedModel() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedLLMModel": "gpt-5.5",
                "reasoningEffort": "max",
            ],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        #"{"output":[{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#.utf8
                    ),
                    Self.httpResponse(url: "https://api.openai.com/v1/responses", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(systemPrompt: "Fix grammar", userText: "hello", model: nil)

        XCTAssertEqual(result, "Done")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let requestData = try XCTUnwrap(request.httpBody)
        let requestBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertEqual(requestBody["model"] as? String, "gpt-5.5")
        XCTAssertEqual((requestBody["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
    }

    func testOpenAIRealtimeRequestUsesRealtimeWhisperEndpointAndAuth() throws {
        let request = try OpenAIRealtimeTranscriptionSession.makeRequest(apiKey: "sk-test")

        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.host, "api.openai.com")
        XCTAssertEqual(request.url?.path, "/v1/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["intent"], "transcription")
        XCTAssertNil(query["model"])
    }

    func testOpenAIRealtimeSessionUpdatePayloadUsesGATranscriptionSessionAndOmitsUnsupportedPrompt() throws {
        let payload = OpenAIRealtimeTranscriptionSession.sessionUpdatePayload(
            language: "de",
            prompt: "TypeWhisper, OpenAI"
        )

        XCTAssertEqual(payload["type"] as? String, "session.update")
        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "de")
        XCTAssertNil(transcription["prompt"])

        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testGPTLiveTranscribeSessionPayloadIncludesContextHintsAndLowDelay() throws {
        let payload = OpenAIRealtimeTranscriptionSession.sessionUpdatePayload(
            modelID: "gpt-live-transcribe",
            languageSelection: PluginLanguageSelection(
                languageHints: ["de", "en", "DE"]
            ),
            prompt: "A TypeWhisper product interview.",
            keywords: ["TypeWhisper", "AC-42"],
            delay: .low
        )

        let session = try XCTUnwrap(payload["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])

        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(
            transcription["prompt"] as? String,
            "A TypeWhisper product interview."
        )
        XCTAssertEqual(transcription["keywords"] as? [String], ["TypeWhisper", "AC-42"])
        XCTAssertEqual(transcription["languages"] as? [String], ["de", "en"])
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertNil(transcription["language"])
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testFileModelLiveSessionFinalizesTheCompleteBufferedAudio() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "gpt-transcribe"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"The second ending is present.","languages":[{"code":"en"}]}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.openai.com/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let session = try await plugin.createLiveTranscriptionSession(
            language: "en",
            translate: false,
            prompt: nil,
            onProgress: { _ in true }
        )
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 8_000))
        try await session.appendAudio(samples: [Float](repeating: 0.2, count: 8_000))

        let result = try await session.finish()

        XCTAssertEqual(result.text, "The second ending is present.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/v1/audio/transcriptions"])

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        XCTAssertTrue(body.contains("name=\"languages[]\"\r\n\r\nen"))
    }

    func testFileModelLiveSessionKeepsPreviewAndFinalTranscriptionSeparate() async throws {
        let recorder = OpenAIFileTranscriptionRecorder()
        let previews = OpenAIFileTranscriptionPreviewRecorder()
        let session = OpenAIFileTranscriptionSession(
            transcribe: { audio in
                await recorder.record(sampleCount: audio.samples.count)
                return PluginTranscriptionResult(text: "\(audio.samples.count) samples")
            },
            onProgress: { text in
                previews.record(text)
                return true
            }
        )

        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 48_000))
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 16_000))
        let result = try await session.finish()

        let recordedSampleCounts = await recorder.sampleCounts
        XCTAssertEqual(recordedSampleCounts, [48_000, 64_000])
        XCTAssertEqual(previews.values, ["48000 samples"])
        XCTAssertEqual(result.text, "64000 samples")
    }

    func testFileModelLiveSessionSerializesAndCoalescesReentrantPreviews() async throws {
        let sessionBox = OpenAIFileTranscriptionSessionBox()
        let recorder = ReentrantOpenAIFileTranscriptionRecorder(sessionBox: sessionBox)
        let session = OpenAIFileTranscriptionSession(
            transcribe: { audio in
                try await recorder.transcribe(audio)
            },
            onProgress: { _ in true }
        )
        await sessionBox.store(session)

        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 48_000))

        let snapshot = await recorder.snapshot
        XCTAssertEqual(snapshot.sampleCounts, [48_000, 96_000])
        XCTAssertEqual(snapshot.maximumConcurrentRequestCount, 1)
    }

    func testOpenAIRealtimePCMConversionResamples16kTo24kPCM16() {
        let samples = [Float](repeating: 0, count: 16_000)

        let data = OpenAIRealtimeTranscriptionSession.pcm16DataForRealtime(samples)

        XCTAssertEqual(data.count, 24_000 * MemoryLayout<Int16>.size)
    }

    func testOpenAIRealtimeCollectorPublishesDeltaAndCompletedText() async throws {
        let collector = OpenAIRealtimeTranscriptCollector()

        let delta = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_1","delta":"Hello"}"#.utf8
        ))
        XCTAssertEqual(delta, "Hello")

        let completed = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Hello world"}"#.utf8
        ))
        XCTAssertEqual(completed, "Hello world")

        let result = await collector.finalResult(fallbackLanguage: "en")
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testOpenAIRealtimeCollectorTracksSessionReadyEvents() async throws {
        let collector = OpenAIRealtimeTranscriptCollector()

        _ = try await collector.applyEvent(Data(#"{"type":"session.updated"}"#.utf8))
        let isSessionReady = await collector.isSessionReady
        XCTAssertTrue(isSessionReady)
    }

    func testOpenAIRealtimeCollectorStoresConnectionFailure() async {
        let collector = OpenAIRealtimeTranscriptCollector()

        await collector.recordConnectionFailure("Socket is not connected")

        let error = await collector.error
        XCTAssertEqual(error, "Socket is not connected")
    }

    func testOpenAIRealtimeFinishAndCancelAreIdempotent() async throws {
        let collector = OpenAIRealtimeTranscriptCollector()
        _ = try await collector.applyEvent(Data(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_1","transcript":"Fertig"}"#.utf8
        ))
        let session = OpenAIRealtimeTranscriptionSession(
            webSocketTask: nil,
            receiveTask: nil,
            collector: collector,
            language: "de",
            onProgress: { _ in true }
        )

        let result = try await session.finish()
        await session.cancel()
        await session.cancel()

        XCTAssertEqual(result.text, "Fertig")
        XCTAssertEqual(result.detectedLanguage, "de")
    }

    func testOpenAIRealtimeSocketOpenWaiterResumesAfterDidOpen() async throws {
        let waiter = OpenAIRealtimeWebSocketOpenWaiter()

        let waitTask = Task {
            try await waiter.waitForOpen()
        }
        try await Task.sleep(for: .milliseconds(10))

        waiter.markOpened()

        try await waitTask.value
    }

    func testOpenAITTSConfigUsesMiniTTSPCMAndDefaultVoice() throws {
        XCTAssertEqual(OpenAITTSConfiguration.defaultVoiceId, "marin")
        XCTAssertEqual(OpenAITTSConfiguration.availableVoices.count, 13)
        XCTAssertTrue(OpenAITTSConfiguration.availableVoices.contains { $0.id == "cedar" })

        let body = OpenAITTSConfiguration.requestBody(
            text: "Hallo Welt",
            voice: nil,
            instructions: "Speak calmly."
        )

        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini-tts")
        XCTAssertEqual(body["voice"] as? String, "marin")
        XCTAssertEqual(body["input"] as? String, "Hallo Welt")
        XCTAssertEqual(body["instructions"] as? String, "Speak calmly.")
        XCTAssertEqual(body["response_format"] as? String, "pcm")
    }

    func testOpenAITTSPlaybackSessionStopIsIdempotent() {
        let playback = MockOpenAITTSAudioPlayback()
        let session = OpenAITTSPlaybackSession(task: nil, audioPlayback: playback)
        let counter = FinishCounter()
        session.onFinish = { counter.increment() }

        session.stop()
        session.stop()

        XCTAssertFalse(session.isActive)
        XCTAssertEqual(playback.stopCount, 1)
        XCTAssertEqual(counter.value, 1)
    }

    func testOpenAIResponsesRequestBodyUsesStoreFalseAndReasoning() throws {
        let body = OpenAIResponsesClient.requestBody(
            model: "gpt-5.5",
            systemPrompt: "Fix grammar",
            userText: "hello world",
            reasoningEffort: "medium"
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.5")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, "Fix grammar")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }

    func testOpenAIResponsesRequestPreservesCustomTemperatureForGPT51AtNone() async throws {
        try await assertOpenAIResponsesRequestTemperature(
            model: "gpt-5.1",
            reasoningEffort: "none",
            expectedTemperature: 0.7
        )
    }

    func testOpenAIResponsesRequestPreservesCustomTemperatureForGPT52AtNone() async throws {
        try await assertOpenAIResponsesRequestTemperature(
            model: "gpt-5.2",
            reasoningEffort: "none",
            expectedTemperature: 0.7
        )
    }

    func testOpenAIResponsesRequestOmitsCustomTemperatureForGPT52AboveNone() async throws {
        try await assertOpenAIResponsesRequestTemperature(
            model: "gpt-5.2",
            reasoningEffort: "medium",
            expectedTemperature: nil
        )
    }

    func testOpenAIResponsesParserExtractsOutputText() throws {
        let data = Data(
            """
            {
              "id": "resp_123",
              "output": [
                {
                  "type": "message",
                  "content": [
                    { "type": "output_text", "text": "Cleaned transcript" }
                  ]
                }
              ]
            }
            """.utf8
        )

        XCTAssertEqual(try OpenAIResponsesClient.parseResponse(data), "Cleaned transcript")
    }

    func testOpenAIRefreshFetchedLLMModelsQueriesModelsEndpointAndPersistsCurrentChatModels() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedLLMModel": "stale-model"],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "data": [
                            { "id": "whisper-1", "owned_by": "openai" },
                            { "id": "gpt-4o-mini-transcribe", "owned_by": "openai" },
                            { "id": "o4-mini", "owned_by": "openai" },
                            { "id": "gpt-4.1-mini", "owned_by": "openai" },
                            { "id": "tts-1", "owned_by": "openai" }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://api.openai.com/v1/models", statusCode: 200)
                )
            ])
        }

        let models = await plugin.refreshFetchedLLMModels()

        XCTAssertEqual(models.map(\.id), ["gpt-4.1-mini", "o4-mini"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gpt-4.1-mini", "o4-mini"])
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-4.1-mini")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gpt-4.1-mini")

        let cachedData = try XCTUnwrap(host.userDefault(forKey: "fetchedLLMModels") as? Data)
        let cachedModels = try JSONDecoder().decode([OpenAIFetchedModel].self, from: cachedData)
        XCTAssertEqual(cachedModels.map(\.id), ["gpt-4.1-mini", "o4-mini"])

        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/v1/models"])
        XCTAssertEqual(
            store.sessions[0].requestedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-live"
        )
    }

    func testOpenAIChatGPTModelsRequestUsesAccountScopedCodexEndpoint() throws {
        let request = try OpenAIPlugin.makeChatGPTModelsRequest(
            accessToken: "oauth-token",
            accountID: "account-123",
            clientVersion: "1.3.0"
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "chatgpt.com")
        XCTAssertEqual(request.url?.path, "/backend-api/codex/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query["client_version"], "1.3.0")
    }

    func testOpenAIRefreshAvailableLLMModelsFetchesFutureChatGPTCatalogAndPersistsSelection() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "authMode": "chatgpt",
                "selectedLLMModel": "gpt-5.6-sol",
                "oauthAccountID": "account-123",
                "oauthExpiresAt": Date().addingTimeInterval(3_600),
            ],
            secrets: [
                "oauth-access-token": "oauth-token",
                "oauth-refresh-token": "refresh-token",
            ]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "models": [
                            {
                              "slug": "gpt-hidden",
                              "display_name": "Hidden",
                              "priority": 0,
                              "visibility": "hide"
                            },
                            {
                              "slug": "gpt-5.6-sol",
                              "display_name": "GPT-5.6 Sol",
                              "priority": 2,
                              "visibility": "list"
                            },
                            {
                              "slug": "gpt-5.7",
                              "display_name": "GPT-5.7",
                              "priority": 1,
                              "visibility": "list"
                            },
                            {
                              "slug": "gpt-internal",
                              "display_name": "Internal",
                              "priority": 3,
                              "visibility": "none"
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(
                        url: "https://chatgpt.com/backend-api/codex/models",
                        statusCode: 200
                    )
                ),
            ])
        }

        let models = await plugin.refreshAvailableLLMModels()

        XCTAssertEqual(models.map(\.id), ["gpt-5.7", "gpt-5.6-sol"])
        XCTAssertEqual(models.map(\.displayName), ["GPT-5.7", "GPT-5.6 Sol"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gpt-5.7", "gpt-5.6-sol"])
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-5.6-sol")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gpt-5.6-sol")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/backend-api/codex/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-ID"), "account-123")
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertFalse(
            components.queryItems?
                .first(where: { $0.name == "client_version" })?
                .value?
                .isEmpty ?? true
        )

        let cachedData = try XCTUnwrap(host.userDefault(forKey: "fetchedChatGPTModels") as? Data)
        let cache = try JSONDecoder().decode(OpenAIChatGPTModelCache.self, from: cachedData)
        XCTAssertEqual(cache.accountID, "account-123")
        XCTAssertEqual(cache.models.map(\.id), ["gpt-5.7", "gpt-5.6-sol"])

        let restoredPlugin = OpenAIPlugin()
        restoredPlugin.activate(host: host)
        XCTAssertEqual(restoredPlugin.supportedModels.map(\.id), ["gpt-5.7", "gpt-5.6-sol"])
        XCTAssertEqual(restoredPlugin.selectedLLMModelId, "gpt-5.6-sol")
    }

    func testOpenAIChatGPTModelRefreshFailureKeepsFallbackAndSelection() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "authMode": "chatgpt",
                "selectedLLMModel": "gpt-5.5",
                "oauthAccountID": "account-123",
                "oauthExpiresAt": Date().addingTimeInterval(3_600),
            ],
            secrets: [
                "oauth-access-token": "oauth-token",
                "oauth-refresh-token": "refresh-token",
            ]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [.failure(URLError(.cannotConnectToHost))])
        }

        let models = await plugin.refreshAvailableLLMModels()

        XCTAssertTrue(models.isEmpty)
        XCTAssertEqual(plugin.supportedModels.first?.id, "gpt-5.6-sol")
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-5.5")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gpt-5.5")
        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/backend-api/codex/models"])
    }

    func testOpenAIChatGPTModelCacheIsScopedToAccount() throws {
        let cache = OpenAIChatGPTModelCache(
            accountID: "old-account",
            models: [
                OpenAIChatGPTModel(
                    id: "gpt-5.7",
                    displayName: "GPT-5.7",
                    priority: 1,
                    visibility: "list"
                ),
            ]
        )
        let host = try PluginTestHostServices(defaults: [
            "authMode": "chatgpt",
            "selectedLLMModel": "gpt-5.5",
            "oauthAccountID": "new-account",
            "fetchedChatGPTModels": try JSONEncoder().encode(cache),
        ])
        let plugin = OpenAIPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.first?.id, "gpt-5.6-sol")
        XCTAssertFalse(plugin.supportedModels.contains { $0.id == "gpt-5.7" })
        XCTAssertEqual(plugin.selectedLLMModelId, "gpt-5.5")
    }

    private static func testAudio() -> AudioData {
        let samples = [Float](repeating: 0.1, count: 16_000)
        return AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )
    }

    private static func formValues(named name: String, in body: String) -> [String] {
        let marker = "name=\"\(name)\"\r\n\r\n"
        return body
            .components(separatedBy: marker)
            .dropFirst()
            .compactMap { component in
                component.components(separatedBy: "\r\n").first
            }
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func assertOpenAIResponsesRequestTemperature(
        model: String,
        reasoningEffort: String,
        expectedTemperature: Double?
    ) async throws {
        let host = try PluginTestHostServices(
            defaults: ["reasoningEffort": reasoningEffort],
            secrets: ["api-key": "sk-live"]
        )
        let plugin = OpenAIPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        #"{"output":[{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#.utf8
                    ),
                    Self.httpResponse(url: "https://api.openai.com/v1/responses", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(
            systemPrompt: "Fix grammar",
            userText: "hello",
            model: model,
            temperatureDirective: .custom(0.7)
        )

        XCTAssertEqual(result, "Done")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        let requestData = try XCTUnwrap(request.httpBody)
        let requestBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        XCTAssertEqual(requestBody["model"] as? String, model)
        XCTAssertEqual(
            (requestBody["reasoning"] as? [String: Any])?["effort"] as? String,
            reasoningEffort
        )
        XCTAssertEqual(requestBody["temperature"] as? Double, expectedTemperature)
    }
}

private final class FinishCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        lock.withLock { $0 }
    }

    func increment() {
        lock.withLock { $0 += 1 }
    }
}

private actor OpenAIFileTranscriptionRecorder {
    private(set) var sampleCounts: [Int] = []

    func record(sampleCount: Int) {
        sampleCounts.append(sampleCount)
    }
}

private actor OpenAIFileTranscriptionSessionBox {
    private var session: OpenAIFileTranscriptionSession?

    func store(_ session: OpenAIFileTranscriptionSession) {
        self.session = session
    }

    func appendAudio(samples: [Float]) async throws {
        try await session?.appendAudio(samples: samples)
    }
}

private actor ReentrantOpenAIFileTranscriptionRecorder {
    struct Snapshot {
        let sampleCounts: [Int]
        let maximumConcurrentRequestCount: Int
    }

    private let sessionBox: OpenAIFileTranscriptionSessionBox
    private var sampleCounts: [Int] = []
    private var activeRequestCount = 0
    private var maximumConcurrentRequestCount = 0

    init(sessionBox: OpenAIFileTranscriptionSessionBox) {
        self.sessionBox = sessionBox
    }

    func transcribe(_ audio: AudioData) async throws -> PluginTranscriptionResult {
        activeRequestCount += 1
        defer { activeRequestCount -= 1 }
        maximumConcurrentRequestCount = max(maximumConcurrentRequestCount, activeRequestCount)
        sampleCounts.append(audio.samples.count)

        if sampleCounts.count == 1 {
            try await sessionBox.appendAudio(samples: [Float](repeating: 0.1, count: 48_000))
        }

        return PluginTranscriptionResult(text: "\(audio.samples.count) samples")
    }

    var snapshot: Snapshot {
        Snapshot(
            sampleCounts: sampleCounts,
            maximumConcurrentRequestCount: maximumConcurrentRequestCount
        )
    }
}

private final class OpenAIFileTranscriptionPreviewRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())

    var values: [String] {
        lock.withLock { $0 }
    }

    func record(_ value: String) {
        lock.withLock { $0.append(value) }
    }
}

private final class MockOpenAITTSAudioPlayback: OpenAITTSAudioPlayback, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var onDrained: (@Sendable () -> Void)?

    var stopCount: Int {
        lock.withLock { $0 }
    }

    func start(sampleRate: Int) throws {}
    func appendPCM16(_ data: Data) throws {}
    func finishInput() {}

    func stop() {
        lock.withLock { $0 += 1 }
    }
}
