import AppKit
import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PromptProcessingService")

@MainActor
class PromptProcessingService: ObservableObject {
    @Published var selectedProviderId: String {
        didSet {
            let normalized = normalizeProviderId(selectedProviderId)
            guard normalized == selectedProviderId else {
                selectedProviderId = normalized
                return
            }

            UserDefaults.standard.set(selectedProviderId, forKey: "llmProviderType")
            normalizeSelectedCloudModelIfNeeded(for: selectedProviderId)
        }
    }
    @Published var selectedCloudModel: String {
        didSet { UserDefaults.standard.set(selectedCloudModel, forKey: "llmCloudModel") }
    }

    weak var memoryService: MemoryService?
    private var appleIntelligenceProvider: LLMProvider?
    private var cancellables = Set<AnyCancellable>()

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

    func observePluginManager() {
        PluginManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.validateSelectionAfterPluginLoad()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Validate and fix selectedProviderId and selectedCloudModel after plugins are loaded.
    /// Called from ServiceContainer after scanAndLoadPlugins().
    func validateSelectionAfterPluginLoad() {
        // Normalize provider ID (e.g., "groq" -> "Groq")
        let normalized = normalizeProviderId(selectedProviderId)
        if normalized != selectedProviderId {
            selectedProviderId = normalized
        }

        normalizeSelectedCloudModelIfNeeded(for: selectedProviderId)
    }

    func process(prompt: String, text: String, providerOverride: String? = nil, cloudModelOverride: String? = nil, skipMemoryInjection: Bool = false) async throws -> String {
        try await process(
            prompt: prompt,
            text: text,
            providerOverride: providerOverride,
            cloudModelOverride: cloudModelOverride,
            temperatureDirective: .inheritProviderSetting,
            skipMemoryInjection: skipMemoryInjection
        )
    }

    static func requiresForegroundActivation(for plugin: any LLMProviderPlugin) -> Bool {
        guard let setupStatus = plugin as? any LLMProviderSetupStatusProviding else {
            return false
        }
        return !setupStatus.requiresExternalCredentials
    }

    func process(
        prompt: String,
        text: String,
        providerOverride: String? = nil,
        cloudModelOverride: String? = nil,
        temperatureDirective: PluginLLMTemperatureDirective = .inheritProviderSetting,
        skipMemoryInjection: Bool = false
    ) async throws -> String {
        // Inject memory context into prompt if available
        var effectivePrompt = prompt
        if !skipMemoryInjection, let memoryService {
            let memoryContext = await memoryService.retrieveRelevantMemories(for: text)
            if !memoryContext.isEmpty {
                effectivePrompt = memoryContext + "\n\n" + prompt
            }
        }

        let effectiveId = normalizeProviderId(providerOverride ?? selectedProviderId)

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
            if let setupStatus = plugin as? any LLMProviderSetupStatusProviding,
               !setupStatus.requiresExternalCredentials {
                throw LLMError.providerNotReady(
                    setupStatus.unavailableReason ?? "This provider is not ready yet."
                )
            }
            throw LLMError.noApiKey
        }

        normalizeSelectedCloudModelIfNeeded(for: effectiveId)
        let requestedModel = cloudModelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = resolvedModelId(
            for: effectiveId,
            requestedModel: requestedModel?.isEmpty == false ? requestedModel : nil,
            persistGlobalSelection: false
        )
        logger.info("Processing prompt with plugin \(effectiveId)")
        let result = try await withForegroundActivationIfNeeded(for: plugin, providerId: effectiveId) {
            try await processWithPlugin(
                plugin,
                prompt: effectivePrompt,
                text: text,
                model: model,
                temperatureDirective: temperatureDirective
            )
        }
        logger.info("Prompt processing complete, result length: \(result.count)")
        return result
    }

    private func processWithPlugin(
        _ plugin: any LLMProviderPlugin,
        prompt: String,
        text: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        if let temperatureAwarePlugin = plugin as? any LLMTemperatureControllableProvider {
            return try await temperatureAwarePlugin.process(
                systemPrompt: prompt,
                userText: text,
                model: model,
                temperatureDirective: temperatureDirective
            )
        }

        return try await plugin.process(
            systemPrompt: prompt,
            userText: text,
            model: model
        )
    }

    private func withForegroundActivationIfNeeded<T>(
        for plugin: any LLMProviderPlugin,
        providerId: String,
        operation: () async throws -> T
    ) async throws -> T {
        guard Self.requiresForegroundActivation(for: plugin) else {
            return try await operation()
        }

        // Keep local prompt processing on a high-priority activity budget, but do not
        // activate the app window. Stealing focus here breaks insertion because the
        // original target text field is no longer frontmost once the LLM step finishes.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Local prompt processing with \(providerId)"
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
        }

        return try await operation()
    }

    private func normalizeSelectedCloudModelIfNeeded(for providerId: String) {
        guard providerId != Self.appleIntelligenceId else { return }
        _ = resolvedModelId(
            for: providerId,
            requestedModel: selectedCloudModel.isEmpty ? nil : selectedCloudModel,
            persistGlobalSelection: true
        )
    }

    private func resolvedModelId(
        for providerId: String,
        requestedModel: String?,
        persistGlobalSelection: Bool
    ) -> String? {
        let models = modelsForProvider(providerId)
        guard !models.isEmpty else { return requestedModel }

        let validIds = Set(models.map(\.id))
        if let requestedModel,
           validIds.contains(requestedModel) {
            return requestedModel
        }

        let preferredModelId = (PluginManager.shared.llmProvider(for: providerId) as? LLMModelSelectable)?.preferredModelId as? String
        let fallbackModelId: String?
        if let preferredModelId,
           validIds.contains(preferredModelId) {
            fallbackModelId = preferredModelId
        } else if !selectedCloudModel.isEmpty,
                  validIds.contains(selectedCloudModel) {
            fallbackModelId = selectedCloudModel
        } else {
            fallbackModelId = models.first?.id
        }

        if persistGlobalSelection,
           let fallbackModelId,
           selectedCloudModel != fallbackModelId {
            selectedCloudModel = fallbackModelId
        }

        return fallbackModelId
    }
}
