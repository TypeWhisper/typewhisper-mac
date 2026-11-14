import Combine
import Foundation
import SwiftUI
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT
import os
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(SOVTranscribePlugin)
final class SOVTranscribePlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, DictionaryTermsBudgetProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PassiveModelRestoreProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.sov-transcribe"
    static let pluginName = "SOV-Transcribe"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var model: SOVTranscribeModel?
    fileprivate var loadedModelId: String?
    private let activationLock = NSRecursiveLock()
    private var _activationID = UUID()
    private var activationID: UUID {
        get { activationLock.withLock { _activationID } }
        set { activationLock.withLock { _activationID = newValue } }
    }
    fileprivate var _hfToken: String?

    fileprivate var modelState: SOVTranscribeModelState = .notLoaded

    /// MLX creates its Metal device lazily, so clearing the cache can be the
    /// first MLX call in this process. Set before this plugin first enters MLX
    /// and never reset: the runtime outlives deactivation.
    static let runtimeUsage = OSAllocatedUnfairLock(initialState: false)

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
            _selectedModelId = host.userDefault(forKey: "selectedModel") as? String
                ?? Self.availableModels.first?.id
            _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

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

    // MARK: - Memory Requirement

    /// The 4-bit model peaks at about 16 GB while transcribing, so only Macs with
    /// 32 GB or more offer it.
    static let minimumMemoryGB = 32

    /// Installed memory of this Mac in GB, rounded the way Apple advertises it.
    static var hostMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    static func isSupported(memoryGB: Int) -> Bool {
        memoryGB >= minimumMemoryGB
    }

    /// The models this Mac can run. Below the memory requirement the host lists none.
    static func offeredModels(forMemoryGB memoryGB: Int) -> [SOVTranscribeModelDef] {
        isSupported(memoryGB: memoryGB) ? availableModels : []
    }

    fileprivate static var insufficientMemoryMessage: String {
        String(
            localized: "This Mac has \(hostMemoryGB) GB of memory. SOV-Transcribe needs \(minimumMemoryGB) GB or more.",
            bundle: Bundle(for: SOVTranscribePlugin.self)
        )
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "sov-transcribe" }
    var providerDisplayName: String { "SOV-Transcribe (MLX)" }

    var isConfigured: Bool {
        model != nil && loadedModelId != nil
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        host?.shouldRestoreLoadedModelsPassively ?? true
    }

    var transcriptionModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return Self.availableModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    var availableModels: [PluginModelInfo] {
        Self.offeredModels(forMemoryGB: Self.hostMemoryGB).map { def in
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
        Self.availableModels
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
        try activationLock.withLock {
            guard modelState != .loading else { throw PluginModelImportError.busy }
            guard let modelDef = Self.availableModels.first(where: { $0.id == modelId }) else { return }

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

    var supportedLanguages: [String] { Self.supportedLanguageCodes }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        activationLock.withLock {
            if _selectedModelId != modelId || (loadedModelId != nil && loadedModelId != modelId) {
                unloadModel(clearPersistence: true)
            }
            _selectedModelId = modelId
            host?.setUserDefault(modelId, forKey: "selectedModel")
            guard loadedModelId != modelId, modelState != .loading,
                  Self.isSupported(memoryGB: Self.hostMemoryGB),
                  let definition = Self.availableModels.first(where: { $0.id == modelId }),
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

    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var dictionaryTermsSupport: DictionaryTermsSupport { .supported }
    var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 4_000) }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        try await transcribeRecording(audio, language: language, prompt: prompt, onProgress: nil)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        try await transcribeRecording(audio, language: language, prompt: prompt, onProgress: onProgress)
    }

    /// The model takes up to 30 minutes per call. Longer recordings are transcribed in
    /// chunks of at most that length, cut at a quiet stretch.
    private func transcribeRecording(
        _ audio: AudioData,
        language: String?,
        prompt: String?,
        onProgress: (@Sendable (String) -> Bool)?
    ) async throws -> PluginTranscriptionResult {
        let languageCode = Self.supportedLanguageCode(language)
        let instruction = Self.instruction(forLanguage: languageCode)
        let hotwords = Self.hotwords(fromPrompt: prompt)

        var finishedText = ""
        var stopped = false
        let chunkTranscriber: (AudioData) async throws -> PluginTranscriptionResult = { [self] chunk in
            guard !stopped else { return PluginTranscriptionResult(text: "", detectedLanguage: languageCode) }
            let chunkProgress = Self.progress(onProgress, after: finishedText)
            let chunkResult = try await transcribeChunk(
                chunk.samples, instruction: instruction, hotwords: hotwords, onProgress: chunkProgress
            )
            stopped = !chunkResult.completed
            finishedText = Self.joined(finishedText, chunkResult.text)
            return PluginTranscriptionResult(text: chunkResult.text, detectedLanguage: languageCode)
        }
        let result = try await PluginAudioChunking.transcribe(
            audio,
            maximumChunkDuration: Self.maximumChunkDuration,
            transcribeChunk: chunkTranscriber
        )
        return PluginTranscriptionResult(text: result.text, detectedLanguage: languageCode)
    }

    /// Transcribes at most 30 minutes of audio. `completed` is false when `onProgress`
    /// asked to stop early.
    private func transcribeChunk(
        _ samples: [Float],
        instruction: String,
        hotwords: [String]?,
        onProgress: (@Sendable (String) -> Bool)?
    ) async throws -> (text: String, completed: Bool) {
        try await PluginLocalInferenceGate.shared.withLock { [self] in
            guard let model else {
                throw PluginTranscriptionError.notConfigured
            }
            defer { Self.clearCacheAfterInference() }
            guard !samples.isEmpty else { return ("", true) }
            // The model stops the process on longer input; chunking keeps every call below it.
            guard samples.count <= Self.maximumChunkSampleCount else {
                throw PluginTranscriptionError.apiError("SOV-Transcribe takes at most 30 minutes of audio per request.")
            }

            let audioArray = MLXArray(samples)
            let duration = Double(samples.count) / Double(Self.sampleRate)
            // No `language` here: the model would append "The spoken language is …" to the
            // instruction, which names the language already.
            let parameters = STTGenerateParameters(
                maxTokens: Self.maxTokens(forAudioDuration: duration),
                temperature: 0.0,
                topP: 1.0
            )

            guard let onProgress else {
                let output = model.generate(
                    audio: audioArray,
                    generationParameters: parameters,
                    prompt: instruction,
                    hotwords: hotwords
                )
                return (Self.normalizeTranscript(output.text), true)
            }

            let stream = model.generateStream(
                audio: audioArray,
                generationParameters: parameters,
                prompt: instruction,
                hotwords: hotwords
            )
            var accumulated = ""
            var completed = true
            generationLoop: for try await generation in stream {
                switch generation {
                case .token(let token):
                    accumulated += token
                    if !onProgress(Self.normalizeTranscript(accumulated)) {
                        completed = false
                        break generationLoop
                    }
                case .info:
                    break
                case .result(let output):
                    accumulated = output.text
                }
            }
            return (Self.normalizeTranscript(accumulated), completed)
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: SOVTranscribeModelDef, passively: Bool = false,
                               notifyHost: Bool = true, expectedGeneration: UUID? = nil) async throws {
        let generation = expectedGeneration ?? activationID
        try await modelLoadGate.withLock { [self] in
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            if passively {
                guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
            }
            guard !(isConfigured && loadedModelId == modelDef.id) else { return }
            guard Self.isSupported(memoryGB: Self.hostMemoryGB) else {
                if passively { return }
                let message = Self.insufficientMemoryMessage
                activationLock.withLock {
                    if generation == activationID { modelState = .error(message) }
                }
                throw PluginTranscriptionError.apiError(message)
            }
            try await performModelLoad(modelDef, allowDownloads: !passively, notifyHost: notifyHost, generation: generation)
        }
    }

    private func performModelLoad(_ modelDef: SOVTranscribeModelDef, allowDownloads: Bool,
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
                // Refuse before the size lookup, and keep any partial cache untouched.
                try host?.requireModelDownloadAllowed()
                removeIncompleteModelIfNeeded(modelDef, modelsDirectory: modelsDir)
                guard let repoID = Repo.ID(rawValue: modelDef.repoId) else {
                    throw NSError(
                        domain: "SOVTranscribePlugin",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid repository ID: \(modelDef.repoId)"]
                    )
                }
                let spaceReservation = try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
                    repositoryID: modelDef.repoId,
                    revision: modelDef.revision,
                    matching: Self.modelDownloadPatterns,
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
                        revision: modelDef.revision,
                        matching: Self.modelDownloadPatterns
                    )
                    guard PluginHuggingFaceModelStore(modelsDirectory: modelsDir).isUsableModelDirectory(
                        modelDirectory,
                        requirements: Self.modelRequirements
                    ) else {
                        throw NSError(
                            domain: "SOVTranscribePlugin",
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
            try activationLock.withLock {
                try Task.checkCancellation()
                guard generation == activationID, host != nil else { throw CancellationError() }
                model = nil
                loadedModelId = nil
            }
            try await PluginLocalInferenceGate.shared.withLock {
                try Task.checkCancellation()
                Self.runtimeUsage.withLock { $0 = true }
                Stream.gpu.synchronize()
                Memory.clearCache()
            }
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            let loaded = try await SOVTranscribeModel.fromModelDirectory(modelDirectory)

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
                  let modelDef = Self.availableModels.first(where: { $0.id == modelId }) else {
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
            // Reject pending loads before they can repopulate an unloaded engine.
            activationID = UUID()
            genericModelLoadTask?.cancel()
            genericModelLoadTask = nil
            explicitModelLoadTask?.cancel()
            explicitModelLoadTask = nil
            model = nil
            loadedModelId = nil
            modelState = .notLoaded
            // The released weights stay in MLX's cache until it is cleared.
            scheduleRuntimeCacheClearWhenInferenceIsIdle()
            if clearPersistence {
                host?.setUserDefault(nil, forKey: "loadedModel")
            }
            host?.notifyCapabilitiesChanged()
        }
    }

    /// The key-value cache of a long recording takes gigabytes, which MLX would
    /// otherwise keep in its cache after the transcription.
    private static func clearCacheAfterInference() {
        Memory.clearCache()
    }

    private(set) var runtimeCacheClearTask: Task<Void, Never>?

    private func scheduleRuntimeCacheClearWhenInferenceIsIdle() {
        guard Self.runtimeUsage.withLock({ $0 }) else { return }
        // A model under construction is released only when its load ends, so wait
        // for the load gate first, in the same lock order as `loadModel`.
        runtimeCacheClearTask = Task { [modelLoadGate] in
            try? await modelLoadGate.withLock {
                try await PluginLocalInferenceGate.shared.withLock {
                    Stream.gpu.synchronize()
                    Memory.clearCache()
                }
            }
        }
    }

    fileprivate func deleteModelFiles(_ modelDef: SOVTranscribeModelDef) throws {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        try PluginHuggingFaceModelStore(modelsDirectory: modelsDir).deleteModelFiles(
            for: modelDef.repoId,
            legacyDirectories: []
        )
    }

    func restoreLoadedModel(allowDownloads: Bool = true, passively: Bool = false, expectedGeneration: UUID? = nil) async {
        let generation = expectedGeneration ?? activationID
        guard !Task.isCancelled, generation == activationID else { return }
        if passively {
            guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
        }
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.availableModels.first(where: { $0.id == savedId }) else {
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef, passively: passively, expectedGeneration: generation)
    }

    /// The downloaded model the host loads on demand, see `HostServices.modelIdLoadedOnDemand`.
    fileprivate var modelIdLoadedOnDemand: String? {
        guard let modelId = host?.modelIdLoadedOnDemand,
              let modelDef = Self.availableModels.first(where: { $0.id == modelId }),
              hasDownloadedModel(modelDef) else { return nil }
        return modelId
    }

    private func hasDownloadedModel(_ modelDef: SOVTranscribeModelDef) -> Bool {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return false }
        return usableModelDirectory(for: modelDef, modelsDirectory: modelsDir) != nil
    }

    private func usableModelDirectory(for modelDef: SOVTranscribeModelDef, modelsDirectory: URL) -> URL? {
        let store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
        // A download pinned to a commit writes no refs/ entry, so look up its snapshot directly.
        guard let snapshot = store.repositoryCacheDirectory(for: modelDef.repoId)?
                .appendingPathComponent("snapshots", isDirectory: true)
                .appendingPathComponent(modelDef.revision, isDirectory: true),
              store.isUsableModelDirectory(snapshot, requirements: Self.modelRequirements) else { return nil }
        return snapshot
    }

    private func removeIncompleteModelIfNeeded(_ modelDef: SOVTranscribeModelDef, modelsDirectory: URL) {
        let store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
        guard usableModelDirectory(for: modelDef, modelsDirectory: modelsDirectory) == nil,
              store.hasCachedModelFiles(for: modelDef.repoId, legacyDirectories: []) else {
            return
        }
        try? store.deleteModelFiles(for: modelDef.repoId, legacyDirectories: [])
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
        AnyView(SOVTranscribeSettingsView(plugin: self))
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

    /// The 4-bit MLX weights, pinned to one commit. Moving them to another repository
    /// with the same files changes only these two lines.
    static let modelRepoId = "nativ-community/SOV-Transcribe-1-4bit"
    static let modelRevision = "8a2f46d85735e55c0b6d1c8d882c570ed20d4d5c"

    static let availableModels: [SOVTranscribeModelDef] = [
        SOVTranscribeModelDef(
            id: "sov-transcribe-1-4bit",
            displayName: "SOV-Transcribe-1 (4-bit)",
            repoId: modelRepoId,
            revision: modelRevision,
            sizeDescription: "~15.6 GB",
            ramRequirement: "\(minimumMemoryGB) GB+"
        ),
    ]

    private static let modelDownloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

    /// Every shard is required, so an interrupted download of the 15.6 GB is not taken
    /// for a complete model.
    fileprivate static let modelRequirements = PluginHuggingFaceModelStore.Requirements(
        requiredFiles: [
            "config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors.index.json",
            "model-00001-of-00003.safetensors", "model-00002-of-00003.safetensors",
            "model-00003-of-00003.safetensors",
        ],
        weightFileExtensions: ["safetensors"]
    )

    // MARK: - Prompt and Limits

    static let sampleRate = 16_000
    /// The model encodes up to 30 minutes per call and stops the process beyond that.
    static let maximumChunkDuration: TimeInterval = 1_800
    static let maximumChunkSampleCount = Int(maximumChunkDuration) * sampleRate

    /// Short clips get at least this many tokens.
    static let minimumMaxTokens = 1_024
    /// Generous for fast speech: about three times what normal speech produces.
    static let maxTokensPerSecond = 10.0

    /// The token budget for a clip: grows with its length, never below
    /// `minimumMaxTokens`, never above what 30 minutes needs.
    static func maxTokens(forAudioDuration seconds: TimeInterval) -> Int {
        let ceiling = Int(maximumChunkDuration * maxTokensPerSecond)
        guard seconds.isFinite, seconds > 0 else { return minimumMaxTokens }
        let budget = Int((seconds * maxTokensPerSecond).rounded(.up))
        return min(ceiling, max(minimumMaxTokens, budget))
    }

    static let supportedLanguageCodes = ["en", "de", "fr", "es", "it", "pt", "nl"]

    private static let languageNames: [String: String] = [
        "en": "English",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "it": "Italian",
        "pt": "Portuguese",
        "nl": "Dutch",
    ]

    /// The model card's instruction when the language is unknown.
    static let automaticLanguageInstruction =
        "Transcribe the audio verbatim in the language's standard writing system, using punctuation and capitalization. Output only the transcript."

    /// The supported base language of a code such as "de" or "pt-BR", or nil for
    /// automatic detection and other languages.
    static func supportedLanguageCode(_ language: String?) -> String? {
        guard let language else { return nil }
        let base = language
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map { $0.lowercased() } ?? ""
        return languageNames[base] == nil ? nil : base
    }

    /// The model card's instructions: one naming the language, or one for any language.
    static func instruction(forLanguage language: String?) -> String {
        guard let code = supportedLanguageCode(language), let name = languageNames[code] else {
            return automaticLanguageInstruction
        }
        return "Transcribe the \(name) audio into text, ensuring all punctuation marks are included."
    }

    /// The host passes dictionary terms as "A, B" in the prompt. The model appends them
    /// to the instruction as "Contextual vocabulary: A, B".
    static func hotwords(fromPrompt prompt: String?) -> [String]? {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        return terms.isEmpty ? nil : terms
    }

    /// Reports a chunk's text after the text of the chunks before it.
    private static func progress(
        _ onProgress: (@Sendable (String) -> Bool)?,
        after finishedText: String
    ) -> (@Sendable (String) -> Bool)? {
        guard let onProgress else { return nil }
        return { text in onProgress(joined(finishedText, text)) }
    }

    private static func joined(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return "\(first) \(second)"
    }

    fileprivate static func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Model Types

struct SOVTranscribeModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let revision: String
    let sizeDescription: String
    let ramRequirement: String
}

enum SOVTranscribeModelState: Equatable {
    case notLoaded
    case loading
    case ready(String)
    case error(String)
}

// MARK: - Settings View

private struct SOVTranscribeSettingsView: View {
    let plugin: SOVTranscribePlugin
    private let bundle = Bundle(for: SOVTranscribePlugin.self)
    private let hostMemoryGB = SOVTranscribePlugin.hostMemoryGB
    @State private var modelState: SOVTranscribeModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var isPolling = false
    @State private var onDemandModelId: String?
    @State private var hfTokenInput = ""
    @State private var showHfToken = false
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var isSupported: Bool {
        SOVTranscribePlugin.isSupported(memoryGB: hostMemoryGB)
    }

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
            Text("SOV-Transcribe (MLX)")
                .font(.headline)

            Text("Local speech-to-text by Salesforce, powered by MLX on Apple Silicon. Transcribes English, German, French, Spanish, Italian, Portuguese and Dutch with punctuation. Needs a Mac with 32 GB of memory or more.", bundle: bundle)
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
                Text("Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(SOVTranscribePlugin.availableModels) { modelDef in
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
            selectedModelId = plugin.selectedModelId ?? SOVTranscribePlugin.availableModels.first?.id ?? ""
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
    private func modelRow(_ modelDef: SOVTranscribeModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                Text("Uses about 16 GB of memory while transcribing. Supports dictionary terms, no translation.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(isSupported ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                if !isSupported {
                    Text("This Mac has \(hostMemoryGB) GB of memory. SOV-Transcribe needs \(SOVTranscribePlugin.minimumMemoryGB) GB or more.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                        try? plugin.deleteModelFiles(modelDef)
                        modelState = plugin.modelState
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Unload \(modelDef.displayName)", bundle: bundle))
                }
            } else if modelDef.id == onDemandModelId, modelState == .notLoaded {
                PluginModelLoadsOnDemandStatus(bundle: bundle)
            } else {
                Button(String(localized: "Download & Load", bundle: bundle)) {
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
                .disabled(modelState == .loading || !isSupported)
                .accessibilityLabel(Text("Download and load \(modelDef.displayName)", bundle: bundle))
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
