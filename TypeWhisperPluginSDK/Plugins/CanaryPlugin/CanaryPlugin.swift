import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXNN
import MLXAudioCore
import MLXAudioSTT
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(CanaryPlugin)
final class CanaryPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, PluginCustomModelImporting, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PassiveModelRestoreProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.canary"
    static let pluginName = "Canary Speech"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var model: CanaryModel?
    fileprivate var loadedModelId: String?
    private let activationLock = NSRecursiveLock()
    private var _activationID = UUID()
    private var activationID: UUID {
        get { activationLock.withLock { _activationID } }
        set { activationLock.withLock { _activationID = newValue } }
    }
    @MainActor private var isImportingModel = false
    fileprivate var _hfToken: String?

    fileprivate var modelState: CanaryModelState = .notLoaded

    private static let modelRequirements = PluginHuggingFaceModelStore.Requirements(
        requiredFiles: ["config.json"],
        alternativeFileGroups: [["tokenizer.model"], ["tokenizer.json"]],
        weightFileExtensions: ["safetensors"]
    )
    private static let modelDownloadPatterns = ["*.safetensors", "*.json", "*.txt", "*.model"]

    private let passiveRestoreController = PluginPassiveModelRestoreController()
    let modelLoadGate = PluginLocalInferenceGate()
    private var _explicitModelLoadTask: Task<Void, Never>?
    private(set) var explicitModelLoadTask: Task<Void, Never>? {
        get { activationLock.withLock { _explicitModelLoadTask } }
        set { activationLock.withLock { _explicitModelLoadTask = newValue } }
    }
    private var _genericModelLoadTask: Task<Void, Never>?
    private(set) var genericModelLoadTask: Task<Void, Never>? {
        get { activationLock.withLock { _genericModelLoadTask } }
        set { activationLock.withLock { _genericModelLoadTask = newValue } }
    }

    func requestPassiveModelRestore() {
        passiveRestoreController.request { [weak self] in
            guard let self else { return }
            await self.restoreLoadedModel(allowDownloads: false, passively: true)
        }
    }

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        activationLock.withLock {
            activationID = UUID()
            self.host = host
            if let store = customModelStore {
                Task.detached(priority: .utility) { try? store.recoverAbandonedImports() }
            }
            _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
                ?? allModelDefinitions.first?.id
            _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)
            cleanupRedundantModelCopies()

            if shouldRestoreLoadedModelsPassively {
                requestPassiveModelRestore()
            }
        }
    }

    func deactivate() {
        activationLock.withLock {
            genericModelLoadTask?.cancel()
            genericModelLoadTask = nil
            explicitModelLoadTask?.cancel()
            explicitModelLoadTask = nil
            passiveRestoreController.cancel()
            activationID = UUID()
            model = nil
            loadedModelId = nil
            modelState = .notLoaded
            scheduleRuntimeCacheClearWhenInferenceIsIdle()
            host = nil
        }
    }

    // Imported files are owned by this plugin, separate from the built-in model cache.
    fileprivate var customModelStore: PluginCustomModelStore? {
        host.map { PluginCustomModelStore(directory: $0.pluginDataDirectory.appendingPathComponent("custom-models")) }
    }

    fileprivate var allModelDefinitions: [CanaryModelDef] {
        Self.availableModels + (customModelStore?.models() ?? []).map(Self.importedDefinition)
    }

    private static func importedDefinition(_ model: PluginCustomModelStore.Model) -> CanaryModelDef {
        CanaryModelDef(id: model.id, displayName: model.displayName, repoId: model.id,
            sizeDescription: model.sizeDescription, ramRequirement: "—")
    }

    var supportedImportModelTypes: Set<String> { ["canary"] }

    @MainActor
    func importModel(_ candidate: PluginModelImportCandidate, token: String?) async throws -> PluginModelInfo {
        guard !isImportingModel, modelState != .loading else { throw PluginModelImportError.busy }
        guard let store = customModelStore else { throw PluginTranscriptionError.notConfigured }
        isImportingModel = true
        let previousState = modelState
        let previousLoadedModelID = loadedModelId
        let previousSelectedModelID = _selectedModelId
        let previousPersistedLoadedID = host?.userDefault(forKey: "loadedModel") as? String
        let previousPersistedSelectedID = host?.userDefault(forKey: "selectedModel") as? String
        let generation = activationID
        modelState = .loading
        defer { isImportingModel = false }
        var importedID: String?
        do {
            let imported = try await store.add(candidate, supportedTypes: supportedImportModelTypes,
                requirements: Self.modelRequirements, token: token ?? _hfToken,
                validation: { [self] imported in
                    try await validateImportedModel(imported, generation: generation)
                })
            importedID = imported.id
            host?.notifyCapabilitiesChanged()
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            return PluginModelInfo(id: imported.id, displayName: imported.displayName,
                sizeDescription: imported.sizeDescription, downloaded: true, loaded: true)
        } catch {
            if let importedID { try? store.remove(importedID) }
            if generation == activationID {
                if loadedModelId != previousLoadedModelID {
                    // Validation released the old runtime or loaded a model
                    // whose files rolled back. Leave the engine unloaded.
                    model = nil
                    loadedModelId = nil
                    host?.setUserDefault(nil, forKey: "loadedModel")
                    modelState = .notLoaded
                } else {
                    host?.setUserDefault(previousPersistedLoadedID, forKey: "loadedModel")
                    modelState = previousState
                }
                _selectedModelId = previousSelectedModelID
                host?.setUserDefault(previousPersistedSelectedID, forKey: "selectedModel")
                host?.notifyCapabilitiesChanged()
            }
            throw error
        }
    }

    @MainActor
    private func validateImportedModel(_ imported: PluginCustomModelStore.Model, generation: UUID) async throws {
        try Task.checkCancellation()
        guard generation == activationID, host != nil else { throw CancellationError() }
        try await loadModel(Self.importedDefinition(imported), notifyHost: false, expectedGeneration: generation)
        guard generation == activationID, host != nil else { throw CancellationError() }
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "canary" }
    var providerDisplayName: String { "Canary Speech (MLX)" }

    var isConfigured: Bool {
        model != nil && loadedModelId != nil
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        host?.shouldRestoreLoadedModelsPassively ?? true
    }

    var transcriptionModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return allModelDefinitions
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    var availableModels: [PluginModelInfo] {
        allModelDefinitions.map { def in
            PluginModelInfo(
                id: def.id,
                displayName: def.displayName,
                sizeDescription: def.sizeDescription,
                downloaded: hasDownloadedModel(def),
                loaded: def.id == loadedModelId
            )
        }
    }

    var downloadedModels: [PluginModelInfo] {
        allModelDefinitions
            .filter { $0.id.hasPrefix("custom-") || hasDownloadedModel($0) }
            .map { def in
                PluginModelInfo(
                    id: def.id,
                    displayName: def.displayName,
                    sizeDescription: def.sizeDescription,
                    downloaded: true,
                    loaded: def.id == loadedModelId
                )
            }
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        try activationLock.withLock {
            guard modelState != .loading else { throw PluginModelImportError.busy }
            guard let modelDef = allModelDefinitions.first(where: { $0.id == modelId }) else { return }

            if _selectedModelId == modelId || host?.userDefault(forKey: "loadedModel") as? String == modelId {
                // A task queued on modelLoadGate has not set .loading yet.
                // Invalidate it before removing files it could redownload.
                activationID = UUID()
                genericModelLoadTask?.cancel()
                genericModelLoadTask = nil
                explicitModelLoadTask?.cancel()
                explicitModelLoadTask = nil
                passiveRestoreController.cancel()
            }
            if loadedModelId == modelId {
                unloadModel(clearPersistence: true)
            }
            if _selectedModelId == modelId {
                _selectedModelId = nil
                host?.setUserDefault(nil, forKey: "selectedModel")
            }
            if host?.userDefault(forKey: "loadedModel") as? String == modelId {
                host?.setUserDefault(nil, forKey: "loadedModel")
            }

            try deleteModelFiles(modelDef)
            host?.notifyCapabilitiesChanged()
        }
    }

    var supportedLanguages: [String] { CanaryConfig.defaultSupportedLanguages }


    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
    }

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .unsupported }

    func transcribe(
        audio: AudioData, language: String?, translate: Bool, prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt,
                             onProgress: { _ in true })
    }

    func transcribe(
        audio: AudioData, language: String?, translate: Bool, prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await PluginLocalInferenceGate.shared.withLock { [self] in
            guard let model else { throw PluginTranscriptionError.notConfigured }
            let sourceLanguage = try Self.sourceLanguage(language)
            guard !translate else { throw PluginTranscriptionError.apiError("Canary translation is not available in this engine.") }
            var chunks: [String] = []
            // Use the same low-energy boundary search as Qwen instead of fixed cuts.
            // Each chunk still gets its own decoding budget and bounded encoder memory.
            for chunk in Self.transcriptionChunks(audio.samples) {
                try Task.checkCancellation()
                let output = model.generate(audio: chunk, generationParameters: STTGenerateParameters(
                    maxTokens: 512, temperature: 0, language: sourceLanguage
                ))
                try Task.checkCancellation()
                guard output.generationTokens < 512 else {
                    throw PluginTranscriptionError.apiError("Canary reached its transcription limit. Retry with a shorter recording.")
                }
                let text = Self.normalizeTranscript(output.text, language: sourceLanguage)
                if !text.isEmpty { chunks.append(text) }
                guard onProgress(chunks.joined(separator: " ")) else { throw CancellationError() }
            }
            return PluginTranscriptionResult(text: chunks.joined(separator: " "), detectedLanguage: sourceLanguage)
        }
    }

    static func transcriptionChunks(_ samples: [Float]) -> [MLXArray] {
        guard !samples.isEmpty else { return [] }
        return splitAudioIntoChunks(
            MLXArray(samples), sampleRate: 16_000, chunkDuration: 20,
            minChunkDuration: 1, searchExpandSec: 5, minWindowMs: 100
        ).map(\.0)
    }

    static func sourceLanguage(_ language: String?) throws -> String {
        guard let language = language?.lowercased(), CanaryConfig.defaultSupportedLanguages.contains(language) else {
            throw PluginTranscriptionError.apiError("Select a source language, such as Greek or English, in Dictation settings. Canary does not detect the language automatically.")
        }
        return language
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: CanaryModelDef, passively: Bool = false,
                               notifyHost: Bool = true, expectedGeneration: UUID? = nil) async throws {
        let generation = expectedGeneration ?? activationID
        try await modelLoadGate.withLock { [self] in
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            if passively {
                guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
            }
            guard !(isConfigured && loadedModelId == modelDef.id) else { return }
            try await performModelLoad(modelDef, allowDownloads: !passively, notifyHost: notifyHost, generation: generation)
        }
    }

    private func performModelLoad(_ modelDef: CanaryModelDef, allowDownloads: Bool,
                                  notifyHost: Bool, generation: UUID) async throws {
        try activationLock.withLock {
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            modelState = .loading
        }
        do {
            let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models")
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let modelDirectory: URL
            if let existing = usableModelDirectory(for: modelDef, modelsDirectory: modelsDir) {
                modelDirectory = existing
            } else {
                guard allowDownloads else {
                    modelState = .notLoaded
                    return
                }
                guard !modelDef.id.hasPrefix("custom-") else {
                    throw PluginModelImportError.invalidModel("Imported files are missing. Remove and import the model again.")
                }
                removeIncompleteModelIfNeeded(modelDef, modelsDirectory: modelsDir)
                guard let repoID = Repo.ID(rawValue: modelDef.repoId) else {
                    throw NSError(
                        domain: "CanaryPlugin",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid repository ID: \(modelDef.repoId)"]
                    )
                }
                let client = HubClient(
                    host: HubClient.defaultHost,
                    bearerToken: PluginHuggingFaceTokenHelper.normalizedToken(_hfToken),
                    cache: HubCache(cacheDirectory: modelsDir)
                )
                do {
                    modelDirectory = try await client.downloadSnapshot(
                        of: repoID,
                        matching: Self.modelDownloadPatterns
                    )
                    guard PluginHuggingFaceModelStore(modelsDirectory: modelsDir).isUsableModelDirectory(
                        modelDirectory,
                        requirements: Self.modelRequirements
                    ) else {
                        throw NSError(
                            domain: "CanaryPlugin",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Downloaded model is incomplete: \(modelDef.repoId)"]
                        )
                    }
                } catch {
                    removeIncompleteModelIfNeeded(modelDef, modelsDirectory: modelsDir)
                    throw error
                }
            }
            // Release the previous runtime before constructing its replacement.
            // Keep its files and selection so a failed import can be retried.
            try activationLock.withLock {
                try Task.checkCancellation()
                guard generation == activationID, host != nil else { throw CancellationError() }
                model = nil
                loadedModelId = nil
            }
            try await PluginLocalInferenceGate.shared.withLock {
                try Task.checkCancellation()
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            let loaded = try Self.loadCanaryModel(from: modelDirectory)
            guard loaded.tokenizer != nil else {
                throw PluginModelImportError.invalidModel("Canary tokenizer could not be loaded")
            }

            try activationLock.withLock {
                try Task.checkCancellation()
                guard generation == activationID, host != nil else { throw CancellationError() }
                model = loaded
                loadedModelId = modelDef.id
                _selectedModelId = modelDef.id
                host?.setUserDefault(modelDef.id, forKey: "selectedModel")
                host?.setUserDefault(modelDef.id, forKey: "loadedModel")
                modelState = .ready(modelDef.id)
                if notifyHost { host?.notifyCapabilitiesChanged() }
            }
        } catch is CancellationError {
            if generation == activationID, host != nil {
                modelState = loadedModelId.map { .ready($0) } ?? .notLoaded
            }
            throw CancellationError()
        } catch {
            if generation == activationID { modelState = .error(error.localizedDescription) }
            throw error
        }
    }

    // NeMo exports retain these deterministic preprocessing buffers. MLXAudio
    // computes the Hann window and mel filter bank from config at inference time.
    // Keep every other key so incompatible weights still fail validation.
    static func isDerivedPreprocessingBuffer(_ key: String) -> Bool {
        key == "preprocessor.featurizer.fb" || key == "preprocessor.featurizer.window"
    }

    static func sanitizeCanaryWeights(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = CanaryModel.sanitize(weights: weights)
        let isNemo = !weights.keys.contains { $0.hasPrefix("decoder.blocks.") || $0.hasPrefix("transf_decoder.layers.") }
            && weights["head.classifier.weight"] == nil
        if isNemo {
            // Upstream remaps these Conv2d names before checking for "conv";
            // their NeMo OIHW layout therefore misses the conversion to OHWI.
            for (key, value) in sanitized where value.ndim == 4 && key.hasSuffix(".weight")
                && (key.hasPrefix("encoder.conformer.pre_encode.depthwise_layers.")
                    || key.hasPrefix("encoder.conformer.pre_encode.pointwise_layers.")) {
                sanitized[key] = value.transposed(0, 2, 3, 1)
            }
        }
        return sanitized
    }

    private static func loadCanaryModel(from directory: URL) throws -> CanaryModel {
        try Task.checkCancellation()
        let config = try JSONDecoder().decode(
            CanaryConfig.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        let tokenizer = try CanaryTokenizer.fromModelDirectory(directory, config: config)
        let model = CanaryModel(config: config, tokenizer: tokenizer)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw PluginModelImportError.invalidModel("No Canary safetensors weights found")
        }
        var weights: [String: MLXArray] = [:]
        for file in files {
            try Task.checkCancellation()
            // MLX reads the header here and creates lazy Load arrays; tensor
            // payloads are materialized individually below.
            for (key, value) in try MLX.loadArrays(url: file) where !isDerivedPreprocessingBuffer(key) {
                try Task.checkCancellation()
                guard weights.updateValue(value, forKey: key) == nil else {
                    throw PluginModelImportError.invalidModel("Duplicate Canary weight: \(key)")
                }
            }
        }
        try Task.checkCancellation()
        let sanitized = Self.sanitizeCanaryWeights(weights)
        if config.quantization != nil || config.perLayerQuantization != nil {
            quantize(model: model) { path, _ in
                guard sanitized["\(path).scales"] != nil else { return nil }
                if let layer = config.perLayerQuantization?.quantization(layer: path) {
                    return layer.asTuple
                }
                return config.quantization?.asTuple
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)
        model.train(false)
        for (_, parameter) in model.parameters().flattened() {
            try Task.checkCancellation()
            eval(parameter)
        }
        try Task.checkCancellation()
        return model
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() {
        activationLock.withLock {
            guard !isConfigured, modelState != .loading, explicitModelLoadTask == nil else { return }
            genericModelLoadTask?.cancel()
            let generation = activationID
            genericModelLoadTask = Task {
                guard !Task.isCancelled, generation == activationID, host != nil else { return }
                await restoreLoadedModel(allowDownloads: true, expectedGeneration: generation)
            }
        }
    }

    @objc(triggerRestoreModelForModel:)
    func triggerRestoreModel(forModel modelId: NSString?) {
        activationLock.withLock {
            guard let modelId = modelId.map(String.init),
                  let modelDef = allModelDefinitions.first(where: { $0.id == modelId }) else {
                return
            }
            if loadedModelId != nil, loadedModelId != modelId {
                unloadModel(clearPersistence: true)
            }
            if loadedModelId == nil,
               host?.userDefault(forKey: "loadedModel") as? String != modelId {
                host?.setUserDefault(nil, forKey: "loadedModel")
            }
            _selectedModelId = modelId
            host?.setUserDefault(modelId, forKey: "selectedModel")
            // Supersede the previous request synchronously, before either task runs.
            genericModelLoadTask?.cancel()
            genericModelLoadTask = nil
            explicitModelLoadTask?.cancel()
            activationID = UUID()
            if isConfigured, loadedModelId == modelId {
                // Superseding an import can keep this already-loaded runtime.
                modelState = .ready(modelId)
            }
            let generation = activationID
            explicitModelLoadTask = Task {
                defer {
                    activationLock.withLock {
                        if generation == activationID { explicitModelLoadTask = nil }
                    }
                }
                guard !Task.isCancelled, generation == activationID, host != nil else { return }
                try? await loadModel(modelDef, expectedGeneration: generation)
            }
        }
    }

    func unloadModel(clearPersistence: Bool = true) {
        activationLock.withLock {
            // Reject pending imports and loads before they can repopulate an unloaded engine.
            activationID = UUID()
            genericModelLoadTask?.cancel()
            genericModelLoadTask = nil
            explicitModelLoadTask?.cancel()
            explicitModelLoadTask = nil
            passiveRestoreController.cancel()
            model = nil
            loadedModelId = nil
            modelState = .notLoaded
            scheduleRuntimeCacheClearWhenInferenceIsIdle()
            if clearPersistence {
                host?.setUserDefault(nil, forKey: "loadedModel")
            }
            host?.notifyCapabilitiesChanged()
        }
    }

    private(set) var runtimeCacheClearTask: Task<Void, Never>?

    private func scheduleRuntimeCacheClearWhenInferenceIsIdle() {
        runtimeCacheClearTask = Task {
            try? await PluginLocalInferenceGate.shared.withLock {
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
        }
    }

    fileprivate func deleteModelFiles(_ modelDef: CanaryModelDef) throws {
        if modelDef.id.hasPrefix("custom-") {
            try customModelStore?.remove(modelDef.id)
            return
        }
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        try PluginHuggingFaceModelStore(modelsDirectory: modelsDir).deleteModelFiles(
            for: modelDef.repoId,
            legacyDirectories: [legacyModelDirectory(for: modelDef, modelsDirectory: modelsDir)]
        )
    }

    func restoreLoadedModel(allowDownloads: Bool = true, passively: Bool = false, expectedGeneration: UUID? = nil) async {
        let generation = expectedGeneration ?? activationID
        guard !Task.isCancelled, generation == activationID else { return }
        if passively {
            guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
        }
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = allModelDefinitions.first(where: { $0.id == savedId }) else {
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef, passively: passively, expectedGeneration: generation)
    }

    private func hasDownloadedModel(_ modelDef: CanaryModelDef) -> Bool {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return false }
        return usableModelDirectory(for: modelDef, modelsDirectory: modelsDir) != nil
    }

    private func usableModelDirectory(for modelDef: CanaryModelDef, modelsDirectory: URL) -> URL? {
        if modelDef.id.hasPrefix("custom-") {
            guard let directory = customModelStore?.modelDirectory(for: modelDef.id),
                  PluginHuggingFaceModelStore(modelsDirectory: directory).isUsableModelDirectory(
                    directory, requirements: Self.modelRequirements) else { return nil }
            return directory
        }
        return PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory).usableModelDirectory(
            for: modelDef.repoId,
            legacyDirectories: [legacyModelDirectory(for: modelDef, modelsDirectory: modelsDirectory)],
            requirements: Self.modelRequirements
        )
    }

    private func legacyModelDirectory(for modelDef: CanaryModelDef, modelsDirectory: URL) -> URL {
        modelsDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelDef.repoId.replacingOccurrences(of: "/", with: "_"))
    }

    private func removeIncompleteModelIfNeeded(_ modelDef: CanaryModelDef, modelsDirectory: URL) {
        let store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
        let legacyDirectories = [legacyModelDirectory(for: modelDef, modelsDirectory: modelsDirectory)]
        guard usableModelDirectory(for: modelDef, modelsDirectory: modelsDirectory) == nil,
              store.hasCachedModelFiles(for: modelDef.repoId, legacyDirectories: legacyDirectories) else {
            return
        }
        try? store.deleteModelFiles(for: modelDef.repoId, legacyDirectories: legacyDirectories)
    }

    private func cleanupRedundantModelCopies() {
        guard let modelsDirectory = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        let store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
        for modelDef in Self.availableModels {
            _ = try? store.removeRedundantLegacyDirectories(
                for: modelDef.repoId,
                legacyDirectories: [legacyModelDirectory(for: modelDef, modelsDirectory: modelsDirectory)],
                requirements: Self.modelRequirements
            )
        }
    }

    // MARK: - Settings View

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .loading:
            return PluginSettingsActivity(message: "Preparing model")
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    var settingsView: AnyView? {
        AnyView(CanarySettingsView(plugin: self))
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

    static let availableModels: [CanaryModelDef] = [
        CanaryModelDef(
            id: "sophea-canary-bf16", displayName: "Sophea Canary (Greek / English)",
            repoId: "KIEFERSA/Sophea-Canary-ASR-mlx", sizeDescription: "~1.9 GB", ramRequirement: "8 GB+"
        ),
    ]

    // MARK: - Helpers

    static func normalizeTranscript(_ text: String, language: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Canary's Greek tokenizer uses medial sigma at the end of words.
        return language == "el" ? text.replacingOccurrences(of: "σ\\b", with: "ς", options: .regularExpression) : text
    }
}

// MARK: - Model Types

struct CanaryModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
}

