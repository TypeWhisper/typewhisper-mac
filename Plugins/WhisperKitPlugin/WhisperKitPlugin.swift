import Foundation
import SwiftUI
import WhisperKit
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(WhisperKitPlugin)
final class WhisperKitPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.whisperkit"
    static let pluginName = "WhisperKit"

    fileprivate var host: HostServices?
    fileprivate var whisperKit: WhisperKit?
    fileprivate var loadedModelId: String?
    fileprivate var _selectedModelId: String?
    fileprivate var modelState: WhisperModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
        Task { await restoreLoadedModel(allowDownloads: false) }
    }

    func deactivate() {
        whisperKit = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "whisper" }
    var providerDisplayName: String { "WhisperKit" }

    var isConfigured: Bool {
        whisperKit != nil && loadedModelId != nil
    }

    var transcriptionModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return Self.availableModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName, sizeDescription: $0.sizeDescription, languageCount: 99) }
    }

    var availableModels: [PluginModelInfo] {
        Self.availableModels.map { def in
            PluginModelInfo(
                id: def.id,
                displayName: def.displayName,
                sizeDescription: def.sizeDescription,
                languageCount: 99,
                loaded: def.id == loadedModelId
            )
        }
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { true }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }

    var supportedLanguages: [String] {
        [
            "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
            "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
            "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
            "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
            "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
            "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
            "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
            "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
            "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
            "tr", "tt", "uk", "ur", "uz", "vi", "vo", "yi", "yo", "yue",
            "zh",
        ]
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let whisperKit else {
            throw PluginTranscriptionError.notConfigured
        }

        var options = DecodingOptions(
            verbose: false,
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        let effectivePrompt = Self.conditioningPrompt(from: prompt)
        if let tokenizer = whisperKit.tokenizer,
           let promptTokens = Self.promptTokens(from: effectivePrompt, tokenizer: tokenizer) {
            options.promptTokens = promptTokens
            options.usePrefillPrompt = true
        }

        let results = try await whisperKit.transcribe(
            audioArray: audio.samples,
            decodeOptions: options
        )

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = results.first?.language
        let segments = results.flatMap { $0.segments }.map {
            PluginTranscriptionSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage, segments: segments)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        guard let whisperKit else {
            throw PluginTranscriptionError.notConfigured
        }

        var options = DecodingOptions(
            verbose: false,
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            chunkingStrategy: .vad
        )
        let effectivePrompt = Self.conditioningPrompt(from: prompt)
        if let tokenizer = whisperKit.tokenizer,
           let promptTokens = Self.promptTokens(from: effectivePrompt, tokenizer: tokenizer) {
            options.promptTokens = promptTokens
            options.usePrefillPrompt = true
        }

        let results = try await whisperKit.transcribe(
            audioArray: audio.samples,
            decodeOptions: options,
            callback: { progress in
                let shouldContinue = onProgress(progress.text)
                return shouldContinue ? nil : false
            }
        )

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = results.first?.language
        let segments = results.flatMap { $0.segments }.map {
            PluginTranscriptionSegment(text: $0.text, start: Double($0.start), end: Double($0.end))
        }

        return PluginTranscriptionResult(text: text, detectedLanguage: detectedLanguage, segments: segments)
    }

    private static func promptTokens(from prompt: String?, tokenizer: WhisperTokenizer) -> [Int]? {
        guard let prompt, !prompt.isEmpty else { return nil }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        let encoded = tokenizer.encode(text: " " + trimmedPrompt)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return encoded.isEmpty ? nil : encoded
    }

    private static func conditioningPrompt(from prompt: String?) -> String? {
        guard let prompt else { return nil }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        // WhisperKit reacts badly to a bare comma-separated term list as decoder prompt.
        // Convert the legacy transport format into a softer natural-language context line.
        let terms = PluginDictionaryTerms.terms(fromPrompt: trimmedPrompt)
        if !terms.isEmpty && Self.looksLikePlainTermList(trimmedPrompt, terms: terms) {
            return "The audio may contain these names or technical terms: \(terms.joined(separator: ", "))."
        }

        return trimmedPrompt
    }

    private static func looksLikePlainTermList(_ prompt: String, terms: [String]) -> Bool {
        let normalizedPrompt = prompt
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedPrompt.isEmpty, normalizedPrompt.count == terms.count else { return false }

        return zip(normalizedPrompt, terms).allSatisfy { raw, parsed in
            raw.compare(parsed, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: .current) == .orderedSame
        }
    }

    // MARK: - Model Management

    fileprivate var downloadBase: URL {
        host?.pluginDataDirectory.appendingPathComponent("models")
            ?? FileManager.default.temporaryDirectory
    }

    private var modelStorageRoots: [URL] {
        [
            downloadBase
                .appendingPathComponent("models")
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml"),
            downloadBase
                .appendingPathComponent("argmaxinc")
                .appendingPathComponent("whisperkit-coreml"),
        ]
    }

    private func resolvedModelPath(for modelDef: WhisperModelDef) -> URL {
        let fileManager = FileManager.default
        for root in modelStorageRoots {
            let candidate = root.appendingPathComponent(modelDef.id)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return modelStorageRoots[0].appendingPathComponent(modelDef.id)
    }

    fileprivate func loadModel(_ modelDef: WhisperModelDef) async {
        do {
            // Migrate old models if they exist
            migrateOldModels(for: modelDef)

            let modelFolder: URL
            if isModelDownloaded(modelDef) {
                modelState = .loading(phase: "loading")
                downloadProgress = 0.80
                modelFolder = resolvedModelPath(for: modelDef)
            } else {
                modelState = .downloading
                downloadProgress = 0.05

                var lastProgress = 0.0
                modelFolder = try await WhisperKit.download(
                    variant: modelDef.id,
                    downloadBase: downloadBase
                ) { progress in
                    let fraction = progress.fractionCompleted
                    let mapped = 0.05 + fraction * 0.75
                    guard mapped - lastProgress >= 0.01 else { return }
                    lastProgress = mapped
                    self.downloadProgress = mapped
                }
            }

            // Load
            modelState = .loading(phase: "loading")
            downloadProgress = 0.80

            let config = WhisperKitConfig(
                downloadBase: downloadBase,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: false,
                download: false
            )

            let kit = try await WhisperKit(config)

            kit.modelStateCallback = { [weak self] _, newState in
                switch newState {
                case .loading:
                    self?.modelState = .loading(phase: "loading")
                case .prewarming:
                    self?.modelState = .loading(phase: "prewarming")
                default:
                    break
                }
            }

            try await kit.loadModels()
            downloadProgress = 0.90
            try await kit.prewarmModels()

            whisperKit = kit
            loadedModelId = modelDef.id
            _selectedModelId = modelDef.id
            downloadProgress = 1.0
            modelState = .ready(modelDef.id)

            host?.setUserDefault(modelDef.id, forKey: "selectedModel")
            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            host?.notifyCapabilitiesChanged()
        } catch {
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        whisperKit = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    fileprivate func deleteModelFiles(_ modelDef: WhisperModelDef) {
        let modelPath = resolvedModelPath(for: modelDef)
        try? FileManager.default.removeItem(at: modelPath)
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.availableModels.first(where: { $0.id == savedId }) else {
            return
        }
        guard allowDownloads || isModelDownloaded(modelDef) else { return }
        await loadModel(modelDef)
    }

    fileprivate func isModelDownloaded(_ modelDef: WhisperModelDef) -> Bool {
        let modelPath = resolvedModelPath(for: modelDef)
        return FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Migrate models from old location (TypeWhisper/models/) to plugin data directory
    private func migrateOldModels(for modelDef: WhisperModelDef) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let destination = resolvedModelPath(for: modelDef)
        if fm.fileExists(atPath: destination.path) {
            return
        }

        // Check both production and dev paths
        for dirName in ["TypeWhisper", "TypeWhisper-Dev"] {
            let legacyRoots = [
                appSupport
                    .appendingPathComponent(dirName)
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent("whisperkit-coreml"),
                appSupport
                    .appendingPathComponent(dirName)
                    .appendingPathComponent("models")
                    .appendingPathComponent("models")
                    .appendingPathComponent("argmaxinc")
                    .appendingPathComponent("whisperkit-coreml"),
            ]

            for legacyRoot in legacyRoots {
                let oldPath = legacyRoot.appendingPathComponent(modelDef.id)
                guard fm.fileExists(atPath: oldPath.path) else { continue }
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: oldPath, to: destination)
                if fm.fileExists(atPath: destination.path) {
                    return
                }
            }
        }
    }

    // MARK: - Settings View

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(
                message: "Downloading model",
                progress: downloadProgress
            )
        case .loading(let phase):
            let message: String
            switch phase {
            case "prewarming":
                message = "Optimizing model"
            case "loading":
                message = "Loading model"
            default:
                message = "Preparing model"
            }
            return PluginSettingsActivity(message: message)
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    var settingsView: AnyView? {
        AnyView(WhisperKitSettingsView(plugin: self))
    }

    // MARK: - Model Definitions

    static let availableModels: [WhisperModelDef] = [
        WhisperModelDef(
            id: "openai_whisper-tiny",
            displayName: "Tiny",
            sizeDescription: "~39 MB",
            ramRequirement: "4 GB+"
        ),
        WhisperModelDef(
            id: "openai_whisper-base",
            displayName: "Base",
            sizeDescription: "~74 MB",
            ramRequirement: "4 GB+"
        ),
        WhisperModelDef(
            id: "openai_whisper-small",
            displayName: "Small",
            sizeDescription: "~244 MB",
            ramRequirement: "8 GB+"
        ),
        WhisperModelDef(
            id: "openai_whisper-medium",
            displayName: "Medium",
            sizeDescription: "~1.5 GB",
            ramRequirement: "8 GB+"
        ),
        WhisperModelDef(
            id: "openai_whisper-large-v3",
            displayName: "Large v3",
            sizeDescription: "~1.5 GB",
            ramRequirement: "16 GB+"
        ),
        WhisperModelDef(
            id: "openai_whisper-large-v3_turbo",
            displayName: "Large v3 Turbo",
            sizeDescription: "~800 MB",
            ramRequirement: "8 GB+"
        ),
        WhisperModelDef(
            id: "distil-whisper_distil-large-v3",
            displayName: "Distil Large v3",
            sizeDescription: "~594 MB",
            ramRequirement: "8 GB+"
        ),
    ]
}

// MARK: - Model Types

struct WhisperModelDef: Identifiable {
    let id: String
    let displayName: String
    let sizeDescription: String
    let ramRequirement: String

    var isRecommended: Bool {
        let ram = ProcessInfo.processInfo.physicalMemory
        let gb = ram / (1024 * 1024 * 1024)

        switch displayName {
        case "Tiny", "Base":
            return gb < 8
        case "Small", "Medium", "Large v3 Turbo":
            return gb >= 8 && gb <= 16
        case "Large v3":
            return gb > 16
        default:
            return false
        }
    }
}

enum WhisperModelState: Equatable {
    case notLoaded
    case downloading
    case loading(phase: String)
    case ready(String)
    case error(String)

    static func == (lhs: WhisperModelState, rhs: WhisperModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.downloading, .downloading): true
        case let (.loading(a), .loading(b)): a == b
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}

// MARK: - Settings View

private struct WhisperKitSettingsView: View {
    let plugin: WhisperKitPlugin
    private let bundle = Bundle(for: WhisperKitPlugin.self)
    @State private var modelState: WhisperModelState = .notLoaded
    @State private var downloadProgress: Double = 0
    @State private var activeModelId: String?
    @State private var isPolling = false

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WhisperKit", bundle: bundle)
                .font(.headline)

            Text("Local speech-to-text using OpenAI Whisper via CoreML. 99+ languages, streaming, translation to English.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Models", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(WhisperKitPlugin.availableModels) { modelDef in
                    modelRow(modelDef)
                }
            }

            if case .error(let message) = modelState {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding()
        .onAppear {
            modelState = plugin.modelState
            downloadProgress = plugin.downloadProgress
            activeModelId = plugin._selectedModelId
            // If the plugin is mid-load (e.g., restoring on app launch), start polling
            if case .downloading = plugin.modelState { isPolling = true }
            else if case .loading = plugin.modelState { isPolling = true }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            downloadProgress = plugin.downloadProgress
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState

                switch pluginState {
                case .ready:
                    activeModelId = plugin._selectedModelId ?? activeModelId
                case .downloading, .loading:
                    break
                case .notLoaded, .error:
                    activeModelId = plugin._selectedModelId ?? activeModelId
                }
            }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
    }

    @ViewBuilder
    private func modelRow(_ modelDef: WhisperModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(modelDef.displayName)
                        .font(.body)
                    if modelDef.isRecommended {
                        Text("Recommended", bundle: bundle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            modelStatusView(modelDef)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func modelStatusView(_ modelDef: WhisperModelDef) -> some View {
        if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(String(localized: "Unload", bundle: bundle)) {
                    plugin.unloadModel()
                    plugin.deleteModelFiles(modelDef)
                    modelState = plugin.modelState
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if case .downloading = modelState, activeModelId == modelDef.id {
            HStack(spacing: 8) {
                ProgressView(value: downloadProgress)
                    .frame(width: 80)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
            }
        } else if case .loading(let phase) = modelState, activeModelId == modelDef.id {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(phaseText(phase))
                    .font(.caption)
            }
        } else {
            Button(String(localized: "Download & Load", bundle: bundle)) {
                activeModelId = modelDef.id
                modelState = .downloading
                downloadProgress = 0.05
                isPolling = true
                Task {
                    await plugin.loadModel(modelDef)
                    isPolling = false
                    modelState = plugin.modelState
                    downloadProgress = plugin.downloadProgress
                    activeModelId = plugin._selectedModelId
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(modelState == .downloading || modelState == .loading(phase: "loading"))
        }
    }

    private func phaseText(_ phase: String) -> String {
        switch phase {
        case "prewarming":
            String(localized: "Optimizing for Neural Engine...", bundle: bundle)
        case "loading":
            String(localized: "Loading model...", bundle: bundle)
        default:
            String(localized: "Loading...", bundle: bundle)
        }
    }
}
