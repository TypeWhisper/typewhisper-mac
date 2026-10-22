import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

// Screenshot automation blocks provider requests, so an automatic refresh could only fail.
enum ClaudeAutomaticRefreshPolicy {
    static func allowsRefreshOnAppear(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        !arguments.contains("--store-screenshots")
    }
}

// MARK: - Plugin Entry Point

@objc(ClaudePlugin)
final class ClaudePlugin: NSObject, LLMProviderPlugin, LLMTemperatureAndEffortControllableProvider, LLMModelSelectable, @unchecked Sendable {
    static let pluginId = "com.typewhisper.claude"
    static let pluginName = "Claude"

    private static let modelsEndpoint = "https://api.anthropic.com/v1/models"
    private static let messagesEndpoint = "https://api.anthropic.com/v1/messages"
    private static let anthropicVersion = "2023-06-01"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let cachedModelsKey = "fetchedLLMModels.v1"
    private static let reasoningEffortKey = "reasoningEffort"
    private static let promptCacheKey = "promptCacheTTL"
    private static let refusalFallbackKey = "refusalFallback"
    /// Models that accept `fallbacks: "default"`: when a safety classifier
    /// declines, Anthropic re-runs the request on a fallback model in the same
    /// call. Claude Haiku 5.5 has no server-side fallback.
    nonisolated static let refusalFallbackModels: Set<String> = [
        "claude-opus-5-5",
        "claude-opus-5",
        "claude-sonnet-5-5",
        "claude-fable-5-1",
    ]
    nonisolated static let refusalFallbackBeta = "server-side-fallback-2026-07-01"
    /// Serve a cached model list without re-fetching for 24 hours.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    /// Safety bound on pagination so a misbehaving `has_more` never loops forever.
    private static let maxModelPages = 20
    private static let logger = Logger(subsystem: "com.typewhisper.claude", category: "Plugin")

    typealias ModelFetchOperation = @Sendable (String) async -> [ClaudeFetchedModel]?

    private struct InFlightModelRefresh {
        let id: UUID
        let apiKey: String
        let generation: UInt64
        let task: Task<Bool, Never>
        var waiterCount: Int
    }

    private struct State {
        var isActive = false
        var host: HostServices?
        var apiKey: String?
        var selectedLLMModelId: String?
        var llmTemperatureModeRaw = PluginLLMTemperatureMode.providerDefault.rawValue
        var llmTemperatureValue = 0.3
        /// Saved `output_config.effort`; empty means the model's own default.
        var reasoningEffortId = ""
        var promptCache = ClaudePromptCache.fiveMinutes
        var refusalFallbackEnabled = true
        var lastRequestSummary: ClaudeRequestSummary?
        var modelCache: ClaudeModelCache?
        var refreshGeneration: UInt64 = 0
        var inFlightModelRefresh: InFlightModelRefresh?
        var lastModelRefreshFailure: ClaudeModelRefreshFailure?
    }

    private struct ProcessingSnapshot {
        let apiKey: String?
        let selectedModelId: String?
        let defaultModelId: String
        let temperatureDirective: PluginLLMTemperatureDirective
        let reasoningEffortId: String
        let promptCache: ClaudePromptCache
        let refusalFallbackEnabled: Bool
        let modelCache: ClaudeModelCache?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let modelFetchOverride: ModelFetchOperation?

    required override init() {
        modelFetchOverride = nil
        super.init()
    }

    init(modelFetchOverride: @escaping ModelFetchOperation) {
        self.modelFetchOverride = modelFetchOverride
        super.init()
    }

    func activate(host: HostServices) {
        let apiKey = host.loadSecret(key: "api-key")
        let selectedLLMModelId = host.userDefault(forKey: Self.selectedLLMModelKey) as? String
        let modelCache: ClaudeModelCache?
        if let data = host.userDefault(forKey: Self.cachedModelsKey) as? Data,
           let cache = try? JSONDecoder().decode(ClaudeModelCache.self, from: data) {
            modelCache = cache
        } else {
            modelCache = nil
        }
        let llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        let llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.3
        let reasoningEffortId = Self.normalizedEffortId(
            host.userDefault(forKey: Self.reasoningEffortKey) as? String
        ) ?? ""
        let promptCache = (host.userDefault(forKey: Self.promptCacheKey) as? String)
            .flatMap(ClaudePromptCache.init(rawValue:)) ?? .fiveMinutes
        let refusalFallbackEnabled = host.userDefault(forKey: Self.refusalFallbackKey) as? Bool ?? true

        let previousTask = state.withLock { state -> Task<Bool, Never>? in
            let previousTask = state.inFlightModelRefresh?.task
            state.isActive = true
            state.host = host
            state.apiKey = apiKey
            state.selectedLLMModelId = selectedLLMModelId
            state.llmTemperatureModeRaw = llmTemperatureModeRaw
            state.llmTemperatureValue = llmTemperatureValue
            state.reasoningEffortId = reasoningEffortId
            state.promptCache = promptCache
            state.refusalFallbackEnabled = refusalFallbackEnabled
            state.modelCache = modelCache
            state.refreshGeneration &+= 1
            state.inFlightModelRefresh = nil
            return previousTask
        }
        previousTask?.cancel()

        // Refresh the model list on activation when the cache is missing or stale.
        refreshModelsIfNeeded()
    }

    func deactivate() {
        let refreshTask = state.withLock { state -> Task<Bool, Never>? in
            let refreshTask = state.inFlightModelRefresh?.task
            state.isActive = false
            state.host = nil
            state.refreshGeneration &+= 1
            state.inFlightModelRefresh = nil
            return refreshTask
        }
        refreshTask?.cancel()
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Claude" }

    var isAvailable: Bool {
        state.withLock { state in
            guard let key = state.apiKey else { return false }
            return !key.isEmpty
        }
    }

    fileprivate var apiKey: String? { state.withLock { $0.apiKey } }

    /// Shown when no cache exists yet (no key configured, or offline). Uses the
    /// current alias ids with no date suffixes — the API returns the same aliases.
    fileprivate static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        PluginModelInfo(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        PluginModelInfo(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
        PluginModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        PluginModelInfo(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
    ]

    /// The fetched list (newest-first) when a non-empty cache exists, otherwise
    /// the hardcoded fallback.
    private static func baseModels(from cache: ClaudeModelCache?) -> [PluginModelInfo] {
        if let cache, !cache.models.isEmpty {
            return cache.models.map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
        }
        return fallbackLLMModels
    }

    var supportedModels: [PluginModelInfo] {
        let snapshot = state.withLock { ($0.modelCache, $0.selectedLLMModelId) }
        var models = Self.baseModels(from: snapshot.0)
        // Selection preservation: if the user's selected model isn't in the
        // current list (e.g. a previously-selected dated id, or a model the
        // account no longer exposes), keep it selectable by appending it rather
        // than silently switching the user to a different model.
        if let selected = snapshot.1,
           !selected.isEmpty,
           !models.contains(where: { $0.id == selected }) {
            models.append(PluginModelInfo(id: selected, displayName: selected))
        }
        return models
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting,
            effort: nil
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: temperatureDirective,
            effort: nil
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        effort: String?
    ) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting,
            effort: effort
        )
    }

    /// Every request ends here. A nil `effort` (the host's "Provider Default")
    /// falls back to the saved reasoning effort, then to the model's default.
    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective,
        effort: String?
    ) async throws -> String {
        let snapshot = state.withLock { state -> ProcessingSnapshot in
            let models = Self.baseModels(from: state.modelCache)
            return ProcessingSnapshot(
                apiKey: state.apiKey,
                selectedModelId: state.selectedLLMModelId,
                defaultModelId: models.first?.id ?? Self.fallbackLLMModels[0].id,
                temperatureDirective: PluginLLMTemperatureDirective(
                    mode: PluginLLMTemperatureMode(rawValue: state.llmTemperatureModeRaw) ?? .providerDefault,
                    value: state.llmTemperatureValue
                ),
                reasoningEffortId: state.reasoningEffortId,
                promptCache: state.promptCache,
                refusalFallbackEnabled: state.refusalFallbackEnabled,
                modelCache: state.modelCache
            )
        }
        guard let apiKey = snapshot.apiKey, !apiKey.isEmpty else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? snapshot.selectedModelId ?? snapshot.defaultModelId
        let resolvedTemperature = snapshot.temperatureDirective.resolvedTemperature(applying: temperatureDirective)
        let context = Self.requestContext(
            model: modelId,
            requestedEffort: Self.normalizedEffortId(effort) ?? Self.normalizedEffortId(snapshot.reasoningEffortId),
            temperature: resolvedTemperature,
            promptCache: snapshot.promptCache,
            refusalFallbackEnabled: snapshot.refusalFallbackEnabled,
            metadata: snapshot.modelCache?.models.first { $0.id == modelId }
        )
        return try await callMessagesAPI(
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            userText: userText,
            context: context
        )
    }

