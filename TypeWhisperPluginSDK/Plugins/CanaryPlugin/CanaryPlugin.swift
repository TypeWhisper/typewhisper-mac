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
    private let activationLock = NSLock()
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
    private(set) var explicitModelLoadTask: Task<Void, Never>?

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

    func deactivate() {
        explicitModelLoadTask?.cancel()
        explicitModelLoadTask = nil
        passiveRestoreController.cancel()
        activationID = UUID()
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        host = nil
    }

    // Imported files are owned by this plugin, separate from the built-in model cache.
    fileprivate var customModelStore: PluginCustomModelStore? {
        host.map { PluginCustomModelStore(directory: $0.pluginDataDirectory.appendingPathComponent("custom-models")) }
    }

    fileprivate var allModelDefinitions: [CanaryModelDef] {
        Self.availableModels + (customModelStore?.models() ?? []).map { model in
            CanaryModelDef(id: model.id, displayName: model.displayName, repoId: model.id,
                sizeDescription: model.sizeDescription, ramRequirement: "—")
        }
    }

    var supportedImportModelTypes: Set<String> { ["canary"] }

    @MainActor
    func importModel(_ candidate: PluginModelImportCandidate, token: String?) async throws -> PluginModelInfo {
        guard !isImportingModel, modelState != .loading else { throw PluginModelImportError.busy }
        guard let store = customModelStore else { throw PluginTranscriptionError.notConfigured }
        isImportingModel = true
        let previousState = modelState
        let generation = activationID
        modelState = .loading
        defer { isImportingModel = false }
        var importedID: String?
        do {
            let imported = try await store.add(candidate, supportedTypes: supportedImportModelTypes,
                requirements: Self.modelRequirements, token: token ?? _hfToken)
            importedID = imported.id
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            guard let definition = allModelDefinitions.first(where: { $0.id == imported.id }) else {
                throw PluginModelImportError.invalidModel("Imported model is unavailable")
            }
            // Use the real engine loader to validate the weights before accepting the import.
            try await loadModel(definition)
            guard generation == activationID, host != nil else { throw CancellationError() }
            return PluginModelInfo(id: imported.id, displayName: imported.displayName,
                sizeDescription: imported.sizeDescription, downloaded: true, loaded: true)
        } catch {
            if let importedID { try? store.remove(importedID) }
            if generation == activationID { modelState = previousState }
            throw error
        }
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
            .filter { hasDownloadedModel($0) }
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
        guard modelState != .loading else { throw PluginModelImportError.busy }
        guard let modelDef = allModelDefinitions.first(where: { $0.id == modelId }) else { return }

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
        guard let model else { throw PluginTranscriptionError.notConfigured }
        let sourceLanguage = try Self.sourceLanguage(language)
        guard !translate else { throw PluginTranscriptionError.apiError("Canary translation is not available in this engine.") }
        var chunks: [String] = []
        // Bound encoder memory and give each chunk its own decoding budget.
        for start in stride(from: 0, to: audio.samples.count, by: 320_000) {
            try Task.checkCancellation()
            let samples = Array(audio.samples[start..<min(start + 320_000, audio.samples.count)])
            let output = model.generate(audio: MLXArray(samples), generationParameters: STTGenerateParameters(
                maxTokens: 512, temperature: 0, language: sourceLanguage
            ))
            try Task.checkCancellation()
            guard output.generationTokens < 512 else {
                throw PluginTranscriptionError.apiError("Canary reached its transcription limit. Retry with a shorter recording.")
            }
            chunks.append(Self.normalizeTranscript(output.text, language: sourceLanguage))
            guard onProgress(chunks.joined(separator: " ")) else { throw CancellationError() }
        }
        return PluginTranscriptionResult(text: chunks.joined(separator: " "), detectedLanguage: sourceLanguage)
    }

    static func sourceLanguage(_ language: String?) throws -> String {
        guard let language = language?.lowercased(), CanaryConfig.defaultSupportedLanguages.contains(language) else {
            throw PluginTranscriptionError.apiError("Select a source language, such as Greek or English, in Dictation settings. Canary does not detect the language automatically.")
        }
        return language
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: CanaryModelDef, passively: Bool = false) async throws {
        let generation = activationID
        try await modelLoadGate.withLock { [self] in
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            if passively {
                guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
            }
            guard !(isConfigured && loadedModelId == modelDef.id) else { return }
            try await performModelLoad(modelDef, allowDownloads: !passively)
        }
    }

    private func performModelLoad(_ modelDef: CanaryModelDef, allowDownloads: Bool) async throws {
        let generation = activationID
        modelState = .loading
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
            let loaded = try Self.loadCanaryModel(from: modelDirectory)
            guard loaded.tokenizer != nil else {
                throw PluginModelImportError.invalidModel("Canary tokenizer could not be loaded")
            }

            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            model = loaded
            loadedModelId = modelDef.id
            _selectedModelId = modelDef.id
            host?.setUserDefault(modelDef.id, forKey: "selectedModel")
            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            modelState = .ready(modelDef.id)
            host?.notifyCapabilitiesChanged()
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
            for (key, value) in try MLX.loadArrays(url: file) where !isDerivedPreprocessingBuffer(key) {
                guard weights.updateValue(value, forKey: key) == nil else {
                    throw PluginModelImportError.invalidModel("Duplicate Canary weight: \(key)")
                }
            }
        }
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
        eval(model)
        return model
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    @objc(triggerRestoreModelForModel:)
    func triggerRestoreModel(forModel modelId: NSString?) {
        guard let modelId = modelId.map(String.init),
              let modelDef = allModelDefinitions.first(where: { $0.id == modelId }) else {
            return
        }
        if loadedModelId != nil, loadedModelId != modelId {
            unloadModel(clearPersistence: true)
        }
        _selectedModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedModel")
        // Supersede the previous request synchronously, before either task runs.
        explicitModelLoadTask?.cancel()
        let generation = activationID
        explicitModelLoadTask = Task {
            guard !Task.isCancelled, generation == activationID, host != nil else { return }
            try? await loadModel(modelDef)
        }
    }

    func unloadModel(clearPersistence: Bool = true) {
        explicitModelLoadTask?.cancel()
        explicitModelLoadTask = nil
        passiveRestoreController.cancel()
        model = nil
        loadedModelId = nil
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
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

    func restoreLoadedModel(allowDownloads: Bool = true, passively: Bool = false) async {
        guard !Task.isCancelled else { return }
        if passively {
            guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
        }
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = allModelDefinitions.first(where: { $0.id == savedId }) else {
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef, passively: passively)
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
