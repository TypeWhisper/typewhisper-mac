import Foundation
import Combine
import TypeWhisperPluginSDK

enum TranscriptionEngineError: LocalizedError {
    case modelNotLoaded
    case unsupportedTask(String)
    case transcriptionFailed(String)
    case modelLoadFailed(String)
    case modelDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "No model loaded. Please download and select a model first."
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

        if !plugin.isConfigured {
            await triggerRestoreModel(plugin)
        }
        guard plugin.isConfigured else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let overrideRestoreId = applyCloudModelOverride(plugin: plugin, override: cloudModelOverride)
        defer { restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId) }

        guard let livePlugin = plugin as? LiveTranscriptionCapablePlugin else {
            return nil
        }

        let runtimeSelection = runtimeLanguageSelection(for: languageSelection, plugin: plugin)
        let session: any LiveTranscriptionSession
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
        return LiveTranscriptionSessionHandle(providerId: providerId, session: session)
    }

    func finishLiveTranscriptionSession(
        _ handle: LiveTranscriptionSessionHandle,
        bufferedDuration: Double
    ) async throws -> TranscriptionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await handle.session.finish()
        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: bufferedDuration,
            processingTime: processingTime,
            engineUsed: handle.providerId,
            segments: Self.transcriptionSegments(from: result.segments)
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil
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

        if !plugin.isConfigured {
            await triggerRestoreModel(plugin)
        }
        guard plugin.isConfigured else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let overrideRestoreId = applyCloudModelOverride(plugin: plugin, override: cloudModelOverride)
        defer { restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId) }

        let startTime = CFAbsoluteTimeGetCurrent()
        let audio = await Self.makeAudioData(from: audioSamples)

        let result = try await transcribeWithResolvedLanguageSelection(
            plugin: plugin,
            audio: audio,
            languageSelection: runtimeLanguageSelection(for: languageSelection, plugin: plugin),
            task: task,
            prompt: prompt
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: audio.duration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: Self.transcriptionSegments(from: result.segments)
        )
    }

    func transcribe(
        audioSamples: [Float],
        language: String?,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: audioSamples,
            languageSelection: language.map(LanguageSelection.exact) ?? .auto,
            task: task,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            prompt: prompt,
            onProgress: onProgress
        )
    }

    func transcribe(
        audioSamples: [Float],
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        engineOverrideId: String? = nil,
        cloudModelOverride: String? = nil,
        prompt: String? = nil,
        onProgress: @Sendable @escaping (String) -> Bool
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

        if !plugin.isConfigured {
            await triggerRestoreModel(plugin)
        }
        guard plugin.isConfigured else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let overrideRestoreId = applyCloudModelOverride(plugin: plugin, override: cloudModelOverride)
        defer { restoreCloudModelOverride(plugin: plugin, previousId: overrideRestoreId) }

        let startTime = CFAbsoluteTimeGetCurrent()
        let audio = await Self.makeAudioData(from: audioSamples)

        let result = try await transcribeWithResolvedLanguageSelection(
            plugin: plugin,
            audio: audio,
            languageSelection: runtimeLanguageSelection(for: languageSelection, plugin: plugin),
            task: task,
            prompt: prompt,
            onProgress: onProgress
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: audio.duration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: Self.transcriptionSegments(from: result.segments)
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

    /// Trigger model restore via ObjC dispatch (avoids Swift protocol witness table issues
    /// with dynamically loaded plugin bundles) and poll until ready.
    private func triggerRestoreModel(_ plugin: TranscriptionEnginePlugin) async {
        guard let nsPlugin = plugin as? NSObject,
              nsPlugin.responds(to: NSSelectorFromString("triggerRestoreModel")) else { return }
        nsPlugin.perform(NSSelectorFromString("triggerRestoreModel"))
        // Poll until model is loaded (up to 30s)
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(100))
            if plugin.isConfigured { return }
        }
    }
}