    // MARK: - LLMEffortControllableProvider

    func supportedEfforts(for model: String?) -> [PluginLLMEffortInfo] {
        resolvedModel(model).capabilities.effortLevels.map {
            PluginLLMEffortInfo(id: $0, displayName: Self.effortDisplayName($0))
        }
    }

    /// What a request without an explicit effort will use: the saved effort when
    /// the model supports it, otherwise the model's own default.
    func defaultEffortId(for model: String?) -> String? {
        let capabilities = resolvedModel(model).capabilities
        if let saved = Self.normalizedEffortId(reasoningEffortId), capabilities.effortLevels.contains(saved) {
            return saved
        }
        return capabilities.defaultEffort
    }

    /// The level the API uses when no effort is sent, for the "Model Default" label.
    func modelDefaultEffortId(for model: String?) -> String? {
        resolvedModel(model).capabilities.defaultEffort
    }

    /// Saved reasoning effort; empty means the model's default.
    var reasoningEffortId: String { state.withLock { $0.reasoningEffortId } }

    func setReasoningEffort(_ effortId: String) {
        let normalized = Self.normalizedEffortId(effortId) ?? ""
        let host = state.withLock { state -> HostServices? in
            // The settings view echoes the loaded value back on appear.
            guard state.reasoningEffortId != normalized else { return nil }
            state.reasoningEffortId = normalized
            return state.host
        }
        host?.setUserDefault(normalized, forKey: Self.reasoningEffortKey)
        // The host labels its "Provider Default" effort with defaultEffortId(for:).
        host?.notifyCapabilitiesChanged()
    }

    /// Whether a custom temperature is dropped: newer models reject sampling
    /// parameters, older ones reject them while thinking.
    func ignoresCustomTemperature(for model: String?, reasoningEffortId: String) -> Bool {
        let resolved = resolvedModel(model)
        let thinks = Self.normalizedEffortId(reasoningEffortId).map {
            resolved.capabilities.effortLevels.contains($0) && resolved.capabilities.supportsAdaptiveThinking
        } ?? false
        return thinks || Self.modelRejectsSamplingParams(resolved.id)
    }

    // MARK: - Prompt Caching

    var promptCache: ClaudePromptCache { state.withLock { $0.promptCache } }

    func setPromptCache(_ promptCache: ClaudePromptCache) {
        let host = state.withLock { state -> HostServices? in
            state.promptCache = promptCache
            return state.host
        }
        host?.setUserDefault(promptCache.rawValue, forKey: Self.promptCacheKey)
    }

    // MARK: - Refusal Fallback

    var refusalFallbackEnabled: Bool { state.withLock { $0.refusalFallbackEnabled } }

    func setRefusalFallbackEnabled(_ enabled: Bool) {
        let host = state.withLock { state -> HostServices? in
            state.refusalFallbackEnabled = enabled
            return state.host
        }
        host?.setUserDefault(enabled, forKey: Self.refusalFallbackKey)
    }

    /// Token usage of the last answered request; shows whether caching works.
    var lastRequestSummary: ClaudeRequestSummary? { state.withLock { $0.lastRequestSummary } }

    /// `model`, or the model a request without one would use, with its capabilities.
    private func resolvedModel(_ model: String?) -> (id: String, capabilities: ClaudeModelCapabilities) {
        let (modelId, metadata) = state.withLock { state -> (String, ClaudeFetchedModel?) in
            let modelId = model
                ?? state.selectedLLMModelId
                ?? Self.baseModels(from: state.modelCache).first?.id
                ?? Self.fallbackLLMModels[0].id
            return (modelId, state.modelCache?.models.first { $0.id == modelId })
        }
        return (modelId, Self.capabilities(for: modelId, metadata: metadata))
    }

    func selectLLMModel(_ modelId: String) {
        let host = state.withLock { state -> HostServices? in
            state.selectedLLMModelId = modelId
            return state.host
        }
        host?.setUserDefault(modelId, forKey: Self.selectedLLMModelKey)
    }

