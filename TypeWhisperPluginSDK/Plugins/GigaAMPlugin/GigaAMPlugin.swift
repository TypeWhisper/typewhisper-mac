import Combine
import Foundation
import HuggingFace
import SwiftUI
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(GigaAMPlugin)
final class GigaAMPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, DictionaryTermsCapabilityProviding, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PassiveModelRestoreProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gigaam"
    static let pluginName = "GigaAM"

    fileprivate var host: HostServices?
    fileprivate var _selectedModelId: String?
    fileprivate var runtime: GigaAMRuntime?
    fileprivate var loadedModelId: String?
    private let activationLock = NSRecursiveLock()
    private var _activationID = UUID()
    private var activationID: UUID {
        get { activationLock.withLock { _activationID } }
        set { activationLock.withLock { _activationID = newValue } }
    }
    fileprivate var _hfToken: String?

    fileprivate var modelState: GigaAMModelState = .notLoaded

    static let modelRequirements = PluginHuggingFaceModelStore.Requirements(
        requiredFiles: Set(GigaAMModelFiles.all),
        weightFileExtensions: ["onnx"]
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
            runtime = nil
            loadedModelId = nil
            modelState = .notLoaded
            host = nil
        }
    }

    // MARK: - TranscriptionEnginePlugin

    var providerId: String { "gigaam" }
    var providerDisplayName: String { "GigaAM (Russian)" }

    var isConfigured: Bool {
        runtime != nil && loadedModelId != nil
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        host?.shouldRestoreLoadedModelsPassively ?? true
    }

    var transcriptionModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return Self.availableModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName, languageCount: 1) }
    }

    var availableModels: [PluginModelInfo] {
        Self.availableModels.map { def in
            PluginModelInfo(
                id: def.id,
                displayName: def.displayName,
                sizeDescription: def.sizeDescription,
                languageCount: 1,
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
                    languageCount: 1,
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

    /// GigaAM v3 only recognizes Russian.
    var supportedLanguages: [String] { ["ru"] }

    var selectedModelId: String? { _selectedModelId }

    func selectModel(_ modelId: String) {
        activationLock.withLock {
            if _selectedModelId != modelId || (loadedModelId != nil && loadedModelId != modelId) {
                unloadModel(clearPersistence: true)
            }
            _selectedModelId = modelId
            host?.setUserDefault(modelId, forKey: "selectedModel")
            guard loadedModelId != modelId, modelState != .loading,
                  let definition = Self.availableModels.first(where: { $0.id == modelId }),
                  hasDownloadedModel(definition) else { return }
            // Advertise the cached restore immediately so a generic request cannot replace it.
            modelState = .loading
            let generation = activationID
            genericModelLoadTask = Task {
                guard !Task.isCancelled, generation == activationID, host != nil else { return }
                try? await loadModel(definition, expectedGeneration: generation)
            }
        }
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
            guard let runtime else { throw PluginTranscriptionError.notConfigured }
            guard !translate else {
                throw PluginTranscriptionError.apiError("GigaAM cannot translate. It only transcribes Russian.")
            }
            let progress = GigaAMTranscriptProgress()
            do {
                let result = try await PluginAudioChunking.transcribe(
                    audio, maximumChunkDuration: GigaAMRuntime.maximumChunkDuration
                ) { chunk in
                    try Task.checkCancellation()
                    let text = progress.continuing(try runtime.transcribe(chunk.samples))
                    try Task.checkCancellation()
                    guard onProgress(progress.append(text)) else { throw CancellationError() }
                    return PluginTranscriptionResult(text: text, detectedLanguage: "ru")
                }
                return PluginTranscriptionResult(text: result.text, detectedLanguage: "ru", segments: result.segments)
            } catch let error as CancellationError {
                throw error
            } catch let error as PluginTranscriptionError {
                throw error
            } catch {
                // ONNX Runtime and model errors are unknown to the host; report them as engine errors.
                throw PluginTranscriptionError.apiError("GigaAM transcription failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Model Management

    fileprivate func loadModel(_ modelDef: GigaAMModelDef, passively: Bool = false,
                               expectedGeneration: UUID? = nil) async throws {
        let generation = expectedGeneration ?? activationID
        try await modelLoadGate.withLock { [self] in
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            if passively {
                guard host?.shouldRestoreLoadedModelsPassively == true, !isConfigured else { return }
            }
            guard !(isConfigured && loadedModelId == modelDef.id) else { return }
            try await performModelLoad(modelDef, allowDownloads: !passively, generation: generation)
        }
    }

    private func performModelLoad(_ modelDef: GigaAMModelDef, allowDownloads: Bool, generation: UUID) async throws {
        try activationLock.withLock {
            try Task.checkCancellation()
            guard generation == activationID, host != nil else { throw CancellationError() }
            modelState = .loading
        }
        do {
            let modelsDir = modelsDirectory ?? FileManager.default.temporaryDirectory
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
                modelDirectory = try await downloadModel(modelDef, modelsDirectory: modelsDir)
            }
            guard let preprocessorURL = Self.preprocessorURL else {
                throw GigaAMRuntimeError.missingOutput("preprocessor")
            }
            try activationLock.withLock {
                try Task.checkCancellation()
                guard generation == activationID, host != nil else { throw CancellationError() }
                runtime = nil
                loadedModelId = nil
            }
            let loaded = try GigaAMRuntime(modelDirectory: modelDirectory, preprocessorURL: preprocessorURL)

            try activationLock.withLock {
                try Task.checkCancellation()
                guard generation == activationID, host != nil else { throw CancellationError() }
                runtime = loaded
                loadedModelId = modelDef.id
                _selectedModelId = modelDef.id
                host?.setUserDefault(modelDef.id, forKey: "selectedModel")
                host?.setUserDefault(modelDef.id, forKey: "loadedModel")
                modelState = .ready(modelDef.id)
                host?.notifyCapabilitiesChanged()
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

    private func downloadModel(_ modelDef: GigaAMModelDef, modelsDirectory: URL) async throws -> URL {
        removeIncompleteModelIfNeeded(modelDef, modelsDirectory: modelsDirectory)
        guard let repoID = Repo.ID(rawValue: modelDef.repoId) else {
            throw NSError(domain: "GigaAMPlugin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid repository ID: \(modelDef.repoId)"])
        }
        let spaceReservation = try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
            repositoryID: modelDef.repoId,
            matching: GigaAMModelFiles.all,
            token: _hfToken,
            destination: modelsDirectory,
            trackedDirectory: PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
                .repositoryCacheDirectory(for: modelDef.repoId),
            // HubClient downloads through URLSession's temporary directory.
            stagingDirectory: FileManager.default.temporaryDirectory,
            modelName: modelDef.displayName
        )
        defer { spaceReservation?.release() }
        let client = HubClient(
            host: HubClient.defaultHost,
            bearerToken: PluginHuggingFaceTokenHelper.normalizedToken(_hfToken),
            cache: HubCache(cacheDirectory: modelsDirectory)
        )
        do {
            let directory = try await client.downloadSnapshot(of: repoID, matching: GigaAMModelFiles.all)
            guard PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
                .isUsableModelDirectory(directory, requirements: Self.modelRequirements) else {
                throw NSError(domain: "GigaAMPlugin", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Downloaded model is incomplete: \(modelDef.repoId)"])
            }
            return directory
        } catch {
            removeIncompleteModelIfNeeded(modelDef, modelsDirectory: modelsDirectory)
            throw error
        }
    }

    /// The feature extractor ships with the plugin; only the model weights are downloaded.
    static var preprocessorURL: URL? {
        pluginModuleBundle.url(forResource: "gigaam_v3_preprocessor", withExtension: "onnx")
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
            passiveRestoreController.cancel()
            runtime = nil
            loadedModelId = nil
            modelState = .notLoaded
            if clearPersistence {
                host?.setUserDefault(nil, forKey: "loadedModel")
            }
            host?.notifyCapabilitiesChanged()
        }
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

    private var modelsDirectory: URL? {
        host?.pluginDataDirectory.appendingPathComponent("models")
    }

    private func hasDownloadedModel(_ modelDef: GigaAMModelDef) -> Bool {
        guard let modelsDirectory else { return false }
        return usableModelDirectory(for: modelDef, modelsDirectory: modelsDirectory) != nil
    }

    private func usableModelDirectory(for modelDef: GigaAMModelDef, modelsDirectory: URL) -> URL? {
        PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory).usableModelDirectory(
            for: modelDef.repoId,
            legacyDirectories: [],
            requirements: Self.modelRequirements
        )
    }

    private func removeIncompleteModelIfNeeded(_ modelDef: GigaAMModelDef, modelsDirectory: URL) {
        let store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
        guard usableModelDirectory(for: modelDef, modelsDirectory: modelsDirectory) == nil,
              store.hasCachedModelFiles(for: modelDef.repoId, legacyDirectories: []) else {
            return
        }
        try? store.deleteModelFiles(for: modelDef.repoId, legacyDirectories: [])
    }

    fileprivate func deleteModelFiles(_ modelDef: GigaAMModelDef) throws {
        guard let modelsDirectory else { return }
        try PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
            .deleteModelFiles(for: modelDef.repoId, legacyDirectories: [])
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
        AnyView(GigaAMSettingsView(plugin: self))
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

    static let availableModels: [GigaAMModelDef] = [
        GigaAMModelDef(
            id: "gigaam-v3-e2e-rnnt",
            displayName: "GigaAM v3 (Russian, with punctuation)",
            repoId: "istupakov/gigaam-v3-onnx",
            sizeDescription: "~230 MB",
            ramRequirement: "2 GB+"
        ),
    ]
}

private let pluginModuleBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: GigaAMPlugin.self)
#endif
}()

/// Collects chunk transcripts for progress updates while a long recording is transcribed.
final class GigaAMTranscriptProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []

    func append(_ text: String) -> String {
        lock.withLock {
            if !text.isEmpty { parts.append(text) }
            return parts.joined(separator: " ")
        }
    }

    /// GigaAM capitalizes the first word of every chunk. When the previous chunk ended without
    /// closing a sentence, the cut fell mid-sentence, so that word is lowercased. A proper noun
    /// right after such a cut loses its capital, which is rarer than an ordinary word there.
    func continuing(_ text: String) -> String {
        let previous = lock.withLock { parts.last }
        guard let last = previous?.last, !".!?…".contains(last),
              let first = text.first, first.isUppercase,
              let second = text.dropFirst().first, second.isLowercase else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

// MARK: - Model Types

struct GigaAMModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
}

enum GigaAMModelState: Equatable {
    case notLoaded
    case loading
    case ready(String)
    case error(String)
}

// MARK: - Settings View

private struct GigaAMSettingsView: View {
    let plugin: GigaAMPlugin
    private let bundle = pluginModuleBundle
    @State private var modelState: GigaAMModelState = .notLoaded
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GigaAM (Russian)", bundle: bundle)
                .font(.headline)

            Text("Local Russian speech recognition with GigaAM v3 by Sber. Adds punctuation and capitalization and runs on the CPU. It only recognizes Russian, so recordings in other languages are transcribed as Russian.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            tokenSection

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Model", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                ForEach(GigaAMPlugin.availableModels) { modelDef in
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
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != storedHfToken {
                tokenValidationResult = nil
            }
        }
    }

    private var tokenSection: some View {
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

                if !storedHfToken.isEmpty {
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
    }

    @ViewBuilder
    private func modelRow(_ modelDef: GigaAMModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                Text(verbatim: "\(modelDef.sizeDescription) - RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .loading = modelState {
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
