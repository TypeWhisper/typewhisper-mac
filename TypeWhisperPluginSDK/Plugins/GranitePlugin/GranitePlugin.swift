import Combine
import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(GranitePlugin)
final class GranitePlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, PluginCustomModelImporting, DictionaryTermsCapabilityProviding, DictionaryTermsBudgetProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PassiveModelRestoreProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.granite"
    static let pluginName = "Granite Speech"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var model: GraniteRuntime?
    fileprivate var loadedModelId: String?
    private let activationLock = NSRecursiveLock()
    private var _activationID = UUID()
    private var activationID: UUID {
        get { activationLock.withLock { _activationID } }
        set { activationLock.withLock { _activationID = newValue } }
    }
    @MainActor private var isImportingModel = false
    fileprivate var _hfToken: String?

    fileprivate var modelState: GraniteModelState = .notLoaded

    fileprivate static let modelRequirements = PluginHuggingFaceModelStore.Requirements(
        requiredFiles: ["config.json", "tokenizer.json"],
        weightFileExtensions: ["safetensors"]
    )

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
            host = nil
        }
    }

    // Imported files are owned by this plugin, separate from the built-in model cache.
    fileprivate var customModelStore: PluginCustomModelStore? {
        host.map { PluginCustomModelStore(directory: $0.pluginDataDirectory.appendingPathComponent("custom-models")) }
    }

    fileprivate var allModelDefinitions: [GraniteModelDef] {
        Self.availableModels + (customModelStore?.models() ?? []).map(Self.importedDefinition)
    }

    private static func importedDefinition(_ model: PluginCustomModelStore.Model) -> GraniteModelDef {
        GraniteModelDef(id: model.id, displayName: model.displayName, repoId: model.id,
            sizeDescription: model.sizeDescription, ramRequirement: "—",
            family: model.modelType == GraniteModelFamily.turboCTCModelType ? .turboCTC : .granite4)
    }

    var supportedImportModelTypes: Set<String> { ["granite_speech", GraniteModelFamily.turboCTCModelType] }

    @MainActor
    func importModel(_ candidate: PluginModelImportCandidate, token: String?) async throws -> PluginModelInfo {
        guard !isImportingModel, modelState != .loading else { throw PluginModelImportError.busy }
        guard let store = customModelStore else { throw PluginTranscriptionError.notConfigured }
        if case .huggingFace = candidate.source { try host?.requireModelDownloadAllowed() }
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

    var providerId: String { "granite" }
    var providerDisplayName: String { "Granite Speech (MLX)" }

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

    /// The family of the loaded model, or of the selected one before it loads.
    private var activeFamily: GraniteModelFamily? {
        activationLock.withLock {
            if let model { return model.family }
            guard let id = _selectedModelId else { return nil }
            return allModelDefinitions.first { $0.id == id }?.family
        }
    }

    var supportedLanguages: [String] { Self.supportedLanguages(for: activeFamily) }

    static func supportedLanguages(for family: GraniteModelFamily?) -> [String] {
        family == .turboCTC
            ? ["en", "fr", "de", "es", "pt", "it", "ja"]
            : ["en", "fr", "de", "es", "pt", "ja"]
    }

    private func family(ofModel modelId: String?) -> GraniteModelFamily? {
        guard let modelId else { return activeFamily }
        return allModelDefinitions.first { $0.id == modelId }?.family ?? activeFamily
    }

    // Let the host resolve capabilities for a per-flow model override, such as the Recorder's or
    // file transcription's own model. Looked up through the Objective-C runtime, so the plugin
    // stays loadable by hosts that do not know about them.
    @objc(supportedLanguagesForModelId:)
    func supportedLanguages(forModelId modelId: String?) -> [String] {
        Self.supportedLanguages(for: family(ofModel: modelId))
    }

    @objc(supportsTranslationForModelId:)
    func supportsTranslation(forModelId modelId: String?) -> NSNumber {
        NSNumber(value: family(ofModel: modelId) != .turboCTC)
    }

    @objc(supportsDictionaryTermsForModelId:)
    func supportsDictionaryTerms(forModelId modelId: String?) -> NSNumber {
        NSNumber(value: family(ofModel: modelId) != .turboCTC)
    }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        activationLock.withLock {
            if _selectedModelId != modelId || (loadedModelId != nil && loadedModelId != modelId) {
                unloadModel(clearPersistence: true)
            }
            _selectedModelId = modelId
            host?.setUserDefault(modelId, forKey: "selectedModel")
            guard loadedModelId != modelId, modelState != .loading,
                  let definition = allModelDefinitions.first(where: { $0.id == modelId }),
                  hasDownloadedModel(definition) else { return }
            // Override cleanup restores selection synchronously. Advertise the
            // cached restore immediately so a generic request cannot replace it.
            modelState = .loading
            let generation = activationID
            genericModelLoadTask = Task {
                guard !Task.isCancelled, generation == activationID, host != nil else { return }
                try? await loadModel(definition, expectedGeneration: generation)
            }
        }
    }

    // TurboCTC is a CTC encoder without a prompt: it can neither translate nor take keywords.
    var supportsTranslation: Bool { activeFamily != .turboCTC }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { activeFamily == .turboCTC ? .unsupported : .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 4_000) }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await PluginLocalInferenceGate.shared.withLock { [self] in
            guard let model else {
                throw PluginTranscriptionError.notConfigured
            }
            if translate, model.family == .turboCTC { throw Self.turboCTCTranslationError }
            guard !audio.samples.isEmpty else {
                return PluginTranscriptionResult(text: "", detectedLanguage: language)
            }

            let audioArray = MLXArray(audio.samples)
            let output: STTOutput
            switch model {
            case .turboCTC(let ctc):
                output = ctc.generate(audio: audioArray, generationParameters: ctc.defaultGenerationParameters)
            case .speech(let speech, let family):
                output = speech.generate(
                    audio: audioArray,
                    maxTokens: 4096,
                    temperature: 0.0,
                    prompt: Self.resolvePrompt(family: family, translate: translate, language: language, prompt: prompt),
                    language: translate ? (language ?? "en") : nil
                )
            }
            let text = Self.normalizeTranscript(output.text)

            return PluginTranscriptionResult(text: text, detectedLanguage: language)
        }
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await PluginLocalInferenceGate.shared.withLock { [self] in
            guard let model else {
                throw PluginTranscriptionError.notConfigured
            }
            if translate, model.family == .turboCTC { throw Self.turboCTCTranslationError }
            guard !audio.samples.isEmpty else {
                return PluginTranscriptionResult(text: "", detectedLanguage: language)
            }

            let audioArray = MLXArray(audio.samples)
            guard case .speech(let speech, let family) = model else {
                // TurboCTC decodes the whole buffer in one pass, in milliseconds.
                guard case .turboCTC(let ctc) = model else { throw PluginTranscriptionError.notConfigured }
                let output = ctc.generate(audio: audioArray, generationParameters: ctc.defaultGenerationParameters)
                let text = Self.normalizeTranscript(output.text)
                _ = onProgress(text)
                return PluginTranscriptionResult(text: text, detectedLanguage: language)
            }
            let stream = speech.generateStream(
                audio: audioArray,
                maxTokens: 4096,
                temperature: 0.0,
                prompt: Self.resolvePrompt(family: family, translate: translate, language: language, prompt: prompt),
                language: translate ? (language ?? "en") : nil
            )

            var accumulated = ""
            generationLoop: for try await generation in stream {
                switch generation {
                case .token(let token):
                    accumulated += token
                    let shouldContinue = onProgress(Self.normalizeTranscript(accumulated))
                    if !shouldContinue { break generationLoop }
                case .info:
                    break
                case .result(let output):
                    accumulated = output.text
                }
            }

            let text = Self.normalizeTranscript(accumulated)
            return PluginTranscriptionResult(text: text, detectedLanguage: language)
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: GraniteModelDef, passively: Bool = false,
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

    private func performModelLoad(_ modelDef: GraniteModelDef, allowDownloads: Bool,
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
                // Refuse before the size lookup, and keep any partial cache untouched.
                try host?.requireModelDownloadAllowed()
                removeIncompleteModelIfNeeded(modelDef, modelsDirectory: modelsDir)
                guard let repoID = Repo.ID(rawValue: modelDef.repoId) else {
                    throw NSError(
                        domain: "GranitePlugin",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid repository ID: \(modelDef.repoId)"]
                    )
                }
                let spaceReservation = try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
                    repositoryID: modelDef.repoId,
                    revision: modelDef.revision ?? "main",
                    matching: modelDef.downloadPatterns,
                    token: _hfToken,
                    destination: modelsDir,
                    trackedDirectory: PluginHuggingFaceModelStore(modelsDirectory: modelsDir)
                        .repositoryCacheDirectory(for: modelDef.repoId),
                    // HubClient downloads through URLSession's temporary directory.
                    stagingDirectory: FileManager.default.temporaryDirectory,
                    modelName: modelDef.displayName
                )
                defer { spaceReservation?.release() }
                let client = HubClient(
                    host: HubClient.defaultHost,
                    bearerToken: PluginHuggingFaceTokenHelper.normalizedToken(_hfToken),
                    cache: HubCache(cacheDirectory: modelsDir)
                )
                do {
                    modelDirectory = try await client.downloadSnapshot(
                        of: repoID,
                        revision: modelDef.revision ?? "main",
                        matching: modelDef.downloadPatterns
                    )
                    guard PluginHuggingFaceModelStore(modelsDirectory: modelsDir).isUsableModelDirectory(
                        modelDirectory,
                        requirements: modelDef.requirements
                    ) else {
                        throw NSError(
                            domain: "GranitePlugin",
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
            let loaded: GraniteRuntime = switch modelDef.family {
            case .turboCTC: .turboCTC(try GraniteSpeech5CTCModel.fromModelDirectory(modelDirectory))
            case .granite4, .granite5:
                .speech(try await GraniteSpeechModel.fromModelDirectory(modelDirectory), modelDef.family)
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
            model = nil
            loadedModelId = nil
            modelState = .notLoaded
            if clearPersistence {
                host?.setUserDefault(nil, forKey: "loadedModel")
            }
            host?.notifyCapabilitiesChanged()
        }
    }

    fileprivate func deleteModelFiles(_ modelDef: GraniteModelDef) throws {
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

    /// The downloaded model the host loads on demand, see `HostServices.modelIdLoadedOnDemand`.
    fileprivate var modelIdLoadedOnDemand: String? {
        guard let modelId = host?.modelIdLoadedOnDemand,
              let modelDef = allModelDefinitions.first(where: { $0.id == modelId }),
              hasDownloadedModel(modelDef) else { return nil }
        return modelId
    }

    private func hasDownloadedModel(_ modelDef: GraniteModelDef) -> Bool {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return false }
        return usableModelDirectory(for: modelDef, modelsDirectory: modelsDir) != nil
    }

    private func usableModelDirectory(for modelDef: GraniteModelDef, modelsDirectory: URL) -> URL? {
        if modelDef.id.hasPrefix("custom-") {
            guard let directory = customModelStore?.modelDirectory(for: modelDef.id),
                  PluginHuggingFaceModelStore(modelsDirectory: directory).isUsableModelDirectory(
                    directory, requirements: Self.modelRequirements) else { return nil }
            return directory
        }
        let store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
        if let revision = modelDef.revision {
            // A download pinned to a commit writes no refs/ entry, so look up its snapshot directly.
            guard let snapshot = store.repositoryCacheDirectory(for: modelDef.repoId)?
                    .appendingPathComponent("snapshots", isDirectory: true)
                    .appendingPathComponent(revision, isDirectory: true),
                  store.isUsableModelDirectory(snapshot, requirements: modelDef.requirements) else { return nil }
            return snapshot
        }
        return store.usableModelDirectory(
            for: modelDef.repoId,
            legacyDirectories: [legacyModelDirectory(for: modelDef, modelsDirectory: modelsDirectory)],
            requirements: Self.modelRequirements
        )
    }

    private func legacyModelDirectory(for modelDef: GraniteModelDef, modelsDirectory: URL) -> URL {
        modelsDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelDef.repoId.replacingOccurrences(of: "/", with: "_"))
    }

    private func removeIncompleteModelIfNeeded(_ modelDef: GraniteModelDef, modelsDirectory: URL) {
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
        for modelDef in Self.availableModels where modelDef.revision == nil {
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
        AnyView(GraniteSettingsView(plugin: self))
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

    // The first entry is the default for users who have not picked a model yet. Granite 4.0
    // users keep their selected or downloaded model, its id is unchanged.
    static let availableModels: [GraniteModelDef] = [
        GraniteModelDef(
            id: "granite-speech-5.0-470m-turboctc",
            displayName: "Granite 5.0 TurboCTC (470M)",
            repoId: "ibm-granite/granite-speech-5.0-470m-turboctc",
            // Multilingual release of 2026-10-21 (EN, FR, DE, ES, PT, IT, JA).
            revision: "1dd23f46f6d4e6eae2531982ba2e33220086dd97",
            sizeDescription: "~950 MB",
            ramRequirement: "8 GB+",
            family: .turboCTC
        ),
        GraniteModelDef(
            id: "granite-speech-5.0-2b",
            displayName: "Granite 5.0 2B",
            repoId: "ibm-granite/granite-speech-5.0-2b",
            revision: "c684620bb54fc89d14ba27256b23bbc9e09ba764",
            sizeDescription: "~4.6 GB",
            ramRequirement: "16 GB+",
            family: .granite5
        ),
        GraniteModelDef(
            id: "granite-1b-speech-4bit",
            displayName: "Granite 4.0 1B (4-bit)",
            repoId: "mlx-community/granite-4.0-1b-speech-4bit",
            sizeDescription: "~2 GB",
            ramRequirement: "8 GB+"
        ),
        GraniteModelDef(
            id: "granite-1b-speech-5bit",
            displayName: "Granite 4.0 1B (5-bit)",
            repoId: "mlx-community/granite-4.0-1b-speech-5bit",
            sizeDescription: "~2.2 GB",
            ramRequirement: "8 GB+"
        ),
        GraniteModelDef(
            id: "granite-1b-speech-8bit",
            displayName: "Granite 4.0 1B (8-bit)",
            repoId: "mlx-community/granite-4.0-1b-speech-8bit",
            sizeDescription: "~2.9 GB",
            ramRequirement: "16 GB+"
        ),
    ]

    // MARK: - Helpers

    fileprivate static let turboCTCTranslationError = PluginTranscriptionError.apiError(
        "Granite 5.0 TurboCTC cannot translate. To translate, select Granite 5.0 2B or Granite 4.0 in the Granite settings."
    )

    static let transcribeInstruction = "can you transcribe the speech into a written format?"
    static let granite5TranscribeInstruction = "transcribe the speech with proper punctuation and capitalization."

    private static let translationLanguageNames: [String: String] = [
        "en": "English",
        "fr": "French",
        "de": "German",
        "es": "Spanish",
        "pt": "Portuguese",
        "it": "Italian",
        "ja": "Japanese",
        "zh": "Mandarin",
    ]

    /// Resolve the instruction for Granite. The host's prompt carries dictionary terms
    /// ("A, B"), and mlx-audio uses a non-nil prompt as the whole instruction and then
    /// ignores `language`. Granite expects the terms after the task instruction, so the
    /// terms are appended as "Keywords: A, B" to the transcribe or translate instruction.
    ///
    /// Granite 4.0 without terms gets nil, which keeps mlx-audio's built-in instructions.
    /// Granite 5.0 always gets the model card's instructions for punctuated, truecased output.
    /// TurboCTC takes no prompt.
    static func resolvePrompt(
        family: GraniteModelFamily = .granite4,
        translate: Bool,
        language: String?,
        prompt: String?
    ) -> String? {
        let keywords = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target = translationLanguageNames[(language ?? "en").lowercased()] ?? (language ?? "en")
        let instruction: String
        switch family {
        case .turboCTC:
            return nil
        case .granite4:
            guard !keywords.isEmpty else { return nil }
            instruction = translate ? "Translate the speech to \(target)." : transcribeInstruction
        case .granite5:
            instruction = translate
                ? "translate the speech to \(target) with proper punctuation and capitalization."
                : granite5TranscribeInstruction
        }
        return keywords.isEmpty ? instruction : "\(instruction) Keywords: \(keywords)"
    }

    fileprivate static func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model Types

enum GraniteModelFamily: Equatable {
    /// Granite Speech 4.0: lowercase output, translation and keywords through the prompt.
    case granite4
    /// Granite Speech 5.0 2B: YaRN decoder, punctuated output, translation and keywords.
    case granite5
    /// Granite Speech 5.0 TurboCTC: CTC encoder without a prompt. Punctuated output, 7 languages.
    case turboCTC

    static let turboCTCModelType = "granite_speech5_ctc"
}

struct GraniteModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    /// A pinned commit. nil follows `main`, as Granite 4.0 always has.
    var revision: String? = nil
    let sizeDescription: String
    let ramRequirement: String
    var family: GraniteModelFamily = .granite4

    var downloadPatterns: [String] {
        switch family {
        case .granite4: ["*.safetensors", "*.json", "*.txt", "*.wav"]
        // The 2B repo also has out_llm.safetensors (411 MB), which transcription does not use.
        case .granite5: ["model*.safetensors", "*.json", "*.txt", "*.jinja"]
        case .turboCTC: ["*.safetensors", "*.json"]
        }
    }

    var requirements: PluginHuggingFaceModelStore.Requirements {
        switch family {
        case .granite4, .turboCTC:
            GranitePlugin.modelRequirements
        case .granite5:
            // Without chat_template.jinja the prompt falls back to a different format.
            PluginHuggingFaceModelStore.Requirements(
                requiredFiles: ["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"],
                weightFileExtensions: ["safetensors"]
            )
        }
    }
}

enum GraniteRuntime {
    case speech(GraniteSpeechModel, GraniteModelFamily)
    case turboCTC(GraniteSpeech5CTCModel)

    var family: GraniteModelFamily {
        switch self {
        case .speech(_, let family): family
        case .turboCTC: .turboCTC
        }
    }
}

enum GraniteModelState: Equatable {
    case notLoaded
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: GraniteModelState, rhs: GraniteModelState) -> Bool {
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

private struct GraniteSettingsView: View {
    let plugin: GranitePlugin
    private let bundle = Bundle(for: GranitePlugin.self)
    @State private var modelState: GraniteModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var isPolling = false
    @State private var onDemandModelId: String?
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
            Text("Granite Speech (MLX)")
                .font(.headline)

            Text("Local speech-to-text and translation by IBM, powered by MLX on Apple Silicon. Granite 5.0 TurboCTC transcribes 7 languages with punctuation; Granite 5.0 2B also translates.", bundle: bundle)
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
                            .accessibilityLabel(Text("Hugging Face token", bundle: bundle))
                    } else {
                        SecureField("hf_...", text: $hfTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel(Text("Hugging Face token", bundle: bundle))
                    }

                    Button {
                        showHfToken.toggle()
                    } label: {
                        Image(systemName: showHfToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showHfToken ? Text("Hide Hugging Face token", bundle: bundle) : Text("Show Hugging Face token", bundle: bundle))

                    if hasStoredHfToken {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            hfTokenInput = ""
                            tokenValidationResult = nil
                            isValidatingToken = false
                            plugin.clearHuggingFaceToken()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Remove Hugging Face token", bundle: bundle))
                    }

                    Button(String(localized: "Save", bundle: bundle)) {
                        validateAndSaveHuggingFaceToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)
                    .accessibilityLabel(Text("Save Hugging Face token", bundle: bundle))
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
                            .accessibilityHidden(true)
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
                        .accessibilityLabel(Text("Error", bundle: bundle))
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
            onDemandModelId = plugin.modelIdLoadedOnDemand
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
            onDemandModelId = plugin.modelIdLoadedOnDemand
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
    private func modelRow(_ modelDef: GraniteModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                if let note = note(for: modelDef) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .loading = modelState, selectedModelId == modelDef.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Loading \(modelDef.displayName)", bundle: bundle))
            } else if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Loaded", bundle: bundle))
                    Button(String(localized: "Unload", bundle: bundle)) {
                        plugin.unloadModel()
                        if !modelDef.id.hasPrefix("custom-") {
                            try? plugin.deleteModelFiles(modelDef)
                        }
                        modelState = plugin.modelState
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Unload \(modelDef.displayName)", bundle: bundle))
                }
            } else if modelDef.id == onDemandModelId, modelState == .notLoaded {
                PluginModelLoadsOnDemandStatus(bundle: bundle)
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
                .accessibilityLabel(modelDef.id.hasPrefix("custom-") ? Text("Load \(modelDef.displayName)", bundle: bundle) : Text("Download and load \(modelDef.displayName)", bundle: bundle))
            }
        }
        .padding(.vertical, 4)
    }

    private func note(for modelDef: GraniteModelDef) -> String? {
        guard !modelDef.id.hasPrefix("custom-") else { return nil }
        switch modelDef.family {
        case .turboCTC:
            return String(localized: "Fastest. 7 languages with punctuation and capitalization. No translation or dictionary terms.", bundle: bundle)
        case .granite5:
            return String(localized: "Translation and dictionary terms. 6 languages with punctuation and capitalization. Slower.", bundle: bundle)
        case .granite4:
            return String(localized: "Older model. Writes mostly lowercase with little punctuation.", bundle: bundle)
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