    var selectedLLMModelId: String? { state.withLock { $0.selectedLLMModelId } }
    @objc var preferredModelId: String? { state.withLock { $0.selectedLLMModelId } }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        state.withLock {
            PluginLLMTemperatureMode(rawValue: $0.llmTemperatureModeRaw) ?? .providerDefault
        }
    }
    var llmTemperatureValue: Double { state.withLock { $0.llmTemperatureValue } }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        let host = state.withLock { state -> HostServices? in
            state.llmTemperatureModeRaw = mode.rawValue
            return state.host
        }
        host?.setUserDefault(mode.rawValue, forKey: "llmTemperatureMode")
    }

    func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        let host = state.withLock { state -> HostServices? in
            state.llmTemperatureValue = clamped
            return state.host
        }
        host?.setUserDefault(clamped, forKey: "llmTemperatureValue")
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(ClaudeSettingsView(plugin: self))
    }

    // MARK: - API Key Management

    func setApiKey(_ key: String) {
        let transition = state.withLock { state -> (host: HostServices?, task: Task<Bool, Never>?) in
            let keyChanged = state.apiKey != key
            let task = keyChanged ? state.inFlightModelRefresh?.task : nil
            state.apiKey = key
            if keyChanged {
                state.refreshGeneration &+= 1
                state.inFlightModelRefresh = nil
                state.lastModelRefreshFailure = nil
            }
            return (state.host, task)
        }
        transition.task?.cancel()

        if let host = transition.host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[ClaudePlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        let transition = state.withLock { state -> (host: HostServices?, task: Task<Bool, Never>?) in
            let task = state.inFlightModelRefresh?.task
            state.apiKey = nil
            state.refreshGeneration &+= 1
            state.inFlightModelRefresh = nil
            state.lastModelRefreshFailure = nil
            return (state.host, task)
        }
        transition.task?.cancel()

        if let host = transition.host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[ClaudePlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    /// Validates the current key through the same coordinated model refresh used
    /// by activation and the settings UI. The settings flow stores the candidate
    /// key before calling this method, so an obsolete validation can never replace
    /// the cache after the key changes again.
    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }
        return await coordinatedModelRefresh(apiKey: key)
    }

    // MARK: - Dynamic Model Discovery

    /// True when a cached list exists and is younger than the TTL.
    var isModelCacheFresh: Bool {
        guard let cache = state.withLock({ $0.modelCache }) else { return false }
        return Date().timeIntervalSince(cache.fetchedAt) < Self.cacheTTL
    }

    var cacheLastUpdated: Date? { state.withLock { $0.modelCache?.fetchedAt } }

    /// Commits only a result that still belongs to the active API key and refresh
    /// generation. Persistence and host callbacks deliberately run outside the
    /// state lock.
    private func commitModelCache(
        _ models: [ClaudeFetchedModel],
        apiKey: String,
        generation: UInt64
    ) -> Bool {
        let cache = ClaudeModelCache(models: models, fetchedAt: Date())
        let host = state.withLock { state -> HostServices? in
            guard state.isActive,
                  state.apiKey == apiKey,
                  state.refreshGeneration == generation else { return nil }
            state.modelCache = cache
            state.lastModelRefreshFailure = nil
            return state.host
        }
        guard let host else { return false }

        if let data = try? JSONEncoder().encode(cache) {
            host.setUserDefault(data, forKey: Self.cachedModelsKey)
        }
        host.notifyCapabilitiesChanged()
        return true
    }

    /// Why the last model refresh (or key validation) failed, for the settings UI.
    /// Cleared by a successful refresh and whenever the API key changes.
    var lastModelRefreshFailure: ClaudeModelRefreshFailure? {
        state.withLock { $0.lastModelRefreshFailure }
    }

    /// Fetches the full model list (following pagination), returning nil on any
    /// network/HTTP failure so callers can keep serving the existing cache. The
    /// reason is kept in `lastModelRefreshFailure`.
    func fetchModels(apiKey: String) async -> [ClaudeFetchedModel]? {
        guard !apiKey.isEmpty else { return nil }

        var collected: [ClaudeFetchedModel] = []
        var afterId: String?
        var seenCursors = Set<String>()

        for _ in 0..<Self.maxModelPages {
            guard var components = URLComponents(string: Self.modelsEndpoint) else { return nil }
            var queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterId {
                queryItems.append(URLQueryItem(name: "after_id", value: afterId))
            }
            components.queryItems = queryItems
            guard let url = components.url else { return nil }

            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 15

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await PluginHTTPClient.data(for: request)
            } catch {
                if let urlError = error as? URLError, urlError.code != .cancelled, !Task.isCancelled {
                    recordModelRefreshFailure(
                        ClaudeModelRefreshFailure(
                            statusCode: nil,
                            message: Self.transportFailureMessage(
                                urlError,
                                timeout: request.timeoutInterval,
                                context: nil
                            )
                        ),
                        apiKey: apiKey
                    )
                }
                return nil
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                recordModelRefreshFailure(
                    ClaudeModelRefreshFailure(statusCode: nil, message: "Anthropic sent a response that isn't HTTP."),
                    apiKey: apiKey
                )
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                recordModelRefreshFailure(
                    ClaudeModelRefreshFailure(
                        statusCode: httpResponse.statusCode,
                        message: Self.describeHTTPFailure(
                            statusCode: httpResponse.statusCode,
                            data: data,
                            response: httpResponse,
                            context: nil
                        )
                    ),
                    apiKey: apiKey
                )
                return nil
            }

            let page: (models: [ClaudeFetchedModel], hasMore: Bool, lastId: String?)
            do {
                page = try Self.decodeModelsPage(from: data)
            } catch {
                let summary = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
                recordModelRefreshFailure(
                    ClaudeModelRefreshFailure(
                        statusCode: 200,
                        message: "Couldn't read Anthropic's model list (\(data.count) bytes): \(summary)"
                    ),
                    apiKey: apiKey
                )
                return nil
            }
            collected.append(contentsOf: page.models)
            guard page.hasMore else {
                return Self.sortedNewestFirst(collected)
            }

            guard let lastId = page.lastId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lastId.isEmpty,
                  seenCursors.insert(lastId).inserted else {
                recordModelRefreshFailure(
                    ClaudeModelRefreshFailure(
                        statusCode: 200,
                        message: "Anthropic's model list was incomplete (a page had no new cursor), so the cached list was kept."
                    ),
                    apiKey: apiKey
                )
                return nil
            }
            afterId = lastId
        }

        // Reaching the safety bound with `has_more` still set means the response
        // is incomplete. Never replace a known-good cache with a partial list.
        recordModelRefreshFailure(
            ClaudeModelRefreshFailure(
                statusCode: 200,
                message: "Anthropic's model list didn't end after \(Self.maxModelPages) pages, so the cached list was kept."
            ),
            apiKey: apiKey
        )
        return nil
    }

    private func recordModelRefreshFailure(_ failure: ClaudeModelRefreshFailure, apiKey: String) {
        Self.logger.error("Model list refresh failed: \(failure.message, privacy: .private)")
        state.withLock { state in
            guard state.apiKey == apiKey else { return }
            state.lastModelRefreshFailure = failure
        }
    }

    /// Explicit refresh used by the settings UI and the "Refresh models" button.
    /// Returns whether a fresh list was fetched and cached.
    @discardableResult
    func refreshModels() async -> Bool {
        guard let apiKey = state.withLock({ state -> String? in
            guard state.isActive else { return nil }
            return state.apiKey
        }), !apiKey.isEmpty else { return false }
        return await coordinatedModelRefresh(apiKey: apiKey)
    }

    /// Background refresh: serve the cache immediately, refresh only when missing
    /// or stale, and keep the cache on failure.
    private func refreshModelsIfNeeded() {
        let apiKey = state.withLock { state -> String? in
            guard state.isActive,
                  let apiKey = state.apiKey,
                  !apiKey.isEmpty else { return nil }
            if let cache = state.modelCache,
               Date().timeIntervalSince(cache.fetchedAt) < Self.cacheTTL {
                return nil
            }
            return apiKey
        }
        guard let apiKey else { return }

        Task { [weak self] in
            _ = await self?.coordinatedModelRefresh(apiKey: apiKey)
        }
    }

    /// Starts or joins the single refresh for the active key. The task itself
    /// performs the guarded commit exactly once, so every same-key caller sees the
    /// same result without duplicate writes or requests.
    private func coordinatedModelRefresh(apiKey: String) async -> Bool {
        let refresh = state.withLock { state -> InFlightModelRefresh? in
            guard state.isActive, state.apiKey == apiKey else { return nil }

            if var inFlight = state.inFlightModelRefresh,
               inFlight.apiKey == apiKey,
               inFlight.generation == state.refreshGeneration {
                inFlight.waiterCount += 1
                state.inFlightModelRefresh = inFlight
                return inFlight
            }

            let id = UUID()
            let generation = state.refreshGeneration
            state.lastModelRefreshFailure = nil
            let task = Task { [weak self] in
                guard let self, !Task.isCancelled,
                      let models = await self.performModelFetch(apiKey: apiKey),
                      !Task.isCancelled,
                      !models.isEmpty else { return false }
                return self.commitModelCache(models, apiKey: apiKey, generation: generation)
            }
            let refresh = InFlightModelRefresh(
                id: id,
                apiKey: apiKey,
                generation: generation,
                task: task,
                waiterCount: 1
            )
            state.inFlightModelRefresh = refresh
            return refresh
        }
        guard let refresh else { return false }

        let succeeded = await refresh.task.value
        state.withLock { state in
            if state.inFlightModelRefresh?.id == refresh.id {
                state.inFlightModelRefresh = nil
            }
        }
        return succeeded
    }

    var inFlightModelRefreshWaiterCountForTesting: Int {
        state.withLock { $0.inFlightModelRefresh?.waiterCount ?? 0 }
    }

    private func performModelFetch(apiKey: String) async -> [ClaudeFetchedModel]? {
        if let modelFetchOverride {
            return await modelFetchOverride(apiKey)
        }
        return await fetchModels(apiKey: apiKey)
    }

    nonisolated static func decodeModelsPage(
        from data: Data
    ) throws -> (models: [ClaudeFetchedModel], hasMore: Bool, lastId: String?) {
        let decoded = try JSONDecoder().decode(ClaudeModelsResponse.self, from: data)
        let models = decoded.data.map {
            ClaudeFetchedModel(
                id: $0.id,
                displayName: $0.displayName ?? $0.id,
                createdAt: parseTimestamp($0.createdAt),
                maxOutputTokens: $0.maxTokens.flatMap { $0 > 0 ? $0 : nil },
                supportsAdaptiveThinking: $0.capabilities?.thinking?.types?.adaptive?.supported,
                effortLevels: $0.capabilities?.effort?.supportedLevels
            )
        }
        return (models, decoded.hasMore ?? false, decoded.lastId)
    }

    /// Sort newest-first by `created_at`; ties fall back to id for determinism.
    nonisolated static func sortedNewestFirst(_ models: [ClaudeFetchedModel]) -> [ClaudeFetchedModel] {
        models.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id < rhs.id
        }
    }

    nonisolated private static func parseTimestamp(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date.timeIntervalSince1970
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)?.timeIntervalSince1970 ?? 0
    }

    /// Anthropic models released after Opus 4.6 reject sampling parameters. Keep
    /// an explicit allowlist for known compatible families and conservatively
    /// omit `temperature` for every unknown or future model id.
    nonisolated static func modelRejectsSamplingParams(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        let compatiblePrefixes = [
            "claude-3-",
            "claude-haiku-4-5",
            "claude-sonnet-4-6",
            "claude-opus-4-6",
        ]
        return !compatiblePrefixes.contains { id.hasPrefix($0) }
    }

    // MARK: - Reasoning Effort

    /// `output_config.effort` levels, lowest first.
    nonisolated static let effortLadder = ["low", "medium", "high", "xhigh", "max"]
    /// Room for thinking plus the reply. `max_tokens` doesn't count toward rate
    /// limits and only generated tokens are billed, so it can be generous.
    nonisolated static let defaultMaxOutputTokens = 16_000

    nonisolated static func normalizedEffortId(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        return value
    }

    /// Reasoning support for models the Models API metadata doesn't cover: the
    /// fallback list, caches written by plugin 1.1, or a selection that is no
    /// longer listed. The first matching row wins, so longer ids come first.
    nonisolated static func staticCapabilities(for modelId: String) -> ClaudeModelCapabilities {
        let id = modelId.lowercased()
        // Claude 3 models cap output at 4,096 tokens; newer ones allow far more.
        let maxOutputTokens = id.hasPrefix("claude-3-") ? 4_096 : nil
        let rows: [(prefixes: [String], levels: [String], adaptiveThinking: Bool, defaultEffort: String)] = [
            (["claude-opus-5-5", "claude-haiku-5-5"], effortLadder, true, "medium"),
            (
                ["claude-fable-", "claude-mythos-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-opus-4-7"],
                effortLadder,
                true,
                "high"
            ),
            (["claude-opus-4-6", "claude-sonnet-4-6", "claude-mythos-preview"], ["low", "medium", "high", "max"], true, "high"),
            // Effort without adaptive thinking: `thinking.type.adaptive` is a 400 here.
            (["claude-opus-4-5"], ["low", "medium", "high"], false, "high"),
        ]
        for row in rows where row.prefixes.contains(where: { id.hasPrefix($0) }) {
            return ClaudeModelCapabilities(
                effortLevels: row.levels,
                supportsAdaptiveThinking: row.adaptiveThinking,
                defaultEffort: row.defaultEffort,
                maxOutputTokens: maxOutputTokens
            )
        }
        return ClaudeModelCapabilities(
            effortLevels: [],
            supportsAdaptiveThinking: false,
            defaultEffort: nil,
            maxOutputTokens: maxOutputTokens
        )
    }

    /// Models API metadata where present, the static table for the rest.
    nonisolated static func capabilities(
        for modelId: String,
        metadata: ClaudeFetchedModel?
    ) -> ClaudeModelCapabilities {
        let fallback = staticCapabilities(for: modelId)
        guard let metadata else { return fallback }
        let levels = metadata.effortLevels.map { listed in effortLadder.filter { listed.contains($0) } }
            ?? fallback.effortLevels
        let defaultEffort: String?
        if let known = fallback.defaultEffort, levels.contains(known) {
            defaultEffort = known
        } else {
            // Every model that takes `effort` defaults to high except Opus 5.5 and Haiku 5.5.
            defaultEffort = levels.contains("high") ? "high" : levels.last
        }
        return ClaudeModelCapabilities(
            effortLevels: levels,
            supportsAdaptiveThinking: metadata.supportsAdaptiveThinking ?? fallback.supportsAdaptiveThinking,
            defaultEffort: defaultEffort,
            maxOutputTokens: metadata.maxOutputTokens ?? fallback.maxOutputTokens
        )
    }

    /// Non-streaming requests stay idle until the reply is complete, and the
    /// HTTP client retries a timed-out POST once, so the timeout has to cover
    /// the thinking time of the effort level in use.
    nonisolated static func requestTimeout(forEffort effort: String?) -> TimeInterval {
        switch effort {
        case "high": 120
        case "xhigh": 180
        case "max": 300
        default: 60
        }
    }

    nonisolated static func effortDisplayName(_ id: String) -> String {
        switch id {
        case "low": String(localized: "Low", bundle: localizationBundle)
        case "medium": String(localized: "Medium", bundle: localizationBundle)
        case "high": String(localized: "High", bundle: localizationBundle)
        case "xhigh": String(localized: "X High", bundle: localizationBundle)
        case "max": String(localized: "Maximum", bundle: localizationBundle)
        default: id.capitalized
        }
    }

    nonisolated private static var localizationBundle: Bundle {
#if SWIFT_PACKAGE
        .module
#else
        Bundle(for: ClaudePlugin.self)
#endif
    }

    /// Resolves what a request sends: an effort the model doesn't take falls
    /// back to the model default, adaptive thinking accompanies an effort where
    /// the model needs it to think, and `temperature` is dropped whenever the
    /// model can't take it.
    nonisolated static func requestContext(
        model: String,
        requestedEffort: String?,
        temperature: Double?,
        promptCache: ClaudePromptCache = .off,
        refusalFallbackEnabled: Bool = false,
        metadata: ClaudeFetchedModel?
    ) -> ClaudeRequestContext {
        let capabilities = capabilities(for: model, metadata: metadata)
        var effort = requestedEffort
        if let requestedEffort, !capabilities.effortLevels.contains(requestedEffort) {
            logger.info("Reasoning effort \(requestedEffort, privacy: .public) isn't available for \(model, privacy: .public); using the model default")
            effort = nil
        }
        let adaptiveThinking = effort != nil && capabilities.supportsAdaptiveThinking
        // Newer models reject sampling parameters outright; older ones while thinking.
        let acceptsTemperature = !adaptiveThinking && !modelRejectsSamplingParams(model)
        return ClaudeRequestContext(
            model: model,
            effort: effort,
            adaptiveThinking: adaptiveThinking,
            temperature: acceptsTemperature ? temperature : nil,
            promptCache: promptCache,
            refusalFallback: refusalFallbackEnabled && refusalFallbackModels.contains(model.lowercased()),
            maxTokens: min(defaultMaxOutputTokens, capabilities.maxOutputTokens ?? defaultMaxOutputTokens),
            timeout: requestTimeout(forEffort: effort ?? capabilities.defaultEffort)
        )
    }

    // MARK: - Anthropic Messages API

    nonisolated static func messagesRequestBody(
        systemPrompt: String,
        userText: String,
        context: ClaudeRequestContext
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": context.model,
            "max_tokens": context.maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userText]
            ]
        ]
        // The breakpoint closes the stable prefix (the workflow's system prompt);
        // the dictated text after it differs every time and is never cached.
        // Top-level automatic caching would place it after that text instead.
        if let cacheControl = context.promptCache.cacheControl,
           !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["system"] = [
                ["type": "text", "text": systemPrompt, "cache_control": cacheControl]
            ]
        }
        if let effort = context.effort {
            body["output_config"] = ["effort": effort]
            if context.adaptiveThinking {
                body["thinking"] = ["type": "adaptive"]
            }
        }
        if let temperature = context.temperature {
            body["temperature"] = temperature
        }
        if context.refusalFallback {
            body["fallbacks"] = "default"
        }
        return body
    }

    private func callMessagesAPI(
        apiKey: String,
        systemPrompt: String,
        userText: String,
        context: ClaudeRequestContext
    ) async throws -> String {
        guard let url = URL(string: Self.messagesEndpoint) else {
            throw PluginChatError.apiError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if context.refusalFallback {
            request.setValue(Self.refusalFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.timeoutInterval = context.timeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.messagesRequestBody(systemPrompt: systemPrompt, userText: userText, context: context)
        )
        let model = context.model

        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await PluginHTTPClient.data(for: request)
        } catch {
            // Cancellation is the caller's decision; pass it through untouched.
            guard let urlError = error as? URLError, urlError.code != .cancelled, !Task.isCancelled else {
                throw error
            }
            let message = Self.transportFailureMessage(urlError, timeout: context.timeout, context: context)
            Self.logger.error(
                "Messages request failed [URLError \(urlError.code.rawValue)] \(Self.detailSuffix(context: context), privacy: .public): \(message, privacy: .private)"
            )
            throw PluginChatError.networkError(message)
        }
        let elapsed = ContinuousClock.now - started

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError(
                "Anthropic sent a response that isn't HTTP. \(Self.detailSuffix(context: context))"
            )
        }
        let requestId = httpResponse.value(forHTTPHeaderField: "request-id")

        guard httpResponse.statusCode == 200 else {
            let message = Self.describeHTTPFailure(
                statusCode: httpResponse.statusCode,
                data: data,
                response: httpResponse,
                context: context
            )
            Self.logger.error(
                "Messages request failed after \(String(describing: elapsed), privacy: .public) \(Self.detailSuffix(statusCode: httpResponse.statusCode, context: context, requestId: requestId), privacy: .public): \(message, privacy: .private)"
            )
            throw PluginChatError.apiError(message)
        }

        // Reported before the reply is read: refused, cut-off and unreadable replies still used tokens.
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for usage in Self.usageReports(from: json) {
                PluginLLMUsageReporting.report(usage)
            }
        }

        guard let decoded = try? JSONDecoder().decode(ClaudeMessagesResponse.self, from: data) else {
            let summary = PluginHTTPErrorBodyFormatter.summary(from: data, response: httpResponse)
            let message = "Couldn't read Claude's reply (\(data.count) bytes). "
                + Self.detailSuffix(statusCode: 200, context: context, requestId: requestId)
            Self.logger.error(
                "Couldn't read Claude's reply (\(data.count) bytes) \(Self.detailSuffix(statusCode: 200, context: context, requestId: requestId), privacy: .public): \(summary, privacy: .private)"
            )
            throw PluginChatError.apiError(message)
        }

        let usage = decoded.usage
        Self.logger.info(
            """
            Messages \(decoded.model ?? model, privacy: .public) -> 200 in \(String(describing: elapsed), privacy: .public) \
            [request \(requestId ?? "-", privacy: .public), stop \(decoded.stopReason ?? "-", privacy: .public), \
            input \(usage?.inputTokens ?? 0), cache read \(usage?.cacheReadInputTokens ?? 0), \
            cache write \(usage?.cacheCreationInputTokens ?? 0), output \(usage?.outputTokens ?? 0)]
            """
        )
        let declinedModel = decoded.declinedModels.first
        if let declinedModel {
            Self.logger.info("Refusal fallback: \(declinedModel, privacy: .public) declined, \(decoded.model ?? "-", privacy: .public) answered")
        }
        let summary = ClaudeRequestSummary(
            date: Date(),
            model: decoded.model ?? model,
            declinedModel: declinedModel,
            inputTokens: usage?.inputTokens ?? 0,
            cacheReadInputTokens: usage?.cacheReadInputTokens ?? 0,
            cacheCreationInputTokens: usage?.cacheCreationInputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
        state.withLock { $0.lastRequestSummary = summary }

        do {
            return try Self.replyText(from: decoded, context: context, requestId: requestId)
        } catch {
            Self.logger.error("Messages reply rejected")
            throw error
        }
    }

    /// The usage to report for one Messages response. With the refusal
    /// fallback, top-level `usage` counts only the model that answered, while
    /// `usage.iterations` lists every model that ran, the declined ones included.
    nonisolated static func usageReports(from response: [String: Any]) -> [PluginLLMUsage] {
        let iterations = (response["usage"] as? [String: Any])?["iterations"] as? [[String: Any]] ?? []
        guard !iterations.isEmpty else {
            return PluginLLMUsage.anthropicMessages(from: response).map { [$0] } ?? []
        }
        return iterations.compactMap { iteration in
            var attempt: [String: Any] = ["usage": iteration]
            attempt["model"] = iteration["model"]
            return PluginLLMUsage.anthropicMessages(from: attempt)
        }
    }

    // MARK: - Reply and Error Descriptions

    /// The reply text, or a descriptive error when the stop reason or content
    /// means the text must not be inserted.
    nonisolated static func replyText(
        from response: ClaudeMessagesResponse,
        context: ClaudeRequestContext,
        requestId: String?
    ) throws -> String {
        let text = response.replyText
        let details = detailSuffix(statusCode: 200, context: context, requestId: requestId)

        switch response.stopReason {
        case "refusal":
            // Never return partial text from a declined reply.
            let category = response.stopDetails?.category.map { " (\($0))" } ?? ""
            let explanation = response.stopDetails?.explanation.map(sentence)
                ?? "Anthropic's safety checks stopped the reply."
            throw PluginChatError.apiError(
                "Claude declined this request\(category): \(explanation) Rephrase the text or try another model. \(details)"
            )
        case "max_tokens":
            // A reply stopped at max_tokens is incomplete; fail instead of returning it.
            if text.isEmpty {
                throw PluginChatError.apiError(
                    "Claude used the whole \(context.maxTokens)-token output limit before writing an answer, so there is no reply. Lower the reasoning effort or shorten the text. \(details)"
                )
            }
            throw PluginChatError.apiError(
                "The reply was cut off at the output token limit (\(context.maxTokens) tokens), so the text is incomplete. \(details)"
            )
        case "model_context_window_exceeded":
            throw PluginChatError.apiError(
                "The text is too long for \(context.model)'s context window. Shorten it or choose a model with a larger context window. \(details)"
            )
        default:
            break
        }

        guard !text.isEmpty else {
            let blockTypes = response.content.map(\.type)
            let blocks = blockTypes.isEmpty ? "none" : blockTypes.joined(separator: ", ")
            throw PluginChatError.apiError(
                "Claude returned no text (stop reason: \(response.stopReason ?? "none"); content blocks: \(blocks)). Try again. \(details)"
            )
        }
        return text
    }

    /// Describes a non-200 Anthropic response: what failed, Anthropic's own
    /// message, what to do, then status, error type, request settings and the
    /// request id (the host's error log shows only the first lines, so the
    /// cause and the fix come first).
    nonisolated static func describeHTTPFailure(
        statusCode: Int,
        data: Data,
        response: HTTPURLResponse,
        context: ClaudeRequestContext?
    ) -> String {
        let envelope = try? JSONDecoder().decode(ClaudeAPIErrorEnvelope.self, from: data)
        let errorType = envelope?.error?.type
        let providerMessage: String
        if let message = envelope?.error?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            providerMessage = PluginHTTPErrorBodyFormatter.summary(from: message)
        } else {
            let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
            providerMessage = body == "{}" || body == "[]" ? "the response carried no error details" : body
        }
        let requestId = response.value(forHTTPHeaderField: "request-id") ?? envelope?.requestId

        let headline: String
        var advice: String?
        switch statusCode {
        case 400:
            headline = "Claude rejected the request"
            if context?.refusalFallback == true,
               providerMessage.localizedCaseInsensitiveContains("fallback")
                || providerMessage.localizedCaseInsensitiveContains("anthropic-beta") {
                advice = "Turn off “Retry declined requests on a fallback model” in the Claude plugin settings."
            } else {
                advice = "Check the selected model, reasoning effort and temperature in the Claude plugin settings."
            }
        case 401:
            headline = "Anthropic rejected the API key"
            advice = "Check or replace the key in Settings › Integrations › Claude."
        case 402:
            headline = "Anthropic reported a billing problem"
            advice = "Check Plans & Billing in the Claude Console."
        case 403:
            headline = context.map { "This API key isn't allowed to use \($0.model)" }
                ?? "This API key isn't allowed to make this request"
            advice = "Check the key's organization and workspace access in the Claude Console."
        case 404:
            if let context {
                headline = "Model \(context.model) isn't available to this API key"
                advice = "Refresh the model list in the Claude plugin settings and choose another model."
            } else {
                headline = "Anthropic couldn't find the requested resource"
            }
        case 413:
            headline = "The request is larger than Anthropic accepts (32 MB)"
            advice = "Shorten the text and try again."
        case 429 where envelope?.error?.details?.errorCode == "enforced_spend_limit_reached":
            headline = "Your organization reached its monthly API spend cap"
            advice = "Raise the cap under Settings › Billing in the Claude Console, or wait until it resets."
        case 429:
            headline = "Anthropic's rate limit was reached"
            advice = rateLimitAdvice(from: response)
        case 500:
            headline = "Anthropic had an internal error"
            advice = "Try again; if it keeps happening, check status.anthropic.com."
        case 504:
            headline = "Anthropic timed out while processing the request"
            advice = "Try again with a shorter text or a lower reasoning effort."
        case 529:
            headline = "Anthropic's API is overloaded right now"
            advice = "Try again in a moment or switch to another model."
        default:
            headline = "Anthropic returned HTTP \(statusCode)"
        }

        var message = "\(headline): \(sentence(providerMessage))"
        if let advice {
            message += " \(advice)"
        }
        return message + " " + detailSuffix(
            statusCode: statusCode,
            errorType: errorType,
            context: context,
            requestId: requestId
        )
    }

    /// The `retry-after` delay and, when one is used up, which rate limit and
    /// when it is replenished.
    nonisolated static func rateLimitAdvice(from response: HTTPURLResponse) -> String {
        var advice: [String] = []
        if let raw = response.value(forHTTPHeaderField: "retry-after")?.trimmingCharacters(in: .whitespaces),
           let seconds = Int(raw), seconds >= 0 {
            advice.append("Retry in \(seconds) s.")
        }
        let limits = [
            ("requests", "Request"),
            ("input-tokens", "Input-token"),
            ("output-tokens", "Output-token"),
            ("tokens", "Token"),
        ]
        for (header, label) in limits {
            let prefix = "anthropic-ratelimit-\(header)"
            guard response.value(forHTTPHeaderField: "\(prefix)-remaining")?
                .trimmingCharacters(in: .whitespaces) == "0" else { continue }
            var text = "\(label) limit"
            if let limit = response.value(forHTTPHeaderField: "\(prefix)-limit") {
                text += " (\(limit))"
            }
            text += " used up"
            if let reset = response.value(forHTTPHeaderField: "\(prefix)-reset") {
                text += "; it is fully replenished at \(formattedResetTime(reset))"
            }
            advice.append(text + ".")
            break
        }
        if advice.isEmpty {
            advice.append("Wait a moment and try again, or check your limits in the Claude Console.")
        }
        return advice.joined(separator: " ")
    }

    nonisolated private static func formattedResetTime(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date.formatted(date: .omitted, time: .standard)
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)?.formatted(date: .omitted, time: .standard) ?? raw
    }

    /// Describes a request that never got an HTTP response.
    nonisolated static func transportFailureMessage(
        _ error: URLError,
        timeout: TimeInterval,
        context: ClaudeRequestContext?
    ) -> String {
        let message: String
        switch error.code {
        case .timedOut:
            if let effort = context?.effort {
                message = "Anthropic didn't answer within \(Int(timeout)) s at reasoning effort \(effort). Higher efforts take longer; choose a lower one or try again."
            } else {
                message = "Anthropic didn't answer within \(Int(timeout)) s. Try again; long texts take longer."
            }
        case .notConnectedToInternet:
            message = "This Mac is offline, so Anthropic couldn't be reached. Check the network connection and try again."
        case .networkConnectionLost:
            message = "The connection to Anthropic dropped before the reply arrived. Try again; an unstable network or VPN can cause this."
        case .cannotFindHost, .dnsLookupFailed:
            message = "api.anthropic.com couldn't be found. Check DNS, VPN or proxy settings."
        case .cannotConnectToHost:
            message = "Couldn't connect to api.anthropic.com. A firewall, proxy or VPN may be blocking it."
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            message = "The secure connection to api.anthropic.com failed. A proxy, VPN or security tool may be intercepting HTTPS."
        default:
            message = "Couldn't reach Anthropic: \(sentence(error.localizedDescription))"
        }
        return message + " " + detailSuffix(
            context: context,
            extra: ["URLError \(error.code.rawValue)"]
        )
    }

    /// "[HTTP 404 not_found_error · model claude-x · request req_…]"
    nonisolated static func detailSuffix(
        statusCode: Int? = nil,
        errorType: String? = nil,
        context: ClaudeRequestContext?,
        requestId: String? = nil,
        extra: [String] = []
    ) -> String {
        var items: [String] = []
        if let statusCode {
            items.append(["HTTP \(statusCode)", errorType].compactMap { $0 }.joined(separator: " "))
        }
        items.append(contentsOf: extra)
        if let context {
            items.append(contentsOf: context.detailItems)
        }
        if let requestId, !requestId.isEmpty {
            items.append("request \(requestId)")
        }
        return items.isEmpty ? "" : "[\(items.joined(separator: " · "))]"
    }

    nonisolated private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…".contains(last) ? trimmed : trimmed + "."
    }
}