enum CanaryModelState: Equatable {
    case notLoaded
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: CanaryModelState, rhs: CanaryModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.loading, .loading): true
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}

// MARK: - Settings View

private struct CanarySettingsView: View {
    let plugin: CanaryPlugin
    private let bundle = Bundle(for: CanaryPlugin.self)
    @State private var modelState: CanaryModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var isPolling = false
    @State private var hfTokenInput = ""
    @State private var showHfToken = false
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin._hfToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool {
        !storedHfToken.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Canary Speech (MLX)")
                .font(.headline)

            Text("Local Canary speech recognition on Apple Silicon, including Sophea for Greek and English. Select an explicit source language in Dictation settings.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            // HuggingFace Token
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
                HStack {
                    Text("Model", bundle: bundle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    PluginModelImportButton(importer: plugin, bundle: bundle)
                        .disabled(modelState == .loading)
                }

                ForEach(plugin.allModelDefinitions) { modelDef in
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
                }
            }
        }
        .padding()
        .onAppear {
            modelState = plugin.modelState
            selectedModelId = plugin.selectedModelId ?? plugin.allModelDefinitions.first?.id ?? ""
            if let token = plugin._hfToken, !token.isEmpty {
                hfTokenInput = token
            }
        }
        .task {
            if case .notLoaded = plugin.modelState, plugin.shouldRestoreLoadedModelsPassively {
                isPolling = true
                await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
                isPolling = false
                modelState = plugin.modelState
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else {
                modelState = plugin.modelState
                selectedModelId = plugin.selectedModelId ?? selectedModelId
                return
            }
            let pluginState = plugin.modelState
            if pluginState != .notLoaded {
                modelState = pluginState
            }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
        .onChange(of: hfTokenInput) { _, newValue in
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedValue != storedHfToken {
                tokenValidationResult = nil
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ modelDef: CanaryModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .loading = modelState, selectedModelId == modelDef.id {
                ProgressView()
                    .controlSize(.small)
            } else if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(String(localized: "Unload", bundle: bundle)) {
                        plugin.unloadModel()
                        if !modelDef.id.hasPrefix("custom-") {
                            try? plugin.deleteModelFiles(modelDef)
                        }
                        modelState = plugin.modelState
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Button(modelDef.id.hasPrefix("custom-") ? String(localized: "Load", bundle: bundle) : String(localized: "Download & Load", bundle: bundle)) {
                    selectedModelId = modelDef.id
                    modelState = .loading
                    isPolling = true
                    Task {
                        try? await plugin.loadModel(modelDef)
                        isPolling = false
                        modelState = plugin.modelState
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(modelState == .loading)
            }
        }
        .padding(.vertical, 4)
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
