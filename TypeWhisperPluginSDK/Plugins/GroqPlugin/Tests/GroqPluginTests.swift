import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import GroqPlugin

final class GroqPluginTests: XCTestCase {
    func testDictionaryContextDefaultsOffAndPersistsOptIn() throws {
        let host = try PluginTestHostServices()
        let plugin = GroqPlugin()
        plugin.activate(host: host)
        XCTAssertFalse(plugin.sendDictionaryTerms)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .requiresPluginSetting)
        XCTAssertNil(host.userDefault(forKey: GroqPlugin.sendDictionaryTermsKey))
        plugin.setSendDictionaryTerms(true)
        XCTAssertEqual(host.userDefault(forKey: GroqPlugin.sendDictionaryTermsKey) as? Bool, true)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        let reloaded = GroqPlugin()
        reloaded.activate(host: host)
        XCTAssertTrue(reloaded.sendDictionaryTerms)
        XCTAssertEqual(reloaded.dictionaryTermsSupport, .supported)
        reloaded.setSendDictionaryTerms(false)
        XCTAssertFalse(reloaded.sendDictionaryTerms)
        XCTAssertEqual(reloaded.dictionaryTermsSupport, .requiresPluginSetting)
    }

    func testDictionaryContextKeepsExplicitlySavedChoice() throws {
        for saved in [true, false] {
            let host = try PluginTestHostServices(defaults: [GroqPlugin.sendDictionaryTermsKey: saved])
            let plugin = GroqPlugin()
            plugin.activate(host: host)
            XCTAssertEqual(plugin.sendDictionaryTerms, saved)
            XCTAssertEqual(plugin.dictionaryTermsSupport, saved ? .supported : .requiresPluginSetting)
        }
    }

    func testTranscribeForwardsHostPromptUnchangedIncludingWavRetryWhileTermsAreOff() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)
        XCTAssertFalse(plugin.sendDictionaryTerms)
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"error":{"message":"could not process file - is it a valid media file?"}}"#.utf8),
                         Self.httpResponse(url: "https://api.groq.com/openai/v1/audio/transcriptions", statusCode: 400)),
                .success(Data(#"{"text":"hello","language":"de"}"#.utf8),
                         Self.httpResponse(url: "https://api.groq.com/openai/v1/audio/transcriptions", statusCode: 200)),
                .success(Data(#"{"text":"hello","language":"de"}"#.utf8),
                         Self.httpResponse(url: "https://api.groq.com/openai/v1/audio/transcriptions", statusCode: 200)),
            ])
        }
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1)
        // With terms off, the host no longer adds dictionary terms, so any prompt that
        // arrives here was supplied by the caller and must reach Groq unchanged.
        let prompt = "Meeting notes about the quarterly budget."
        _ = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: prompt)
        let promptRequests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(promptRequests.count, 2)
        for request in promptRequests {
            let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\n\(prompt)\r\n"))
        }
        _ = try await plugin.transcribe(audio: audio, language: "de", translate: false, prompt: nil)
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.last)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"prompt\""))
    }

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

    func testTranscribeUploadsLongRecordingsInChunksBelowTheUploadCap() async throws {
        // Groq closes the connection on bodies over 25 MB (#1538).
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "whisper-large-v3"],
            secrets: ["api-key": "groq-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        let url = "https://api.groq.com/openai/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":" first","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(#"{"text":" second","language":"en"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Eleven minutes, more than one chunk.
        let samples = [Float](repeating: 0.3, count: 16_000 * 660)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 660)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { ($0.httpBody?.count ?? .max) < 25 * 1_024 * 1_024 })
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

        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nwhisper-large-v3"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
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

    func testBuiltInLLMModelsOnlyOfferGroqProductionModels() throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        // Llama 3.3 70B, Llama 3.1 8B and Kimi K2 now return HTTP 404 from Groq.
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["openai/gpt-oss-120b", "openai/gpt-oss-20b"])
        XCTAssertEqual(plugin.defaultModelId, "openai/gpt-oss-120b")
        XCTAssertNil(plugin.preferredModelId)
        XCTAssertNil(plugin.llmModelRefreshTask, "Without a cached list there is nothing stale to refresh")
    }

    func testSavedRetiredLLMModelFallsBackToDefaultModel() async throws {
        let host = try PluginTestHostServices(
            defaults: [GroqPlugin.selectedLLMModelKey: "llama-3.3-70b-versatile"],
            secrets: ["api-key": "test-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        XCTAssertNil(plugin.selectedLLMModelId)
        XCTAssertNil(plugin.preferredModelId)
        XCTAssertEqual(plugin.defaultModelId, GroqPlugin.curatedDefaultLLMModelId)
        // The saved value stays and applies again if Groq lists the model again.
        XCTAssertEqual(host.userDefault(forKey: GroqPlugin.selectedLLMModelKey) as? String, "llama-3.3-70b-versatile")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":"Cleaned text."},"finish_reason":"stop"}]}"#.utf8),
                    Self.httpResponse(url: "https://api.groq.com/openai/v1/chat/completions", statusCode: 200)
                ),
            ])
        }
        let result = try await plugin.process(systemPrompt: "Fix punctuation.", userText: "cleaned text", model: nil)

        XCTAssertEqual(result, "Cleaned text.")
        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/openai/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openai/gpt-oss-120b")
    }

    func testSavedLLMModelStaysSelectedWhileTheFetchedListOffersIt() throws {
        // Groq keeps Llama 3.3 70B for enterprise contracts; the account's own list decides.
        let host = try PluginTestHostServices(
            defaults: [
                GroqPlugin.selectedLLMModelKey: "llama-3.3-70b-versatile",
                GroqPlugin.fetchedLLMModelsKey: try Self.cachedModelList(["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]),
                GroqPlugin.fetchedLLMModelsDateKey: Date(),
            ],
            secrets: ["api-key": "test-key"]
        )
        let plugin = GroqPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedLLMModelId, "llama-3.3-70b-versatile")
        XCTAssertEqual(plugin.preferredModelId, "llama-3.3-70b-versatile")
    }

    func testStaleCachedModelListRefreshesOnActivationAndDropsRetiredSelection() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                GroqPlugin.selectedLLMModelKey: "llama-3.3-70b-versatile",
                // Saved by an earlier plugin version, which stored no date.
                GroqPlugin.fetchedLLMModelsKey: try Self.cachedModelList([
                    "llama-3.1-8b-instant", "llama-3.3-70b-versatile", "openai/gpt-oss-120b",
                ]),
            ],
            secrets: ["api-key": "test-key"]
        )
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Self.groqModelList, Self.httpResponse(url: "https://api.groq.com/openai/v1/models", statusCode: 200)),
            ])
        }
        let plugin = GroqPlugin()
        plugin.activate(host: host)
        XCTAssertEqual(plugin.preferredModelId, "llama-3.3-70b-versatile", "The cached list still offers it")

        let refresh = try XCTUnwrap(plugin.llmModelRefreshTask)
        await refresh.value

        XCTAssertEqual(store.sessions.first?.requestedPaths, ["/openai/v1/models"])
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["allam-2-7b", "openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.8-27b"]
        )
        XCTAssertNil(plugin.preferredModelId)
        XCTAssertEqual(plugin.defaultModelId, "openai/gpt-oss-120b", "Not the alphabetically first model")
        XCTAssertNotNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsDateKey) as? Date)
        XCTAssertEqual(host.userDefault(forKey: GroqPlugin.selectedLLMModelKey) as? String, "llama-3.3-70b-versatile")
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testCachedModelListRefreshesOnlyOnceItIsADayOld() throws {
        for (age, expectsRefresh) in [(-3_600.0, false), (-25 * 3_600.0, true)] {
            let host = try PluginTestHostServices(
                defaults: [
                    GroqPlugin.fetchedLLMModelsKey: try Self.cachedModelList(["openai/gpt-oss-120b"]),
                    GroqPlugin.fetchedLLMModelsDateKey: Date().addingTimeInterval(age),
                ],
                secrets: ["api-key": "test-key"]
            )
            let plugin = GroqPlugin(llmModelFetcher: { _ in [] })
            plugin.activate(host: host)

            XCTAssertEqual(plugin.llmModelRefreshTask != nil, expectsRefresh, "list age \(age)s")
            plugin.deactivate()
        }
    }

    func testModelRefreshFinishingAfterDeactivationChangesNothing() async throws {
        let fetch = HeldModelFetch()
        let host = try PluginTestHostServices(
            defaults: [
                GroqPlugin.selectedLLMModelKey: "llama-3.3-70b-versatile",
                GroqPlugin.fetchedLLMModelsKey: try Self.cachedModelList(["llama-3.3-70b-versatile"]),
            ],
            secrets: ["api-key": "test-key"]
        )
        let plugin = GroqPlugin(llmModelFetcher: { apiKey in await fetch.models(for: apiKey) })
        plugin.activate(host: host)
        let refresh = try XCTUnwrap(plugin.llmModelRefreshTask)
        await fetch.waitUntilRequested()

        plugin.deactivate()
        XCTAssertNil(plugin.llmModelRefreshTask)
        await fetch.release(try Self.fetchedModels(["openai/gpt-oss-120b"]))
        await refresh.value

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["llama-3.3-70b-versatile"])
        XCTAssertNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsDateKey))
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testModelRefreshFinishingAfterAKeyChangeChangesNothing() async throws {
        let fetch = HeldModelFetch()
        let host = try PluginTestHostServices(
            defaults: [GroqPlugin.fetchedLLMModelsKey: try Self.cachedModelList(["llama-3.3-70b-versatile"])],
            secrets: ["api-key": "test-key"]
        )
        let plugin = GroqPlugin(llmModelFetcher: { apiKey in await fetch.models(for: apiKey) })
        plugin.activate(host: host)
        let refresh = try XCTUnwrap(plugin.llmModelRefreshTask)
        await fetch.waitUntilRequested()

        // The list fetched with the previous key may belong to another account.
        plugin.setApiKey("other-test-key")
        await fetch.release(try Self.fetchedModels(["openai/gpt-oss-120b"]))
        await refresh.value

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["llama-3.3-70b-versatile"])
        XCTAssertNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsDateKey))
    }

    func testSettingsModelFetchAppliesTheListWhileItsKeyIsSaved() async throws {
        let host = try PluginTestHostServices(
            defaults: [GroqPlugin.selectedLLMModelKey: "llama-3.3-70b-versatile"],
            secrets: ["api-key": "test-key"]
        )
        let fetched = try Self.fetchedModels(["llama-3.3-70b-versatile", "openai/gpt-oss-120b"])
        let plugin = GroqPlugin(llmModelFetcher: { apiKey in apiKey == "test-key" ? fetched : [] })
        plugin.activate(host: host)
        XCTAssertNil(plugin.preferredModelId, "The built-in list lacks the saved model")

        // As the settings view does after saving a key or on Refresh.
        let models = await plugin.fetchLLMModels(for: "test-key")
        XCTAssertTrue(plugin.applyFetchedLLMModels(models, fetchedWith: "test-key"))

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"])
        XCTAssertNotNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsKey) as? Data)
        XCTAssertNotNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsDateKey) as? Date)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
        // The kept saved model applies again once the account's list offers it.
        XCTAssertEqual(plugin.preferredModelId, "llama-3.3-70b-versatile")
    }

    func testSettingsModelFetchFinishingAfterTheKeyChangedOrThePluginStoppedChangesNothing() async throws {
        let interruptions: [(name: String, apply: (GroqPlugin) -> Void)] = [
            ("key replaced", { $0.setApiKey("other-test-key") }),
            ("key removed", { $0.removeApiKey() }),
            ("plugin deactivated", { $0.deactivate() }),
        ]
        for interruption in interruptions {
            let fetch = HeldModelFetch()
            let host = try PluginTestHostServices(secrets: ["api-key": "test-key"])
            let plugin = GroqPlugin(llmModelFetcher: { apiKey in await fetch.models(for: apiKey) })
            plugin.activate(host: host)
            let lateModels = try Self.fetchedModels(["openai/gpt-oss-120b"])

            // As the settings view does after saving a key or on Refresh.
            async let fetched = plugin.fetchLLMModels(for: "test-key")
            await fetch.waitUntilRequested()
            interruption.apply(plugin)
            await fetch.release(lateModels)
            let models = await fetched

            XCTAssertFalse(plugin.applyFetchedLLMModels(models, fetchedWith: "test-key"), interruption.name)
            XCTAssertEqual(plugin.supportedModels.map(\.id), GroqPlugin.fallbackLLMModels.map(\.id), interruption.name)
            XCTAssertNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsKey), interruption.name)
            XCTAssertNil(host.userDefault(forKey: GroqPlugin.fetchedLLMModelsDateKey), interruption.name)
            let requestedKeys = await fetch.requestedKeys
            XCTAssertEqual(requestedKeys, ["test-key"], interruption.name)
        }
    }

    /// Trimmed GET /openai/v1/models response with the models Groq listed in October 2026.
    private static let groqModelList = Data(#"""
    {"object":"list","data":[
      {"id":"whisper-large-v3","owned_by":"OpenAI"},
      {"id":"qwen/qwen3.8-27b","owned_by":"Alibaba Cloud"},
      {"id":"openai/gpt-oss-20b","owned_by":"OpenAI"},
      {"id":"canopylabs/orpheus-v1-english","owned_by":"Canopy Labs"},
      {"id":"allam-2-7b","owned_by":"SDAIA"},
      {"id":"openai/gpt-oss-120b","owned_by":"OpenAI"},
      {"id":"openai/gpt-oss-safeguard-20b","owned_by":"OpenAI"},
      {"id":"meta-llama/llama-prompt-guard-2-86m","owned_by":"Meta"},
      {"id":"whisper-large-v3-turbo","owned_by":"OpenAI"}
    ]}
    """#.utf8)

    private static func cachedModelList(_ ids: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ids.map { ["id": $0] })
    }

    private static func fetchedModels(_ ids: [String]) throws -> [GroqFetchedModel] {
        try JSONDecoder().decode([GroqFetchedModel].self, from: cachedModelList(ids))
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

/// Keeps a model fetch open until the test releases it.
private actor HeldModelFetch {
    private var pending: CheckedContinuation<[GroqFetchedModel], Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedKeys: [String] = []

    func models(for apiKey: String) async -> [GroqFetchedModel] {
        requestedKeys.append(apiKey)
        return await withCheckedContinuation { continuation in
            pending = continuation
            requestWaiters.forEach { $0.resume() }
            requestWaiters.removeAll()
        }
    }

    func waitUntilRequested() async {
        guard pending == nil else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func release(_ models: [GroqFetchedModel]) {
        pending?.resume(returning: models)
        pending = nil
    }
}
