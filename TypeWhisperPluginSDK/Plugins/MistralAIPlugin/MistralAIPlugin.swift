import Foundation
import os
import TypeWhisperPluginSDK
import SwiftUI

// MARK: - Transcription Mode

/// How dictations are transcribed, with Mistral's list prices (November 2026).
enum MistralTranscriptionMode: String, CaseIterable, Sendable {
    /// Dictations with a live preview stream to Voxtral Realtime ($0.48/h of audio)
    /// for the preview, and the selected transcription model writes the final text
    /// ($0.21/h or $0.24/h more). Recordings and files use only that model.
    case live
    /// Every recording goes to the selected transcription model after it stops
    /// ($0.21/h with Mini, $0.24/h with Small); no live preview from Mistral.
    case batch
}

// MARK: - Plugin Entry Point

@objc(MistralAIPlugin)
public final class MistralAIPlugin: NSObject,
    LLMProviderPlugin,
    LLMProviderIdentityProviding,
    LLMModelSelectable,
    LLMTemperatureAndEffortControllableProvider,
    StructuredTranscriptionEnginePlugin,
    DictionaryTermsCapabilityProviding,
    DictionaryTermsBudgetProviding,
    LiveTranscriptionModelSupportProviding,
    LiveTranscriptionProgressModeProviding,
    TranscriptPreviewFallbackPolicyProviding,
    @unchecked Sendable
{
    public static var pluginId: String { "com.minerale.mistralai" }
    public static var pluginName: String { "Mistral AI" }

    static let transcriptionModeKey = "transcriptionMode"
    static let speakerDiarizationEnabledKey = "speakerDiarizationEnabled"
    static let reasoningEffortsKey = "reasoningEfforts"
    static let modelCatalogKey = "modelCatalog"
    static let modelCatalogDateKey = "modelCatalogDate"
    private static let modelCatalogLifetime: TimeInterval = 24 * 60 * 60

    /// Mistral Small 4. Used when the user has not picked an LLM.
    static let defaultLLMModelId = MistralModelCatalog.defaultLLMModelId
    /// Mistral Large 4.
    static let largeLLMModelId = MistralModelCatalog.largeLLMModelId
    /// Voxtral Mini Transcribe 3. Used when the user has not picked a model.
    static let defaultTranscriptionModelId = MistralModelCatalog.defaultTranscriptionModelId

    typealias CatalogFetcher = @Sendable (_ apiKey: String) async throws -> MistralModelCatalog
    typealias RealtimeSocketFactory = @Sendable (URLRequest) -> any MistralRealtimeSocket

    private let lock = NSRecursiveLock()
    private var _host: HostServices?
    private var _selectedModelId: String?
    private var _selectedLLMModelId: String?
    private var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    private var _llmTemperatureValue: Double = 0.3
    private var _catalog = MistralModelCatalog.builtIn
    private var _hasFetchedCatalog = false
    private var _transcriptionMode = MistralTranscriptionMode.live
    private var _speakerDiarizationEnabled = false
    private var _reasoningEfforts: [String: String] = [:]
    private var catalogRefreshTask: Task<Void, Never>?
    private var catalogRefreshGeneration = 0

    private let catalogFetcher: CatalogFetcher
    private let realtimeSocketFactory: RealtimeSocketFactory
    private let logger = Logger(subsystem: "com.minerale.mistralai", category: "Plugin")

    private var host: HostServices? {
        get { lock.withLock { _host } }
        set { lock.withLock { _host = newValue } }
    }

    public var apiKey: String {
        host?.loadSecret(key: "api-key") ?? ""
    }

    public override init() {
        catalogFetcher = { apiKey in try await MistralAPIClient(apiKey: apiKey).fetchModelCatalog() }
        realtimeSocketFactory = { request in URLSessionMistralRealtimeSocket(request: request) }
        super.init()
    }

    init(
        catalogFetcher: @escaping CatalogFetcher,
        realtimeSocketFactory: @escaping RealtimeSocketFactory = { URLSessionMistralRealtimeSocket(request: $0) }
    ) {
        self.catalogFetcher = catalogFetcher
        self.realtimeSocketFactory = realtimeSocketFactory
        super.init()
    }

    public func activate(host: HostServices) {
        cancelCatalogRefresh()
        var persistedTranscriptionModel: String?
        var shouldRewriteTranscriptionModel = false
        var persistedLLMModel: String?
        var shouldRewriteLLMModel = false
        lock.withLock {
            self._host = host
            if let data = host.userDefault(forKey: Self.modelCatalogKey) as? Data,
               let catalog = try? JSONDecoder().decode(MistralModelCatalog.self, from: data) {
                _catalog = catalog
                _hasFetchedCatalog = true
            }
            let storedLLMModel = host.userDefault(forKey: "selectedLLMModel") as? String
            let resolvedLLMModel = storedLLMModel.flatMap(_catalog.resolvedLLMModelId)
            _selectedLLMModelId = resolvedLLMModel
            let storedTranscriptionModel = host.userDefault(forKey: "selectedModel") as? String
            let resolvedTranscriptionModel = storedTranscriptionModel.flatMap(_catalog.resolvedTranscriptionModelId)
            _selectedModelId = resolvedTranscriptionModel
            _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
                ?? PluginLLMTemperatureMode.providerDefault.rawValue
            _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double ?? 0.3
            _transcriptionMode = (host.userDefault(forKey: Self.transcriptionModeKey) as? String)
                .flatMap(MistralTranscriptionMode.init(rawValue:)) ?? .live
            _speakerDiarizationEnabled = host.userDefault(forKey: Self.speakerDiarizationEnabledKey) as? Bool ?? false
            _reasoningEfforts = host.userDefault(forKey: Self.reasoningEffortsKey) as? [String: String] ?? [:]
            persistedLLMModel = resolvedLLMModel
            shouldRewriteLLMModel = Self.shouldRewriteStoredModel(storedLLMModel, resolved: resolvedLLMModel)
            persistedTranscriptionModel = resolvedTranscriptionModel
            shouldRewriteTranscriptionModel = Self.shouldRewriteStoredModel(
                storedTranscriptionModel,
                resolved: resolvedTranscriptionModel
            )
        }
        if shouldRewriteLLMModel {
            Self.storeModel(persistedLLMModel, forKey: "selectedLLMModel", host: host)
        }
        if shouldRewriteTranscriptionModel {
            Self.storeModel(persistedTranscriptionModel, forKey: "selectedModel", host: host)
        }
        refreshStaleCatalogIfNeeded()
    }

    public func deactivate() {
        cancelCatalogRefresh()
        lock.withLock {
            self._host = nil
        }
    }

    public var settingsView: AnyView? {
        AnyView(MistralSettingsView(plugin: self))
    }

    public func setApiKey(_ key: String) {
        guard let host = host else {
            logger.error("Failed to save API key: host services not active")
            return
        }
        do {
            try host.storeSecret(key: "api-key", value: key)
            host.notifyCapabilitiesChanged()
        } catch {
            logger.error("Failed to store API key: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func clearApiKey() {
        guard let host = host else { return }
        do {
            try host.storeSecret(key: "api-key", value: "")
            host.notifyCapabilitiesChanged()
        } catch {
            logger.error("Failed to delete API key: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Model Catalog

    var catalog: MistralModelCatalog { lock.withLock { _catalog } }
    var hasFetchedCatalog: Bool { lock.withLock { _hasFetchedCatalog } }
    /// The background refresh started on activation, if one is running.
    var pendingCatalogRefresh: Task<Void, Never>? { lock.withLock { catalogRefreshTask } }

    /// Loads the account's model list with `apiKey`, rather than the key saved when
    /// the request starts. Pass the same key to `applyFetchedCatalog`.
    func fetchCatalog(for apiKey: String) async throws -> MistralModelCatalog {
        try await catalogFetcher(apiKey)
    }

    /// Caches a fetched list only while the plugin is active and the key it was
    /// fetched with is still the saved one, so a slow response for a replaced or
    /// removed key cannot overwrite the list.
    @discardableResult
    func applyFetchedCatalog(_ catalog: MistralModelCatalog, fetchedWith apiKey: String) -> Bool {
        guard let host, !apiKey.isEmpty, self.apiKey == apiKey else { return false }
        lock.withLock {
            _catalog = catalog
            _hasFetchedCatalog = true
        }
        if let data = try? JSONEncoder().encode(catalog) {
            host.setUserDefault(data, forKey: Self.modelCatalogKey)
        }
        host.setUserDefault(Date(), forKey: Self.modelCatalogDateKey)
        host.notifyCapabilitiesChanged()
        return true
    }

    /// A cached list can still offer models Mistral retired since. Refresh it in the
    /// background once it is a day old. Without a cached list the built-in one stays
    /// until the settings load the account's list.
    private func refreshStaleCatalogIfNeeded() {
        guard let host, hasFetchedCatalog else { return }
        let key = apiKey
        guard !key.isEmpty else { return }
        if let fetchedAt = host.userDefault(forKey: Self.modelCatalogDateKey) as? Date {
            let age = Date().timeIntervalSince(fetchedAt)
            guard age < 0 || age >= Self.modelCatalogLifetime else { return }
        }

        let fetcher = catalogFetcher
        let generation = lock.withLock { catalogRefreshGeneration }
        let task = Task { [weak self] in
            guard let catalog = try? await fetcher(key), !Task.isCancelled, let self else { return }
            // Drop a result that arrives after deactivation or reactivation.
            guard self.lock.withLock({ self.catalogRefreshGeneration == generation }) else { return }
            self.applyFetchedCatalog(catalog, fetchedWith: key)
        }
        lock.withLock { catalogRefreshTask = task }
    }

    private func cancelCatalogRefresh() {
        lock.withLock {
            catalogRefreshGeneration += 1
            catalogRefreshTask?.cancel()
            catalogRefreshTask = nil
        }
    }

    // MARK: - LLMProviderPlugin

    public var providerName: String { "Mistral AI" }

    public var isAvailable: Bool { !apiKey.isEmpty }

    public var supportedModels: [PluginModelInfo] {
        guard !apiKey.isEmpty else { return [] }
        return catalog.llmModels.map(\.modelInfo)
    }

    /// The model a request without one uses: the chosen model, otherwise Mistral Small 4.
    private func llmModelId(for model: String?) -> String {
        let catalog = self.catalog
        let selected = lock.withLock { _selectedLLMModelId }
        return model.flatMap(catalog.resolvedLLMModelId)
            ?? selected.flatMap(catalog.resolvedLLMModelId)
            ?? Self.defaultLLMModelId
    }

    public func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting,
            effort: nil
        )
    }

    public func process(
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

    public func process(systemPrompt: String, userText: String, model: String?, effort: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting,
            effort: effort
        )
    }

    public func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective,
        effort: String?
    ) async throws -> String {
        let modelId = llmModelId(for: model)
        let temperature = providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective)
        let client = MistralAPIClient(apiKey: apiKey)
        return try await client.processChat(
            systemPrompt: systemPrompt,
            userText: userText,
            model: modelId,
            temperature: temperature,
            reasoningEffort: requestReasoningEffort(effort, forModelId: modelId)
        )
    }

    // MARK: - Reasoning Effort

    public func supportedEfforts(for model: String?) -> [PluginLLMEffortInfo] {
        let bundle = Bundle(for: MistralAIPlugin.self)
        return MistralReasoningEffort.supportedEfforts(forModelId: llmModelId(for: model)).map { effort in
            PluginLLMEffortInfo(id: effort, displayName: Self.effortDisplayName(effort, bundle: bundle))
        }
    }

    /// The level a request without an explicit effort uses: the one picked in the
    /// plugin settings for that model, otherwise the fastest.
    public func defaultEffortId(for model: String?) -> String? {
        savedReasoningEffort(forModelId: llmModelId(for: model))
    }

    func savedReasoningEffort(forModelId modelId: String) -> String? {
        let supported = MistralReasoningEffort.supportedEfforts(forModelId: modelId)
        if let saved = lock.withLock({ _reasoningEfforts[modelId] }), supported.contains(saved) {
            return saved
        }
        return MistralReasoningEffort.defaultEffort(forModelId: modelId)
    }

    func setReasoningEffort(_ effort: String, forModelId modelId: String) {
        let efforts = lock.withLock {
            _reasoningEfforts[modelId] = effort
            return _reasoningEfforts
        }
        host?.setUserDefault(efforts, forKey: Self.reasoningEffortsKey)
    }

    /// The `reasoning_effort` a request sends, or nil to leave the field out. Small 4
    /// and Medium 3.5 answer without thinking when it is missing, as they do with
    /// `none`; Large 4 thinks at `high` unless asked for less.
    private func requestReasoningEffort(_ requested: String?, forModelId modelId: String) -> String? {
        let supported = MistralReasoningEffort.supportedEfforts(forModelId: modelId)
        guard !supported.isEmpty else { return nil }
        let effort = requested.flatMap { supported.contains($0) ? $0 : nil }
            ?? savedReasoningEffort(forModelId: modelId)
        return effort == "none" ? nil : effort
    }

    static func effortDisplayName(_ effort: String, bundle: Bundle) -> String {
        switch effort {
        case "none": String(localized: "Off", bundle: bundle)
        case "low": String(localized: "Low", bundle: bundle)
        case "medium": String(localized: "Medium", bundle: bundle)
        case "high": String(localized: "High", bundle: bundle)
        default: effort
        }
    }

    // MARK: - LLMTemperatureControllableProvider

    public var llmTemperatureMode: PluginLLMTemperatureMode {
        lock.withLock { PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault }
    }

    public var llmTemperatureValue: Double { lock.withLock { _llmTemperatureValue } }

    private var providerTemperatureDirective: PluginLLMTemperatureDirective {
        lock.withLock { PluginLLMTemperatureDirective(mode: PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault, value: _llmTemperatureValue) }
    }

    public func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        lock.withLock { _llmTemperatureModeRaw = mode.rawValue }
        host?.setUserDefault(mode.rawValue, forKey: "llmTemperatureMode")
    }

    public func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        lock.withLock { _llmTemperatureValue = clamped }
        host?.setUserDefault(clamped, forKey: "llmTemperatureValue")
    }

    // MARK: - LLMModelSelectable

    public var selectedLLMModelId: String? { lock.withLock { _selectedLLMModelId } }

    @objc public var preferredModelId: String? { lock.withLock { _selectedLLMModelId } }

    @objc public var defaultModelId: String? { Self.defaultLLMModelId }

    public func selectLLMModel(_ modelId: String) {
        let valueToSave = catalog.resolvedLLMModelId(modelId)
        lock.withLock {
            _selectedLLMModelId = valueToSave
        }
        if let host {
            Self.storeModel(valueToSave, forKey: "selectedLLMModel", host: host)
        }
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Identity & TranscriptionEnginePlugin

    public var providerId: String { "mistral" }
    public var providerDisplayName: String { "Mistral AI" }
    public var isConfigured: Bool { isAvailable }

    public var transcriptionModels: [PluginModelInfo] {
        guard !apiKey.isEmpty else { return [] }
        return catalog.transcriptionModels.map(\.modelInfo)
    }

    public var selectedModelId: String? { lock.withLock { _selectedModelId } }

    public func selectModel(_ modelId: String) {
        let valueToSave = catalog.resolvedTranscriptionModelId(modelId)
        let changed = lock.withLock {
            let changed = _selectedModelId != valueToSave
            _selectedModelId = valueToSave
            return changed
        }
        if let host {
            Self.storeModel(valueToSave, forKey: "selectedModel", host: host)
        }
        if changed {
            // Languages and dictionary support depend on the model.
            host?.notifyCapabilitiesChanged()
        }
    }

    /// The model file transcriptions use, and what the catalog knows about it. A
    /// model the list does not offer is sent as it is, with Transcribe 3's languages.
    private var transcriptionModelForRequests: (id: String, model: MistralTranscriptionModel) {
        let catalog = self.catalog
        let selected = lock.withLock { _selectedModelId }
        let id = selected ?? Self.defaultTranscriptionModelId
        let model = catalog.transcriptionModel(id)
            ?? catalog.transcriptionModel(Self.defaultTranscriptionModelId)
            ?? MistralModelCatalog.builtIn.transcriptionModels[0]
        return (catalog.transcriptionModel(id)?.id ?? id, model)
    }

    var transcriptionMode: MistralTranscriptionMode { lock.withLock { _transcriptionMode } }
    var isSpeakerDiarizationEnabled: Bool { lock.withLock { _speakerDiarizationEnabled } }

    func setTranscriptionMode(_ mode: MistralTranscriptionMode) {
        let changed = lock.withLock {
            guard _transcriptionMode != mode else { return false }
            _transcriptionMode = mode
            return true
        }
        guard changed else { return }
        host?.setUserDefault(mode.rawValue, forKey: Self.transcriptionModeKey)
        host?.notifyCapabilitiesChanged()
    }

    func setSpeakerDiarizationEnabled(_ enabled: Bool) {
        let changed = lock.withLock {
            guard _speakerDiarizationEnabled != enabled else { return false }
            _speakerDiarizationEnabled = enabled
            return true
        }
        guard changed else { return }
        host?.setUserDefault(enabled, forKey: Self.speakerDiarizationEnabledKey)
        host?.notifyCapabilitiesChanged()
    }

    public var supportsTranslation: Bool { false }

    /// Dictations stream through live sessions; finished audio always goes to the
    /// transcription model, which is faster than replaying it in real time.
    public var supportsStreaming: Bool { supportsLiveTranscriptionSession(forModelId: nil) }

    public var supportedLanguages: [String] {
        transcriptionModelForRequests.model.languages
    }

    public var dictionaryTermsSupport: DictionaryTermsSupport {
        transcriptionModelForRequests.model.supportsContextBias ? .supported : .unsupported
    }

    /// `context_bias` has no fixed number of entries, but shares the 65,536-token
    /// context with the audio, and a request over it fails with HTTP 400. Ten
    /// minutes of audio leave room for several thousand terms; this keeps a margin.
    public var dictionaryTermsBudget: DictionaryTermsBudget {
        DictionaryTermsBudget(maxTerms: 1_000, maxCharsPerTerm: 100)
    }

    func contextBias(fromPrompt prompt: String?) -> [String] {
        PluginDictionaryTerms.clippedTerms(
            from: PluginDictionaryTerms.terms(fromPrompt: prompt),
            budget: dictionaryTermsBudget
        )
    }

    /// The language as Mistral takes it, a two-letter code the model lists, or nil
    /// to let the model detect it.
    static func requestLanguage(_ language: String?, supported: [String]) -> String? {
        guard let code = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !code.isEmpty else {
            return nil
        }
        let base = String(code.split(separator: "-").first ?? Substring(code))
        return supported.contains(base) ? base : nil
    }

    // MARK: - Live Sessions

    /// Dictations stream to Voxtral Realtime in the Live mode. Speaker labels come
    /// only from the transcription model, so they turn live sessions off.
    public func supportsLiveTranscriptionSession(forModelId modelId: String?) -> Bool {
        lock.withLock {
            _transcriptionMode == .live && !_speakerDiarizationEnabled && !_catalog.realtimeModels.isEmpty
        }
    }

    /// The deltas so far make up the whole transcript.
    public var liveTranscriptionProgressMode: LiveTranscriptionProgressMode { .completeSnapshot }

    /// The After recording mode shows no preview, so it costs what its price says,
    /// instead of sending the last seconds again every few seconds. The rule depends
    /// on the mode alone because TypeWhisper reads it for the saved model when a
    /// profile's model override has no live session.
    public var allowsTranscriptPreviewFallback: Bool {
        transcriptionMode == .live && !supportsLiveTranscriptionSession(forModelId: nil)
    }

    public func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        let apiKey = self.apiKey
        guard !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        guard supportsLiveTranscriptionSession(forModelId: nil),
              let model = catalog.realtimeModels.first else {
            throw PluginTranscriptionError.apiError("Live transcription is off in the Mistral settings")
        }
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()

        var components = URLComponents(string: "wss://api.mistral.ai/v1/audio/transcriptions/realtime")
        components?.queryItems = [URLQueryItem(name: "model", value: model.id)]
        guard let url = components?.url else {
            throw PluginTranscriptionError.apiError("Invalid realtime URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // The transcription model writes the final text: it heard dictations more
        // accurately than Realtime 3 and was done sooner after the stop.
        let finalTranscriber: MistralLiveTranscriptionSession.FinalTranscriber = { [self] audio in
            try await self.transcribe(audio: audio, language: language, translate: false, prompt: prompt)
        }
        return try await MistralLiveTranscriptionSession.connect(
            socket: realtimeSocketFactory(request),
            language: Self.requestLanguage(language, supported: model.languages),
            contextBias: model.supportsContextBias ? contextBias(fromPrompt: prompt) : [],
            finalTranscriber: finalTranscriber,
            onProgress: onProgress
        )
    }

    // MARK: - Transcription

    public func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        Self.legacyResult(from: try await transcribeStructured(
            audio: audio,
            language: language,
            translate: translate,
            prompt: prompt
        ))
    }

    /// Recordings, files and dictations without a live session: the selected model
    /// on `/v1/audio/transcriptions`, in ten-minute chunks, with dictionary terms as
    /// `context_bias` and speaker labels when they are on.
    public func transcribeStructured(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
        let apiKey = self.apiKey
        guard !apiKey.isEmpty else {
            throw PluginTranscriptionError.notConfigured
        }
        let (modelId, model) = transcriptionModelForRequests
        let request = MistralAPIClient.TranscriptionRequest(
            model: modelId,
            language: Self.requestLanguage(language, supported: model.languages),
            contextBias: model.supportsContextBias ? contextBias(fromPrompt: prompt) : [],
            diarize: isSpeakerDiarizationEnabled && model.supportsDiarization
        )
        let client = MistralAPIClient(apiKey: apiKey)
        return try await PluginAudioChunking.transcribeStructured(audio) { chunk in
            try await client.transcribe(audio: chunk, request: request)
        }
    }

    static func legacyResult(from result: PluginStructuredTranscriptionResult) -> PluginTranscriptionResult {
        PluginTranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            segments: result.segments.map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
        )
    }

    // MARK: - Stored Selections

    private static func shouldRewriteStoredModel(_ stored: String?, resolved: String?) -> Bool {
        guard let stored else { return false }
        if let resolved {
            return stored != resolved
        }
        return true
    }

    private static func storeModel(_ modelId: String?, forKey key: String, host: HostServices) {
        host.setUserDefault(modelId, forKey: key)
    }
}

