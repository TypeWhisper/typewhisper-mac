import Foundation
import Combine
import TypeWhisperPluginSDK

enum TranscriptionEngineError: LocalizedError {
    case modelNotLoaded
    case appleSpeechModelNotLoaded
    case unsupportedTask(String)
    case transcriptionFailed(String)
    case modelLoadFailed(String)
    case modelDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "No model loaded. Please download and select a model first."
        case .appleSpeechModelNotLoaded:
            "Apple Speech needs a language model. Open Integrations > Apple Speech and select a language model, or choose a specific transcription language."
        case .unsupportedTask(let detail):
            "Unsupported task: \(detail)"
        case .transcriptionFailed(let detail):
            "Transcription failed: \(detail)"
        case .modelLoadFailed(let detail):
            "Failed to load model: \(detail)"
        case .modelDownloadFailed(let detail):
            "Failed to download model: \(detail)"
        }
    }
}

extension TranscriptionEnginePlugin {
    var acceptsLanguageHints: Bool {
        self is LanguageHintTranscriptionEnginePlugin
            || self is StructuredLanguageHintTranscriptionEnginePlugin
            || self is LiveLanguageHintTranscriptionCapablePlugin
    }
}

enum ModelAutoUnloadPolicy {
    static let defaultSeconds = 600

    static func effectiveSeconds(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds) != nil else {
            return defaultSeconds
        }
        return defaults.integer(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
    }

    static func shouldRestoreLoadedModelsPassively(defaults: UserDefaults = .standard) -> Bool {
        effectiveSeconds(defaults: defaults) == 0
    }

    static func policyName(seconds: Int) -> String {
        switch seconds {
        case 0:
            return "never"
        case -1:
            return "immediate"
        default:
            return "afterSeconds"
        }
    }
}

struct ModelAutoUnloadDiagnosticsSnapshot: Encodable, Equatable, Sendable {
    struct Entry: Encodable, Equatable, Sendable {
        let pluginClassName: String
        let pluginObjectIdentifier: String
        let policySeconds: Int
        let scheduledAt: Date?
        let dueAt: Date?
        let lastFiredAt: Date?
        let lastSelectorResponded: Bool?
    }

    let policySeconds: Int
    let policyName: String
    let entries: [Entry]
}

@MainActor
final class ModelManagerService: ObservableObject {
    struct LiveTranscriptionSessionHandle: Sendable {
        let providerId: String
        let session: any LiveTranscriptionSession
        fileprivate let cloudModelOverridePlugin: (any TranscriptionEnginePlugin)?
        fileprivate let cloudModelOverrideRestoreId: String?
    }

    private final class AutoUnloadTarget {
        weak var plugin: NSObject?

        init(plugin: NSObject) {
            self.plugin = plugin
        }
    }

    private enum PluginRestoreResult {
        case unavailable
        case configured
        case failed(String)
    }

    private enum PluginRestoreWaitResult {
        case configured
        case failed(String)
        case timedOut(activity: PluginSettingsActivity?)
    }

    @Published private(set) var selectedProviderId: String?

    @Published var autoUnloadSeconds: Int {
        didSet {
            UserDefaults.standard.set(autoUnloadSeconds, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            cancelAutoUnloadTimer()
            scheduleAutoUnloadIfNeeded()
        }
    }

    private var autoUnloadTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var autoUnloadTargets: [ObjectIdentifier: AutoUnloadTarget] = [:]
    private var autoUnloadDiagnostics: [ObjectIdentifier: ModelAutoUnloadDiagnosticsSnapshot.Entry] = [:]
    private var autoUnloadUsageCounts: [ObjectIdentifier: Int] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var pluginConfiguredWaitAttempts = 300
    private var pluginRestoreBusyWaitAttempts = 5_700
    private var pluginConfiguredPollInterval: Duration = .milliseconds(100)

    private let providerKey = UserDefaultsKeys.selectedEngine
    private let modelKey = UserDefaultsKeys.selectedModelId

    init() {
        self.autoUnloadSeconds = ModelAutoUnloadPolicy.effectiveSeconds()
        self.selectedProviderId = UserDefaults.standard.string(forKey: providerKey)
    }

    #if DEBUG
    func setPluginRestoreWaitConfigurationForTesting(
        initialAttempts: Int,
        busyAttempts: Int,
        pollInterval: Duration
    ) {
        pluginConfiguredWaitAttempts = max(0, initialAttempts)
        pluginRestoreBusyWaitAttempts = max(0, busyAttempts)
        pluginConfiguredPollInterval = pollInterval
    }
    #endif

    // MARK: - Public API

    var isModelReady: Bool {
        guard let providerId = selectedProviderId else { return false }
        return PluginManager.shared.transcriptionEngine(for: providerId)?.isConfigured ?? false
    }

    /// True when the selected engine plugin exists. The actual model readiness check
    /// happens in transcribe() which handles restoration via triggerRestoreModel().
    var canTranscribe: Bool {
        guard let providerId = selectedProviderId,
              let engine = PluginManager.shared.transcriptionEngine(for: providerId) else { return false }
        return canUseForTranscription(engine)
    }

    var activeEngineName: String? {
        guard let providerId = selectedProviderId else { return nil }
        return PluginManager.shared.transcriptionEngine(for: providerId)?.providerDisplayName
    }

    var selectedModelId: String? {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return nil }
        return plugin.selectedModelId
    }

