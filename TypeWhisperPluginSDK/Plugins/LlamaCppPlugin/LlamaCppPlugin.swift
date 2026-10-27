import Combine
import Foundation
import HuggingFace
import SwiftUI
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK
import os

/// Screenshot runs must never reach Hugging Face or GitHub.
enum LlamaCppNetworkAccessPolicy {
    static func ensureAccessIsAllowed(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws {
        guard !arguments.contains("--store-screenshots") else {
            throw URLError(.notConnectedToInternet)
        }
    }
}

enum LlamaCppModelState: Equatable, Sendable {
    case notLoaded
    case downloading
    case loading
    case ready(String)
    case error(String)
}

// MARK: - Plugin Entry Point

/// Runs GGUF language models on this Mac with llama.cpp's `llama-server`.
///
/// The plugin downloads a pinned llama.cpp build (see `LlamaCppRuntimeRelease.pinned`) and
/// starts `llama-server` on a random loopback port for the loaded model. Prompts go to its
/// OpenAI-style chat endpoint. Models come from a pinned catalog, from any Hugging Face GGUF
/// repository, or from a local `.gguf` file. A model may name a multimodal projector, which
/// the server receives with `--mmproj`; audio input for transcription can build on that.
@objc(LlamaCppPlugin)
final class LlamaCppPlugin: NSObject, ObservableObject, LLMProviderPlugin, LLMProviderIdentityProviding,
    LLMTemperatureControllableProvider, LLMProviderSetupStatusProviding, LLMModelSelectable,
    PluginSettingsActivityReporting, PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.typewhisper.local-llm-llamacpp"
    static let pluginName = "Local LLM (llama.cpp)"
    static let defaultGenerationTemperature = 0.1

    private enum DefaultsKey {
        static let selectedModel = "selectedLLMModel"
        static let loadedModel = "loadedModel"
        static let temperature = "generationTemperature"
        static let temperatureMode = "llmTemperatureMode"
    }

    private static let logger = Logger(subsystem: pluginId, category: "Plugin")
    private static let downloadProgressShare = 0.85
    private static let preparingProgress = 0.9
    private static let minimumVisibleDownloadProgress = 0.01

    private(set) var host: HostServices?
    @Published private(set) var modelState: LlamaCppModelState = .notLoaded
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var customModels: [LlamaCppModelDefinition] = []
    @Published private(set) var isImportingModel = false
    /// The model the current load works on, for the settings row that shows its progress.
    @Published private(set) var loadingModelId: String?
    private(set) var loadedModelId: String?
    /// Whether the current load error points at broken files that a fresh download can fix.
    private(set) var loadErrorSuggestsCacheReset = false

    private var selectedModelIdStorage: String?
    private var generationTemperatureStorage = defaultGenerationTemperature
    private var temperatureModeRaw = PluginLLMTemperatureMode.custom.rawValue
    private var huggingFaceTokenStorage: String?
    private let server = LlamaCppServer()
    private var loadGeneration = 0
    private var activeLoadTask: Task<Void, Never>?
    private var fallbackDataDirectory: URL?

    required override init() {
        super.init()
        server.onUnexpectedExit = { [weak self] outputTail in
            Task { @MainActor in
                self?.handleUnexpectedServerExit(outputTail: outputTail)
            }
        }
    }

    // MARK: - Lifecycle

    func activate(host: HostServices) {
        self.host = host
        selectedModelIdStorage = host.userDefault(forKey: DefaultsKey.selectedModel) as? String
        generationTemperatureStorage = host.userDefault(forKey: DefaultsKey.temperature) as? Double
            ?? Self.defaultGenerationTemperature
        temperatureModeRaw = host.userDefault(forKey: DefaultsKey.temperatureMode) as? String
            ?? PluginLLMTemperatureMode.custom.rawValue
        huggingFaceTokenStorage = PluginHuggingFaceTokenHelper.loadToken(from: host)
        customModels = customModelStore.load()
        runtime.removeInterruptedInstallFiles()
        if modelDefinition(for: selectedModelIdStorage) == nil {
            selectedModelIdStorage = LlamaCppModelCatalog.recommendedModel()?.id
        }

        if host.shouldRestoreLoadedModelsPassively,
           let persisted = host.userDefault(forKey: DefaultsKey.loadedModel) as? String {
            if let model = modelDefinition(for: persisted), canLoadWithoutDownload(model) {
                Self.runOnMain { [weak self] in
                    self?.startLoading(model)
                }
            } else {
                host.setUserDefault(nil, forKey: DefaultsKey.loadedModel)
            }
        }
    }

