import Foundation
import SwiftUI
import WhisperKit
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(WhisperKitPlugin)
final class WhisperKitPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, DictionaryTermsBudgetProviding, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.whisperkit"
    static let pluginName = "WhisperKit"
    private static let maxConditioningPromptChars = 500
    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let modelEndpoint = "https://huggingface.co"

    fileprivate var host: HostServices?
    fileprivate var whisperKit: WhisperKit?
    fileprivate var loadedModelId: String?
    fileprivate var _selectedModelId: String?
    fileprivate var _hfToken: String?
    fileprivate var modelState: WhisperModelState = .notLoaded
    fileprivate var downloadProgress: Double = 0

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)
        if let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String,
           !persistedLoadedModel.isEmpty {
            if _selectedModelId == nil {
                _selectedModelId = persistedLoadedModel
                host.setUserDefault(persistedLoadedModel, forKey: "selectedModel")
            }
        }
        Task { await restoreLoadedModel(allowDownloads: false) }
    }

    func deactivate() {
        releaseWhisperKitResources()
        whisperKit = nil
        loadedModelId = nil
        modelState = .notLoaded
        downloadProgress = 0
        _hfToken = nil
        host = nil
    }

    private func releaseWhisperKitResources() {
        guard let whisperKit else { return }

        // Release Core ML submodels and callbacks explicitly instead of relying
        // solely on WhisperKit deallocation to eventually tear them down.
        autoreleasepool {
            whisperKit.modelStateCallback = nil
            whisperKit.segmentDiscoveryCallback = nil
            whisperKit.transcriptionStateCallback = nil
            whisperKit.tokenizer = nil
            whisperKit.voiceActivityDetector = nil
            whisperKit.clearState()
            (whisperKit.featureExtractor as? WhisperMLModel)?.unloadModel()
            (whisperKit.audioEncoder as? WhisperMLModel)?.unloadModel()
            (whisperKit.textDecoder as? WhisperMLModel)?.unloadModel()
        }
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
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: Self.maxConditioningPromptChars) }

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
                let sanitizedText = Self.sanitizedStreamingText(
                    progress.text,
                    conditioningPrompt: effectivePrompt
                )
                let shouldContinue = onProgress(sanitizedText)
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

    static func conditioningPrompt(from prompt: String?) -> String? {
        guard let prompt = clampedPrompt(prompt, maxLength: maxConditioningPromptChars) else { return nil }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        // WhisperKit reacts badly to a bare comma-separated term list as decoder prompt.
        // Convert the legacy transport format into a softer natural-language context line.
        let terms = PluginDictionaryTerms.terms(fromPrompt: trimmedPrompt)
        if !terms.isEmpty && Self.looksLikePlainTermList(trimmedPrompt, terms: terms) {
            let prefix = "The audio may contain these names or technical terms: "
            let suffix = "."
            let availableTermChars = max(0, maxConditioningPromptChars - prefix.count - suffix.count)
            guard let termPrompt = PluginDictionaryTerms.prompt(from: terms, maxLength: availableTermChars) else {
                return nil
            }
            return prefix + termPrompt + suffix
        }

        return trimmedPrompt
    }

    static func sanitizedStreamingText(_ text: String, conditioningPrompt: String?) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        guard let conditioningPrompt = conditioningPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !conditioningPrompt.isEmpty,
              let promptRange = trimmedText.range(
                  of: conditioningPrompt,
                  options: [.anchored, .caseInsensitive, .diacriticInsensitive]
              ) else {
            return trimmedText
        }

        return String(trimmedText[promptRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clampedPrompt(_ prompt: String?, maxLength: Int) -> String? {
        guard let prompt else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
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
            let modelPath = resolvedModelPath(for: modelDef)

            let modelFolder: URL
            if isUsableDownloadedModel(at: modelPath) {
                modelState = .loading(phase: "loading")
                downloadProgress = 0.80
                modelFolder = modelPath
            } else {
                removeIncompleteModelIfNeeded(at: modelPath)
                modelState = .downloading
                downloadProgress = 0.05

                var lastProgress = 0.0
                modelFolder = try await WhisperKit.download(
                    variant: modelDef.id,
                    downloadBase: downloadBase,
                    token: _hfToken
                ) { progress in
                    let fraction = progress.fractionCompleted
                    let mapped = 0.05 + fraction * 0.75
                    guard mapped - lastProgress >= 0.01 else { return }
                    lastProgress = mapped
                    self.downloadProgress = mapped
                }
            }
            try await repairDownloadedModelIfNeeded(at: modelFolder, variant: modelDef.id)

            // Load
            modelState = .loading(phase: "loading")
            downloadProgress = 0.80

            let config = WhisperKitConfig(
                downloadBase: downloadBase,
                modelToken: _hfToken,
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
            releaseWhisperKitResources()
            whisperKit = nil
            loadedModelId = nil
            modelState = .error(error.localizedDescription)
            downloadProgress = 0
            host?.setUserDefault(nil, forKey: "loadedModel")
            host?.notifyCapabilitiesChanged()
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        releaseWhisperKitResources()
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
        return isUsableDownloadedModel(at: modelPath)
    }

    private func isUsableDownloadedModel(at modelPath: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelPath.path) else { return false }

        let requiredRootFiles = [
            "config.json",
            "generation_config.json",
        ]
        guard requiredRootFiles.allSatisfy({ fileManager.fileExists(atPath: modelPath.appendingPathComponent($0).path) }) else {
            return false
        }

        let requiredModelNames = [
            "MelSpectrogram",
            "AudioEncoder",
            "TextDecoder",
        ]

        return requiredModelNames.allSatisfy { name in
            let compiled = modelPath.appendingPathComponent("\(name).mlmodelc")
            let package = modelPath.appendingPathComponent("\(name).mlpackage")
            return isUsableCompiledModel(at: compiled) || fileManager.fileExists(atPath: package.path)
        }
    }

    private func isUsableCompiledModel(at compiledPath: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: compiledPath.path) else { return false }

        let componentName = compiledPath.deletingPathExtension().lastPathComponent
        let requiredCompiledFiles = requiredCompiledFiles(for: componentName)

        return requiredCompiledFiles.allSatisfy {
            fileManager.fileExists(atPath: compiledPath.appendingPathComponent($0).path)
        }
    }

    private func repairDownloadedModelIfNeeded(at modelPath: URL, variant: String) async throws {
        let missingFiles = requiredModelFiles(at: modelPath)
            .filter { !FileManager.default.fileExists(atPath: modelPath.appendingPathComponent($0).path) }

        guard !missingFiles.isEmpty else { return }

        for relativePath in missingFiles {
            try await downloadModelFile(
                variant: variant,
                relativePath: relativePath,
                destination: modelPath.appendingPathComponent(relativePath)
            )
        }
    }

    private func requiredModelFiles(at modelPath: URL) -> [String] {
        let requiredComponents = Set(["MelSpectrogram", "AudioEncoder", "TextDecoder"])
        let existingComponents = (try? FileManager.default.contentsOfDirectory(at: modelPath, includingPropertiesForKeys: nil))
            .map { urls in
                urls
                    .filter { $0.pathExtension == "mlmodelc" }
                    .map { $0.deletingPathExtension().lastPathComponent }
            } ?? []

        let componentNames = Array(requiredComponents.union(existingComponents)).sorted()

        var files = [
            "config.json",
            "generation_config.json",
        ]

        for componentName in componentNames {
            for suffix in requiredCompiledFiles(for: componentName) {
                files.append("\(componentName).mlmodelc/\(suffix)")
            }
        }

        return files
    }

    private func requiredCompiledFiles(for componentName: String) -> [String] {
        var files = [
            "metadata.json",
            "model.mil",
            "coremldata.bin",
            "analytics/coremldata.bin",
            "weights/weight.bin",
        ]

        if componentName == "AudioEncoder" || componentName == "TextDecoder" {
            files.append("model.mlmodel")
        }

        return files
    }

    private func downloadModelFile(
        variant: String,
        relativePath: String,
        destination: URL
    ) async throws {
        var url = URL(string: Self.modelEndpoint)!
        for component in Self.modelRepo.split(separator: "/") {
            url.append(path: String(component))
        }
        url.append(path: "resolve")
        url.append(path: "main")
        url.append(path: variant)
        for component in relativePath.split(separator: "/") {
            url.append(path: String(component))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        if let token = _hfToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (temporaryFile, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryFile, to: destination)
    }

    private func removeIncompleteModelIfNeeded(at modelPath: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: modelPath.path), !isUsableDownloadedModel(at: modelPath) else { return }
        try? fileManager.removeItem(at: modelPath)
    }

    /// Migrate models from old location (TypeWhisper/models/) to plugin data directory
    private func migrateOldModels(for modelDef: WhisperModelDef) {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let destination = resolvedModelPath(for: modelDef)
        if isUsableDownloadedModel(at: destination) {
            return
        }
        removeIncompleteModelIfNeeded(at: destination)

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
                guard isUsableDownloadedModel(at: oldPath) else { continue }
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

    func setHuggingFaceToken(_ token: String) {
        _hfToken = PluginHuggingFaceTokenHelper.saveToken(token, to: host)
    }

    func clearHuggingFaceToken() {
        _hfToken = nil
        PluginHuggingFaceTokenHelper.clearToken(from: host)
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> Bool {
        await PluginHuggingFaceTokenHelper.validateToken(token, dataFetcher: dataFetcher)
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

struct WhisperKitSettingsPollState: Equatable {
    var modelState: WhisperModelState
    var downloadProgress: Double
    var activeModelId: String?
    var isPolling: Bool

    var isBusy: Bool {
        switch modelState {
        case .downloading, .loading:
            return true
        case .notLoaded, .ready, .error:
            return false
        }
    }

    func applyingPolledPluginState(
        _ pluginState: WhisperModelState,
        downloadProgress: Double,
        selectedModelId: String?
    ) -> WhisperKitSettingsPollState {
        var updated = self
        updated.modelState = pluginState
        updated.downloadProgress = downloadProgress

        switch pluginState {
        case .ready:
            updated.activeModelId = selectedModelId ?? updated.activeModelId
            updated.isPolling = false
        case .downloading, .loading:
            updated.isPolling = true
        case .notLoaded, .error:
            updated.activeModelId = selectedModelId ?? updated.activeModelId
            updated.isPolling = false
        }

        return updated
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
    @State private var hfTokenInput = ""
    @State private var showHfToken = false
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?

    private let pollTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin._hfToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool {
        !storedHfToken.isEmpty
    }

    private var normalizedPluginModelState: WhisperModelState {
        switch plugin.modelState {
        case .downloading, .loading, .error:
            return plugin.modelState
        case .ready:
            return (plugin.whisperKit != nil && plugin.loadedModelId != nil) ? plugin.modelState : .notLoaded
        case .notLoaded:
            return .notLoaded
        }
    }

    private var persistedLoadedModelId: String? {
        plugin.host?.userDefault(forKey: "loadedModel") as? String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WhisperKit", bundle: bundle)
                .font(.headline)

            Text("Local speech-to-text using OpenAI Whisper via CoreML. 99+ languages, streaming, translation to English.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("HuggingFace Token", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Optional. Increases download rate limits. Free at huggingface.co/settings/tokens", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    if showHfToken {
                        TextField("hf_...", text: $hfTokenInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("hf_...", text: $hfTokenInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showHfToken.toggle()
                    } label: {
                        Image(systemName: showHfToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if hasStoredHfToken {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            hfTokenInput = ""
                            tokenValidationResult = nil
                            isValidatingToken = false
                            plugin.clearHuggingFaceToken()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSaveHuggingFaceToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)
                }

                if isValidatingToken {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating token...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let tokenValidationResult {
                    HStack(spacing: 4) {
                        Image(systemName: tokenValidationResult ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tokenValidationResult ? .green : .red)
                        Text(
                            tokenValidationResult
                                ? String(localized: "Valid HuggingFace Token", bundle: bundle)
                                : String(localized: "Invalid HuggingFace Token", bundle: bundle)
                        )
                        .font(.caption)
                        .foregroundStyle(tokenValidationResult ? .green : .red)
                    }
                }
            }

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
            modelState = normalizedPluginModelState
            downloadProgress = plugin.downloadProgress
            activeModelId = plugin._selectedModelId
            if let token = plugin._hfToken, !token.isEmpty {
                hfTokenInput = token
            }
            isPolling = WhisperKitSettingsPollState(
                modelState: normalizedPluginModelState,
                downloadProgress: plugin.downloadProgress,
                activeModelId: plugin._selectedModelId,
                isPolling: false
            ).isBusy

            if plugin.whisperKit == nil,
               plugin.loadedModelId == nil,
               plugin.modelState == .notLoaded,
               let persistedLoadedModelId,
               !persistedLoadedModelId.isEmpty {
                activeModelId = persistedLoadedModelId
                modelState = .loading(phase: "loading")
                isPolling = true
                Task {
                    await plugin.restoreLoadedModel(allowDownloads: false)
                    syncViewStateFromPlugin()
                }
            }
        }
        .onReceive(pollTimer) { _ in
            let updatedState = WhisperKitSettingsPollState(
                modelState: modelState,
                downloadProgress: downloadProgress,
                activeModelId: activeModelId,
                isPolling: isPolling
            ).applyingPolledPluginState(
                normalizedPluginModelState,
                downloadProgress: plugin.downloadProgress,
                selectedModelId: plugin._selectedModelId
            )

            modelState = updatedState.modelState
            downloadProgress = updatedState.downloadProgress
            activeModelId = updatedState.activeModelId
            isPolling = updatedState.isPolling
        }
        .onChange(of: hfTokenInput) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue != storedHfToken {
                tokenValidationResult = nil
            }
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
        let isDownloaded = plugin.isModelDownloaded(modelDef)
        let viewState = WhisperKitSettingsPollState(
            modelState: modelState,
            downloadProgress: downloadProgress,
            activeModelId: activeModelId,
            isPolling: isPolling
        )

        if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button(String(localized: "Unload", bundle: bundle)) {
                    plugin.unloadModel()
                    syncViewStateFromPlugin()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(String(localized: "Remove", bundle: bundle), role: .destructive) {
                    removeDownloadedModel(modelDef)
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
            HStack(spacing: 8) {
                Button(
                    isDownloaded
                        ? String(localized: "Load", bundle: bundle)
                        : String(localized: "Download & Load", bundle: bundle)
                ) {
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
                .disabled(viewState.isBusy)

                if isDownloaded {
                    Button(String(localized: "Remove", bundle: bundle), role: .destructive) {
                        removeDownloadedModel(modelDef)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewState.isBusy)
                }
            }
        }
    }

    private func syncViewStateFromPlugin() {
        modelState = normalizedPluginModelState
        downloadProgress = plugin.downloadProgress
        activeModelId = plugin._selectedModelId
        isPolling = false
    }

    private func removeDownloadedModel(_ modelDef: WhisperModelDef) {
        if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
            plugin.unloadModel()
        }
        plugin.deleteModelFiles(modelDef)
        syncViewStateFromPlugin()
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

    private func validateAndSaveHuggingFaceToken() {
        let trimmedToken = trimmedHfTokenInput
        guard !trimmedToken.isEmpty else { return }

        isValidatingToken = true
        tokenValidationResult = nil

        Task {
            let isValid = await plugin.validateHuggingFaceToken(trimmedToken)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    plugin.setHuggingFaceToken(trimmedToken)
                    hfTokenInput = trimmedToken
                }
            }
        }
    }
}