    func selectedModelId(for providerId: String?) -> String? {
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return nil }
        return plugin.selectedModelId
    }

    func resolvedModelId(engineOverrideId: String? = nil, cloudModelOverride: String? = nil) -> String? {
        if let cloudModelOverride {
            return cloudModelOverride
        }
        let providerId = engineOverrideId ?? selectedProviderId
        return selectedModelId(for: providerId)
    }

    var activeModelName: String? {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return nil }
        return Self.activeModelName(for: plugin)
    }

    static func activeModelName(for plugin: any TranscriptionEnginePlugin) -> String? {
        if let selectedId = plugin.selectedModelId {
            if let model = plugin.modelCatalog.first(where: { $0.id == selectedId }) {
                return model.displayName
            }
            return plugin.providerDisplayName
        }

        if plugin.isConfigured {
            return plugin.providerDisplayName
        }

        return nil
    }

    func selectProvider(_ providerId: String) {
        selectedProviderId = providerId
        UserDefaults.standard.set(providerId, forKey: providerKey)
    }

    func clearProviderSelection() {
        selectedProviderId = nil
        UserDefaults.standard.removeObject(forKey: providerKey)
    }

    func selectModel(_ providerId: String, modelId: String) {
        selectProvider(providerId)
        PluginManager.shared.transcriptionEngine(for: providerId)?.selectModel(modelId)
    }

    func observePluginManager() {
        PluginManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.restoreProviderSelection()
                self.scheduleAutoUnloadIfNeeded()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var supportsTranslation: Bool {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return false }
        return plugin.supportsTranslation
    }

    var supportsStreaming: Bool {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return false }
        return plugin.supportsStreaming
    }

    func supportsLiveTranscriptionSession(engineOverrideId: String? = nil) -> Bool {
        guard let providerId = engineOverrideId ?? selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            return false
        }
        return plugin is LiveTranscriptionCapablePlugin
    }

    func usesMeteredStreamingFallback(engineOverrideId: String? = nil) -> Bool {
        guard let providerId = engineOverrideId ?? selectedProviderId,
              let loadedPlugin = PluginManager.shared.loadedTranscriptionPlugin(for: providerId) else {
            return false
        }
        return loadedPlugin.manifest.requiresAPIKey == true
    }

    func allowsTranscriptPreviewFallback(engineOverrideId: String? = nil, selectedProviderId: String? = nil) -> Bool {
        guard let providerId = engineOverrideId ?? selectedProviderId ?? self.selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            return false
        }
        return (plugin as? any TranscriptPreviewFallbackPolicyProviding)?.allowsTranscriptPreviewFallback ?? true
    }

    func transcriptionAuthStatus(for engine: TranscriptionEnginePlugin) -> PluginAuthRoleStatus {
        // Legacy plugins may use isConfigured for loaded-model state, so absence of the
        // optional auth-role protocol should not make auto-unloaded local engines unselectable.
        PluginAuthRoleStatusResolver.status(
            for: engine,
            role: .transcription,
            legacyIsConfigured: true
        )
    }

    func transcriptionAuthStatus(for providerId: String?) -> PluginAuthRoleStatus? {
        guard let providerId,
              let engine = PluginManager.shared.transcriptionEngine(for: providerId) else {
            return nil
        }
        return transcriptionAuthStatus(for: engine)
    }

    func canUseForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        transcriptionAuthStatus(for: engine).isAvailable
    }

    func canPrepareForTranscription(_ engine: TranscriptionEnginePlugin) -> Bool {
        guard canUseForTranscription(engine) else { return false }
        if engine.isConfigured { return true }
        guard engine.providerId == AppleSpeechModelSelection.providerId else { return false }
        return engine.selectedModelId != nil || !engine.modelCatalog.isEmpty
    }

    /// Resolve display name for a given engine/model override combination
    func resolvedModelDisplayName(engineOverrideId: String? = nil, cloudModelOverride: String? = nil) -> String? {
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return nil }

        if let modelId = cloudModelOverride,
           let model = plugin.modelCatalog.first(where: { $0.id == modelId })
            ?? plugin.transcriptionModels.first(where: { $0.id == modelId }) {
            return model.displayName
        }
        if let selectedId = plugin.selectedModelId,
           let model = plugin.modelCatalog.first(where: { $0.id == selectedId })
            ?? plugin.transcriptionModels.first(where: { $0.id == selectedId }) {
            return model.displayName
        }
        return plugin.providerDisplayName
    }

    /// Re-validate provider selection after plugins have been loaded.
    /// If the selected plugin is missing, fall back to the first available engine.
    func restoreProviderSelection() {
        if let providerId = selectedProviderId,
           let engine = PluginManager.shared.transcriptionEngine(for: providerId),
           canUseForTranscription(engine) {
            return
        }
        // Selected provider doesn't exist - find a fallback
        if let fallback = PluginManager.shared.transcriptionEngines.first(where: { $0.isConfigured && canUseForTranscription($0) }) {
            selectProvider(fallback.providerId)
        } else if let anyEngine = PluginManager.shared.transcriptionEngines.first(where: { canUseForTranscription($0) }) {
            selectProvider(anyEngine.providerId)
        } else {
            clearProviderSelection()
        }
    }

    // MARK: - Transcription

    /// Apply a one-shot cloud model override without persisting the default.
    ///
    /// Returns the model id that should be restored after the transcription call completes
    /// (nil means "no restore needed" -- either no override was applied or the plugin had no
    /// previous selection to restore to). Callers must pair this with `restoreCloudModelOverride`
    /// inside a `defer` so the original selection is restored even on throw.
    private func applyCloudModelOverride(
        plugin: any TranscriptionEnginePlugin,
        override: String?
    ) -> String? {
        guard let override else { return nil }
        let previousId = plugin.selectedModelId
        if previousId != override || !plugin.isConfigured {
            plugin.selectModel(override)
        }
        // If the plugin had no previous selection we can't express "unselect" through the SDK,
        // so the override stays in place. For configured plugins selectedModelId is normally set.
        guard let previousId, previousId != override else {
            return nil
        }
        return previousId
    }

    private func restoreCloudModelOverride(
        plugin: any TranscriptionEnginePlugin,
        previousId: String?
    ) {
        guard let previousId else { return }
        plugin.selectModel(previousId)
    }

    private func restoreCloudModelOverride(for handle: LiveTranscriptionSessionHandle) {
        guard let plugin = handle.cloudModelOverridePlugin else { return }
        restoreCloudModelOverride(plugin: plugin, previousId: handle.cloudModelOverrideRestoreId)
    }

    nonisolated private static func makeAudioData(from audioSamples: [Float]) async -> AudioData {
        let wavData = await Task.detached(priority: .userInitiated) {
            WavEncoder.encode(audioSamples)
        }.value

        return AudioData(
            samples: audioSamples,
            wavData: wavData,
            duration: Double(audioSamples.count) / 16000.0
        )
    }

    func createLiveTranscriptionSession(
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> LiveTranscriptionSessionHandle? {
        try await createLiveTranscriptionSession(
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> LiveTranscriptionSessionHandle? {
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let authStatus = transcriptionAuthStatus(for: plugin)
        guard authStatus.isAvailable else {
            throw TranscriptionEngineError.unsupportedTask(
                authStatus.unavailableReason ?? "Transcription is not available for this engine."
            )
        }

        let runtimeSelection = runtimeLanguageSelection(for: languageSelection, plugin: plugin)
        let preparationLanguage = preparationRequestedLanguage(
            for: languageSelection,
            runtimeSelection: runtimeSelection,
            plugin: plugin
        )
        let overrideRestoreId = try await prepareEngineForTranscription(
            plugin,
            requestedLanguage: preparationLanguage,
            cloudModelOverride: cloudModelOverride
        )

        guard plugin.isConfigured else {
            restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId)
            throw modelNotLoadedError(for: plugin)
        }

        guard let livePlugin = plugin as? LiveTranscriptionCapablePlugin else {
            restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId)
            return nil
        }

        let session: any LiveTranscriptionSession
        do {
            if !runtimeSelection.languageHints.isEmpty,
               !dictionaryTermHints.isEmpty,
               let hintTermPlugin = livePlugin as? LiveLanguageHintDictionaryTermHintTranscriptionCapablePlugin {
                session = try await hintTermPlugin.createLiveTranscriptionSession(
                    languageSelection: runtimeSelection,
                    translate: task == .translate,
                    prompt: prompt,
                    dictionaryTermHints: dictionaryTermHints,
                    onProgress: onProgress
                )
            } else if !runtimeSelection.languageHints.isEmpty,
               let hintPlugin = livePlugin as? LiveLanguageHintTranscriptionCapablePlugin {
                session = try await hintPlugin.createLiveTranscriptionSession(
                    languageSelection: runtimeSelection,
                    translate: task == .translate,
                    prompt: prompt,
                    onProgress: onProgress
                )
            } else if !dictionaryTermHints.isEmpty,
                      let termHintPlugin = livePlugin as? LiveDictionaryTermHintTranscriptionCapablePlugin {
                session = try await termHintPlugin.createLiveTranscriptionSession(
                    language: runtimeSelection.requestedLanguage,
                    translate: task == .translate,
                    prompt: prompt,
                    dictionaryTermHints: dictionaryTermHints,
                    onProgress: onProgress
                )
            } else {
                session = try await livePlugin.createLiveTranscriptionSession(
                    language: runtimeSelection.requestedLanguage,
                    translate: task == .translate,
                    prompt: prompt,
                    onProgress: onProgress
                )
            }
        } catch {
            restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId)
            throw error
        }

        return LiveTranscriptionSessionHandle(
            providerId: providerId,
            session: session,
            cloudModelOverridePlugin: overrideRestoreId == nil ? nil : plugin,
            cloudModelOverrideRestoreId: overrideRestoreId
        )
    }

    func finishLiveTranscriptionSession(
        _ handle: LiveTranscriptionSessionHandle,
        bufferedDuration: Double,
        language: String? = nil,
        languageCandidates: [String] = [],
        task: TranscriptionTask = .transcribe,
        normalizeNumbers: Bool? = nil
    ) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        defer { restoreCloudModelOverride(for: handle) }

        let result = try await handle.session.finish()
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionNormalizationService.normalizeResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            configuredLanguage: language,
            configuredLanguageCandidates: languageCandidates,
            duration: bufferedDuration,
            processingTime: processingTime,
            engineUsed: handle.providerId,
            segments: Self.transcriptionSegments(from: result.segments),
            task: task,
            normalizeNumbers: normalizeNumbers
        )
    }

    func cancelLiveTranscriptionSession(_ handle: LiveTranscriptionSessionHandle) async {
        await handle.session.cancel()
        restoreCloudModelOverride(for: handle)
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil
    ) async throws -> TranscriptionResult {
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let authStatus = transcriptionAuthStatus(for: plugin)
        guard authStatus.isAvailable else {
            throw TranscriptionEngineError.unsupportedTask(
                authStatus.unavailableReason ?? "Transcription is not available for this engine."
            )
        }

        let runtimeSelection = runtimeLanguageSelection(for: languageSelection, plugin: plugin)
        let preparationLanguage = preparationRequestedLanguage(
            for: languageSelection,
            runtimeSelection: runtimeSelection,
            plugin: plugin
        )
        let overrideRestoreId = try await prepareEngineForTranscription(
            plugin,
            requestedLanguage: preparationLanguage,
            cloudModelOverride: cloudModelOverride
        )
        defer { restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId) }

        guard plugin.isConfigured else {
            throw modelNotLoadedError(for: plugin)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let audio = await Self.makeAudioData(from: audioSamples)
        let normalizationLanguageCandidates = normalizationLanguageCandidates(
            for: languageSelection,
            plugin: plugin
        )

        let result = try await transcribeWithResolvedLanguageSelection(
            plugin: plugin,
            audio: audio,
            languageSelection: runtimeSelection,
            task: task,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionNormalizationService.normalizeResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            configuredLanguage: runtimeSelection.requestedLanguage,
            configuredLanguageCandidates: normalizationLanguageCandidates,
            duration: audio.duration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: Self.transcriptionSegments(from: result.segments),
            task: task,
            normalizeNumbers: normalizeNumbers
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers,
            onProgress: onProgress,
            onSourceProgress: { _ in true }
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: languageSelection,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers,
            onProgress: onProgress,
            onSourceProgress: { _ in true }
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            normalizeNumbers: normalizeNumbers,
            onProgress: onProgress,
            onSourceProgress: onSourceProgress
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        normalizeNumbers: Bool? = nil,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> TranscriptionResult {
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let authStatus = transcriptionAuthStatus(for: plugin)
        guard authStatus.isAvailable else {
            throw TranscriptionEngineError.unsupportedTask(
                authStatus.unavailableReason ?? "Transcription is not available for this engine."
            )
        }

        let runtimeSelection = runtimeLanguageSelection(for: languageSelection, plugin: plugin)
        let preparationLanguage = preparationRequestedLanguage(
            for: languageSelection,
            runtimeSelection: runtimeSelection,
            plugin: plugin
        )
        let overrideRestoreId = try await prepareEngineForTranscription(
            plugin,
            requestedLanguage: preparationLanguage,
            cloudModelOverride: cloudModelOverride
        )
        defer { restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId) }

        guard plugin.isConfigured else {
            throw modelNotLoadedError(for: plugin)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let audio = await Self.makeAudioData(from: audioSamples)
        let normalizationLanguageCandidates = normalizationLanguageCandidates(
            for: languageSelection,
            plugin: plugin
        )

        let result = try await transcribeWithResolvedLanguageSelection(
            plugin: plugin,
            audio: audio,
            languageSelection: runtimeSelection,
            task: task,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress,
            onSourceProgress: onSourceProgress
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionNormalizationService.normalizeResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            configuredLanguage: runtimeSelection.requestedLanguage,
            configuredLanguageCandidates: normalizationLanguageCandidates,
            duration: audio.duration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: Self.transcriptionSegments(from: result.segments),
            task: task,
            normalizeNumbers: normalizeNumbers
        )
    }

    // MARK: - Auto-Unload

    func scheduleAutoUnloadIfNeeded() {
        var scheduledKeys = Set<ObjectIdentifier>()

        for plugin in PluginManager.shared.transcriptionEngines where plugin.isConfigured {
            scheduleAutoUnloadIfNeeded(for: plugin, scheduledKeys: &scheduledKeys)
        }

        for plugin in PluginManager.shared.llmProviders
            where plugin.isAvailable && Self.shouldAutoUnloadLocalLLMProvider(plugin) {
            scheduleAutoUnloadIfNeeded(for: plugin, scheduledKeys: &scheduledKeys)
        }

        let existingKeys = Set(autoUnloadTasks.keys)
            .union(autoUnloadTargets.keys)
            .union(autoUnloadDiagnostics.keys)
        for key in existingKeys.subtracting(scheduledKeys) {
            autoUnloadTasks[key]?.cancel()
            autoUnloadTasks[key] = nil
            autoUnloadTargets[key] = nil
            autoUnloadDiagnostics[key] = nil
        }
    }

    func scheduleAutoUnloadIfNeeded(for plugin: any TypeWhisperPlugin) {
        guard let nsPlugin = plugin as? NSObject else { return }
        var scheduledKeys = Set<ObjectIdentifier>()
        scheduleAutoUnloadIfNeeded(for: nsPlugin, scheduledKeys: &scheduledKeys)
    }

    func beginAutoUnloadProtectedUse(of plugin: any TypeWhisperPlugin) {
        guard let nsPlugin = plugin as? NSObject else { return }
        let key = ObjectIdentifier(nsPlugin)
        autoUnloadUsageCounts[key, default: 0] += 1
        clearAutoUnloadSchedule(for: key)
    }

    func endAutoUnloadProtectedUse(of plugin: any TypeWhisperPlugin) {
        guard let nsPlugin = plugin as? NSObject else { return }
        let key = ObjectIdentifier(nsPlugin)
        guard let currentUses = autoUnloadUsageCounts[key], currentUses > 0 else { return }
        let remainingUses = currentUses - 1
        if remainingUses > 0 {
            autoUnloadUsageCounts[key] = remainingUses
            return
        }

        autoUnloadUsageCounts[key] = nil
        var scheduledKeys = Set<ObjectIdentifier>()
        scheduleAutoUnloadIfNeeded(for: nsPlugin, scheduledKeys: &scheduledKeys)
    }

    private static func shouldAutoUnloadLocalLLMProvider(_ plugin: any LLMProviderPlugin) -> Bool {
        guard let setupStatus = plugin as? any LLMProviderSetupStatusProviding else {
            return false
        }
        return !setupStatus.requiresExternalCredentials
    }

    private func scheduleAutoUnloadIfNeeded(
        for plugin: any TypeWhisperPlugin,
        scheduledKeys: inout Set<ObjectIdentifier>
    ) {
        guard let nsPlugin = plugin as? NSObject else { return }
        scheduleAutoUnloadIfNeeded(for: nsPlugin, scheduledKeys: &scheduledKeys)
    }

    private func scheduleAutoUnloadIfNeeded(
        for nsPlugin: NSObject,
        scheduledKeys: inout Set<ObjectIdentifier>
    ) {
        let key = ObjectIdentifier(nsPlugin)
        guard scheduledKeys.insert(key).inserted else { return }

        clearAutoUnloadSchedule(for: key)
        guard autoUnloadUsageCounts[key] == nil else { return }

        let seconds = autoUnloadSeconds
        guard seconds != 0 else { return }

        let scheduledAt = Date()
        let dueAt = seconds == -1
            ? scheduledAt.addingTimeInterval(0.1)
            : scheduledAt.addingTimeInterval(TimeInterval(seconds))
        autoUnloadDiagnostics[key] = ModelAutoUnloadDiagnosticsSnapshot.Entry(
            pluginClassName: String(describing: type(of: nsPlugin)),
            pluginObjectIdentifier: Self.diagnosticIdentifier(for: key),
            policySeconds: seconds,
            scheduledAt: scheduledAt,
            dueAt: dueAt,
            lastFiredAt: nil,
            lastSelectorResponded: nil
        )
        autoUnloadTargets[key] = AutoUnloadTarget(plugin: nsPlugin)
        autoUnloadTasks[key] = Task { [weak self] in
            if seconds == -1 {
                // Small delay to let transcription call stack fully unwind
                // before releasing the model (avoids EXC_BAD_ACCESS from MLX cleanup)
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            self?.performAutoUnload(for: key)
        }
    }

    private func clearAutoUnloadSchedule(for key: ObjectIdentifier) {
        autoUnloadTasks[key]?.cancel()
        autoUnloadTasks[key] = nil
        autoUnloadTargets[key] = nil
        autoUnloadDiagnostics[key] = nil
    }

    func cancelAutoUnloadTimer() {
        for task in autoUnloadTasks.values {
            task.cancel()
        }
        autoUnloadTasks.removeAll()
        autoUnloadTargets.removeAll()
        autoUnloadDiagnostics.removeAll()
    }

    private func performAutoUnload(for key: ObjectIdentifier) {
        defer {
            autoUnloadTasks[key] = nil
            autoUnloadTargets[key] = nil
        }

        guard let nsPlugin = autoUnloadTargets[key]?.plugin else {
            recordAutoUnloadFired(for: key, plugin: nil, selectorResponded: false)
            return
        }
        let sel = NSSelectorFromString("triggerAutoUnload")
        let selectorResponded = nsPlugin.responds(to: sel)
        recordAutoUnloadFired(for: key, plugin: nsPlugin, selectorResponded: selectorResponded)
        guard selectorResponded else { return }
        nsPlugin.perform(sel)
    }

    private func recordAutoUnloadFired(
        for key: ObjectIdentifier,
        plugin: NSObject?,
        selectorResponded: Bool
    ) {
        let previous = autoUnloadDiagnostics[key]
        autoUnloadDiagnostics[key] = ModelAutoUnloadDiagnosticsSnapshot.Entry(
            pluginClassName: plugin.map { String(describing: type(of: $0)) } ?? previous?.pluginClassName ?? "unknown",
            pluginObjectIdentifier: previous?.pluginObjectIdentifier ?? Self.diagnosticIdentifier(for: key),
            policySeconds: previous?.policySeconds ?? autoUnloadSeconds,
            scheduledAt: nil,
            dueAt: nil,
            lastFiredAt: Date(),
            lastSelectorResponded: selectorResponded
        )
    }

    func autoUnloadDiagnosticsSnapshot() -> ModelAutoUnloadDiagnosticsSnapshot {
        ModelAutoUnloadDiagnosticsSnapshot(
            policySeconds: autoUnloadSeconds,
            policyName: ModelAutoUnloadPolicy.policyName(seconds: autoUnloadSeconds),
            entries: autoUnloadDiagnostics.values.sorted {
                if $0.pluginClassName == $1.pluginClassName {
                    return $0.pluginObjectIdentifier < $1.pluginObjectIdentifier
                }
                return $0.pluginClassName < $1.pluginClassName
            }
        )
    }

    private static func diagnosticIdentifier(for key: ObjectIdentifier) -> String {
        String(describing: key)
    }

    private func runtimeLanguageSelection(
        for languageSelection: LanguageSelection,
        plugin: TranscriptionEnginePlugin
    ) -> PluginLanguageSelection {
        let normalizedSelection = languageSelection.normalizedForSupportedLanguages(plugin.supportedLanguages)
        switch normalizedSelection {
        case .exact(let code):
            return PluginLanguageSelection(requestedLanguage: code)
        case .hints(let codes):
            if plugin.acceptsLanguageHints {
                return PluginLanguageSelection(languageHints: codes)
            }
            return PluginLanguageSelection(requestedLanguage: codes.first)
        case .inheritGlobal, .auto:
            return PluginLanguageSelection()
        }
    }

    private func preparationRequestedLanguage(
        for languageSelection: LanguageSelection,
        runtimeSelection: PluginLanguageSelection,
        plugin: TranscriptionEnginePlugin
    ) -> String? {
        guard plugin.providerId == AppleSpeechModelSelection.providerId else {
            return runtimeSelection.requestedLanguage
        }
        return languageSelection.requestedLanguage ?? runtimeSelection.requestedLanguage
    }

    private func normalizationLanguageCandidates(
        for languageSelection: LanguageSelection,
        plugin: TranscriptionEnginePlugin
    ) -> [String] {
        languageSelection
            .normalizedForSupportedLanguages(plugin.supportedLanguages)
            .selectedCodes
    }

    private func transcribeWithResolvedLanguageSelection(
        plugin: TranscriptionEnginePlugin,
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        task: TranscriptionTask,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint]
    ) async throws -> PluginStructuredTranscriptionResult {
        if !languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let structuredCombinedPlugin = plugin as? StructuredLanguageHintDictionaryTermHintTranscriptionEnginePlugin {
            return try await structuredCombinedPlugin.transcribeStructured(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            )
        }

        if !languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let combinedPlugin = plugin as? LanguageHintDictionaryTermHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await combinedPlugin.transcribe(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            ))
        }

        if !languageSelection.languageHints.isEmpty,
           let structuredHintPlugin = plugin as? StructuredLanguageHintTranscriptionEnginePlugin {
            return try await structuredHintPlugin.transcribeStructured(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt
            )
        }

        if !languageSelection.languageHints.isEmpty,
           let hintPlugin = plugin as? LanguageHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await hintPlugin.transcribe(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt
            ))
        }

        if !dictionaryTermHints.isEmpty,
           let structuredTermHintPlugin = plugin as? StructuredDictionaryTermHintTranscriptionEnginePlugin {
            return try await structuredTermHintPlugin.transcribeStructured(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            )
        }

        if !dictionaryTermHints.isEmpty,
           let termHintPlugin = plugin as? DictionaryTermHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await termHintPlugin.transcribe(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            ))
        }

        if let structuredPlugin = plugin as? StructuredTranscriptionEnginePlugin {
            return try await structuredPlugin.transcribeStructured(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt
            )
        }

        return Self.structuredResult(from: try await plugin.transcribe(
            audio: audio,
            language: languageSelection.requestedLanguage,
            translate: task == .translate,
            prompt: prompt
        ))
    }

    private func transcribeWithResolvedLanguageSelection(
        plugin: TranscriptionEnginePlugin,
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        task: TranscriptionTask,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginStructuredTranscriptionResult {
        if !languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let structuredCombinedPlugin = plugin as? StructuredLanguageHintDictionaryTermHintTranscriptionEnginePlugin {
            let result = try await structuredCombinedPlugin.transcribeStructured(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            )
            let _ = onProgress(result.text)
            return result
        }

        if !languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let combinedPlugin = plugin as? LanguageHintDictionaryTermHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await combinedPlugin.transcribe(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress
            ))
        }

        if !languageSelection.languageHints.isEmpty,
           let structuredHintPlugin = plugin as? StructuredLanguageHintTranscriptionEnginePlugin,
           !plugin.supportsStreaming {
            let result = try await structuredHintPlugin.transcribeStructured(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt
            )
            let _ = onProgress(result.text)
            return result
        }

        if !languageSelection.languageHints.isEmpty,
           let hintPlugin = plugin as? LanguageHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await hintPlugin.transcribe(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                onProgress: onProgress
            ))
        }

        if !dictionaryTermHints.isEmpty,
           let structuredTermHintPlugin = plugin as? StructuredDictionaryTermHintTranscriptionEnginePlugin {
            let result = try await structuredTermHintPlugin.transcribeStructured(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            )
            let _ = onProgress(result.text)
            return result
        }

        if !dictionaryTermHints.isEmpty,
           let termHintPlugin = plugin as? DictionaryTermHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await termHintPlugin.transcribe(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress
            ))
        }

        if plugin.supportsStreaming {
            return Self.structuredResult(from: try await plugin.transcribe(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                onProgress: onProgress
            ))
        }

        if let structuredPlugin = plugin as? StructuredTranscriptionEnginePlugin {
            let result = try await structuredPlugin.transcribeStructured(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt
            )
            let _ = onProgress(result.text)
            return result
        }

        let result = try await plugin.transcribe(
            audio: audio,
            language: languageSelection.requestedLanguage,
            translate: task == .translate,
            prompt: prompt
        )
        let _ = onProgress(result.text)
        return Self.structuredResult(from: result)
    }

    private func transcribeWithResolvedLanguageSelection(
        plugin: TranscriptionEnginePlugin,
        audio: AudioData,
        languageSelection: PluginLanguageSelection,
        task: TranscriptionTask,
        prompt: String?,
        dictionaryTermHints: [PluginDictionaryTermHint],
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginStructuredTranscriptionResult {
        if !languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let sourceCombinedPlugin = plugin as? LanguageHintDictionaryTermHintSourceProgressTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await sourceCombinedPlugin.transcribe(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress,
                onSourceProgress: onSourceProgress
            ))
        }

        if !languageSelection.languageHints.isEmpty,
           let sourceHintPlugin = plugin as? SourceProgressLanguageHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await sourceHintPlugin.transcribe(
                audio: audio,
                languageSelection: languageSelection,
                translate: task == .translate,
                prompt: prompt,
                onProgress: onProgress,
                onSourceProgress: onSourceProgress
            ))
        }

        if languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let sourceTermPlugin = plugin as? DictionaryTermHintSourceProgressTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await sourceTermPlugin.transcribe(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress,
                onSourceProgress: onSourceProgress
            ))
        }

        if languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let structuredTermHintPlugin = plugin as? StructuredDictionaryTermHintTranscriptionEnginePlugin {
            let result = try await structuredTermHintPlugin.transcribeStructured(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints
            )
            let _ = onProgress(result.text)
            return result
        }

        if languageSelection.languageHints.isEmpty,
           !dictionaryTermHints.isEmpty,
           let termHintPlugin = plugin as? DictionaryTermHintTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await termHintPlugin.transcribe(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: onProgress
            ))
        }

        if languageSelection.languageHints.isEmpty,
           let sourcePlugin = plugin as? SourceProgressTranscriptionEnginePlugin {
            return Self.structuredResult(from: try await sourcePlugin.transcribe(
                audio: audio,
                language: languageSelection.requestedLanguage,
                translate: task == .translate,
                prompt: prompt,
                onProgress: onProgress,
                onSourceProgress: onSourceProgress
            ))
        }

        return try await transcribeWithResolvedLanguageSelection(
            plugin: plugin,
            audio: audio,
            languageSelection: languageSelection,
            task: task,
            prompt: prompt,
            dictionaryTermHints: dictionaryTermHints,
            onProgress: onProgress
        )
    }

    nonisolated private static func structuredResult(
        from result: PluginTranscriptionResult
    ) -> PluginStructuredTranscriptionResult {
        PluginStructuredTranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            segments: result.segments.map {
                PluginStructuredTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
        )
    }

    nonisolated private static func transcriptionSegments(
        from segments: [PluginStructuredTranscriptionSegment]
    ) -> [TranscriptionSegment] {
        segments.map {
            TranscriptionSegment(
                text: $0.text,
                start: $0.start,
                end: $0.end,
                speakerLabel: $0.speakerLabel,
                speakerConfidence: $0.speakerConfidence
            )
        }
    }

    nonisolated private static func transcriptionSegments(
        from segments: [PluginTranscriptionSegment]
    ) -> [TranscriptionSegment] {
        segments.map { TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end) }
    }

    private func prepareEngineForTranscription(
        _ plugin: TranscriptionEnginePlugin,
        requestedLanguage: String?,
        cloudModelOverride: String?
    ) async throws -> String? {
        let overrideRestoreId = applyCloudModelOverride(plugin: plugin, override: cloudModelOverride)

        if let cloudModelOverride {
            _ = await waitForPluginConfigured(plugin, selectedModelId: cloudModelOverride)
            return overrideRestoreId
        }

        if plugin.providerId == AppleSpeechModelSelection.providerId {
            let prepared = await triggerAppleSpeechModelPreparation(
                plugin,
                requestedLanguage: requestedLanguage
            )
            guard prepared else {
                throw modelNotLoadedError(for: plugin)
            }
        } else if !plugin.isConfigured {
            let restoreResult = await triggerRestoreModel(plugin)
            if case .failed(let message) = restoreResult {
                throw TranscriptionEngineError.modelLoadFailed(message)
            }
        }

        return overrideRestoreId
    }

    private func modelNotLoadedError(for plugin: TranscriptionEnginePlugin) -> TranscriptionEngineError {
        plugin.providerId == AppleSpeechModelSelection.providerId
            ? .appleSpeechModelNotLoaded
            : .modelNotLoaded
    }

    private func triggerAppleSpeechModelPreparation(
        _ plugin: TranscriptionEnginePlugin,
        requestedLanguage: String?
    ) async -> Bool {
        let expectedModelId = requestedLanguage.flatMap {
            AppleSpeechModelSelection.preferredModelId(
                from: plugin.modelCatalog,
                localeIdentifier: $0,
                languageCode: $0,
                fallbackToFirst: false
            )
        }

        if requestedLanguage != nil, expectedModelId == nil, !plugin.modelCatalog.isEmpty {
            return false
        }

        guard let nsPlugin = plugin as? NSObject else {
            return plugin.isConfigured
                && expectedModelId.map { plugin.selectedModelId == $0 } != false
        }

        let languageSelector = NSSelectorFromString("triggerRestoreModelForLanguage:")
        if nsPlugin.responds(to: languageSelector) {
            let languageObject = requestedLanguage.map { $0 as NSString }
            _ = nsPlugin.perform(languageSelector, with: languageObject)
        } else if !plugin.isConfigured {
            let restoreSelector = NSSelectorFromString("triggerRestoreModel")
            if nsPlugin.responds(to: restoreSelector) {
                _ = nsPlugin.perform(restoreSelector)
            }
        }

        return await waitForPluginConfigured(
            plugin,
            selectedModelId: expectedModelId,
            stopOnMismatchedSelection: expectedModelId != nil
        )
    }

    /// Trigger model restore via ObjC dispatch (avoids Swift protocol witness table issues
    /// with dynamically loaded plugin bundles) and poll until ready.
    private func triggerRestoreModel(_ plugin: TranscriptionEnginePlugin) async -> PluginRestoreResult {
        let restoreSelector = NSSelectorFromString("triggerRestoreModel")
        guard let nsPlugin = plugin as? NSObject,
              nsPlugin.responds(to: restoreSelector) else {
            return .unavailable
        }
        _ = nsPlugin.perform(restoreSelector)

        switch await waitForPluginRestoreConfigured(plugin) {
        case .configured:
            return .configured
        case .failed(let message):
            return .failed(message)
        case .timedOut(let activity):
            guard let activity else { return .unavailable }
            return .failed(Self.restoreTimeoutMessage(activity: activity))
        }
    }

    private func waitForPluginConfigured(
        _ plugin: TranscriptionEnginePlugin,
        selectedModelId: String? = nil,
        stopOnMismatchedSelection: Bool = false
    ) async -> Bool {
        for _ in 0..<pluginConfiguredWaitAttempts {
            if let configured = pluginConfiguredState(
                plugin,
                selectedModelId: selectedModelId,
                stopOnMismatchedSelection: stopOnMismatchedSelection
            ) {
                return configured
            }
            try? await Task.sleep(for: pluginConfiguredPollInterval)
        }

        return pluginConfiguredState(
            plugin,
            selectedModelId: selectedModelId,
            stopOnMismatchedSelection: stopOnMismatchedSelection
        ) ?? false
    }

    private func waitForPluginRestoreConfigured(_ plugin: TranscriptionEnginePlugin) async -> PluginRestoreWaitResult {
        var latestActivity: PluginSettingsActivity?

        for _ in 0..<pluginConfiguredWaitAttempts {
            if plugin.isConfigured { return .configured }
            if let activity = pluginSettingsActivity(plugin) {
                latestActivity = activity
                if activity.isError {
                    return .failed(activity.message)
                }
            }
            try? await Task.sleep(for: pluginConfiguredPollInterval)
        }

        if plugin.isConfigured { return .configured }

        guard latestActivity != nil else {
            return .timedOut(activity: nil)
        }

        for _ in 0..<pluginRestoreBusyWaitAttempts {
            if plugin.isConfigured { return .configured }
            guard let activity = pluginSettingsActivity(plugin) else {
                return .timedOut(activity: latestActivity)
            }
            latestActivity = activity
            if activity.isError {
                return .failed(activity.message)
            }
            try? await Task.sleep(for: pluginConfiguredPollInterval)
        }

        if plugin.isConfigured { return .configured }
        return .timedOut(activity: latestActivity)
    }

    private func pluginConfiguredState(
        _ plugin: TranscriptionEnginePlugin,
        selectedModelId: String?,
        stopOnMismatchedSelection: Bool
    ) -> Bool? {
        guard plugin.isConfigured else { return nil }
        guard let selectedModelId else { return true }
        let currentModelId = plugin.selectedModelId
        if currentModelId == selectedModelId { return true }
        if stopOnMismatchedSelection, currentModelId != nil { return false }
        return nil
    }

    private func pluginSettingsActivity(_ plugin: TranscriptionEnginePlugin) -> PluginSettingsActivity? {
        (plugin as? any PluginSettingsActivityReporting)?.currentSettingsActivity
    }

    private static func restoreTimeoutMessage(activity: PluginSettingsActivity) -> String {
        let message = activity.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return "Timed out while restoring the selected model."
        }
        return "Timed out while restoring the selected model: \(message)."
    }
}
