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
    private var cancellables = Set<AnyCancellable>()

    private let providerKey = UserDefaultsKeys.selectedEngine
    private let modelKey = UserDefaultsKeys.selectedModelId

    init() {
        self.autoUnloadSeconds = UserDefaults.standard.integer(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        self.selectedProviderId = UserDefaults.standard.string(forKey: providerKey)
    }

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
        // If the plugin had no previous selection we can't express "unselect" through the SDK,
        // so the override stays in place. For configured plugins selectedModelId is normally set.
        guard let previousId, previousId != override else {
            if previousId != override { plugin.selectModel(override) }
            return nil
        }
        plugin.selectModel(override)
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
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> LiveTranscriptionSessionHandle? {
        try await createLiveTranscriptionSession(
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            onProgress: onProgress
        )
    }

    func createLiveTranscriptionSession(
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
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
            // For engines without native live session support, use a universal chunked session
            // that processes audio in the background during recording. This ensures that when
            // recording stops, only a short tail of audio needs transcription regardless of
            // how long the recording was.
            let allowsChunked = (plugin as? TranscriptPreviewFallbackPolicyProviding)?.allowsTranscriptPreviewFallback ?? true
            guard allowsChunked else {
                restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId)
                return nil
            }

            let capturedPlugin = plugin
            let capturedLanguage = runtimeSelection.requestedLanguage
            let capturedTranslate = task == .translate
            let capturedPrompt = prompt

            let transcribeChunk: UniversalChunkedLiveSession.ChunkTranscriber = { samples in
                let audio = await Self.makeAudioData(from: samples)
                return try await capturedPlugin.transcribe(
                    audio: audio,
                    language: capturedLanguage,
                    translate: capturedTranslate,
                    prompt: capturedPrompt
                )
            }

            let session = UniversalChunkedLiveSession(
                transcribeChunk: transcribeChunk,
                onProgress: onProgress
            )

            return LiveTranscriptionSessionHandle(
                providerId: providerId,
                session: session,
                cloudModelOverridePlugin: overrideRestoreId == nil ? nil : plugin,
                cloudModelOverrideRestoreId: overrideRestoreId
            )
        }

        let session: any LiveTranscriptionSession
        do {
            if !runtimeSelection.languageHints.isEmpty,
               let hintPlugin = livePlugin as? LiveLanguageHintTranscriptionCapablePlugin {
                session = try await hintPlugin.createLiveTranscriptionSession(
                    languageSelection: runtimeSelection,
                    translate: task == .translate,
                    prompt: prompt,
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
        normalizeNumbers: Bool? = nil
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
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
            prompt: prompt
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
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
              plugin.isConfigured else { return }

        scheduleAutoUnloadIfNeeded(for: plugin)
    }

    func scheduleAutoUnloadIfNeeded(for plugin: any TypeWhisperPlugin) {
        guard let nsPlugin = plugin as? NSObject else { return }
        let key = ObjectIdentifier(nsPlugin)

        autoUnloadTasks[key]?.cancel()
        autoUnloadTasks[key] = nil
        autoUnloadTargets[key] = nil

        let seconds = autoUnloadSeconds
        guard seconds != 0 else { return }

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

    func cancelAutoUnloadTimer() {
        for task in autoUnloadTasks.values {
            task.cancel()
        }
        autoUnloadTasks.removeAll()
        autoUnloadTargets.removeAll()
    }

    private func performAutoUnload(for key: ObjectIdentifier) {
        defer {
            autoUnloadTasks[key] = nil
            autoUnloadTargets[key] = nil
        }

        guard let nsPlugin = autoUnloadTargets[key]?.plugin else { return }
        let sel = NSSelectorFromString("triggerAutoUnload")
        guard nsPlugin.responds(to: sel) else { return }
        nsPlugin.perform(sel)
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
        prompt: String?
    ) async throws -> PluginStructuredTranscriptionResult {
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
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginStructuredTranscriptionResult {
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
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginStructuredTranscriptionResult {
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
            await triggerRestoreModel(plugin)
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
    private func triggerRestoreModel(_ plugin: TranscriptionEnginePlugin) async {
        guard let nsPlugin = plugin as? NSObject,
              nsPlugin.responds(to: NSSelectorFromString("triggerRestoreModel")) else { return }
        _ = nsPlugin.perform(NSSelectorFromString("triggerRestoreModel"))
        _ = await waitForPluginConfigured(plugin)
    }

    private func waitForPluginConfigured(
        _ plugin: TranscriptionEnginePlugin,
        selectedModelId: String? = nil,
        stopOnMismatchedSelection: Bool = false
    ) async -> Bool {
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(100))
            guard plugin.isConfigured else { continue }
            guard let selectedModelId else { return true }
            let currentModelId = plugin.selectedModelId
            if currentModelId == selectedModelId { return true }
            if stopOnMismatchedSelection, currentModelId != nil { return false }
        }
        return false
    }
}
