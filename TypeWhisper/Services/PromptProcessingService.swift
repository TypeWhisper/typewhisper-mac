import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PromptProcessingService")

struct DictationContext {
    let appName: String?
    let url: String?
    let surroundingText: TextInsertionService.SurroundingTextContext?
}

@MainActor
class PromptProcessingService: ObservableObject {
    @Published var selectedProviderId: String {
        didSet { UserDefaults.standard.set(selectedProviderId, forKey: "llmProviderType") }
    }
    @Published var selectedCloudModel: String {
        didSet { UserDefaults.standard.set(selectedCloudModel, forKey: "llmCloudModel") }
    }

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
            selectedCloudModel = models.first?.id ?? ""
        }
    }

    func process(prompt: String, text: String, providerOverride: String? = nil, cloudModelOverride: String? = nil, context: DictationContext? = nil) async throws -> String {
        let effectiveId = providerOverride ?? selectedProviderId
        var effectivePrompt = prompt
        if let context, let contextBlock = buildContextBlock(context) {
            effectivePrompt = prompt + contextBlock
        }

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

        let model = cloudModelOverride ?? selectedCloudModel
        logger.info("Processing prompt with plugin \(effectiveId)")
        let result = try await plugin.process(
            systemPrompt: effectivePrompt,
            userText: text,
            model: model.isEmpty ? nil : model
        )
        logger.info("Prompt processing complete, result length: \(result.count)")
        return result
    }

    private func buildContextBlock(_ context: DictationContext) -> String? {
        var sections: [String] = []

        if let appName = context.appName {
            sections.append("Application: \(appName)")
        }
        if let url = context.url {
            sections.append("URL: \(url)")
        }
        if let surrounding = context.surroundingText {
            if !surrounding.textBefore.isEmpty {
                sections.append("Text before cursor:\n\"\(surrounding.textBefore)\"")
            }
            if let selected = surrounding.selectedText, !selected.isEmpty {
                sections.append("Selected text:\n\"\(selected)\"")
            }
            if !surrounding.textAfter.isEmpty {
                sections.append("Text after cursor:\n\"\(surrounding.textAfter)\"")
            }
        }

        guard !sections.isEmpty else { return nil }
        return "\n\n---\nContext:\n\(sections.joined(separator: "\n\n"))\n---"
    }
}
