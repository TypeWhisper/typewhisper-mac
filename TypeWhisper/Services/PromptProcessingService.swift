import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PromptProcessingService")

@MainActor
class PromptProcessingService: ObservableObject {
    @Published var selectedProviderId: String {
        didSet { UserDefaults.standard.set(selectedProviderId, forKey: "llmProviderType") }
    }
    @Published var selectedCloudModel: String {
        didSet { UserDefaults.standard.set(selectedCloudModel, forKey: "llmCloudModel") }
    }

    weak var memoryService: MemoryService?
    private var appleIntelligenceProvider: LLMProvider?

    static let appleIntelligenceId = "appleIntelligence"

    var isAppleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) {
            return appleIntelligenceProvider?.isAvailable ?? false
        }
        return false
    }

    /// Returns (id, displayName) pairs for all available providers
    var availableProviders: [(id: String, displayName: String)] {
        var result: [(id: String, displayName: String)] = []

        if #available(macOS 26, *) {
            result.append((id: Self.appleIntelligenceId, displayName: "Apple Intelligence"))
        }

        for plugin in PluginManager.shared.llmProviders {
            result.append((id: plugin.providerName, displayName: plugin.providerName))
        }

        return result
    }

    var isCurrentProviderReady: Bool {
        isProviderReady(selectedProviderId)
    }

    func isProviderReady(_ providerId: String) -> Bool {
        if providerId == Self.appleIntelligenceId {
            return isAppleIntelligenceAvailable
        }
        return PluginManager.shared.llmProvider(for: providerId)?.isAvailable ?? false
    }

    /// Returns supported models for a given provider
    func modelsForProvider(_ providerId: String) -> [PluginModelInfo] {
        if providerId == Self.appleIntelligenceId {
            return []
        }
        return PluginManager.shared.llmProvider(for: providerId)?.supportedModels ?? []
    }

    /// Returns display name for a provider ID
    func displayName(for providerId: String) -> String {
        if providerId == Self.appleIntelligenceId {
            return "Apple Intelligence"
        }
        // Use the plugin's canonical providerName for display
        return PluginManager.shared.llmProvider(for: providerId)?.providerName ?? providerId
    }

    /// Normalize a provider ID to match the plugin's canonical providerName.
    /// Handles migration from old enum rawValues ("groq") to plugin names ("Groq").
    func normalizeProviderId(_ id: String) -> String {
        if id == Self.appleIntelligenceId { return id }
        return PluginManager.shared.llmProvider(for: id)?.providerName ?? id
    }

    init() {
        let savedId = UserDefaults.standard.string(forKey: "llmProviderType") ?? Self.appleIntelligenceId
        self.selectedProviderId = savedId
        self.selectedCloudModel = UserDefaults.standard.string(forKey: "llmCloudModel") ?? ""

        setupProviders()
    }

    private func setupProviders() {
        if #available(macOS 26, *) {
            appleIntelligenceProvider = FoundationModelsProvider()
        }
    }

    /// Validate and fix selectedProviderId and selectedCloudModel after plugins are loaded.
    /// Called from ServiceContainer after scanAndLoadPlugins().
    func validateSelectionAfterPluginLoad() {
        // Normalize provider ID (e.g., "groq" -> "Groq")
        let normalized = normalizeProviderId(selectedProviderId)
        if normalized != selectedProviderId {
            selectedProviderId = normalized
        }

        // Validate cloud model against available models for the selected provider
        let models = modelsForProvider(selectedProviderId)
        if !models.isEmpty && !models.contains(where: { $0.id == selectedCloudModel }) {
            let pluginPreferred = (PluginManager.shared.llmProvider(for: selectedProviderId) as? LLMModelSelectable)?.preferredModelId as? String
            selectedCloudModel = pluginPreferred ?? models.first?.id ?? ""
        }
    }

    func process(prompt: String, text: String, providerOverride: String? = nil, cloudModelOverride: String? = nil, skipMemoryInjection: Bool = false) async throws -> String {
        // Inject memory context into prompt if available
        var effectivePrompt = prompt
        if !skipMemoryInjection, let memoryService {
            let memoryContext = await memoryService.retrieveRelevantMemories(for: text)
            if !memoryContext.isEmpty {
                effectivePrompt = memoryContext + "\n\n" + prompt
            }
        }

        let effectiveId = providerOverride ?? selectedProviderId

        if effectiveId == Self.appleIntelligenceId {
            guard let provider = appleIntelligenceProvider, provider.isAvailable else {
                throw LLMError.notAvailable
            }
            logger.info("Processing prompt with Apple Intelligence")
            let result = try await provider.process(systemPrompt: effectivePrompt, userText: text)
            logger.info("Prompt processing complete, result length: \(result.count)")
            return result
        }

        // Plugin provider
        guard let plugin = PluginManager.shared.llmProvider(for: effectiveId) else {
            throw LLMError.noProviderConfigured
        }
        guard plugin.isAvailable else {
            throw LLMError.noApiKey
        }

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId as? String
        let model = cloudModelOverride ?? preferred ?? (selectedCloudModel.isEmpty ? nil : selectedCloudModel)
        logger.info("Processing prompt with plugin \(effectiveId)")
        let result = try await plugin.process(
            systemPrompt: effectivePrompt,
            userText: text,
            model: model
        )
        logger.info("Prompt processing complete, result length: \(result.count)")
        return result
    }
}