/// What a Messages request is sent with; error messages and logs quote it.
struct ClaudeRequestContext: Sendable {
    let model: String
    /// `output_config.effort`, or nil for the model's default.
    let effort: String?
    /// Send `thinking: {type: "adaptive"}` (only together with an effort).
    let adaptiveThinking: Bool
    let temperature: Double?
    let promptCache: ClaudePromptCache
    /// Send `fallbacks: "default"` with the server-side fallback beta.
    let refusalFallback: Bool
    let maxTokens: Int
    let timeout: TimeInterval

    var detailItems: [String] {
        var items = ["model \(model)"]
        if let effort {
            items.append("effort \(effort)")
        }
        if promptCache != .off {
            items.append("cache \(promptCache.rawValue)")
        }
        if refusalFallback {
            items.append("refusal fallback")
        }
        return items
    }
}

/// `cache_control` on the system prompt. Prompts shorter than the model's
/// minimum (512 to 4,096 tokens) are not cached and cost nothing extra.
enum ClaudePromptCache: String, CaseIterable, Sendable {
    case off
    case fiveMinutes = "5m"
    case oneHour = "1h"

    /// The `cache_control` object, or nil when caching is off.
    var cacheControl: [String: String]? {
        switch self {
        case .off: nil
        case .fiveMinutes: ["type": "ephemeral"]
        case .oneHour: ["type": "ephemeral", "ttl": "1h"]
        }
    }
}