// MARK: - API Client

enum MistralAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .invalidResponse: return "Invalid API response."
        case .apiError(let message): return "API Error: \(message)"
        }
    }
}

struct MistralAPIClient {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Chat Completions (LLM)

    func processChat(
        systemPrompt: String,
        userText: String,
        model: String,
        temperature: Double? = nil,
        reasoningEffort: String? = nil
    ) async throws -> String {
        guard let url = URL(string: "https://api.mistral.ai/v1/chat/completions") else {
            throw MistralAPIError.invalidURL
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]
        if let temperature {
            body["temperature"] = temperature
        }
        if let reasoningEffort {
            body["reasoning_effort"] = reasoningEffort
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            // Reported before parsing: an unreadable reply still used the tokens.
            PluginLLMUsageReporting.report(.openAICompatible(from: data))
            return try parseChatResponse(data)
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimitOrQuota(from: data)
        default:
            throw MistralAPIError.apiError(Self.errorMessage(from: data, response: httpResponse))
        }
    }

    private func parseChatResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = chatContentText(from: message["content"]) else {
            throw MistralAPIError.apiError("Failed to parse response text")
        }
        return content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    /// Small and Ministral return `content` as a string. Large 4 returns a list
    /// of chunks, `thinking` then one or more `text` chunks, including when
    /// `reasoning_effort` is `low`. The reply is those text chunks joined.
    private func chatContentText(from content: Any?) -> String? {
        if let text = content as? String {
            return text
        }
        guard let chunks = content as? [[String: Any]] else { return nil }
        let texts = chunks.compactMap { chunk -> String? in
            guard chunk["type"] as? String == "text" else { return nil }
            return chunk["text"] as? String
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined()
    }

    // MARK: - Transcriptions (STT)

    struct TranscriptionRequest: Equatable, Sendable {
        let model: String
        let language: String?
        let contextBias: [String]
        let diarize: Bool
    }

    func transcribe(audio: AudioData, request transcription: TranscriptionRequest) async throws -> PluginStructuredTranscriptionResult {
        guard let url = URL(string: "https://api.mistral.ai/v1/audio/transcriptions") else {
            throw MistralAPIError.invalidURL
        }

        func makeRequest(uploadFile: PluginAudioUploadFile) -> URLRequest {
            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 120

            var body = Data()
            func appendField(_ name: String, _ value: String) {
                body.append(Data("--\(boundary)\r\n".utf8))
                body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                body.append(Data("\(value)\r\n".utf8))
            }

            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFile.filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(uploadFile.contentType)\r\n\r\n".utf8))
            body.append(uploadFile.data)
            body.append(Data("\r\n".utf8))

            appendField("model", transcription.model)
            if let language = transcription.language {
                appendField("language", language)
            } else {
                // Transcribe 3 leaves `language` null unless asked. Request it
                // only when nothing is pinned: sending `return_language` with a
                // language is a 422, "Cannot do language prediction if language
                // is already set". A pinned language stays the fallback below
                // when the response omits one.
                appendField("return_language", "true")
            }
            // One field per term; an entry may hold several words.
            for term in transcription.contextBias {
                appendField("context_bias", term)
            }
            if transcription.diarize {
                appendField("timestamp_granularities", "segment")
                appendField("diarize", "true")
            }

            body.append(Data("--\(boundary)--\r\n".utf8))
            request.httpBody = body
            return request
        }

        let preferredUpload = (try? PluginAudioUploadEncoder.compressedM4AUpload(from: audio))
            ?? PluginAudioUploadEncoder.wavUpload(from: audio)
        var (data, response) = try await PluginHTTPClient.data(for: makeRequest(uploadFile: preferredUpload))

        guard var httpResponse = response as? HTTPURLResponse else {
            throw MistralAPIError.invalidResponse
        }

        if preferredUpload.format != "wav",
           PluginAudioUploadEncoder.shouldRetryWithWavUpload(
            statusCode: httpResponse.statusCode,
            responseData: data
           ) {
            (data, response) = try await PluginHTTPClient.data(
                for: makeRequest(uploadFile: PluginAudioUploadEncoder.wavUpload(from: audio))
            )
            guard let retryResponse = response as? HTTPURLResponse else {
                throw MistralAPIError.invalidResponse
            }
            httpResponse = retryResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimitOrQuota(from: data)
        default:
            throw MistralAPIError.apiError(Self.errorMessage(from: data, response: httpResponse))
        }

        if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
            from: data,
            response: httpResponse
        ) {
            throw MistralAPIError.apiError(
                "Failed to parse transcription response: \(htmlPageSummary)"
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw MistralAPIError.apiError("Failed to parse transcription response")
        }
        // Prefer the language reported in the response. Transcribe 3 fills it
        // only when `return_language` is set, which is the unpinned request.
        // A pinned language stays the fallback.
        let detectedLanguage = (json["language"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? transcription.language
            ?? "en"
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard transcription.diarize else {
            return PluginStructuredTranscriptionResult(text: trimmedText, detectedLanguage: detectedLanguage)
        }
        let segments = (json["segments"] as? [[String: Any]] ?? []).compactMap(Self.speakerSegment)
        guard segments.contains(where: { $0.speakerLabel != nil }) else {
            return PluginStructuredTranscriptionResult(text: trimmedText, detectedLanguage: detectedLanguage, segments: segments)
        }
        return PluginStructuredTranscriptionResult(
            text: Self.labelledText(segments),
            detectedLanguage: detectedLanguage,
            segments: segments
        )
    }

    /// One line per change of speaker. Mistral ends a segment after each sentence,
    /// so a speaker's sentences in a row share one label.
    static func labelledText(_ segments: [PluginStructuredTranscriptionSegment]) -> String {
        var lines: [(speaker: String?, text: String)] = []
        for segment in segments {
            if let last = lines.last, last.speaker == segment.speakerLabel {
                lines[lines.count - 1].text += " " + segment.text
            } else {
                lines.append((segment.speakerLabel, segment.text))
            }
        }
        return lines.map { line in
            line.speaker.map { "\($0): \(line.text)" } ?? line.text
        }.joined(separator: "\n")
    }

    private static func speakerSegment(_ segment: [String: Any]) -> PluginStructuredTranscriptionSegment? {
        let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let start = (segment["start"] as? NSNumber)?.doubleValue ?? 0
        let end = (segment["end"] as? NSNumber)?.doubleValue ?? start
        return PluginStructuredTranscriptionSegment(
            text: text,
            start: start,
            end: end,
            speakerLabel: speakerLabel(segment["speaker_id"])
        )
    }

    /// Mistral names speakers `speaker_1`, `speaker_2` and so on.
    static func speakerLabel(_ value: Any?) -> String? {
        let raw: String
        if let number = value as? Int {
            raw = String(number)
        } else if let string = value as? String {
            raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        guard !raw.isEmpty else { return nil }
        let number = raw.lowercased().hasPrefix("speaker_") ? String(raw.dropFirst("speaker_".count)) : raw
        return "Speaker \(number)"
    }

    // MARK: - Models

    func fetchModelCatalog() async throws -> MistralModelCatalog {
        guard let url = URL(string: "https://api.mistral.ai/v1/models") else {
            throw MistralAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let (data, response) = try await PluginHTTPClient.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MistralAPIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            struct ModelsResponse: Decodable { let data: [MistralCatalogEntry] }
            let entries = try JSONDecoder().decode(ModelsResponse.self, from: data).data
            return MistralModelCatalog.from(entries: entries)
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimitOrQuota(from: data)
        default:
            throw MistralAPIError.apiError(Self.errorMessage(from: data, response: httpResponse))
        }
    }

    // MARK: - Errors

    /// Mistral's `message` is a string, or for a rejected field an object whose
    /// `detail` list holds one `msg` per problem.
    static func errorMessage(from data: Data, response: HTTPURLResponse) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = json["message"] as? String, !message.isEmpty {
                return PluginHTTPErrorBodyFormatter.summary(from: message)
            }
            if let message = json["message"] as? [String: Any], let text = detailText(from: message) {
                return PluginHTTPErrorBodyFormatter.summary(from: text)
            }
            if let text = detailText(from: json) {
                return PluginHTTPErrorBodyFormatter.summary(from: text)
            }
        }
        let body = PluginHTTPErrorBodyFormatter.summary(from: data, response: response)
        return "HTTP \(response.statusCode): \(body)"
    }

    /// The `msg` of each `detail` entry, without the "Assertion failed, " prefix.
    static func detailText(from object: [String: Any]) -> String? {
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        guard let details = object["detail"] as? [[String: Any]] else { return nil }
        let messages = details.compactMap { detail -> String? in
            guard var message = detail["msg"] as? String, !message.isEmpty else { return nil }
            if message.hasPrefix("Assertion failed, ") {
                message.removeFirst("Assertion failed, ".count)
            }
            return message
        }
        return messages.isEmpty ? nil : messages.joined(separator: "; ")
    }
}

// MARK: - Settings View

struct MistralSettingsView: View {
    let plugin: MistralAIPlugin
    @State private var apiKeyInput: String = ""
    @State private var showApiKey: Bool = false
    @State private var isValidating: Bool = false
    @State private var validationResult: Bool?
    @State private var selectedSTTModel: String = ""
    @State private var selectedLLMModel: String = ""
    @State private var transcriptionMode = MistralTranscriptionMode.live
    @State private var speakerDiarizationEnabled = false
    @State private var reasoningEffort: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var catalog = MistralModelCatalog.builtIn
    @State private var hasFetchedCatalog = false
    @State private var isRefreshing = false
    @State private var refreshFailed = false
    @State private var hasApiKey = false
    /// Changes with every Save and Remove, so a key check that finishes after
    /// either cannot save its key again.
    @State private var keyRequestId = UUID()
    private let bundle = Bundle(for: MistralAIPlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mistral AI", bundle: bundle)
                .font(.headline)
            Text("Cloud API integration for Mistral LLMs and Voxtral STT.", bundle: bundle)
                .font(.callout)
                .foregroundColor(.secondary)

            Divider()

            apiKeySection

            if hasApiKey {
                Divider()
                transcriptionSection
                Divider()
                llmSection
            }
        }
        .padding()
        .onAppear {
            apiKeyInput = plugin.apiKey
            hasApiKey = !plugin.apiKey.isEmpty
            selectedSTTModel = plugin.selectedModelId ?? ""
            selectedLLMModel = plugin.selectedLLMModelId ?? ""
            transcriptionMode = plugin.transcriptionMode
            speakerDiarizationEnabled = plugin.isSpeakerDiarizationEnabled
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            catalog = plugin.catalog
            hasFetchedCatalog = plugin.hasFetchedCatalog
            showReasoningEffort()
            if hasApiKey, !hasFetchedCatalog {
                refreshModels()
            }
        }
    }

    // MARK: API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                if showApiKey {
                    TextField(String(localized: "e.g. LFztgP5WA...", bundle: bundle), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("API Key", bundle: bundle))
                } else {
                    SecureField(String(localized: "e.g. LFztgP5WA...", bundle: bundle), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(Text("API Key", bundle: bundle))
                }

                Button(action: { showApiKey.toggle() }) {
                    Image(systemName: showApiKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showApiKey ? Text("Hide API key", bundle: bundle) : Text("Show API key", bundle: bundle))

                if hasApiKey {
                    Button(String(localized: "Remove", bundle: bundle)) {
                        keyRequestId = UUID()
                        apiKeyInput = ""
                        validationResult = nil
                        isValidating = false
                        plugin.clearApiKey()
                        hasApiKey = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Remove API key", bundle: bundle))
                }

                Button(String(localized: "Save", bundle: bundle)) {
                    validateAndSave()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                .accessibilityLabel(Text("Save API key", bundle: bundle))
            }

            if isValidating {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Validating...", bundle: bundle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let result = validationResult {
                HStack(spacing: 4) {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result ? .green : .red)
                        .accessibilityHidden(true)
                    Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                        .font(.caption)
                        .foregroundColor(result ? .green : .red)
                }
            }
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Transcription Model", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    refreshButton
                }

                Picker(selection: $selectedSTTModel) {
                    Text("Default", bundle: bundle).tag("")
                    ForEach(catalog.transcriptionModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                } label: {
                    Text("Transcription Model", bundle: bundle)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedSTTModel) { _, newValue in
                    plugin.selectModel(newValue)
                }

                if refreshFailed {
                    Text("Could not load the models of your Mistral account. The built-in list stays.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !hasFetchedCatalog, !isRefreshing {
                    Text("Built-in model list. Refresh loads the models of your Mistral account.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker(String(localized: "Transcription", bundle: bundle), selection: $transcriptionMode) {
                    Text(liveLabel)
                        .tag(MistralTranscriptionMode.live)
                    Text(afterRecordingLabel)
                        .tag(MistralTranscriptionMode.batch)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: transcriptionMode) { _, newValue in
                    plugin.setTranscriptionMode(newValue)
                }

                Group {
                    switch transcriptionMode {
                    case .live:
                        Text("Streams dictations that show a live preview to Voxtral Realtime, so the preview shows Mistral's text while you speak. When you stop, the transcription model above writes the final text, which is more accurate and usually ready within a second. Both are billed. Recordings, files and dictations without a preview use only the transcription model.", bundle: bundle)
                    case .batch:
                        Text("Sends the recording to the transcription model above when you stop; the text is usually ready in under a second. No live preview from Mistral.", bundle: bundle)
                    }
                    if speakerDiarizationEnabled {
                        Text("With speaker labels on, dictations are transcribed after the recording instead of streaming.", bundle: bundle)
                    }
                    Text("Mistral list prices in November 2026, per hour of audio.", bundle: bundle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(String(localized: "Speaker labels", bundle: bundle), isOn: $speakerDiarizationEnabled)
                    .onChange(of: speakerDiarizationEnabled) { _, newValue in
                        plugin.setSpeakerDiarizationEnabled(newValue)
                    }
                Text("Marks who is speaking, for recordings with several people. Transcripts then start each speaker's part with a label.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The selected file transcription model, whose price both modes include.
    private var selectedPricedModelId: String? {
        catalog.transcriptionModel(selectedSTTModel.isEmpty ? MistralAIPlugin.defaultTranscriptionModelId : selectedSTTModel)?.id
    }

    /// Voxtral Realtime ($0.48/h) plus the transcription model for the final text.
    private var liveLabel: String {
        switch selectedPricedModelId {
        case MistralModelCatalog.defaultTranscriptionModelId:
            return String(localized: "Live – $0.69/h", bundle: bundle)
        case MistralModelCatalog.smallTranscriptionModelId:
            return String(localized: "Live – $0.72/h", bundle: bundle)
        default:
            return String(localized: "Live", bundle: bundle)
        }
    }

    /// Small costs a little more than Mini.
    private var afterRecordingLabel: String {
        switch selectedPricedModelId {
        case MistralModelCatalog.defaultTranscriptionModelId:
            return String(localized: "After recording – $0.21/h", bundle: bundle)
        case MistralModelCatalog.smallTranscriptionModelId:
            return String(localized: "After recording – $0.24/h", bundle: bundle)
        default:
            return String(localized: "After recording", bundle: bundle)
        }
    }

    private var refreshButton: some View {
        Button {
            refreshModels()
        } label: {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isRefreshing)
        .accessibilityLabel(Text("Refresh models", bundle: bundle))
    }

    // MARK: LLM

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker(selection: $selectedLLMModel) {
                    Text("Default", bundle: bundle).tag("")
                    ForEach(catalog.llmModels, id: \.id) { model in
                        Text(model.displayName).tag(model.id)
                    }
                } label: {
                    Text("LLM Model", bundle: bundle)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: selectedLLMModel) { _, newValue in
                    plugin.selectLLMModel(newValue)
                    showReasoningEffort()
                }
            }

            if !reasoningEfforts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reasoning", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Picker(selection: Binding(
                        get: { reasoningEffort },
                        set: { effort in
                            reasoningEffort = effort
                            plugin.setReasoningEffort(effort, forModelId: reasoningModelId)
                        }
                    )) {
                        ForEach(reasoningEfforts, id: \.self) { effort in
                            Text(MistralAIPlugin.effortDisplayName(effort, bundle: bundle)).tag(effort)
                        }
                    } label: {
                        Text("Reasoning", bundle: bundle)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text("The lowest level is the fastest. Higher levels think before they answer, which takes several seconds longer and costs more tokens. Workflows can pick their own level.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Temperature", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Picker(selection: $llmTemperatureMode) {
                    Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                    Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
                } label: {
                    Text("Temperature Mode", bundle: bundle)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: llmTemperatureMode) { _, newValue in
                    plugin.setLLMTemperatureMode(newValue)
                }

                if llmTemperatureMode == .custom {
                    HStack {
                        Text("Applies to workflow (LLM) processing only.", bundle: bundle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                        .onChange(of: llmTemperatureValue) { _, newValue in
                            plugin.setLLMTemperatureValue(newValue)
                        }
                        .accessibilityLabel(Text("Temperature", bundle: bundle))
                }
            }
        }
    }

    /// The model the reasoning picker applies to: the chosen one, or Mistral Small 4.
    private var reasoningModelId: String {
        catalog.resolvedLLMModelId(selectedLLMModel) ?? MistralAIPlugin.defaultLLMModelId
    }

    private var reasoningEfforts: [String] {
        MistralReasoningEffort.supportedEfforts(forModelId: reasoningModelId)
    }

    private func showReasoningEffort() {
        reasoningEffort = plugin.savedReasoningEffort(forModelId: reasoningModelId) ?? ""
    }

    // MARK: Actions

    private func validateAndSave() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isValidating = true
        validationResult = nil
        let requestId = UUID()
        keyRequestId = requestId

        Task {
            // The model list doubles as the key check.
            let fetched: MistralModelCatalog?
            let isValid: Bool
            do {
                fetched = try await plugin.fetchCatalog(for: trimmed)
                isValid = true
            } catch PluginTranscriptionError.invalidApiKey {
                fetched = nil
                isValid = false
            } catch {
                // Not a rejected key: save it and keep the built-in list.
                fetched = nil
                isValid = true
            }
            await MainActor.run {
                guard keyRequestId == requestId else { return }
                isValidating = false
                validationResult = isValid
                guard isValid else { return }
                plugin.setApiKey(trimmed)
                hasApiKey = true
                if let fetched {
                    showFetchedCatalog(fetched, fetchedWith: trimmed)
                }
            }
        }
    }

    private func refreshModels() {
        let apiKey = plugin.apiKey
        guard !apiKey.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        refreshFailed = false
        Task {
            let fetched = try? await plugin.fetchCatalog(for: apiKey)
            await MainActor.run {
                isRefreshing = false
                if let fetched {
                    showFetchedCatalog(fetched, fetchedWith: apiKey)
                } else {
                    refreshFailed = true
                }
            }
        }
    }

    private func showFetchedCatalog(_ fetched: MistralModelCatalog, fetchedWith apiKey: String) {
        guard plugin.applyFetchedCatalog(fetched, fetchedWith: apiKey) else { return }
        catalog = plugin.catalog
        hasFetchedCatalog = true
        refreshFailed = false
        showReasoningEffort()
    }
}
