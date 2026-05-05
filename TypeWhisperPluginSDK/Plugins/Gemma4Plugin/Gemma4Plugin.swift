import Foundation
import SwiftUI
import MLXVLM
import MLXLMCommon
import HuggingFace
import Hub
import Tokenizers
import TypeWhisperPluginSDK

private struct Gemma4HubDownloader: Downloader {
    let client: HubClient
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

        return try await client.downloadSnapshot(
            of: repoID,
            to: destination,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
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
final class Gemma4Plugin: NSObject, LLMProviderPlugin, LLMTemperatureControllableProvider, LLMProviderSetupStatusProviding, LLMModelSelectable, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gemma4"
    static let pluginName = "Gemma 4"
    static let defaultGenerationTemperature = 0.1
    static let experimentalModelWarning = "Experimental. You can try it at your own risk."
    static let promptMaxTokens = 2048

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

    private func modelsDirectory() -> URL {
        host?.pluginDataDirectory.appendingPathComponent("models")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-models")
    }

    private func localModelDirectory(for repoId: String) -> URL {
        modelsDirectory().appendingPathComponent(repoId, isDirectory: true)
    }
    fileprivate var downloadProgress: Double = 0

    var modelState: Gemma4ModelState = .notLoaded

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

        let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String
        if let persistedLoadedModel, !Self.canRestoreLoadedModel(persistedLoadedModel) {
            host.setUserDefault(nil, forKey: "loadedModel")
        }

        _generationTemperature = host.userDefault(forKey: "generationTemperature") as? Double
            ?? Self.defaultGenerationTemperature
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.custom.rawValue
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

        Task { await restoreLoadedModel(allowDownloads: false) }
    }

    func deactivate() {
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Gemma 4 (MLX)" }

    var isAvailable: Bool {
        modelContainer != nil && loadedModelId != nil
    }

    var supportedModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return Self.availableModels
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
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
        guard let modelContainer else {
            throw PluginChatError.notConfigured
        }

        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserText.isEmpty else {
            throw Gemma4PluginError.noInputText
        }

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
        let resolvedTemperature = providerTemperatureDirective
            .resolvedTemperature(applying: temperatureDirective) ?? Self.defaultGenerationTemperature

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
        hasDownloadedModel(modelDef)
    }

    func beginModelLoad(for modelDef: Gemma4ModelDef, isAlreadyDownloaded: Bool) {
        _selectedLLMModelId = modelDef.id
        modelState = isAlreadyDownloaded ? .loading : .downloading
        downloadProgress = isAlreadyDownloaded ? 0.8 : 0.02
        host?.notifyCapabilitiesChanged()
    }

    func cancelModelLoad() {
        downloadProgress = 0
        modelState = .notLoaded
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Model Management

    func loadModel(_ modelDef: Gemma4ModelDef) async throws {
        try Task.checkCancellation()
        let isAlreadyDownloaded = hasDownloadedModel(modelDef)
        beginModelLoad(for: modelDef, isAlreadyDownloaded: isAlreadyDownloaded)
        do {
            let token = _hfToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelsDir = modelsDirectory()
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let hubClient = HubClient(
                host: HubClient.defaultHost,
                bearerToken: token?.isEmpty == false ? token : nil,
                cache: HubCache(cacheDirectory: modelsDir)
            )
            let downloader = Gemma4HubDownloader(client: hubClient, modelsDirectory: modelsDir)
            let configuration = ModelConfiguration(
                id: modelDef.repoId,
                extraEOSTokens: ["<turn|>"]
            )
            let container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: Gemma4TokenizerLoader(),
                configuration: configuration
            ) { progress in
                guard !Task.isCancelled else { return }
                let fraction = max(0.0, min(progress.fractionCompleted, 1.0))
                let mapped = 0.02 + fraction * 0.78
                Task { @MainActor in
                    self.downloadProgress = mapped
                    if case .downloading = self.modelState {
                        self.host?.notifyCapabilitiesChanged()
                    }
                }
            }

            try Task.checkCancellation()
            modelState = .loading
            downloadProgress = 0.9
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
                cancelModelLoad()
                throw error
            }
            downloadProgress = 0
            modelState = .error(Self.userFacingLoadErrorMessage(for: error, modelDef: modelDef))
            throw error
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func deleteModelFiles(_ modelDef: Gemma4ModelDef) {
        let repoDir = localModelDirectory(for: modelDef.repoId)
        try? FileManager.default.removeItem(at: repoDir)
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.modelDefinition(for: savedId) else {
            host?.setUserDefault(nil, forKey: "loadedModel")
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef)
    }

    private func hasDownloadedModel(_ modelDef: Gemma4ModelDef) -> Bool {
        let repoDir = localModelDirectory(for: modelDef.repoId)

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: repoDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Settings Activity

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(
                message: "Downloading model",
                progress: downloadProgress
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

        let rawMessage = String(describing: error).lowercased()
        if rawMessage.contains("unsupported model type")
            || rawMessage.contains("model type gemma4 not supported") {
            return unsupportedModelMessage(for: modelDef)
        }

        return error.localizedDescription
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