/// Token usage of an answered request, shown in the settings view.
struct ClaudeRequestSummary: Sendable, Equatable {
    let date: Date
    /// The model that answered.
    let model: String
    /// The model whose refusal handed the request to `model`, if any.
    let declinedModel: String?
    let inputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreationInputTokens: Int
    let outputTokens: Int
}

/// What a model accepts for reasoning: from the Models API when cached,
/// otherwise from `ClaudePlugin.staticCapabilities(for:)`.
struct ClaudeModelCapabilities: Equatable, Sendable {
    /// Supported `output_config.effort` values, lowest first.
    let effortLevels: [String]
    /// Whether `thinking: {type: "adaptive"}` is accepted.
    let supportsAdaptiveThinking: Bool
    /// The level the API applies when `effort` is omitted.
    let defaultEffort: String?
    let maxOutputTokens: Int?
}

/// Why the model list could not be refreshed (or the key not verified).
struct ClaudeModelRefreshFailure: Sendable, Equatable {
    /// HTTP status, or nil when no HTTP response arrived.
    let statusCode: Int?
    let message: String

    var isAuthenticationFailure: Bool { statusCode == 401 }
}

/// Anthropic's error body: `{"type":"error","error":{"type","message","details"},"request_id"}`.
private struct ClaudeAPIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        struct Details: Decodable {
            let errorCode: String?

