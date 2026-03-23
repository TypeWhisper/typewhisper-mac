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

@MainActor
final class ModelManagerService: ObservableObject {
    @Published private(set) var selectedProviderId: String?

    @Published var autoUnloadSeconds: Int {
        didSet {
            UserDefaults.standard.set(autoUnloadSeconds, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            scheduleAutoUnloadIfNeeded()
        }
    }

    private var autoUnloadTask: Task<Void, Never>?

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

    /// True when a model is ready or can be auto-restored (was auto-unloaded but provider exists).
    var canTranscribe: Bool {
        guard let providerId = selectedProviderId else { return false }
        let plugin = PluginManager.shared.transcriptionEngine(for: providerId)
        if plugin?.isConfigured == true { return true }
        // Auto-unloaded models can be restored if auto-unload is active
        return autoUnloadSeconds != 0 && plugin != nil
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

    var activeModelName: String? {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
              let selectedId = plugin.selectedModelId,
              let model = plugin.transcriptionModels.first(where: { $0.id == selectedId }) else { return nil }
        return model.displayName
    }

    func selectProvider(_ providerId: String) {
        selectedProviderId = providerId
        UserDefaults.standard.set(providerId, forKey: providerKey)
    }

    func selectModel(_ providerId: String, modelId: String) {
        selectProvider(providerId)
        PluginManager.shared.transcriptionEngine(for: providerId)?.selectModel(modelId)
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

    /// Resolve display name for a given engine/model override combination
    func resolvedModelDisplayName(engineOverrideId: String? = nil, cloudModelOverride: String? = nil) -> String? {
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return nil }

        if let modelId = cloudModelOverride,
           let model = plugin.transcriptionModels.first(where: { $0.id == modelId }) {
            return model.displayName
        }
        if let selectedId = plugin.selectedModelId,
           let model = plugin.transcriptionModels.first(where: { $0.id == selectedId }) {
            return model.displayName
        }
        return plugin.providerDisplayName
    }

    /// Re-restore provider selection after plugins have been loaded.
    func restoreProviderSelection() {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
              plugin.isConfigured else { return }
        // Plugin is loaded and ready, nothing else to do
    }

    // MARK: - Transcription

    func transcribe(
        audioSamples: [Float],
        language: String?,
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

        if !plugin.isConfigured {
            await triggerRestoreModel(plugin)
        }
        guard plugin.isConfigured else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        if let modelId = cloudModelOverride {
            plugin.selectModel(modelId)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let wavData = WavEncoder.encode(audioSamples)
        let audioDuration = Double(audioSamples.count) / 16000.0

        let audio = AudioData(
            samples: audioSamples,
            wavData: wavData,
            duration: audioDuration
        )

        let result = try await plugin.transcribe(
            audio: audio,
            language: language,
            translate: task == .translate,
            prompt: prompt
        )

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: result.segments.map { TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end) }
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
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        if !plugin.isConfigured {
            await triggerRestoreModel(plugin)
        }
        guard plugin.isConfigured else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        if let modelId = cloudModelOverride {
            plugin.selectModel(modelId)
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let wavData = WavEncoder.encode(audioSamples)
        let audioDuration = Double(audioSamples.count) / 16000.0

        let audio = AudioData(
            samples: audioSamples,
            wavData: wavData,
            duration: audioDuration
        )

        let result: PluginTranscriptionResult
        if plugin.supportsStreaming {
            result = try await plugin.transcribe(
                audio: audio,
                language: language,
                translate: task == .translate,
                prompt: prompt,
                onProgress: onProgress
            )
        } else {
            result = try await plugin.transcribe(
                audio: audio,
                language: language,
                translate: task == .translate,
                prompt: prompt
            )
            let _ = onProgress(result.text)
        }

        let processingTime = CFAbsoluteTimeGetCurrent() - startTime

        scheduleAutoUnloadIfNeeded()

        return TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: audioDuration,
            processingTime: processingTime,
            engineUsed: providerId,
            segments: result.segments.map { TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end) }
        )
    }

    // MARK: - Auto-Unload

    func scheduleAutoUnloadIfNeeded() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil

        let seconds = autoUnloadSeconds
        guard seconds != 0 else { return }

        autoUnloadTask = Task { [weak self] in
            if seconds == -1 {
                // Small delay to let transcription call stack fully unwind
                // before releasing the model (avoids EXC_BAD_ACCESS from MLX cleanup)
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            self?.performAutoUnload()
        }
    }

    func cancelAutoUnloadTimer() {
        autoUnloadTask?.cancel()
        autoUnloadTask = nil
    }

    private func performAutoUnload() {
        guard let providerId = selectedProviderId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId),
              plugin.isConfigured else { return }
        guard let nsPlugin = plugin as? NSObject else { return }
        let sel = NSSelectorFromString("triggerAutoUnload")
        guard nsPlugin.responds(to: sel) else { return }
        nsPlugin.perform(sel)
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
