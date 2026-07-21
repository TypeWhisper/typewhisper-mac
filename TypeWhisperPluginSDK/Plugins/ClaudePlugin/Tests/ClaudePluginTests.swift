import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ClaudePlugin

final class ClaudePluginTests: XCTestCase {
    private static let cachedModelsKey = "fetchedLLMModels.v1"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let modelsURL = "https://api.anthropic.com/v1/models"
    private static let messagesURL = "https://api.anthropic.com/v1/messages"

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    // MARK: - Existing selection behavior

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
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

    // MARK: - Fallback list

    func testFallbackModelsWhenNoCacheOrKey() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            [
                "claude-opus-4-8",
                "claude-sonnet-5",
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
            ]
        )
        XCTAssertFalse(
            plugin.supportedModels.contains { $0.id == "claude-haiku-4-5-20251001" },
            "the dated haiku id must be replaced by the alias in the fallback list"
        )
        XCTAssertFalse(plugin.isModelCacheFresh)
    }

    // MARK: - Pagination

    func testPaginationAssemblesAllPagesSortedNewestFirstWithAfterId() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("a-old-model", "A Old", "2024-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: "cursor-1"
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
                .success(
                    Self.modelsPage(
                        models: [("z-new-model", "Z New", "2026-05-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertTrue(ok)

        // Both pages assembled and sorted newest-first regardless of page order.
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["z-new-model", "a-old-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value,
            "1000"
        )
        XCTAssertNil(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after_id" }),
            "first page must not carry an after_id"
        )
        let secondAfterId = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "after_id" })?.value
        XCTAssertEqual(secondAfterId, "cursor-1")
        // Requests must carry the Anthropic auth headers.
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-api-key"), "claude-key")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testMissingPaginationCursorKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("partial-model", "Partial", "2026-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-kept"])
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 1)
    }

    func testRepeatedPaginationCursorKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(models: [], hasMore: true, lastId: "cursor-1"),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
                .success(
                    Self.modelsPage(
                        models: [("partial-model", "Partial", "2026-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: "cursor-1"
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-kept"])
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 2)
    }

    func testPaginationSafetyLimitKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let outcomes: [PluginHTTPClientTestOutcome] = (0..<20).map { index in
            .success(
                Self.modelsPage(
                    models: [("partial-\(index)", "Partial \(index)", "2026-01-01T00:00:00Z")],
                    hasMore: true,
                    lastId: "cursor-\(index)"
                ),
                Self.httpResponse(url: Self.modelsURL, statusCode: 200)
            )
        }
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: outcomes)
        }

        let refreshed = await plugin.refreshModels()
        XCTAssertFalse(refreshed)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-kept"])
        XCTAssertEqual(store.sessions[0].requestedRequests.count, 20)
    }

    // MARK: - Cache TTL

    func testFreshCacheServedWithoutRefetch() throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-fresh", displayName: "Cached Fresh", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: cacheData],
            secrets: ["api-key": "claude-key"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.isModelCacheFresh)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-fresh"])
    }

    func testStaleCacheServedImmediatelyThenRefreshes() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-stale", displayName: "Cached Stale", createdAt: 1_000)],
            fetchedAt: Date(timeIntervalSinceNow: -100_000) // > 24h old
        )
        // Activate without a key so the background refresh does not race the test.
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isModelCacheFresh)
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["cached-stale"],
            "the stale cache is still served immediately"
        )

        plugin.setApiKey("claude-key")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("refreshed-model", "Refreshed", "2026-01-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertTrue(ok)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["refreshed-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)
    }

    func testRefreshFailureKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"boom"}}"#.utf8),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 500)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertFalse(ok, "a failed fetch must not report success")
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["cached-kept"],
            "the existing cache must keep being served after a failed fetch"
        )
    }

    // MARK: - Refresh coordination

    func testActivationAndManualRefreshShareOneInFlightRequest() async throws {
        let staleCache = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-stale", displayName: "Cached Stale", createdAt: 1_000)],
            fetchedAt: Date(timeIntervalSinceNow: -100_000)
        )
        let fetcher = ControlledClaudeModelFetcher()
        let plugin = ClaudePlugin { apiKey in
            await fetcher.fetch(apiKey: apiKey)
        }
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: staleCache],
            secrets: ["api-key": "shared-key"]
        )

        plugin.activate(host: host)
        await fetcher.waitForRequestCount(1)

        let manualRefresh = Task { await plugin.refreshModels() }
        await Self.waitForRefreshWaiterCount(2, plugin: plugin)
        XCTAssertEqual(plugin.inFlightModelRefreshWaiterCountForTesting, 2)

        await fetcher.resolveFirst(
            apiKey: "shared-key",
            models: [ClaudeFetchedModel(id: "shared-result", displayName: "Shared", createdAt: 2_000)]
        )

        let manualRefreshSucceeded = await manualRefresh.value
        let recordedKeys = await fetcher.recordedKeys()
        XCTAssertTrue(manualRefreshSucceeded)
        XCTAssertEqual(recordedKeys, ["shared-key"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["shared-result"])
    }

    func testAPIKeyChangeDiscardsOlderInFlightResult() async throws {
        let fetcher = ControlledClaudeModelFetcher()
        let plugin = ClaudePlugin { apiKey in
            await fetcher.fetch(apiKey: apiKey)
        }
        let host = try PluginTestHostServices()
        plugin.activate(host: host)
        plugin.setApiKey("old-key")

        let oldRefresh = Task { await plugin.refreshModels() }
        await fetcher.waitForRequestCount(1)

        plugin.setApiKey("new-key")
        let newRefresh = Task { await plugin.refreshModels() }
        await fetcher.waitForRequestCount(2)

        await fetcher.resolveFirst(
            apiKey: "new-key",
            models: [ClaudeFetchedModel(id: "new-model", displayName: "New", createdAt: 2_000)]
        )
        let newRefreshSucceeded = await newRefresh.value
        XCTAssertTrue(newRefreshSucceeded)

        await fetcher.resolveFirst(
            apiKey: "old-key",
            models: [ClaudeFetchedModel(id: "old-model", displayName: "Old", createdAt: 1_000)]
        )
        let oldRefreshSucceeded = await oldRefresh.value
        let recordedKeys = await fetcher.recordedKeys()
        XCTAssertFalse(oldRefreshSucceeded)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["new-model"])
        XCTAssertEqual(recordedKeys, ["old-key", "new-key"])
        let persistedData = try XCTUnwrap(host.userDefault(forKey: Self.cachedModelsKey) as? Data)
        let persistedCache = try JSONDecoder().decode(ClaudeModelCache.self, from: persistedData)
        XCTAssertEqual(persistedCache.models.map(\.id), ["new-model"])
    }

    func testDeactivateDiscardsInFlightResultWithoutNotification() async throws {
        let fetcher = ControlledClaudeModelFetcher()
        let plugin = ClaudePlugin { apiKey in
            await fetcher.fetch(apiKey: apiKey)
        }
        let host = try PluginTestHostServices()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")
        let notificationsBeforeRefresh = host.capabilitiesChangedCount

        let refresh = Task { await plugin.refreshModels() }
        await fetcher.waitForRequestCount(1)
        plugin.deactivate()

        await fetcher.resolveFirst(
            apiKey: "claude-key",
            models: [ClaudeFetchedModel(id: "stale-model", displayName: "Stale", createdAt: 1_000)]
        )

        let refreshSucceeded = await refresh.value
        XCTAssertFalse(refreshSucceeded)
        XCTAssertNil(plugin.cacheLastUpdated)
        XCTAssertEqual(host.capabilitiesChangedCount, notificationsBeforeRefresh)
    }

    // MARK: - Selection preservation

    func testSelectedModelIsPreservedWhenNotInList() throws {
        let host = try PluginTestHostServices(
            defaults: [Self.selectedLLMModelKey: "claude-haiku-4-5-20251001"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.preferredModelId, "claude-haiku-4-5-20251001")
        XCTAssertTrue(
            plugin.supportedModels.contains { $0.id == "claude-haiku-4-5-20251001" },
            "a selected model that is not in the list must be appended so it stays selectable"
        )
        // Fallback entries still present.
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "claude-opus-4-8" })
    }

    func testSelectionPreservedAgainstFetchedListThatDropsIt() async throws {
        let host = try PluginTestHostServices(
            defaults: [Self.selectedLLMModelKey: "claude-legacy-pinned"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("claude-opus-4-8", "Claude Opus 4.8", "2026-01-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        _ = await plugin.refreshModels()
        XCTAssertEqual(plugin.preferredModelId, "claude-legacy-pinned")
        XCTAssertTrue(
            plugin.supportedModels.contains { $0.id == "claude-legacy-pinned" },
            "the still-selected model must survive even when the fetched list omits it"
        )
    }

    // MARK: - Unify: validation seeds the cache

    func testValidateApiKeySeedsModelCache() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key → no background refresh
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("validated-model", "Validated", "2026-03-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let valid = await plugin.validateApiKey("claude-key")
        XCTAssertTrue(valid)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["validated-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)
    }

    func testValidateApiKeyFailureReturnsFalse() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("bad-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data("{}".utf8), Self.httpResponse(url: Self.modelsURL, statusCode: 401)),
            ])
        }

        let valid = await plugin.validateApiKey("bad-key")
        XCTAssertFalse(valid)
    }

    // MARK: - Sampling parameter correctness

    func testUnselectedProcessingUsesNewestCachedModel() async throws {
        let cacheData = try Self.encodeCache(
            models: [
                ClaudeFetchedModel(id: "newest-model", displayName: "Newest", createdAt: 2_000),
                ClaudeFetchedModel(id: "older-model", displayName: "Older", createdAt: 1_000),
            ],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: cacheData],
            secrets: ["api-key": "claude-key"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.messagesResponse(text: "ok"),
                    Self.httpResponse(url: Self.messagesURL, statusCode: 200)
                ),
            ])
        }

        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: nil)

        let request = try XCTUnwrap(store.sessions[0].requestedRequests.first)
        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "newest-model")
        XCTAssertNil(plugin.selectedLLMModelId, "using the newest default must not persist a selection")
    }

    func testModelRejectsSamplingParamsByFamily() {
        for id in [
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos-5",
            "claude-mythos-preview",
            "claude-opus-4-9",
            "claude-haiku-5",
            "claude-future-unknown",
        ] {
            XCTAssertTrue(
                ClaudePlugin.modelRejectsSamplingParams(id),
                "\(id) rejects sampling params and must have temperature omitted"
            )
        }

        for id in [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-3-5-sonnet-20241022",
        ] {
            XCTAssertFalse(
                ClaudePlugin.modelRejectsSamplingParams(id),
                "\(id) honors sampling params and must keep the temperature override"
            )
        }
    }

    func testMessagesRequestOmitsTemperatureForNewerModelAndKeepsForOlder() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "llmTemperatureMode": PluginLLMTemperatureMode.custom.rawValue,
                "llmTemperatureValue": 0.7,
            ]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key on host → no background model refresh
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
            ])
        }

        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-opus-4-8")
        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-sonnet-4-6")
        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-future-unknown")

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 3)

        let opusBody = try Self.jsonBody(from: requests[0])
        XCTAssertNil(opusBody["temperature"], "temperature must be omitted for claude-opus-4-8")

        let sonnetBody = try Self.jsonBody(from: requests[1])
        XCTAssertEqual(sonnetBody["temperature"] as? Double, 0.7, "temperature must be sent for claude-sonnet-4-6")

        let futureBody = try Self.jsonBody(from: requests[2])
        XCTAssertNil(futureBody["temperature"], "temperature must be omitted for unknown future models")
    }

    // MARK: - Helpers

    private static func waitForRefreshWaiterCount(_ expectedCount: Int, plugin: ClaudePlugin) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while plugin.inFlightModelRefreshWaiterCountForTesting < expectedCount,
              clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func modelsPage(
        models: [(id: String, displayName: String, createdAt: String)],
        hasMore: Bool,
        lastId: String?
    ) -> Data {
        var body: [String: Any] = [
            "data": models.map { model in
                [
                    "id": model.id,
                    "display_name": model.displayName,
                    "created_at": model.createdAt,
                    "type": "model",
                ]
            },
            "has_more": hasMore,
        ]
        if let lastId {
            body["last_id"] = lastId
        }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func messagesResponse(text: String) -> Data {
        let body: [String: Any] = [
            "content": [["type": "text", "text": text]],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func encodeCache(models: [ClaudeFetchedModel], fetchedAt: Date) throws -> Data {
        try JSONEncoder().encode(ClaudeModelCache(models: models, fetchedAt: fetchedAt))
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
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

private actor ControlledClaudeModelFetcher {
    private struct PendingRequest {
        let apiKey: String
        let continuation: CheckedContinuation<[ClaudeFetchedModel]?, Never>
    }

    private struct RequestCountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var keys: [String] = []
    private var pendingRequests: [PendingRequest] = []
    private var requestCountWaiters: [RequestCountWaiter] = []

    func fetch(apiKey: String) async -> [ClaudeFetchedModel]? {
        keys.append(apiKey)
        resumeSatisfiedRequestCountWaiters()
        return await withCheckedContinuation { continuation in
            pendingRequests.append(
                PendingRequest(apiKey: apiKey, continuation: continuation)
            )
        }
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        guard keys.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters.append(
                RequestCountWaiter(expectedCount: expectedCount, continuation: continuation)
            )
        }
    }

    func resolveFirst(apiKey: String, models: [ClaudeFetchedModel]?) {
        guard let index = pendingRequests.firstIndex(where: { $0.apiKey == apiKey }) else {
            preconditionFailure("No pending Claude model request for \(apiKey)")
        }
        let request = pendingRequests.remove(at: index)
        request.continuation.resume(returning: models)
    }

    func recordedKeys() -> [String] {
        keys
    }

    private func resumeSatisfiedRequestCountWaiters() {
        var remaining: [RequestCountWaiter] = []
        for waiter in requestCountWaiters {
            if keys.count >= waiter.expectedCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }
}