            enum CodingKeys: String, CodingKey {
                case errorCode = "error_code"
            }
        }

        let type: String?
        let message: String?
        let details: Details?
    }

    let error: APIError?
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case error
        case requestId = "request_id"
    }
}

// MARK: - Messages API Decoding

/// The parts of a Messages API response the plugin reads. Models that think
/// (adaptive thinking is on by default from Claude Sonnet 5 / Opus 5 on) put
/// `thinking` blocks ahead of the answer, so the reply is every `text` block,
/// never just the first content block.
struct ClaudeMessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        struct ModelReference: Decodable {
            let model: String?
        }

        let type: String
        let text: String?
        /// On `fallback` blocks: the model that declined and the one that took over.
        let from: ModelReference?
        let to: ModelReference?

        enum CodingKeys: String, CodingKey {
            case type, text, from, to
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            text = try? container.decodeIfPresent(String.self, forKey: .text)
            from = try? container.decodeIfPresent(ModelReference.self, forKey: .from)
            to = try? container.decodeIfPresent(ModelReference.self, forKey: .to)
        }
    }

    /// Populated when `stop_reason` is `refusal`.
    struct StopDetails: Decodable {
        let category: String?
        let explanation: String?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    /// The model that produced the reply.
    let model: String?
    let content: [ContentBlock]
    let stopReason: String?
    let stopDetails: StopDetails?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case model
        case content
        case stopReason = "stop_reason"
        case stopDetails = "stop_details"
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        content = try container.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
        // Optional extras must never turn a usable reply into a parse failure.
        stopDetails = try? container.decodeIfPresent(StopDetails.self, forKey: .stopDetails)
        usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
    }

    /// Models that declined before a server-side fallback answered.
    var declinedModels: [String] {
        content.filter { $0.type == "fallback" }.compactMap { $0.from?.model }
    }

    /// The joined text blocks; `thinking`, `redacted_thinking` and `fallback`
    /// blocks are skipped.
    var replyText: String {
        content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models API Decoding

private struct ClaudeModelsResponse: Decodable {
    let data: [ClaudeAPIModel]
    let hasMore: Bool?
    let lastId: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastId = "last_id"
    }
}

