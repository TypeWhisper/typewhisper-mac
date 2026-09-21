import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GroqPlugin

final class GroqPluginTests: XCTestCase {
    private static let framedPromptPrefix = "The audio may contain these names or technical terms: "

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testTranscribeUsesLongTimeoutForLargerAudioUploads() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"hello","language":"en"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let audio = AudioData(samples: [0, 0, 0], wavData: Data("wav".utf8), duration: 1.0)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(store.sessions[0].requestedPaths, ["/openai/v1/audio/transcriptions"])
        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        XCTAssertEqual(request.timeoutInterval, 600)

        let body = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: body.prefix(1_024), as: UTF8.self)
        XCTAssertTrue(bodyText.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(bodyText.contains("Content-Type: audio/mp4"))
        XCTAssertFalse(bodyText.contains(#"filename="audio.wav""#))
    }

    func testTranscribeRetriesWithWavWhenGroqRejectsM4AUpload() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"could not process file - is it a valid media file?","type":"invalid_request_error"}}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 400
                    )
                ),
                .success(
                    Data(#"{"text":"hello","language":"de"}"#.utf8),
                    Self.httpResponse(
                        url: "https://api.groq.com/openai/v1/audio/transcriptions",
                        statusCode: 200
                    )
                ),
            ])
        }

        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )
        let result = try await plugin.transcribe(
            audio: audio,
            language: "de",
            translate: false,
            prompt: "TypeWhisper"
        )

        XCTAssertEqual(result.text, "hello")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(store.sessions[0].requestedPaths, [
            "/openai/v1/audio/transcriptions",
            "/openai/v1/audio/transcriptions",
        ])

        // A single dictionary term is a one-element term list and is framed as well (#1352).
        let framedPrompt = "name=\"prompt\"\r\n\r\n\(Self.framedPromptPrefix)TypeWhisper."

        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(firstBody.contains(framedPrompt))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains(framedPrompt))
        XCTAssertEqual(requests[1].timeoutInterval, 600)
    }

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "preferredModelId must be nil until the user selects a model"
        )

        let target = try XCTUnwrap(plugin.supportedModels.first?.id)
        plugin.selectLLMModel(target)

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId
        XCTAssertEqual(preferred, target)
    }

    // MARK: - Dictionary terms prompt hygiene (#1352)

    func testDictionaryTermsDefaultsToSupportedWithSmallerBudget() throws {
        let host = try PluginTestHostServices()
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertTrue(plugin.sendDictionaryTerms)
        XCTAssertTrue((plugin as Any) is DictionaryTermsBudgetProviding)
        XCTAssertEqual(plugin.dictionaryTermsBudget, DictionaryTermsBudget(maxTotalChars: 350))
        XCTAssertEqual(GroqPlugin.maxDictionaryTermChars, 350)
        XCTAssertEqual(GroqPlugin.maxConditioningPromptChars, 420)
    }

    func testTranscribeFramesTermListAsSentenceOnTheWire() async throws {
        let (plugin, store) = try makeConfiguredPlugin(
            responses: [#"{"text":"hallo","language":"de"}"#]
        )

        _ = try await plugin.transcribe(
            audio: Self.makeAudio(),
            language: "de",
            translate: false,
            prompt: "Prompt Engineering, Keras, Embeddings"
        )

        let body = try Self.bodyText(store, requestIndex: 0)
        XCTAssertTrue(body.contains(
            "name=\"prompt\"\r\n\r\n\(Self.framedPromptPrefix)Prompt Engineering, Keras, Embeddings.\r\n"
        ), body)
        XCTAssertEqual(body.components(separatedBy: "name=\"prompt\"").count - 1, 1, "exactly one prompt field")
        XCTAssertFalse(body.contains("name=\"prompt\"\r\n\r\nPrompt Engineering, Keras"))
    }

    func testTranscribeCapsLongTermListWithoutCuttingTerms() async throws {
        let terms = Self.longTermList
        let bareList = terms.joined(separator: ", ")
        XCTAssertEqual(terms.count, 61)
        XCTAssertGreaterThan(bareList.count, 550, "fixture exceeds the framed budget clearly")

        let (plugin, store) = try makeConfiguredPlugin(
            responses: [#"{"text":"hallo","language":"de"}"#]
        )

        _ = try await plugin.transcribe(
            audio: Self.makeAudio(),
            language: "de",
            translate: false,
            prompt: bareList
        )

        let sentPrompt = try XCTUnwrap(Self.promptField(in: try Self.bodyText(store, requestIndex: 0)))
        XCTAssertLessThanOrEqual(sentPrompt.count, GroqPlugin.maxConditioningPromptChars)
        XCTAssertTrue(sentPrompt.hasPrefix(Self.framedPromptPrefix))
        XCTAssertTrue(sentPrompt.hasSuffix("."))

        let sentTerms = String(sentPrompt.dropFirst(Self.framedPromptPrefix.count).dropLast())
            .components(separatedBy: ", ")
        XCTAssertGreaterThan(sentTerms.count, 10)
        XCTAssertLessThan(sentTerms.count, terms.count, "budget must drop some terms")
        XCTAssertEqual(sentTerms, Array(terms.prefix(sentTerms.count)), "order preserved, no term cut")
        let framingChars = Self.framedPromptPrefix.count + 1
        XCTAssertLessThanOrEqual(
            sentTerms.joined(separator: ", ").count,
            GroqPlugin.maxConditioningPromptChars - framingChars
        )

        // A list the host already clipped to the plugin's budget always fits completely.
        let hostPrompt = try XCTUnwrap(PluginDictionaryTerms.prompt(from: terms, budget: plugin.dictionaryTermsBudget))
        XCTAssertLessThanOrEqual(hostPrompt.count, GroqPlugin.maxDictionaryTermChars)
        XCTAssertEqual(
            GroqPlugin.conditioningPrompt(from: hostPrompt),
            "\(Self.framedPromptPrefix)\(hostPrompt)."
        )
    }

    func testSwitchOffSendsNoPromptAndReportsPluginSetting() async throws {
        let (plugin, store) = try makeConfiguredPlugin(
            responses: [#"{"text":"hallo","language":"de"}"#],
            extraDefaults: ["sendDictionaryTerms": false]
        )

        XCTAssertEqual(plugin.dictionaryTermsSupport, .requiresPluginSetting)
        XCTAssertFalse(plugin.sendDictionaryTerms)

        _ = try await plugin.transcribe(
            audio: Self.makeAudio(),
            language: "de",
            translate: false,
            prompt: "Prompt Engineering, Keras, Embeddings"
        )

        let body = try Self.bodyText(store, requestIndex: 0)
        XCTAssertFalse(body.contains("name=\"prompt\""), body)
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde"))
    }

    func testSetSendDictionaryTermsPersistsAndNotifiesCapabilities() throws {
        let host = try PluginTestHostServices()
        let plugin = GroqPlugin()
        plugin.activate(host: host)
        let notificationsBefore = host.capabilitiesChangedCount

        plugin.setSendDictionaryTerms(false)

        XCTAssertEqual(host.userDefault(forKey: "sendDictionaryTerms") as? Bool, false)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .requiresPluginSetting)
        XCTAssertEqual(host.capabilitiesChangedCount, notificationsBefore + 1)

        plugin.setSendDictionaryTerms(false)
        XCTAssertEqual(host.capabilitiesChangedCount, notificationsBefore + 1, "no-op change must not notify")

        plugin.setSendDictionaryTerms(true)
        XCTAssertEqual(host.userDefault(forKey: "sendDictionaryTerms") as? Bool, true)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)

        let reloaded = GroqPlugin()
        plugin.setSendDictionaryTerms(false)
        reloaded.activate(host: host)
        XCTAssertFalse(reloaded.sendDictionaryTerms, "setting must survive re-activation")
    }

    func testConditioningPromptHandlesEdgeCases() throws {
        XCTAssertNil(GroqPlugin.conditioningPrompt(from: nil))
        XCTAssertNil(GroqPlugin.conditioningPrompt(from: ""))
        XCTAssertNil(GroqPlugin.conditioningPrompt(from: "   \n"))
        // Free text ending like a sentence passes through trimmed and unframed.
        XCTAssertEqual(
            GroqPlugin.conditioningPrompt(from: "  Bitte höflich transkribieren.  "),
            "Bitte höflich transkribieren."
        )
        // A single entry without sentence punctuation is a one-term list (WhisperKit parity).
        XCTAssertEqual(
            GroqPlugin.conditioningPrompt(from: "TypeWhisper"),
            "\(Self.framedPromptPrefix)TypeWhisper."
        )
        XCTAssertEqual(
            GroqPlugin.conditioningPrompt(from: "Keras, Embeddings"),
            "\(Self.framedPromptPrefix)Keras, Embeddings."
        )

        let longFreeText = String(repeating: "Bitte höflich transkribieren. ", count: 40)
        let cappedFreeText = try XCTUnwrap(GroqPlugin.conditioningPrompt(from: longFreeText))
        XCTAssertEqual(cappedFreeText.count, GroqPlugin.maxConditioningPromptChars)
        XCTAssertFalse(cappedFreeText.hasPrefix(Self.framedPromptPrefix))

        // A single term that cannot fit the budget sends nothing rather than a cut fragment.
        XCTAssertNil(GroqPlugin.conditioningPrompt(from: String(repeating: "a", count: 1_000)))
    }

    func testVerboseJsonSegmentsPassThrough() async throws {
        let fixture = #"""
        {"text":"Hallo Welt. Zweiter Satz.","language":"de","duration":40.3,
         "segments":[{"id":0,"start":0.0,"end":2.5,"text":" Hallo Welt."},{"id":1,"start":2.5,"end":30.0,"text":" Zweiter Satz."}]}
        """#
        let (plugin, _) = try makeConfiguredPlugin(responses: [fixture])

        let result = try await plugin.transcribe(audio: Self.makeAudio(), language: "de", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "Hallo Welt. Zweiter Satz.")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.map(\.end), [2.5, 30.0])
        XCTAssertEqual(result.segments.map(\.start), [0.0, 2.5])
    }

    func testInvalidSegmentsFallBackToTextOnly() async throws {
        let fixture = #"{"text":"Hallo Welt.","language":"de","segments":"oops"}"#
        let (plugin, _) = try makeConfiguredPlugin(responses: [fixture])

        let result = try await plugin.transcribe(audio: Self.makeAudio(), language: "de", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "Hallo Welt.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertTrue(result.segments.isEmpty)
    }

    // MARK: - Helpers

    private func makeConfiguredPlugin(
        responses: [String],
        extraDefaults: [String: Any] = [:]
    ) throws -> (GroqPlugin, PluginHTTPClientSessionStore) {
        var defaults: [String: Any] = ["selectedModel": "whisper-large-v3"]
        for (key, value) in extraDefaults {
            defaults[key] = value
        }
        let host = try PluginTestHostServices(
            defaults: defaults,
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        let outcomes = responses.map { response in
            PluginHTTPClientTestOutcome.success(
                Data(response.utf8),
                Self.httpResponse(
                    url: "https://api.groq.com/openai/v1/audio/transcriptions",
                    statusCode: 200
                )
            )
        }
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: outcomes)
        }
        return (plugin, store)
    }

    private static func makeAudio() -> AudioData {
        let samples = [Float](repeating: 0.1, count: 16_000)
        return AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1.0)
    }

    private static func bodyText(_ store: PluginHTTPClientSessionStore, requestIndex: Int) throws -> String {
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        let body = try XCTUnwrap(requests[requestIndex].httpBody)
        return String(decoding: body, as: UTF8.self)
    }

    private static func promptField(in body: String) -> String? {
        let marker = "name=\"prompt\"\r\n\r\n"
        guard let start = body.range(of: marker) else { return nil }
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: "\r\n") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    /// 61 bundled-pack style terms, about 690 characters when joined with ", " (issue #1352 shape).
    private static let longTermList: [String] = [
        "Prompt Engineering", "Keras", "Embeddings", "Transformer", "Fine-Tuning", "Tokenizer",
        "Backpropagation", "Gradient Descent", "Overfitting", "Regularization", "Dropout", "Batch Norm",
        "Attention", "Self-Attention", "Encoder", "Decoder", "Latent Space", "Diffusion", "GAN",
        "Autoencoder", "Reinforcement Learning", "Reward Model", "RLHF", "Chain of Thought", "Few-Shot",
        "Zero-Shot", "Retrieval", "Vector Store", "Cosine Similarity", "Quantization", "LoRA", "Adapter",
        "Inference", "Latency", "Throughput", "GPU", "TPU", "CUDA", "PyTorch", "TensorFlow", "JAX",
        "Hugging Face", "LangChain", "OpenAI", "Anthropic", "Mistral", "Llama", "Gemma", "Whisper",
        "Speech to Text", "Text to Speech", "Diarization", "Beam Search", "Temperature", "Top-p", "Top-k",
        "Perplexity", "BLEU", "ROUGE", "Benchmark", "Evaluation Harness",
    ]

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
