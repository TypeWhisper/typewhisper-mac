import Foundation
import SwiftUI
import MLXVLM
import MLXLMCommon
import Hub
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(Gemma4Plugin)
final class Gemma4Plugin: NSObject, LLMProviderPlugin, LLMModelSelectable, PluginSettingsActivityReporting, @unchecked Sendable {
    static let pluginId = "com.typewhisper.gemma4"
    static let pluginName = "Gemma 4"
    static let defaultGenerationTemperature = 0.1

    fileprivate var host: HostServices?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var modelContainer: ModelContainer?
    fileprivate var loadedModelId: String?
    fileprivate var _generationTemperature: Double = 0.1

    var modelState: Gemma4ModelState = .notLoaded

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _selectedLLMModelId = host.userDefault(forKey: "selectedLLMModel") as? String
            ?? Self.availableModels.first?.id
        _generationTemperature = host.userDefault(forKey: "generationTemperature") as? Double
            ?? Self.defaultGenerationTemperature

        Task { await restoreLoadedModel(allowDownloads: false) }
    }

    func deactivate() {
        modelContainer = nil
        loadedModelId = nil
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

        let parameters = GenerateParameters(
            maxTokens: 2048,
            temperature: Float(_generationTemperature)
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
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedLLMModel")
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }

    var generationTemperature: Double { _generationTemperature }

    func setGenerationTemperature(_ temperature: Double) {
        let clamped = min(max(temperature, 0.0), 1.0)
        _generationTemperature = clamped
        host?.setUserDefault(clamped, forKey: "generationTemperature")
    }

    // MARK: - Model Management

    func loadModel(_ modelDef: Gemma4ModelDef) async throws {
        modelState = .loading
        do {
            let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models")
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let hub = HubApi(downloadBase: modelsDir)
            let configuration = ModelConfiguration(
                id: modelDef.repoId,
                extraEOSTokens: ["<end_of_turn>"]
            )
            let container = try await VLMModelFactory.shared.loadContainer(
                hub: hub,
                configuration: configuration
            )

            modelContainer = container
            loadedModelId = modelDef.id
            _selectedLLMModelId = modelDef.id
            host?.setUserDefault(modelDef.id, forKey: "selectedLLMModel")
            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            modelState = .ready(modelDef.id)
            host?.notifyCapabilitiesChanged()
        } catch {
            modelState = .error(error.localizedDescription)
            throw error
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        modelContainer = nil
        loadedModelId = nil
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func deleteModelFiles(_ modelDef: Gemma4ModelDef) {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return }
        let repo = Hub.Repo(id: modelDef.repoId)
        let repoDir = HubApi(downloadBase: modelsDir).localRepoLocation(repo)
        try? FileManager.default.removeItem(at: repoDir)
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = Self.availableModels.first(where: { $0.id == savedId }) else {
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef)
    }

    private func hasDownloadedModel(_ modelDef: Gemma4ModelDef) -> Bool {
        guard let modelsDir = host?.pluginDataDirectory.appendingPathComponent("models") else { return false }
        let repo = Hub.Repo(id: modelDef.repoId)
        let repoDir = HubApi(downloadBase: modelsDir).localRepoLocation(repo)

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: repoDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Settings Activity

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
            ramRequirement: "8 GB+"
        ),
        Gemma4ModelDef(
            id: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B (4-bit)",
            repoId: "mlx-community/gemma-4-e4b-it-4bit",
            sizeDescription: "~5.2 GB",
            ramRequirement: "16 GB+"
        ),
        Gemma4ModelDef(
            id: "gemma-4-e4b-it-8bit",
            displayName: "Gemma 4 E4B (8-bit)",
            repoId: "mlx-community/gemma-4-e4b-it-8bit",
            sizeDescription: "~8 GB",
            ramRequirement: "16 GB+"
        ),
        Gemma4ModelDef(
            id: "gemma-4-26b-a4b-it-4bit",
            displayName: "Gemma 4 26B-A4B (4-bit, MoE)",
            repoId: "mlx-community/gemma-4-26b-a4b-it-4bit",
            sizeDescription: "~15.6 GB",
            ramRequirement: "32 GB+"
        ),
    ]
}

// MARK: - Model Types

struct Gemma4ModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
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
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: Gemma4ModelState, rhs: Gemma4ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.loading, .loading): true
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}