private struct ClaudeAPIModel: Decodable {
    let id: String
    let displayName: String?
    let createdAt: String?
    let maxTokens: Int?
    let capabilities: ClaudeAPICapabilities?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
        case maxTokens = "max_tokens"
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        // Capability data only refines reasoning settings; an unexpected shape
        // must never fail the whole model list.
        maxTokens = try? container.decodeIfPresent(Int.self, forKey: .maxTokens)
        capabilities = try? container.decodeIfPresent(ClaudeAPICapabilities.self, forKey: .capabilities)
    }
}

/// The parts of `capabilities` the plugin reads; every leaf is `{"supported": Bool}`.
private struct ClaudeAPICapabilities: Decodable {
    struct Support: Decodable {
        let supported: Bool?
    }

    struct Thinking: Decodable {
        struct Types: Decodable {
            let adaptive: Support?
        }

        let types: Types?
    }

    struct Effort: Decodable {
        let supported: Bool?
        let low: Support?
        let medium: Support?
        let high: Support?
        let xhigh: Support?
        let max: Support?

        /// Supported levels, lowest first; empty when effort isn't supported.
        var supportedLevels: [String] {
            guard supported != false else { return [] }
            return [("low", low), ("medium", medium), ("high", high), ("xhigh", xhigh), ("max", max)]
                .filter { $0.1?.supported == true }
                .map(\.0)
        }
    }

    let thinking: Thinking?
    let effort: Effort?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thinking = try? container.decodeIfPresent(Thinking.self, forKey: .thinking)
        effort = try? container.decodeIfPresent(Effort.self, forKey: .effort)
    }

    enum CodingKeys: String, CodingKey {
        case thinking
        case effort
    }
}

// MARK: - Cached Model Types

struct ClaudeFetchedModel: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    /// Epoch seconds parsed from the API `created_at`; used for newest-first sort.
    let createdAt: Double
    /// The Models API capability fields below are nil in caches written by
    /// plugin 1.1, where the static capability table applies instead.
    /// API `max_tokens`: the model's output limit.
    var maxOutputTokens: Int? = nil
    /// `capabilities.thinking.types.adaptive.supported`
    var supportsAdaptiveThinking: Bool? = nil
    /// Levels with `capabilities.effort.<level>.supported`, lowest first.
    var effortLevels: [String]? = nil
}

struct ClaudeModelCache: Codable, Sendable {
    let models: [ClaudeFetchedModel]
    let fetchedAt: Date
}

// MARK: - Settings View

