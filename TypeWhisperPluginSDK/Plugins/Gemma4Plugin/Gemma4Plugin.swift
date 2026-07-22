import Foundation
import Combine
import SwiftUI
import MLX
import MLXLLM
import MLXLMCommon
import HuggingFace
import Hub
import Tokenizers
import TypeWhisperPluginSDK
import os

private struct Gemma4DownloadProgressReport: Equatable {
    let completedUnitCount: Int64
    let totalUnitCount: Int64
    let isSnapshotComplete: Bool
}

private struct Gemma4DownloadProgressAccumulator {
    private var snapshotCompletedUnitCount: Int64 = 0
    private var snapshotTotalUnitCount: Int64 = 0
    private var snapshotFraction: Double = 0
    private var isSnapshotComplete = false
    private var receivedBytesByTask: [Int: Int64] = [:]
    private var lastReport: Gemma4DownloadProgressReport?

    mutating func observeSnapshot(
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        fraction: Double
    ) -> Gemma4DownloadProgressReport? {
        let normalizedFraction = fraction.isFinite
            ? max(0.0, min(fraction, 1.0))
            : 0.0
        snapshotCompletedUnitCount = max(snapshotCompletedUnitCount, max(completedUnitCount, 0))
        snapshotTotalUnitCount = max(snapshotTotalUnitCount, max(totalUnitCount, 0))
        snapshotFraction = max(snapshotFraction, normalizedFraction)
        if snapshotTotalUnitCount > 0,
           snapshotCompletedUnitCount >= snapshotTotalUnitCount || snapshotFraction >= 1.0 {
            isSnapshotComplete = true
        }
        return makeReport()
    }

    mutating func observeNetworkTasks(
        receivedBytes: [Int: Int64]
    ) -> Gemma4DownloadProgressReport? {
        for (taskIdentifier, byteCount) in receivedBytes {
            receivedBytesByTask[taskIdentifier] = max(
                receivedBytesByTask[taskIdentifier] ?? 0,
                max(byteCount, 0)
            )
        }
        return makeReport()
    }

    private mutating func makeReport() -> Gemma4DownloadProgressReport? {
        guard snapshotTotalUnitCount > 0 else { return nil }

        let fractionCompletedUnitCount = Int64(
            (Double(snapshotTotalUnitCount) * snapshotFraction).rounded(.down)
        )
        let receivedByteCount = receivedBytesByTask.values.reduce(Int64(0)) { partial, byteCount in
            partial.addingReportingOverflow(byteCount).overflow
                ? Int64.max
                : partial + byteCount
        }
        var completedUnitCount = max(
            snapshotCompletedUnitCount,
            max(fractionCompletedUnitCount, receivedByteCount)
        )

        if isSnapshotComplete {
            completedUnitCount = snapshotTotalUnitCount
        } else {
            completedUnitCount = min(completedUnitCount, max(snapshotTotalUnitCount - 1, 0))
        }

        let report = Gemma4DownloadProgressReport(
            completedUnitCount: completedUnitCount,
            totalUnitCount: snapshotTotalUnitCount,
            isSnapshotComplete: isSnapshotComplete
        )
        guard report != lastReport else { return nil }
        lastReport = report
        return report
    }
}

private final class Gemma4DownloadProgressSampler: @unchecked Sendable {
    private let session: URLSession
    private let progressHandler: @Sendable (Progress) -> Void
    private let state = OSAllocatedUnfairLock(initialState: Gemma4DownloadProgressAccumulator())

    init(
        session: URLSession,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) {
        self.session = session
        self.progressHandler = progressHandler
    }

    func start() -> Task<Void, Never> {
        let session = session
        return Task { [weak self, session] in
            while !Task.isCancelled {
                let tasks = await session.allTasks
                self?.observeNetworkTasks(tasks)
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    func observeSnapshot(_ progress: Progress) {
        let report = state.withLock { accumulator in
            accumulator.observeSnapshot(
                completedUnitCount: progress.completedUnitCount,
                totalUnitCount: progress.totalUnitCount,
                fraction: progress.fractionCompleted
            )
        }
        emit(report)
    }

    private func observeNetworkTasks(_ tasks: [URLSessionTask]) {
        let receivedBytes = tasks.reduce(into: [Int: Int64]()) { result, task in
            guard Self.isModelFileTask(task) else { return }
            result[task.taskIdentifier] = max(task.countOfBytesReceived, 0)
        }
        let report = state.withLock { accumulator in
            accumulator.observeNetworkTasks(receivedBytes: receivedBytes)
        }
        emit(report)
    }

    private func emit(_ report: Gemma4DownloadProgressReport?) {
        guard let report else { return }
        let progress = Progress(totalUnitCount: report.totalUnitCount)
        progress.completedUnitCount = report.completedUnitCount
        progressHandler(progress)
    }

    private static func isModelFileTask(_ task: URLSessionTask) -> Bool {
        let path = task.originalRequest?.url?.path
            ?? task.currentRequest?.url?.path
            ?? ""
        return path.contains("/resolve/")
    }
}

private struct Gemma4HubDownloader: Downloader {
    let client: HubClient
    let session: URLSession
    let modelsDirectory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest _: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw Gemma4Plugin.DownloadError.invalidRepositoryID(id)
        }

        let destination = modelsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let progressSampler = Gemma4DownloadProgressSampler(
            session: session,
            progressHandler: progressHandler
        )
        let samplingTask = progressSampler.start()
        defer { samplingTask.cancel() }

        return try await client.downloadSnapshot(
            of: repoID,
            to: destination,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressSampler.observeSnapshot(progress)
            }
        )
    }
}

