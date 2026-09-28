import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ClaudePlugin)
final class ClaudePlugin: NSObject, LLMProviderPlugin, LLMTemperatureControllableProvider, LLMModelSelectable, @unchecked Sendable {
    static let pluginId = "com.typewhisper.claude"
    static let pluginName = "Claude"

    private static let modelsEndpoint = "https://api.anthropic.com/v1/models"
    private static let messagesEndpoint = "https://api.anthropic.com/v1/messages"
    private static let anthropicVersion = "2023-06-01"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let cachedModelsKey = "fetchedLLMModels.v1"
    /// Serve a cached model list without re-fetching for 24 hours.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    /// Safety bound on pagination so a misbehaving `has_more` never loops forever.
    private static let maxModelPages = 20

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
        var modelCache: ClaudeModelCache?
        var refreshGeneration: UInt64 = 0
        var inFlightModelRefresh: InFlightModelRefresh?
    }

    private struct ProcessingSnapshot {
        let apiKey: String?
        let selectedModelId: String?
        let defaultModelId: String
        let temperatureDirective: PluginLLMTemperatureDirective
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

        let previousTask = state.withLock { state -> Task<Bool, Never>? in
            let previousTask = state.inFlightModelRefresh?.task
            state.isActive = true
            state.host = host
            state.apiKey = apiKey
            state.selectedLLMModelId = selectedLLMModelId
            state.llmTemperatureModeRaw = llmTemperatureModeRaw
            state.llmTemperatureValue = llmTemperatureValue
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
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
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
                )
            )
        }
        guard let apiKey = snapshot.apiKey, !apiKey.isEmpty else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? snapshot.selectedModelId ?? snapshot.defaultModelId
        let resolvedTemperature = snapshot.temperatureDirective.resolvedTemperature(applying: temperatureDirective)
        return try await callMessagesAPI(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            temperature: resolvedTemperature
        )
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
            return state.host
        }
        guard let host else { return false }

        if let data = try? JSONEncoder().encode(cache) {
            host.setUserDefault(data, forKey: Self.cachedModelsKey)
        }
        host.notifyCapabilitiesChanged()
        return true
    }

    /// Fetches the full model list (following pagination), returning nil on any
    /// network/HTTP failure so callers can keep serving the existing cache.
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

            do {
                let (data, response) = try await PluginHTTPClient.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return nil }
                let page = try Self.decodeModelsPage(from: data)
                collected.append(contentsOf: page.models)
                guard page.hasMore else {
                    return Self.sortedNewestFirst(collected)
                }

                guard let lastId = page.lastId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !lastId.isEmpty,
                      seenCursors.insert(lastId).inserted else { return nil }
                afterId = lastId
            } catch {
                return nil
            }
        }

        // Reaching the safety bound with `has_more` still set means the response
        // is incomplete. Never replace a known-good cache with a partial list.
        return nil
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
                createdAt: parseTimestamp($0.createdAt)
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

    // MARK: - Anthropic Messages API

    private func callMessagesAPI(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?
    ) async throws -> String {
        guard let url = URL(string: Self.messagesEndpoint) else {
            throw PluginChatError.apiError("Invalid URL")
        }

        var requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userText]
            ]
        ]
        // Only send the temperature override to models that accept it; newer
        // families 400 on any sampling parameter.
        if let temperature, !Self.modelRejectsSamplingParams(model) {
            requestBody["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            var displayMessage = "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                displayMessage = message
            }
            throw PluginChatError.apiError(displayMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

// MARK: - Cached Model Types

struct ClaudeFetchedModel: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    /// Epoch seconds parsed from the API `created_at`; used for newest-first sort.
    let createdAt: Double
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
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var isRefreshing = false
    @State private var lastUpdated: Date?
    @State private var refreshErrorMessage: String?
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
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isAvailable {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            refreshErrorMessage = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
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

                    Picker("Model", selection: $selectedModel) {
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
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature", bundle: bundle)
                        .font(.headline)

                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
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
            lastUpdated = plugin.cacheLastUpdated
            // Serve the cache immediately; refresh in the background if stale.
            if plugin.isAvailable, !plugin.isModelCacheFresh {
                refresh()
            }
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        refreshErrorMessage = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                if isValid {
                    lastUpdated = plugin.cacheLastUpdated
                    selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
                }
            }
        }
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
                    refreshErrorMessage = String(
                        localized: "Unable to refresh models. Check your connection and try again.",
                        bundle: bundle
                    )
                }
            }
        }
    }
}