    func deactivate() {
        invalidateLoad()
        server.stop()
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { Self.pluginName }
    var providerId: String { Self.pluginName }
    var providerDisplayName: String { Self.pluginName }

    var isAvailable: Bool {
        loadedModelId != nil && server.session != nil
    }

    var supportedModels: [PluginModelInfo] {
        guard let loadedModelId, let model = modelDefinition(for: loadedModelId) else { return [] }
        return [PluginModelInfo(id: model.id, displayName: model.displayName)]
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserText.isEmpty else { throw LlamaCppPluginError.noInputText }

        let temperature = providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective)
            ?? Self.defaultGenerationTemperature
        let request = LlamaCppChatClient.makeRequest(
            systemPrompt: systemPrompt,
            userText: trimmedUserText,
            temperature: min(max(temperature, 0), 2)
        )
        let server = server
        return try await PluginLocalInferenceGate.shared.withLock {
            guard let session = server.session else { throw LlamaCppPluginError.modelNotLoaded }
            let output = try await LlamaCppChatClient.complete(request, session: session)
            return Self.finalPromptOutput(output)
        }
    }

    /// Removes reasoning that templates emit even with thinking disabled.
    static func finalPromptOutput(_ output: String) -> String {
        var result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Templates that open the reasoning block themselves only leave the closing tag.
        if let end = result.range(of: "</think>", options: [.caseInsensitive, .backwards]),
           result.range(of: "<think>", options: .caseInsensitive, range: result.startIndex..<end.lowerBound) == nil {
            result = String(result[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let start = result.range(of: "<think>", options: .caseInsensitive) {
            if let end = result.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                // Unterminated reasoning never contains the requested text.
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    // MARK: - Setup status, selection and temperature

    var requiresExternalCredentials: Bool { false }

    var unavailableReason: String? {
        if isAvailable { return nil }
        if case .error(let message) = modelState, !message.isEmpty {
            return message
        }
        return LlamaCppPluginError.modelNotLoaded.errorDescription
    }

    var selectedLLMModelId: String? { selectedModelIdStorage }
    var preferredModelId: String? { selectedModelIdStorage }
    var defaultModelId: String? { LlamaCppModelCatalog.recommendedModel()?.id }

    func selectLLMModel(_ modelId: String) {
        guard modelDefinition(for: modelId) != nil else { return }
        selectedModelIdStorage = modelId
        host?.setUserDefault(modelId, forKey: DefaultsKey.selectedModel)
    }

    var generationTemperature: Double { generationTemperatureStorage }

    var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: temperatureModeRaw) ?? .custom
    }

    private var providerTemperatureDirective: PluginLLMTemperatureDirective {
        switch llmTemperatureMode {
        case .providerDefault:
            return .custom(Self.defaultGenerationTemperature)
        case .custom, .inheritProviderSetting:
            return .custom(generationTemperatureStorage)
        }
    }

    func setGenerationTemperature(_ temperature: Double) {
        let clamped = min(max(temperature, 0), 1)
        generationTemperatureStorage = clamped
        host?.setUserDefault(clamped, forKey: DefaultsKey.temperature)
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        let stored: PluginLLMTemperatureMode = mode == .providerDefault ? .providerDefault : .custom
        temperatureModeRaw = stored.rawValue
        host?.setUserDefault(stored.rawValue, forKey: DefaultsKey.temperatureMode)
    }

    var huggingFaceToken: String? { huggingFaceTokenStorage }

    func saveHuggingFaceToken(_ token: String) {
        huggingFaceTokenStorage = PluginHuggingFaceTokenHelper.saveToken(token, to: host)
    }

    func clearHuggingFaceToken() {
        huggingFaceTokenStorage = nil
        PluginHuggingFaceTokenHelper.clearToken(from: host)
    }

    func validateHuggingFaceToken(_ token: String) async -> Bool {
        await PluginHuggingFaceTokenHelper.validateToken(token)
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        host?.shouldRestoreLoadedModelsPassively ?? true
    }

    var modelIdLoadedOnDemand: String? {
        host?.modelIdLoadedOnDemand
    }

    // MARK: - Settings activity

    var hasVisibleDownloadProgress: Bool {
        downloadProgress >= Self.minimumVisibleDownloadProgress
    }

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(
                message: "Downloading model",
                progress: hasVisibleDownloadProgress ? downloadProgress : nil
            )
        case .loading:
            return PluginSettingsActivity(message: "Preparing model")
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(LlamaCppSettingsView(plugin: self))
    }

    // MARK: - Models and files

    var allModels: [LlamaCppModelDefinition] {
        LlamaCppModelCatalog.models + customModels
    }

    func modelDefinition(for id: String?) -> LlamaCppModelDefinition? {
        guard let id else { return nil }
        return allModels.first { $0.id == id }
    }

    var dataDirectory: URL {
        if let host { return host.pluginDataDirectory }
        if let fallbackDataDirectory { return fallbackDataDirectory }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-llm-llamacpp-\(UUID().uuidString)", isDirectory: true)
        fallbackDataDirectory = directory
        return directory
    }

    var runtime: LlamaCppRuntimeInstallation {
        LlamaCppRuntimeInstallation(
            runtimesDirectory: dataDirectory.appendingPathComponent("Runtime", isDirectory: true)
        )
    }

    private var modelsDirectory: URL {
        dataDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    private var customModelStore: LlamaCppCustomModelStore {
        LlamaCppCustomModelStore(fileURL: dataDirectory.appendingPathComponent("custom-models.json"))
    }

    func modelDirectory(for model: LlamaCppModelDefinition) -> URL {
        modelsDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    func weightsURL(for model: LlamaCppModelDefinition) -> URL {
        modelDirectory(for: model).appendingPathComponent(model.fileName)
    }

    func projectorURL(for model: LlamaCppModelDefinition) -> URL? {
        model.projector.map { modelDirectory(for: model).appendingPathComponent($0.fileName) }
    }

    /// Whether every file of the model is present and verified.
    func isModelDownloaded(_ model: LlamaCppModelDefinition) -> Bool {
        let weightsVerified = LlamaCppVerificationMarker.isVerified(
            weightsURL(for: model),
            expectedSize: model.fileSize,
            expectedSHA256: model.weights?.sha256
        )
        guard weightsVerified else { return false }
        guard let projector = model.projector, let projectorURL = projectorURL(for: model) else { return true }
        return LlamaCppVerificationMarker.isVerified(
            projectorURL,
            expectedSize: projector.size,
            expectedSHA256: projector.sha256
        )
    }

    /// Whether any file of the model exists, including partial or unverified downloads.
    func hasModelFiles(_ model: LlamaCppModelDefinition) -> Bool {
        FileManager.default.fileExists(atPath: modelDirectory(for: model).path)
    }

    private func canLoadWithoutDownload(_ model: LlamaCppModelDefinition) -> Bool {
        runtime.isInstalled && isModelDownloaded(model)
    }

    var downloadedModels: [PluginModelInfo] {
        allModels.filter(isModelDownloaded).map { model in
            PluginModelInfo(
                id: model.id,
                displayName: model.displayName,
                sizeDescription: model.sizeDescription,
                downloaded: true,
                loaded: model.id == loadedModelId
            )
        }
    }

    @MainActor
    func deleteDownloadedModel(_ modelId: String) async throws {
        guard let model = modelDefinition(for: modelId) else { return }
        // An imported model has nothing left to download once its copy is gone.
        try removeModel(model, keepCustomEntry: model.origin == .huggingFace)
    }

    /// Deletes the model's files. Custom models also leave the list unless `keepCustomEntry`.
    @MainActor
    func removeModel(_ model: LlamaCppModelDefinition, keepCustomEntry: Bool = false) throws {
        if loadedModelId == model.id || loadingModelId == model.id {
            unloadModel()
        }
        if host?.userDefault(forKey: DefaultsKey.loadedModel) as? String == model.id {
            host?.setUserDefault(nil, forKey: DefaultsKey.loadedModel)
        }
        let directory = modelDirectory(for: model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        if model.isCustom, !keepCustomEntry {
            customModels.removeAll { $0.id == model.id }
            try customModelStore.save(customModels)
            if selectedModelIdStorage == model.id {
                selectedModelIdStorage = LlamaCppModelCatalog.recommendedModel()?.id
                host?.setUserDefault(nil, forKey: DefaultsKey.selectedModel)
            }
        }
        if case .error = modelState { modelState = .notLoaded }
        objectWillChange.send()
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Loading

    /// Starts loading `model`, downloading the runtime and files first when needed.
    @MainActor
    func startLoading(_ model: LlamaCppModelDefinition) {
        let generation = beginLoad(model)
        activeLoadTask = Task { @MainActor [weak self] in
            try? await self?.performLoad(model, generation: generation)
        }
    }

    /// Loads `model` and returns once it is ready or failed.
    @MainActor
    func loadModel(_ model: LlamaCppModelDefinition) async throws {
        let generation = beginLoad(model)
        try await performLoad(model, generation: generation)
    }

    @MainActor
    func cancelLoad() {
        invalidateLoad()
        server.stop()
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        host?.notifyCapabilitiesChanged()
    }

    @MainActor
    func unloadModel(clearPersistence: Bool = true) {
        invalidateLoad()
        server.stop()
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: DefaultsKey.loadedModel)
        }
        host?.notifyCapabilitiesChanged()
    }

    @objc func triggerAutoUnload() {
        Self.runOnMain { [weak self] in
            self?.unloadModel(clearPersistence: false)
        }
    }

    /// Reloads the last loaded model, for example after auto-unload. The state changes
    /// synchronously so the host sees the load activity right away.
    @objc func triggerRestoreModel() {
        Self.runOnMain { [weak self] in
            guard let self else { return }
            switch self.modelState {
            case .downloading, .loading, .ready:
                return
            case .notLoaded, .error:
                break
            }
            guard let savedId = self.host?.userDefault(forKey: DefaultsKey.loadedModel) as? String,
                  let model = self.modelDefinition(for: savedId) else {
                return
            }
            self.startLoading(model)
        }
    }

    @MainActor
    private func beginLoad(_ model: LlamaCppModelDefinition) -> Int {
        invalidateLoad()
        loadGeneration += 1
        loadingModelId = model.id
        selectedModelIdStorage = model.id
        loadErrorSuggestsCacheReset = false
        let needsDownload = !runtime.isInstalled || !isModelDownloaded(model)
        modelState = needsDownload && model.origin != .importedFile ? .downloading : .loading
        downloadProgress = needsDownload ? 0 : Self.preparingProgress
        host?.notifyCapabilitiesChanged()
        return loadGeneration
    }

    @MainActor
    private func performLoad(_ model: LlamaCppModelDefinition, generation: Int) async throws {
        do {
            try await prepareFiles(for: model, generation: generation)
            try Task.checkCancellation()
            guard isCurrentLoad(generation) else { return }
            modelState = .loading
            downloadProgress = max(downloadProgress, Self.preparingProgress)
            host?.notifyCapabilitiesChanged()

            try await server.start(
                executableURL: runtime.serverExecutableURL,
                options: LlamaCppServerLaunchOptions(
                    modelURL: weightsURL(for: model),
                    projectorURL: projectorURL(for: model)
                )
            )
            guard isCurrentLoad(generation) else { return }
            loadedModelId = model.id
            loadingModelId = nil
            selectedModelIdStorage = model.id
            host?.setUserDefault(model.id, forKey: DefaultsKey.selectedModel)
            host?.setUserDefault(model.id, forKey: DefaultsKey.loadedModel)
            downloadProgress = 1
            modelState = .ready(model.id)
            host?.notifyCapabilitiesChanged()
        } catch {
            guard isCurrentLoad(generation) else { throw error }
            if error is CancellationError {
                cancelLoad()
                throw error
            }
            server.stop()
            loadedModelId = nil
            downloadProgress = 0
            loadErrorSuggestsCacheReset = (error as? LlamaCppPluginError)?.suggestsCacheReset ?? false
            modelState = .error(Self.userFacingMessage(for: error))
            host?.setUserDefault(nil, forKey: DefaultsKey.loadedModel)
            host?.notifyCapabilitiesChanged()
            Self.logger.error("Loading \(model.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Installs the runtime and downloads or verifies the model files.
    @MainActor
    private func prepareFiles(for model: LlamaCppModelDefinition, generation: Int) async throws {
        let runtime = runtime
        var remoteFiles: [(file: LlamaCppRemoteFile, destination: URL)] = []
        if let weights = model.weights {
            remoteFiles.append((weights, weightsURL(for: model)))
        } else if !LlamaCppVerificationMarker.isVerified(
            weightsURL(for: model),
            expectedSize: model.fileSize,
            expectedSHA256: nil
        ) {
            throw LlamaCppPluginError.importedFileMissing(model.fileName)
        }
        if let projector = model.projector, let projectorURL = projectorURL(for: model) {
            remoteFiles.append((projector, projectorURL))
        }

        // Files with the right size but no marker only need their checksum checked.
        for entry in remoteFiles where !Self.isVerified(entry.file, at: entry.destination)
            && LlamaCppFileChecks.fileSize(of: entry.destination) == entry.file.size {
            do {
                try await LlamaCppFileChecks.verify(
                    entry.destination,
                    expectedSize: entry.file.size,
                    expectedSHA256: entry.file.sha256
                )
                try LlamaCppVerificationMarker.write(for: entry.destination, sha256: entry.file.sha256)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: entry.destination)
            }
        }

        let missingFiles = remoteFiles.filter { !Self.isVerified($0.file, at: $0.destination) }
        let runtimeBytes = runtime.missingDownloadBytes
        let totalBytes = runtimeBytes + missingFiles.reduce(0) { $0 + $1.file.size }
        guard totalBytes > 0 else { return }

        try LlamaCppNetworkAccessPolicy.ensureAccessIsAllowed()
        try host?.requireModelDownloadAllowed()
        modelState = .downloading
        host?.notifyCapabilitiesChanged()

        let reservation = try PluginDownloadDiskSpace.reserve(
            downloadBytes: totalBytes,
            destination: dataDirectory,
            trackedDirectory: dataDirectory,
            stagingDirectory: FileManager.default.temporaryDirectory,
            stagingBytes: max(runtimeBytes, missingFiles.map(\.file.size).max() ?? 0),
            modelName: model.displayName
        )
        defer { reservation?.release() }

        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        var completedBytes: Int64 = 0
        // `offset` is the byte count of finished downloads, `fraction` the share of the
        // whole download that the running one has completed.
        let reportProgress: @Sendable (Int64, Double) -> Void = { [weak self] offset, fraction in
            let overall = min(max(Double(offset) / Double(totalBytes) + fraction, 0), 1)
            Task { @MainActor in
                guard let self, self.isCurrentLoad(generation), self.modelState == .downloading else { return }
                let mapped = overall * Self.downloadProgressShare
                guard mapped - self.downloadProgress >= 0.001 || overall >= 1 else { return }
                self.downloadProgress = max(self.downloadProgress, mapped)
                self.host?.notifyCapabilitiesChanged()
            }
        }

        if runtimeBytes > 0 {
            let share = Double(runtimeBytes) / Double(totalBytes)
            try await runtime.install(session: session) { fraction in
                reportProgress(0, fraction * share)
            }
            completedBytes += runtimeBytes
        }
        for entry in missingFiles {
            try Task.checkCancellation()
            let offset = completedBytes
            let share = Double(entry.file.size) / Double(totalBytes)
            try await Self.download(
                entry.file,
                to: entry.destination,
                session: session,
                token: huggingFaceTokenStorage
            ) { fraction in
                reportProgress(offset, fraction * share)
            }
            completedBytes += entry.file.size
        }
    }

    private static func isVerified(_ file: LlamaCppRemoteFile, at url: URL) -> Bool {
        LlamaCppVerificationMarker.isVerified(url, expectedSize: file.size, expectedSHA256: file.sha256)
    }

    /// Downloads one pinned Hugging Face file and keeps it only when size and SHA-256 match.
    static func download(
        _ file: LlamaCppRemoteFile,
        to destination: URL,
        session: URLSession,
        token: String?,
        host: URL = HubClient.defaultHost,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let repositoryId = Repo.ID(rawValue: file.repositoryId) else {
            throw LlamaCppPluginError.invalidRepositoryIdentifier(file.repositoryId)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        LlamaCppVerificationMarker.remove(for: destination)
        try? FileManager.default.removeItem(at: destination)

        let client = HubClient(
            session: session,
            host: host,
            userAgent: "TypeWhisper-LocalLLM-llama.cpp",
            bearerToken: PluginHuggingFaceTokenHelper.normalizedToken(token),
            cache: nil
        )
        let progress = Progress(totalUnitCount: 1)
        let samplingTask = Task {
            while !Task.isCancelled {
                let fraction = progress.fractionCompleted
                progressHandler(fraction.isFinite ? min(max(fraction, 0), 1) : 0)
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
        }
        defer { samplingTask.cancel() }

        _ = try await client.downloadFile(
            at: file.path,
            from: repositoryId,
            to: destination,
            revision: file.revision,
            progress: progress
        )
        progressHandler(1)
        do {
            try await LlamaCppFileChecks.verify(destination, expectedSize: file.size, expectedSHA256: file.sha256)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try LlamaCppVerificationMarker.write(for: destination, sha256: file.sha256)
    }

    @MainActor
    private func handleUnexpectedServerExit(outputTail: String) {
        guard loadedModelId != nil else { return }
        loadedModelId = nil
        downloadProgress = 0
        let message = LlamaCppPluginError.lastErrorLine(in: outputTail)
            .map { "\(Self.localized("The model server stopped unexpectedly.")) \($0)" }
            ?? Self.localized("The model server stopped unexpectedly.")
        // The persisted model stays, so the next prompt restarts the server.
        modelState = .error(message)
        host?.notifyCapabilitiesChanged()
    }

    private func invalidateLoad() {
        loadGeneration += 1
        activeLoadTask?.cancel()
        activeLoadTask = nil
        loadingModelId = nil
    }

    private func isCurrentLoad(_ generation: Int) -> Bool {
        generation == loadGeneration
    }

    static func userFacingMessage(for error: Error) -> String {
        if let pluginError = error as? LlamaCppPluginError, let description = pluginError.errorDescription {
            return description
        }
        if let refusal = error as? PluginModelDownloadRefusedError {
            return refusal.reason
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return localized("The download timed out. Try again. An optional Hugging Face token in this plugin can raise download rate limits.")
        }
        return error.localizedDescription
    }

    // MARK: - Custom models

    /// Finds the GGUF files of a Hugging Face repository for `input`.
    func lookUpHuggingFaceModels(_ input: String) async throws -> LlamaCppHuggingFaceLookupResult {
        let reference = try LlamaCppHuggingFaceReference.parse(input)
        try LlamaCppNetworkAccessPolicy.ensureAccessIsAllowed()
        return try await LlamaCppHuggingFaceLookup.lookUp(reference, token: huggingFaceTokenStorage)
    }

    /// Adds a GGUF file from Hugging Face to the model list; it downloads when loaded.
    @MainActor
    @discardableResult
    func addHuggingFaceModel(_ file: LlamaCppRemoteFile) throws -> LlamaCppModelDefinition {
        guard Repo.ID(rawValue: file.repositoryId) != nil else {
            throw LlamaCppPluginError.invalidRepositoryIdentifier(file.repositoryId)
        }
        guard !LlamaCppGGUFFileName.isProjector(file.path) else { throw LlamaCppPluginError.projectorIsNotAModel }
        guard !LlamaCppGGUFFileName.isSplitPart(file.path) else { throw LlamaCppPluginError.splitFileUnsupported }
        let isDuplicate = allModels.contains { existing in
            existing.weights?.repositoryId.lowercased() == file.repositoryId.lowercased()
                && existing.weights?.path == file.path
        }
        guard !isDuplicate else { throw LlamaCppPluginError.duplicateModel }

        let stem = LlamaCppGGUFFileName.stem(file.path)
        let model = LlamaCppModelDefinition(
            id: LlamaCppModelIdentifier.unique(
                prefix: "hf",
                name: "\(file.repositoryId)-\(stem)",
                existingIds: Set(allModels.map(\.id))
            ),
            displayName: stem,
            origin: .huggingFace,
            fileName: Self.safeFileName(file.fileName),
            fileSize: file.size,
            weights: file
        )
        try saveCustomModel(model)
        return model
    }

    /// Copies a local GGUF file into the plugin's model folder. On APFS the copy is a clone
    /// and takes no extra disk space.
    @MainActor
    @discardableResult
    func importModelFile(_ url: URL) async throws -> LlamaCppModelDefinition {
        guard LlamaCppGGUFFileName.isGGUF(url.lastPathComponent) else { throw LlamaCppPluginError.notAGGUFFile }
        guard !LlamaCppGGUFFileName.isProjector(url.lastPathComponent) else {
            throw LlamaCppPluginError.projectorIsNotAModel
        }
        guard !LlamaCppGGUFFileName.isSplitPart(url.lastPathComponent) else {
            throw LlamaCppPluginError.splitFileUnsupported
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard LlamaCppFileChecks.hasGGUFHeader(url), let size = LlamaCppFileChecks.fileSize(of: url) else {
            throw LlamaCppPluginError.notAGGUFFile
        }
        let fileName = Self.safeFileName(url.lastPathComponent)
        let isDuplicate = customModels.contains { $0.origin == .importedFile && $0.fileName == fileName && $0.fileSize == size }
        guard !isDuplicate else { throw LlamaCppPluginError.duplicateModel }

        let stem = LlamaCppGGUFFileName.stem(fileName)
        let model = LlamaCppModelDefinition(
            id: LlamaCppModelIdentifier.unique(prefix: "file", name: stem, existingIds: Set(allModels.map(\.id))),
            displayName: stem,
            origin: .importedFile,
            fileName: fileName,
            fileSize: size,
            weights: nil
        )
        let destination = weightsURL(for: model)
        isImportingModel = true
        defer { isImportingModel = false }
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: destination)
            try LlamaCppVerificationMarker.write(for: destination, sha256: nil)
        }.value
        do {
            try saveCustomModel(model)
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
        return model
    }

    @MainActor
    private func saveCustomModel(_ model: LlamaCppModelDefinition) throws {
        let updated = customModels + [model]
        try customModelStore.save(updated)
        customModels = updated
        host?.notifyCapabilitiesChanged()
    }

    /// A file name without path separators or a leading dot.
    static func safeFileName(_ name: String) -> String {
        var cleaned = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "model.gguf" : cleaned
    }

    // MARK: - Helpers

    static func localized(_ key: String) -> String {
        Bundle(for: LlamaCppPlugin.self).localizedString(forKey: key, value: key, table: nil)
    }

    private static func runOnMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            Task { @MainActor in body() }
        }
    }

    #if DEBUG
    func setCustomModelsForTesting(_ models: [LlamaCppModelDefinition]) {
        customModels = models
    }
    #endif
}