private struct ClaudeSettingsView: View {
    let plugin: ClaudePlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var validationFailure: ClaudeModelRefreshFailure?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var isRefreshing = false
    @State private var lastUpdated: Date?
    @State private var refreshErrorMessage: String?
    @State private var reasoningEffortId = ""
    @State private var promptCache: ClaudePromptCache = .fiveMinutes
    @State private var refusalFallbackEnabled = true
    @State private var isAdvancedExpanded = false
    private let bundle = Bundle(for: ClaudePlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("API Key", bundle: bundle))
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))

                    if plugin.isAvailable {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            validationFailure = nil
                            refreshErrorMessage = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Remove API key", bundle: bundle))
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(Text("Save API key", bundle: bundle))
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                            .accessibilityHidden(true)
                        Text(validationLabel(isValid: result))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                    if !result, let validationFailure {
                        Text(validationFailure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if plugin.isAvailable {
                Divider()

                // LLM Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LLM Model", bundle: bundle)
                            .font(.headline)

                        Spacer()

                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        }

                        Button {
                            refresh()
                        } label: {
                            Label(String(localized: "Refresh models", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshing)
                    }

                    Picker(String(localized: "Model", bundle: bundle), selection: $selectedModel) {
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectLLMModel(selectedModel)
                    }

                    if let lastUpdated {
                        Text("Last updated \(lastUpdated.formatted(date: .abbreviated, time: .shortened))", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Using default models. Refresh to fetch the full list.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let refreshErrorMessage {
                        Label(refreshErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                DisclosureGroup(
                    String(localized: "Advanced", bundle: bundle),
                    isExpanded: $isAdvancedExpanded
                ) {
                    advancedSettings
                        .padding(.top, 8)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature", bundle: bundle)
                        .font(.headline)

                    Picker(String(localized: "Temperature Mode", bundle: bundle), selection: $llmTemperatureMode) {
                        Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
                    }
                    .onChange(of: llmTemperatureMode) {
                        plugin.setLLMTemperatureMode(llmTemperatureMode)
                    }

                    if llmTemperatureMode == .custom {
                        HStack {
                            Text("Temperature", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                            .onChange(of: llmTemperatureValue) {
                                plugin.setLLMTemperatureValue(llmTemperatureValue)
                            }
                            .accessibilityLabel(Text("Temperature", bundle: bundle))

                        if plugin.ignoresCustomTemperature(for: selectedModelId, reasoningEffortId: reasoningEffortId) {
                            Text("Custom temperature is ignored for this model or while a reasoning effort is set.", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin.apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            reasoningEffortId = plugin.reasoningEffortId
            promptCache = plugin.promptCache
            refusalFallbackEnabled = plugin.refusalFallbackEnabled
            lastUpdated = plugin.cacheLastUpdated
            // Serve the cache immediately; refresh in the background if stale.
            if plugin.isAvailable,
               !plugin.isModelCacheFresh,
               ClaudeAutomaticRefreshPolicy.allowsRefreshOnAppear() {
                refresh()
            }
        }
    }

    private var selectedModelId: String? {
        selectedModel.isEmpty ? nil : selectedModel
    }

    private var supportedEfforts: [PluginLLMEffortInfo] {
        plugin.supportedEfforts(for: selectedModelId)
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            reasoningEffortSettings
            promptCacheSettings
            refusalFallbackSettings
            lastRequestSummary
        }
    }

    private var promptCacheSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "Prompt Caching", bundle: bundle), selection: $promptCache) {
                Text("Off", bundle: bundle).tag(ClaudePromptCache.off)
                Text("5 minutes", bundle: bundle).tag(ClaudePromptCache.fiveMinutes)
                Text("1 hour", bundle: bundle).tag(ClaudePromptCache.oneHour)
            }
            .pickerStyle(.menu)
            .onChange(of: promptCache) {
                plugin.setPromptCache(promptCache)
            }

            Text("Reuses the system prompt across requests within this time, so repeated requests cost less. Only prompts of at least 512 to 4,096 tokens (depending on the model) are cached. Writing the cache costs 1.25× (5 minutes) or 2× (1 hour), reading it a tenth or less. Changing the model or reasoning effort starts a new cache.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refusalFallbackSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(String(localized: "Retry declined requests on a fallback model", bundle: bundle), isOn: $refusalFallbackEnabled)
                .onChange(of: refusalFallbackEnabled) {
                    plugin.setRefusalFallbackEnabled(refusalFallbackEnabled)
                }

            Text("Applies to Claude Opus 5.5, Opus 5, Sonnet 5.5 and Fable 5.1. If Anthropic's safety checks decline a request, a fallback model answers it in the same call, billed at that model's rates.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Refreshes while visible so a dictation made with the settings open shows up.
    private var lastRequestSummary: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            if let summary = plugin.lastRequestSummary {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Request", bundle: bundle)
                        .font(.caption.weight(.semibold))
                    Text(verbatim: "\(summary.date.formatted(date: .omitted, time: .shortened)) · \(answeredBy(summary))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Cache: \(summary.cacheReadInputTokens) read, \(summary.cacheCreationInputTokens) written · Input: \(summary.inputTokens) · Output: \(summary.outputTokens) tokens", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var reasoningEffortSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            if supportedEfforts.isEmpty {
                Text("Reasoning Effort", bundle: bundle)
                Text("The selected model doesn't support reasoning effort.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // A saved effort this model doesn't offer shows as the model
                // default (which requests use) without discarding the choice.
                Picker(
                    String(localized: "Reasoning Effort", bundle: bundle),
                    selection: Binding(
                        get: { supportedEfforts.contains { $0.id == reasoningEffortId } ? reasoningEffortId : "" },
                        set: { reasoningEffortId = $0 }
                    )
                ) {
                    Text(modelDefaultEffortLabel).tag("")
                    ForEach(supportedEfforts, id: \.id) { effort in
                        Text(effort.displayName).tag(effort.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: reasoningEffortId) {
                    plugin.setReasoningEffort(reasoningEffortId)
                }

                Text("Controls how much thinking time the model spends before answering.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Applies when a workflow leaves effort on Provider Default. Higher levels are slower and use more output tokens.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !reasoningEffortId.isEmpty,
                   !supportedEfforts.contains(where: { $0.id == reasoningEffortId }) {
                    Text("\(ClaudePlugin.effortDisplayName(reasoningEffortId)) isn't available for this model, so requests use the model default.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func answeredBy(_ summary: ClaudeRequestSummary) -> String {
        guard let declinedModel = summary.declinedModel else { return summary.model }
        return String(localized: "\(summary.model) (fallback after \(declinedModel) declined)", bundle: bundle)
    }

    private var modelDefaultEffortLabel: String {
        guard let level = plugin.modelDefaultEffortId(for: selectedModelId) else {
            return String(localized: "Model Default", bundle: bundle)
        }
        let levelName = ClaudePlugin.effortDisplayName(level)
        return String(localized: "Model Default (\(levelName))", bundle: bundle)
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        validationFailure = nil
        refreshErrorMessage = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                validationFailure = isValid ? nil : plugin.lastModelRefreshFailure
                if isValid {
                    lastUpdated = plugin.cacheLastUpdated
                    selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
                }
            }
        }
    }

    /// Only a 401 proves the key is wrong; other failures (offline, outage)
    /// mean the key could not be checked.
    private func validationLabel(isValid: Bool) -> String {
        if isValid {
            return String(localized: "Valid API Key", bundle: bundle)
        }
        if let validationFailure, !validationFailure.isAuthenticationFailure {
            return String(localized: "Couldn't verify the API key", bundle: bundle)
        }
        return String(localized: "Invalid API Key", bundle: bundle)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshErrorMessage = nil
        Task {
            let ok = await plugin.refreshModels()
            await MainActor.run {
                isRefreshing = false
                if ok {
                    lastUpdated = plugin.cacheLastUpdated
                    // Keep the current selection working even if the fetched list
                    // dropped it; supportedModels appends it back.
                    selectedModel = plugin.selectedLLMModelId
                        ?? plugin.supportedModels.first?.id
                        ?? selectedModel
                } else {
                    refreshErrorMessage = plugin.lastModelRefreshFailure?.message ?? String(
                        localized: "Unable to refresh models. Check your connection and try again.",
                        bundle: bundle
                    )
                }
            }
        }
    }
}