private struct Gemma4TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct Gemma4TokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return Gemma4TokenizerBridge(upstream: tokenizer)
    }
}

// MARK: - Plugin Entry Point

@objc(Gemma4Plugin)
final class Gemma4Plugin: NSObject, ObservableObject, LLMProviderPlugin, LLMTemperatureControllableProvider, LLMProviderSetupStatusProviding, LLMModelSelectable, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PluginRuntimeMemoryDiagnosticsReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gemma4"
    static let pluginName = "Gemma 4"
    static let defaultGenerationTemperature = 0.1
    static let experimentalModelWarning = "Experimental. You can try it at your own risk."
    static let promptMaxTokens = 2048
    private static let initialDownloadProgress = 0.0
    private static let downloadedModelLoadProgress = 0.8
    private static let loadedModelPreparationProgress = 0.9
    private static let minimumVisibleDownloadProgress = 0.01
    private static let minimumVisibleProgressAdvance = 0.001

    private enum ModelLoadPhase: Equatable {
        case downloading
        case preparing
    }

    enum DownloadError: LocalizedError {
        case invalidRepositoryID(String)

        var errorDescription: String? {
            switch self {
            case .invalidRepositoryID(let id):
                return "Invalid Hugging Face repository ID: '\(id)'. Expected format 'namespace/name'."
            }
        }
    }

    fileprivate var host: HostServices?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var modelContainer: ModelContainer?
    fileprivate var loadedModelId: String?
    fileprivate var _generationTemperature: Double = 0.1
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.custom.rawValue
    fileprivate var _hfToken: String?
    private var modelLoadGeneration = 0
    private var downloadInactivityTimeoutDuration: Duration = .seconds(300)
    private var modelPreparationTimeoutDuration: Duration = .seconds(900)
    private let modelLoadClock = ContinuousClock()
    private var modelLoadPhase: ModelLoadPhase?
    private var lastModelLoadActivityInstant = ContinuousClock().now
    private var lastDownloadCompletedUnitCount: Int64 = 0
    private var lastObservedDownloadFraction = 0.0
    private var lastVisibleDownloadFraction = 0.0
    private var activeModelLoadTask: (generation: Int, task: Task<ModelContainer, Error>)?
    private var modelLoadTimeoutTask: Task<Void, Never>?
    private var restoreModelTask: Task<Void, Never>?

    private func modelsDirectory() -> URL {
        host?.pluginDataDirectory.appendingPathComponent("models")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-models")
    }

    private func localModelDirectory(for repoId: String) -> URL {
        modelsDirectory().appendingPathComponent(repoId, isDirectory: true)
    }

    private func hubCacheDirectory(for repoId: String) -> URL {
        let cacheName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        return modelsDirectory().appendingPathComponent(cacheName, isDirectory: true)
    }

    private func hubLockDirectory(for repoId: String) -> URL {
        let cacheName = "models--" + repoId.replacingOccurrences(of: "/", with: "--")
        return modelsDirectory()
            .appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
    }

    private func modelCacheDirectories(for modelDef: Gemma4ModelDef) -> [URL] {
        [
            localModelDirectory(for: modelDef.repoId),
            hubCacheDirectory(for: modelDef.repoId),
            hubLockDirectory(for: modelDef.repoId),
        ]
    }
    @Published var downloadProgress: Double = 0

    @Published var modelState: Gemma4ModelState = .notLoaded

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        let persistedSelection = host.userDefault(forKey: "selectedLLMModel") as? String
        let sanitizedSelection = Self.sanitizedSelectedModelId(persistedSelection)
        _selectedLLMModelId = sanitizedSelection
        if sanitizedSelection != persistedSelection {
            host.setUserDefault(sanitizedSelection, forKey: "selectedLLMModel")
        }

        let shouldAutoRestoreLoadedModel: Bool
        if host.shouldRestoreLoadedModelsPassively,
           let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String {
            if Self.canRestoreLoadedModel(persistedLoadedModel),
               let modelDef = Self.modelDefinition(for: persistedLoadedModel) {
                shouldAutoRestoreLoadedModel = isModelDownloaded(modelDef)
            } else {
                host.setUserDefault(nil, forKey: "loadedModel")
                shouldAutoRestoreLoadedModel = false
            }
        } else {
            shouldAutoRestoreLoadedModel = false
        }

        _generationTemperature = host.userDefault(forKey: "generationTemperature") as? Double
            ?? Self.defaultGenerationTemperature
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.custom.rawValue
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

        restoreModelTask?.cancel()
        if shouldAutoRestoreLoadedModel {
            restoreModelTask = Task { [weak self] in
                await self?.restoreLoadedModel(allowDownloads: false)
            }
        } else {
            restoreModelTask = nil
        }
    }

    func deactivate() {
        invalidateModelLoad()
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        Self.scheduleRuntimeCacheClearWhenInferenceIsIdle()
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Gemma 4 (MLX)" }

    var isAvailable: Bool {
        modelContainer != nil && loadedModelId != nil
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        host?.shouldRestoreLoadedModelsPassively ?? true
    }

    var supportedModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return Self.availableModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    var downloadedModels: [PluginModelInfo] {
        Self.availableModels
            .filter { isModelDownloaded($0) }
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
        guard let modelDef = Self.modelDefinition(for: modelId) else { return }

        if loadedModelId == modelId {
            modelContainer = nil
            loadedModelId = nil
            downloadProgress = 0
            modelState = .notLoaded
            await Self.clearRuntimeCacheWhenInferenceIsIdle()
        }
        if _selectedLLMModelId == modelId {
            _selectedLLMModelId = nil
            host?.setUserDefault(nil, forKey: "selectedLLMModel")
        }
        if host?.userDefault(forKey: "loadedModel") as? String == modelId {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }

        try deleteModelFiles(modelDef)
        objectWillChange.send()
        host?.notifyCapabilitiesChanged()
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
        guard !trimmedUserText.isEmpty else {
            throw Gemma4PluginError.noInputText
        }

        let resolvedTemperature = providerTemperatureDirective
            .resolvedTemperature(applying: temperatureDirective) ?? Self.defaultGenerationTemperature

        return try await PluginLocalInferenceGate.shared.withLock { [self] in
            guard let modelContainer else {
                throw PluginChatError.notConfigured
            }
            defer { Self.clearRuntimeCache() }

            let combinedPrompt = """
            Follow these instructions exactly:
            \(systemPrompt)

            Input text:
            \(trimmedUserText)
            """

            let chat: [Chat.Message] = [
                .user(combinedPrompt),
            ]
            let userInput = UserInput(chat: chat)
            let input = try await modelContainer.prepare(input: userInput)

            let parameters = Self.promptGenerationParameters(
                temperature: resolvedTemperature,
                modelId: model ?? loadedModelId
            )

            let stream = try await modelContainer.generate(input: input, parameters: parameters)
            var result = ""
            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    result += text
                case .info, .toolCall:
                    break
                }
            }

            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - LLMModelSelectable

    func selectLLMModel(_ modelId: String) {
        let sanitizedModelId = Self.sanitizedSelectedModelId(modelId)
        _selectedLLMModelId = sanitizedModelId
        host?.setUserDefault(sanitizedModelId, forKey: "selectedLLMModel")
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
    var preferredModelId: String? { _selectedLLMModelId }
    var huggingFaceToken: String? { _hfToken }
    var currentDownloadProgress: Double { downloadProgress }
    var hasVisibleDownloadProgress: Bool { downloadProgress >= Self.minimumVisibleDownloadProgress }

    var generationTemperature: Double { _generationTemperature }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .custom
    }
    fileprivate var providerTemperatureDirective: PluginLLMTemperatureDirective {
        switch llmTemperatureMode {
        case .providerDefault:
            return .custom(Self.defaultGenerationTemperature)
        case .custom, .inheritProviderSetting:
            return .custom(_generationTemperature)
        }
    }

    var requiresExternalCredentials: Bool { false }

    var unavailableReason: String? {
        if isAvailable { return nil }

        if case .error(let message) = modelState,
           !message.isEmpty {
            return message
        }

        let bundle = Bundle(for: Gemma4Plugin.self)
        return String(
            localized: "Load a Gemma 4 model in Integrations before using it for prompts.",
            bundle: bundle
        )
    }

    var runtimeMemorySnapshot: PluginRuntimeMemorySnapshot? {
        let snapshot = Memory.snapshot()
        return PluginRuntimeMemorySnapshot(
            activeMemoryBytes: snapshot.activeMemory,
            cacheMemoryBytes: snapshot.cacheMemory,
            peakMemoryBytes: snapshot.peakMemory
        )
    }

    func setGenerationTemperature(_ temperature: Double) {
        let clamped = min(max(temperature, 0.0), 1.0)
        _generationTemperature = clamped
        host?.setUserDefault(clamped, forKey: "generationTemperature")
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        let storedMode: PluginLLMTemperatureMode
        switch mode {
        case .providerDefault:
            storedMode = .providerDefault
        case .custom, .inheritProviderSetting:
            storedMode = .custom
        }
        _llmTemperatureModeRaw = storedMode.rawValue
        host?.setUserDefault(storedMode.rawValue, forKey: "llmTemperatureMode")
    }

    func saveHuggingFaceToken(_ token: String) {
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

    func isModelDownloaded(_ modelDef: Gemma4ModelDef) -> Bool {
        isUsableDownloadedModel(modelDef)
    }

    func hasCachedModelFiles(_ modelDef: Gemma4ModelDef) -> Bool {
        modelCacheDirectories(for: modelDef).contains { cacheDir in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    @discardableResult
    func beginModelLoad(for modelDef: Gemma4ModelDef, isAlreadyDownloaded: Bool) -> Int {
        let generation = beginModelLoad(
            phase: isAlreadyDownloaded ? .preparing : .downloading,
            initialDownloadFraction: isAlreadyDownloaded ? 1.0 : 0.0
        )
        _selectedLLMModelId = modelDef.id
        modelState = isAlreadyDownloaded ? .loading : .downloading
        downloadProgress = isAlreadyDownloaded ? Self.downloadedModelLoadProgress : Self.initialDownloadProgress
        host?.notifyCapabilitiesChanged()
        return generation
    }

    func cancelModelLoad() {
        invalidateModelLoad()
        downloadProgress = 0
        modelState = .notLoaded
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Model Management

    func loadModel(_ modelDef: Gemma4ModelDef) async throws {
        try Task.checkCancellation()
        let isAlreadyDownloaded = isModelDownloaded(modelDef)
        let loadGeneration = beginModelLoad(for: modelDef, isAlreadyDownloaded: isAlreadyDownloaded)
        startModelLoadTimeout(generation: loadGeneration, modelName: modelDef.displayName)
        do {
            let token = _hfToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelsDir = modelsDirectory()
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            if !isAlreadyDownloaded {
                removeIncompleteModelIfNeeded(modelDef)
            }

            let hubSession = URLSession(configuration: .default)
            defer { hubSession.invalidateAndCancel() }
            let hubClient = HubClient(
                session: hubSession,
                host: HubClient.defaultHost,
                bearerToken: token?.isEmpty == false ? token : nil,
                cache: HubCache(cacheDirectory: modelsDir)
            )
            let downloader = Gemma4HubDownloader(
                client: hubClient,
                session: hubSession,
                modelsDirectory: modelsDir
            )
            let configuration = isAlreadyDownloaded
                ? ModelConfiguration(
                    directory: localModelDirectory(for: modelDef.repoId),
                    extraEOSTokens: ["<turn|>"]
                )
                : ModelConfiguration(
                    id: modelDef.repoId,
                    extraEOSTokens: ["<turn|>"]
                )
            let loadTask = Task<ModelContainer, Error> {
                try await LLMModelFactory.shared.loadContainer(
                    from: downloader,
                    using: Gemma4TokenizerLoader(),
                    configuration: configuration
                ) { progress in
                    guard !Task.isCancelled else { return }
                    let rawFraction = progress.fractionCompleted
                    let fraction = rawFraction.isFinite ? max(0.0, min(rawFraction, 1.0)) : 0.0
                    let completedUnitCount = Self.effectiveCompletedUnitCount(
                        completedUnitCount: progress.completedUnitCount,
                        totalUnitCount: progress.totalUnitCount,
                        fraction: fraction
                    )
                    Task { @MainActor in
                        self.recordModelLoadProgress(
                            completedUnitCount: completedUnitCount,
                            fraction: fraction,
                            generation: loadGeneration
                        )
                    }
                }
            }
            activeModelLoadTask = (generation: loadGeneration, task: loadTask)
            defer {
                if activeModelLoadTask?.generation == loadGeneration {
                    activeModelLoadTask = nil
                }
            }
            let container = try await loadTask.value

            try Task.checkCancellation()
            guard isCurrentModelLoad(loadGeneration) else { return }
            stopModelLoadTimeout(generation: loadGeneration)
            modelState = .loading
            downloadProgress = Self.loadedModelPreparationProgress
            modelContainer = container
            loadedModelId = modelDef.id
            _selectedLLMModelId = modelDef.id
            host?.setUserDefault(modelDef.id, forKey: "selectedLLMModel")
            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            downloadProgress = 1.0
            modelState = .ready(modelDef.id)
            host?.notifyCapabilitiesChanged()
        } catch {
            if error is CancellationError {
                if isCurrentModelLoad(loadGeneration) {
                    cancelModelLoad()
                }
                throw error
            }
            guard isCurrentModelLoad(loadGeneration) else { return }
            stopModelLoadTimeout(generation: loadGeneration)
            modelContainer = nil
            loadedModelId = nil
            downloadProgress = 0
            modelState = .error(Self.userFacingLoadErrorMessage(for: error, modelDef: modelDef))
            host?.setUserDefault(nil, forKey: "loadedModel")
            host?.notifyCapabilitiesChanged()
            throw error
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        invalidateModelLoad()
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        Self.scheduleRuntimeCacheClearWhenInferenceIsIdle()
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func deleteModelFiles(_ modelDef: Gemma4ModelDef) throws {
        let fileManager = FileManager.default
        for cacheDir in modelCacheDirectories(for: modelDef) {
            if fileManager.fileExists(atPath: cacheDir.path) {
                try fileManager.removeItem(at: cacheDir)
            }
        }

        let repoNamespaceDir = localModelDirectory(for: modelDef.repoId).deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: repoNamespaceDir.path).isEmpty) == true {
            try? fileManager.removeItem(at: repoNamespaceDir)
        }
    }

    func resetCachedModel(_ modelDef: Gemma4ModelDef) {
        invalidateModelLoad()
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        Self.scheduleRuntimeCacheClearWhenInferenceIsIdle()
        host?.setUserDefault(nil, forKey: "loadedModel")
        try? deleteModelFiles(modelDef)
        host?.notifyCapabilitiesChanged()
    }

    private static func clearRuntimeCache() {
        Memory.clearCache()
    }

    private static func clearRuntimeCacheWhenInferenceIsIdle() async {
        try? await PluginLocalInferenceGate.shared.withLock {
            Memory.clearCache()
        }
    }

    private static func scheduleRuntimeCacheClearWhenInferenceIsIdle() {
        Task {
            await clearRuntimeCacheWhenInferenceIsIdle()
        }
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.modelDefinition(for: savedId) else {
            host?.setUserDefault(nil, forKey: "loadedModel")
            return
        }
        guard allowDownloads || isModelDownloaded(modelDef) else {
            host?.setUserDefault(nil, forKey: "loadedModel")
            return
        }
        try? await loadModel(modelDef)
    }

    @discardableResult
    private func beginModelLoad(
        phase: ModelLoadPhase,
        initialDownloadFraction: Double
    ) -> Int {
        modelLoadGeneration += 1
        modelLoadTimeoutTask?.cancel()
        modelLoadTimeoutTask = nil
        modelLoadPhase = phase
        lastModelLoadActivityInstant = modelLoadClock.now
        lastDownloadCompletedUnitCount = 0
        lastObservedDownloadFraction = max(0.0, min(initialDownloadFraction, 1.0))
        lastVisibleDownloadFraction = 0
        return modelLoadGeneration
    }

    private func invalidateModelLoad() {
        modelLoadGeneration += 1
        modelLoadTimeoutTask?.cancel()
        modelLoadTimeoutTask = nil
        modelLoadPhase = nil
        restoreModelTask?.cancel()
        restoreModelTask = nil
        activeModelLoadTask?.task.cancel()
        activeModelLoadTask = nil
    }

    private func isCurrentModelLoad(_ generation: Int) -> Bool {
        generation == modelLoadGeneration
    }

    private static func effectiveCompletedUnitCount(
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        fraction: Double
    ) -> Int64 {
        let normalizedCompletedUnitCount = max(completedUnitCount, 0)
        guard totalUnitCount > 0 else {
            return normalizedCompletedUnitCount
        }

        // Snapshot Progress reports in-flight child bytes through fractionCompleted,
        // while its parent completedUnitCount may not advance until the file finishes.
        let fractionCompletedUnitCount = Int64(
            (Double(totalUnitCount) * max(0.0, min(fraction, 1.0))).rounded(.down)
        )
        return max(normalizedCompletedUnitCount, fractionCompletedUnitCount)
    }

    private func recordModelLoadProgress(
        completedUnitCount: Int64,
        fraction: Double,
        generation: Int
    ) {
        guard isCurrentModelLoad(generation),
              modelLoadPhase == .downloading else {
            return
        }

        let normalized = max(0.0, min(fraction, 1.0))
        lastObservedDownloadFraction = max(lastObservedDownloadFraction, normalized)

        if completedUnitCount > lastDownloadCompletedUnitCount {
            lastDownloadCompletedUnitCount = completedUnitCount
            lastModelLoadActivityInstant = modelLoadClock.now
        }

        if normalized >= 1.0 {
            enterModelPreparation(generation: generation)
            return
        }

        guard normalized - lastVisibleDownloadFraction >= Self.minimumVisibleProgressAdvance else {
            return
        }

        lastVisibleDownloadFraction = normalized
        let mapped = Self.initialDownloadProgress + normalized * 0.78
        downloadProgress = max(downloadProgress, mapped)
        host?.notifyCapabilitiesChanged()
    }

    private func enterModelPreparation(generation: Int) {
        guard isCurrentModelLoad(generation),
              modelLoadPhase == .downloading else {
            return
        }

        modelLoadPhase = .preparing
        lastModelLoadActivityInstant = modelLoadClock.now
        lastObservedDownloadFraction = 1.0
        modelState = .loading
        downloadProgress = max(downloadProgress, Self.loadedModelPreparationProgress)
        host?.notifyCapabilitiesChanged()
    }

    private func stopModelLoadTimeout(generation: Int) {
        guard isCurrentModelLoad(generation) else { return }
        modelLoadTimeoutTask?.cancel()
        modelLoadTimeoutTask = nil
        modelLoadPhase = nil
    }

    private func timeoutDuration(for phase: ModelLoadPhase) -> Duration {
        switch phase {
        case .downloading:
            downloadInactivityTimeoutDuration
        case .preparing:
            modelPreparationTimeoutDuration
        }
    }

    private func startModelLoadTimeout(generation: Int, modelName: String) {
        modelLoadTimeoutTask?.cancel()
        modelLoadTimeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.isCurrentModelLoad(generation),
                      let phase = self.modelLoadPhase else {
                    return
                }

                guard (phase == .downloading && self.modelState == .downloading)
                        || (phase == .preparing && self.modelState == .loading) else {
                    return
                }

                let timeout = self.timeoutDuration(for: phase)
                let elapsed = self.lastModelLoadActivityInstant.duration(to: self.modelLoadClock.now)
                guard elapsed >= timeout else {
                    do {
                        try await Task.sleep(for: timeout - elapsed)
                    } catch {
                        return
                    }
                    continue
                }

                guard self.modelLoadPhase == phase else { continue }
                if self.applyModelLoadTimeout(
                    generation: generation,
                    modelName: modelName,
                    phase: phase
                ) {
                    return
                }
            }
        }
    }

    @discardableResult
    private func applyModelLoadTimeout(
        generation: Int,
        modelName: String,
        phase: ModelLoadPhase
    ) -> Bool {
        guard isCurrentModelLoad(generation),
              modelLoadPhase == phase else {
            return false
        }

        let lastProgress = lastObservedDownloadFraction
        invalidateModelLoad()
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .error(
            Self.modelLoadTimeoutMessage(
                for: phase,
                modelName: modelName,
                lastDownloadFraction: lastProgress
            )
        )
        host?.setUserDefault(nil, forKey: "loadedModel")
        host?.notifyCapabilitiesChanged()
        return true
    }

    private func isUsableDownloadedModel(_ modelDef: Gemma4ModelDef) -> Bool {
        let repoDir = localModelDirectory(for: modelDef.repoId)
        return Self.isUsableDownloadedModel(at: repoDir)
    }

    static func isUsableDownloadedModel(at repoDir: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: repoDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let requiredRootFiles = [
            "config.json",
            "tokenizer.json",
        ]
        guard requiredRootFiles.allSatisfy({ fileManager.fileExists(atPath: repoDir.appendingPathComponent($0).path) }) else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: repoDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "safetensors" {
            return true
        }
        return false
    }

    private func removeIncompleteModelIfNeeded(_ modelDef: Gemma4ModelDef) {
        let repoDir = localModelDirectory(for: modelDef.repoId)
        guard hasCachedModelFiles(modelDef), !Self.isUsableDownloadedModel(at: repoDir) else { return }
        try? deleteModelFiles(modelDef)
    }

    #if DEBUG
    func setModelLoadTimeoutForTesting(_ timeout: Duration) {
        downloadInactivityTimeoutDuration = timeout
        modelPreparationTimeoutDuration = timeout
    }

    func setModelLoadTimeoutsForTesting(
        downloadInactivity: Duration,
        preparation: Duration
    ) {
        downloadInactivityTimeoutDuration = downloadInactivity
        modelPreparationTimeoutDuration = preparation
    }

    @discardableResult
    func startModelLoadTimeoutForTesting(
        modelName: String,
        scheduleWatchdog: Bool = true
    ) -> Int {
        let generation = beginModelLoad(phase: .downloading, initialDownloadFraction: 0)
        modelState = .downloading
        downloadProgress = Self.initialDownloadProgress
        if scheduleWatchdog {
            startModelLoadTimeout(generation: generation, modelName: modelName)
        }
        return generation
    }

    func recordModelLoadProgressForTesting(
        completedUnitCount: Int64,
        totalUnitCount: Int64 = 1_000_000,
        fraction: Double,
        generation: Int? = nil
    ) {
        let resolvedGeneration = generation ?? modelLoadGeneration
        let effectiveCompletedUnitCount = Self.effectiveCompletedUnitCount(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            fraction: fraction
        )
        recordModelLoadProgress(
            completedUnitCount: effectiveCompletedUnitCount,
            fraction: fraction,
            generation: resolvedGeneration
        )
    }

    static func effectiveCompletedUnitCountForTesting(
        completedUnitCount: Int64,
        totalUnitCount: Int64,
        fraction: Double
    ) -> Int64 {
        effectiveCompletedUnitCount(
            completedUnitCount: completedUnitCount,
            totalUnitCount: totalUnitCount,
            fraction: fraction
        )
    }

    static func sampledDownloadProgressForTesting(
        snapshotCompletedUnitCount: Int64,
        snapshotTotalUnitCount: Int64,
        snapshotFraction: Double,
        receivedBytesByTask: [Int: Int64]
    ) -> (completedUnitCount: Int64, totalUnitCount: Int64, isSnapshotComplete: Bool)? {
        var accumulator = Gemma4DownloadProgressAccumulator()
        let snapshotReport = accumulator.observeSnapshot(
            completedUnitCount: snapshotCompletedUnitCount,
            totalUnitCount: snapshotTotalUnitCount,
            fraction: snapshotFraction
        )
        guard let report = accumulator.observeNetworkTasks(receivedBytes: receivedBytesByTask)
            ?? snapshotReport else {
            return nil
        }
        return (
            completedUnitCount: report.completedUnitCount,
            totalUnitCount: report.totalUnitCount,
            isSnapshotComplete: report.isSnapshotComplete
        )
    }

    func invalidateModelLoadForTesting() {
        invalidateModelLoad()
    }

    func currentModelLoadTimeoutForTesting() -> Duration? {
        guard let phase = modelLoadPhase else { return nil }
        return timeoutDuration(for: phase)
    }

    @discardableResult
    func applyModelLoadTimeoutForTesting(generation: Int, modelName: String) -> Bool {
        guard let phase = modelLoadPhase else { return false }
        return applyModelLoadTimeout(
            generation: generation,
            modelName: modelName,
            phase: phase
        )
    }

    func setLoadedModelIdForTesting(_ modelId: String?) {
        loadedModelId = modelId
    }

    func isCurrentModelLoadForTesting(_ generation: Int) -> Bool {
        isCurrentModelLoad(generation)
    }
    #endif

    // MARK: - Settings Activity

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

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(Gemma4SettingsView(plugin: self))
    }

    // MARK: - Model Definitions

    static let availableModels: [Gemma4ModelDef] = [
        Gemma4ModelDef(
            id: "gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B (4-bit)",
            repoId: "mlx-community/gemma-4-e2b-it-4bit",
            sizeDescription: "~3.6 GB",
            ramRequirement: "8 GB+",
            availability: .supported
        ),
        Gemma4ModelDef(
            id: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B (4-bit)",
            repoId: "mlx-community/gemma-4-e4b-it-4bit",
            sizeDescription: "~5.2 GB",
            ramRequirement: "16 GB+",
            availability: .supported
        ),
        Gemma4ModelDef(
            id: "gemma-4-e4b-it-8bit",
            displayName: "Gemma 4 E4B (8-bit)",
            repoId: "mlx-community/gemma-4-e4b-it-8bit",
            sizeDescription: "~8 GB",
            ramRequirement: "16 GB+",
            availability: .experimental(warning: experimentalModelWarning)
        ),
        Gemma4ModelDef(
            id: "gemma-4-26b-a4b-it-4bit",
            displayName: "Gemma 4 26B-A4B (4-bit, MoE)",
            repoId: "mlx-community/gemma-4-26b-a4b-it-4bit",
            sizeDescription: "~15.6 GB",
            ramRequirement: "32 GB+",
            availability: .experimental(warning: experimentalModelWarning)
        ),
    ]

    static var supportedModelDefinitions: [Gemma4ModelDef] {
        availableModels.filter(\.isSupported)
    }

    static func modelDefinition(for id: String?) -> Gemma4ModelDef? {
        guard let id else { return nil }
        return availableModels.first(where: { $0.id == id })
    }

    static func sanitizedSelectedModelId(_ id: String?) -> String? {
        guard let modelDef = modelDefinition(for: id) else {
            return supportedModelDefinitions.first?.id
        }
        return modelDef.id
    }

    static func canRestoreLoadedModel(_ id: String) -> Bool {
        modelDefinition(for: id) != nil
    }

    static func userFacingLoadErrorMessage(for error: Error, modelDef: Gemma4ModelDef) -> String {
        if let pluginError = error as? Gemma4PluginError,
           let description = pluginError.errorDescription {
            return description
        }

        if let urlError = error as? URLError,
           urlError.code == .timedOut {
            let bundle = Bundle(for: Gemma4Plugin.self)
            return String(
                localized: "Download timed out while fetching Gemma 4 from Hugging Face. Please retry. Adding an optional HuggingFace token in this plugin can also increase download rate limits.",
                bundle: bundle
            )
        }

        let rawMessage = "\(String(describing: error))\n\(error.localizedDescription)".lowercased()
        if isRecoverableCacheError(rawMessage) {
            let bundle = Bundle(for: Gemma4Plugin.self)
            return String(
                localized: "The downloaded Gemma model cache appears incomplete or incompatible. Delete the cached model and download it again.",
                bundle: bundle
            )
        }

        if rawMessage.contains("unsupported model type")
            || rawMessage.contains("model type gemma4 not supported") {
            return unsupportedModelMessage(for: modelDef)
        }

        return error.localizedDescription
    }

    private static func modelLoadTimeoutMessage(
        for phase: ModelLoadPhase,
        modelName: String,
        lastDownloadFraction: Double
    ) -> String {
        let progress = String(
            format: "%.2f%%",
            locale: Locale(identifier: "en_US_POSIX"),
            max(0.0, min(lastDownloadFraction, 1.0)) * 100
        )
        let bundle = Bundle(for: Gemma4Plugin.self)
        switch phase {
        case .downloading:
            let format = String(
                localized: "Downloading %1$@ stalled at %2$@ because no additional bytes were received for five minutes. Try again. If the issue persists, delete the cached model and download it again.",
                bundle: bundle
            )
            return String(format: format, modelName, progress)
        case .preparing:
            let format = String(
                localized: "Preparing %1$@ timed out after 15 minutes (last download progress: %2$@). The downloaded model was kept; try loading it again.",
                bundle: bundle
            )
            return String(format: format, modelName, progress)
        }
    }

    private static func isRecoverableCacheError(_ rawMessage: String) -> Bool {
        (rawMessage.contains("key ") && rawMessage.contains(" not found"))
            || rawMessage.contains("missing key")
            || rawMessage.contains("missing weight")
            || rawMessage.contains("shape mismatch")
            || rawMessage.contains("size mismatch")
            || (rawMessage.contains("mismatched parameter") && rawMessage.contains("shape"))
            || (rawMessage.contains("checkpoint")
                && (rawMessage.contains("not found")
                    || rawMessage.contains("missing")
                    || rawMessage.contains("shape")
                    || rawMessage.contains("mismatch")))
    }

    static func promptPrefillStepSize(for modelId: String?) -> Int {
        switch modelId {
        case "gemma-4-e2b-it-4bit":
            return 256
        case "gemma-4-e4b-it-4bit", "gemma-4-e4b-it-8bit":
            return 128
        case "gemma-4-26b-a4b-it-4bit":
            return 64
        default:
            return 128
        }
    }

    static func promptGenerationParameters(temperature: Double, modelId: String?) -> GenerateParameters {
        GenerateParameters(
            maxTokens: promptMaxTokens,
            temperature: Float(temperature),
            prefillStepSize: promptPrefillStepSize(for: modelId)
        )
    }

    private static func unsupportedModelMessage(for modelDef: Gemma4ModelDef) -> String {
        let supportedModels = supportedModelDefinitions.map(\.displayName).joined(separator: ", ")
        if modelDef.isSupported {
            return "Gemma 4 loading in this TypeWhisper release is limited to \(supportedModels). If loading still fails, update to the latest app build and try again."
        }
        return "\(modelDef.displayName) is experimental in this TypeWhisper release and may still fail to load. Recommended models: \(supportedModels)."
    }
}

// MARK: - Model Types

struct Gemma4ModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
    let availability: Gemma4ModelAvailability

    var isSupported: Bool {
        if case .supported = availability {
            return true
        }
        return false
    }

    var experimentalWarning: String? {
        if case .experimental(let warning) = availability {
            return warning
        }
        return nil
    }
}

enum Gemma4ModelAvailability: Equatable {
    case supported
    case experimental(warning: String)
}

enum Gemma4PluginError: LocalizedError {
    case noInputText

    var errorDescription: String? {
        switch self {
        case .noInputText:
            return "Please select or copy some text first."
        }
    }
}

enum Gemma4ModelState: Equatable {
    case notLoaded
    case downloading
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: Gemma4ModelState, rhs: Gemma4ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.downloading, .downloading): true
        case (.loading, .loading): true
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}
