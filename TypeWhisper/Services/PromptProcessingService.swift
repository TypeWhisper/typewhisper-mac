import AppKit
import Foundation
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PromptProcessingService")

@MainActor
protocol ProcessActivityManaging {
    func withActivity<T>(
        options: ProcessInfo.ActivityOptions,
        reason: String,
        operation: () async throws -> T
    ) async rethrows -> T
}

@MainActor
protocol MemoryRetrieving: AnyObject {
    func retrieveRelevantMemories(for text: String) async -> String
}

@MainActor
struct DefaultProcessActivityManager: ProcessActivityManaging {
    func withActivity<T>(
        options: ProcessInfo.ActivityOptions,
        reason: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        defer {
            ProcessInfo.processInfo.endActivity(activity)
        }

        return try await operation()
    }
}

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

    weak var memoryService: (any MemoryRetrieving)?
    weak var modelManagerService: ModelManagerService?
    private var appleIntelligenceProvider: LLMProvider?
    private var cancellables = Set<AnyCancellable>()
    var processActivityManager: any ProcessActivityManaging = DefaultProcessActivityManager()

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

    func processWorkflow(prompt: String, text: String, behavior: WorkflowBehavior) async throws -> String {
        let effectiveId = normalizeProviderId(behavior.providerId ?? selectedProviderId)
        let shouldBoundDictatedText = effectiveId != Self.appleIntelligenceId
        let workflowInput = shouldBoundDictatedText
            ? TypeWhisperDictatedTextBoundary.wrap(text)
            : text

        let result = try await process(
            prompt: prompt,
            text: workflowInput,
            providerOverride: behavior.providerId,
            cloudModelOverride: behavior.cloudModel,
            temperatureDirective: behavior.temperatureDirective,
            skipMemoryInjection: true
        )

        guard shouldBoundDictatedText else {
            return result
        }

        return TypeWhisperDictatedTextBoundary.sanitize(result, originalUserText: text)
    }

    static func requiresProcessActivityBudget(for plugin: any LLMProviderPlugin) -> Bool {
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
        let totalStart = ContinuousClock.now

        // Inject memory context into prompt if available
        var effectivePrompt = prompt
        if !skipMemoryInjection, let memoryService {
            let memoryStart = ContinuousClock.now
            let memoryContext = await memoryService.retrieveRelevantMemories(for: text)
            logger.info("Prompt memory retrieval finished in \(ContinuousClock.now - memoryStart)")
            if !memoryContext.isEmpty {
                effectivePrompt = memoryContext + "\n\n" + prompt
            }
        } else if skipMemoryInjection {
            logger.info("Prompt memory retrieval skipped")
        }

        let effectiveId = normalizeProviderId(providerOverride ?? selectedProviderId)

        if effectiveId == Self.appleIntelligenceId {
            guard let provider = appleIntelligenceProvider, provider.isAvailable else {
                throw LLMError.notAvailable
            }
            logger.info("Processing prompt with Apple Intelligence")
            let providerStart = ContinuousClock.now
            do {
                let result = try await provider.process(systemPrompt: effectivePrompt, userText: text)
                logger.info("Prompt provider call finished in \(ContinuousClock.now - providerStart)")
                logger.info("Prompt processing complete in \(ContinuousClock.now - totalStart), result length: \(result.count)")
                return result
            } catch {
                logger.error("Prompt provider call failed after \(ContinuousClock.now - providerStart): \(error.localizedDescription)")
                logger.error("Prompt processing failed after \(ContinuousClock.now - totalStart): \(error.localizedDescription)")
                throw error
            }
        }

        // Plugin provider
        guard let plugin = PluginManager.shared.llmProvider(for: effectiveId) else {
            throw LLMError.noProviderConfigured
        }
        await restoreLocalProviderIfNeeded(plugin)
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
        let shouldAutoUnloadAfterProcessing = Self.requiresProcessActivityBudget(for: plugin)
        defer {
            if shouldAutoUnloadAfterProcessing {
                modelManagerService?.scheduleAutoUnloadIfNeeded(for: plugin)
            }
        }

        logger.info("Processing prompt with plugin \(effectiveId)")
        let providerStart = ContinuousClock.now
        do {
            let result = try await withProcessActivityIfNeeded(for: plugin, providerId: effectiveId) {
                try await processWithPlugin(
                    plugin,
                    prompt: effectivePrompt,
                    text: text,
                    model: model,
                    temperatureDirective: temperatureDirective
                )
            }
            logger.info("Prompt provider call finished in \(ContinuousClock.now - providerStart)")
            logger.info("Prompt processing complete in \(ContinuousClock.now - totalStart), result length: \(result.count)")
            return result
        } catch {
            logger.error("Prompt provider call failed after \(ContinuousClock.now - providerStart): \(error.localizedDescription)")
            logger.error("Prompt processing failed after \(ContinuousClock.now - totalStart): \(error.localizedDescription)")
            throw error
        }
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

    private func restoreLocalProviderIfNeeded(_ plugin: any LLMProviderPlugin) async {
        guard Self.requiresProcessActivityBudget(for: plugin),
              !plugin.isAvailable,
              let nsPlugin = plugin as? NSObject else { return }

        let selector = NSSelectorFromString("triggerRestoreModel")
        guard nsPlugin.responds(to: selector) else { return }

        nsPlugin.perform(selector)
        for _ in 0..<300 {
            try? await Task.sleep(for: .milliseconds(100))
            if plugin.isAvailable { return }

            if let activityReporter = plugin as? any PluginSettingsActivityReporting {
                guard let activity = activityReporter.currentSettingsActivity,
                      !activity.isError else { return }
            }
        }
    }

    private func withProcessActivityIfNeeded<T>(
        for plugin: any LLMProviderPlugin,
        providerId: String,
        operation: () async throws -> T
    ) async throws -> T {
        guard Self.requiresProcessActivityBudget(for: plugin) else {
            return try await operation()
        }

        // Keep local prompt processing on a high-priority activity budget, but do not
        // activate the app window. Stealing focus here breaks insertion because the
        // original target text field is no longer frontmost once the LLM step finishes.
        return try await processActivityManager.withActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Local prompt processing with \(providerId)"
        ) {
            try await operation()
        }
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
