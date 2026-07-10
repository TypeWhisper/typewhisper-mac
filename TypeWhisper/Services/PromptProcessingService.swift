import AppKit
import Combine
import Foundation
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

/// A user-configured LLM attempt. This stays app-private: plugin protocols and
/// the local HTTP API continue to expose no fallback-chain surface.
struct LLMFallbackPriorityItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var providerId: String
    var modelId: String?

    init(id: UUID = UUID(), providerId: String, modelId: String? = nil) {
        self.id = id
        self.providerId = providerId
        self.modelId = modelId
    }
}

struct LLMFallbackAttemptFailure: Equatable, Sendable {
    let providerId: String
    let modelId: String?
    let reason: String
}

struct LLMFallbackExhaustedError: LocalizedError, Equatable {
    let failures: [LLMFallbackAttemptFailure]

    var errorDescription: String? {
        guard !failures.isEmpty else {
            return "No LLM fallbacks are configured."
        }

        let details = failures.map { failure in
            let target = failure.modelId.map { "\(failure.providerId) (\($0))" } ?? failure.providerId
            return "\(target): \(failure.reason)"
        }.joined(separator: " · ")
        return "No configured LLM fallback could process this text. \(details)"
    }
}

private enum LLMFallbackAttemptError: LocalizedError {
    case emptyResult
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyResult:
            "The LLM returned an empty result."
        case .modelUnavailable(let modelId):
            "The selected model \(modelId) is not available for this provider."
        }
    }
}

@MainActor
class PromptProcessingService: ObservableObject {
    private enum ProcessingKind {
        case prompt
        case workflow(originalText: String)
    }

    private static let legacyPromptProviderKey = "llmProviderType"
    private static let legacyPromptModelKey = "llmCloudModel"

    private let userDefaults: UserDefaults
    private var isSynchronizingLegacySelection = false

    @Published private(set) var fallbackPriorityList: [LLMFallbackPriorityItem]

    /// Compatibility projections for the currently uninstantiated legacy prompt
    /// settings view. They always reflect the first fallback item and never write
    /// the old UserDefaults keys.
    @Published var selectedProviderId: String {
        didSet {
            guard !isSynchronizingLegacySelection else { return }
            let normalized = normalizeProviderId(selectedProviderId)
            guard normalized == selectedProviderId else {
                selectedProviderId = normalized
                return
            }
            replacePrimaryFallback(providerId: normalized, modelId: nil)
        }
    }
    @Published var selectedCloudModel: String {
        didSet {
            guard !isSynchronizingLegacySelection else { return }
            replacePrimaryFallback(
                providerId: selectedProviderId,
                modelId: Self.normalizedModelId(selectedCloudModel)
            )
        }
    }

    weak var memoryService: (any MemoryRetrieving)?
    weak var modelManagerService: ModelManagerService?
    private var appleIntelligenceProvider: LLMProvider?
    private var cancellables = Set<AnyCancellable>()
    var processActivityManager: any ProcessActivityManaging = DefaultProcessActivityManager()

    static let appleIntelligenceId = "appleIntelligence"

    var primaryFallbackItem: LLMFallbackPriorityItem? {
        fallbackPriorityList.first
    }

    var isAppleIntelligenceAvailable: Bool {
        if #available(macOS 26, *) {
            return appleIntelligenceProvider?.isAvailable ?? false
        }
        return false
    }

    /// Returns (id, displayName) pairs for all available providers.
    var availableProviders: [(id: String, displayName: String)] {
        var result: [(id: String, displayName: String)] = []

        if #available(macOS 26, *) {
            result.append((id: Self.appleIntelligenceId, displayName: "Apple Intelligence"))
        }

        for plugin in PluginManager.shared?.llmProviders ?? [] {
            result.append((id: plugin.llmProviderId, displayName: plugin.llmProviderDisplayName))
        }

        return result
    }

    var isCurrentProviderReady: Bool {
        primaryFallbackItem.map { isProviderReady($0.providerId) } ?? false
    }

    func isProviderReady(_ providerId: String) -> Bool {
        if providerId == Self.appleIntelligenceId {
            return isAppleIntelligenceAvailable
        }
        return PluginManager.shared?.llmProvider(for: providerId)?.isAvailable ?? false
    }

    /// Returns supported models for a given provider.
    func modelsForProvider(_ providerId: String) -> [PluginModelInfo] {
        if providerId == Self.appleIntelligenceId {
            return []
        }
        return PluginManager.shared?.llmProvider(for: providerId)?.supportedModels ?? []
    }

    /// Returns display name for a provider ID, retaining an unknown saved ID so
    /// the user can repair it rather than silently losing that fallback entry.
    func displayName(for providerId: String) -> String {
        if providerId == Self.appleIntelligenceId {
            return "Apple Intelligence"
        }
        return PluginManager.shared?.llmProvider(for: providerId)?.llmProviderDisplayName ?? providerId
    }

    /// Normalize a provider ID to match the plugin's stable runtime ID.
    /// Handles migration from old enum rawValues ("groq") to plugin IDs.
    func normalizeProviderId(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Self.appleIntelligenceId { return trimmed }
        return PluginManager.shared?.llmProvider(for: trimmed)?.llmProviderId ?? trimmed
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let initialList = Self.loadInitialFallbackPriorityList(from: userDefaults)
        self.fallbackPriorityList = initialList
        self.selectedProviderId = initialList.first?.providerId ?? Self.appleIntelligenceId
        self.selectedCloudModel = initialList.first?.modelId ?? ""

        setupProviders()
    }

    private func setupProviders() {
        if #available(macOS 26, *) {
            appleIntelligenceProvider = FoundationModelsProvider()
        }
    }

    func observePluginManager() {
        guard let pluginManager = PluginManager.shared else { return }
        pluginManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.validateSelectionAfterPluginLoad()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Normalize migrated aliases only after plugins are loaded. Unknown items
    /// deliberately remain in the persisted order so they can become available
    /// again after an integration is reinstalled.
    func validateSelectionAfterPluginLoad() {
        setFallbackPriorityList(fallbackPriorityList, normalizeProviderIds: true)
    }

    // MARK: - Fallback list management

    func addLLMFallback(providerId: String, modelId: String? = nil) {
        let normalizedProviderId = normalizeProviderId(providerId)
        guard !normalizedProviderId.isEmpty else { return }
        let normalizedModelId = Self.normalizedModelId(modelId)
        guard !fallbackPriorityList.contains(where: {
            $0.providerId == normalizedProviderId && $0.modelId == normalizedModelId
        }) else { return }

        setFallbackPriorityList(
            fallbackPriorityList + [
                LLMFallbackPriorityItem(providerId: normalizedProviderId, modelId: normalizedModelId)
            ],
            normalizeProviderIds: true
        )
    }

    func updateLLMFallback(
        _ item: LLMFallbackPriorityItem,
        providerId: String,
        modelId: String? = nil
    ) {
        guard let index = fallbackPriorityList.firstIndex(where: { $0.id == item.id }) else { return }
        let normalizedProviderId = normalizeProviderId(providerId)
        guard !normalizedProviderId.isEmpty else { return }
        let normalizedModelId = Self.normalizedModelId(modelId)
        guard !fallbackPriorityList.enumerated().contains(where: { otherIndex, otherItem in
            otherIndex != index
                && otherItem.providerId == normalizedProviderId
                && otherItem.modelId == normalizedModelId
        }) else { return }

        var updated = fallbackPriorityList
        updated[index].providerId = normalizedProviderId
        updated[index].modelId = normalizedModelId
        setFallbackPriorityList(updated, normalizeProviderIds: true)
    }

    func removeLLMFallback(_ item: LLMFallbackPriorityItem) {
        setFallbackPriorityList(
            fallbackPriorityList.filter { $0.id != item.id },
            normalizeProviderIds: false
        )
    }

    func moveLLMFallbacks(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }

        var items = fallbackPriorityList
        let validSource = source.filter { items.indices.contains($0) }.sorted()
        guard !validSource.isEmpty else { return }

        let movingItems = validSource.map { items[$0] }
        for index in validSource.reversed() {
            items.remove(at: index)
        }

        let removedBeforeDestination = validSource.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(items.count, destination - removedBeforeDestination))
        items.insert(contentsOf: movingItems, at: adjustedDestination)
        setFallbackPriorityList(items, normalizeProviderIds: false)
    }

    // MARK: - Processing

    func process(
        prompt: String,
        text: String,
        providerOverride: String? = nil,
        cloudModelOverride: String? = nil,
        skipMemoryInjection: Bool = false
    ) async throws -> String {
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
        try await processWorkflow(
            prompt: prompt,
            text: text,
            providerOverride: behavior.providerId,
            cloudModelOverride: behavior.cloudModel,
            temperatureDirective: behavior.temperatureDirective
        )
    }

    func processWorkflow(
        prompt: String,
        text: String,
        providerOverride: String?,
        cloudModelOverride: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        try await execute(
            prompt: prompt,
            text: text,
            providerOverride: providerOverride,
            cloudModelOverride: cloudModelOverride,
            temperatureDirective: temperatureDirective,
            skipMemoryInjection: true,
            processingKind: .workflow(originalText: text)
        )
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
        try await execute(
            prompt: prompt,
            text: text,
            providerOverride: providerOverride,
            cloudModelOverride: cloudModelOverride,
            temperatureDirective: temperatureDirective,
            skipMemoryInjection: skipMemoryInjection,
            processingKind: .prompt
        )
    }

    private func execute(
        prompt: String,
        text: String,
        providerOverride: String?,
        cloudModelOverride: String?,
        temperatureDirective: PluginLLMTemperatureDirective,
        skipMemoryInjection: Bool,
        processingKind: ProcessingKind
    ) async throws -> String {
        let totalStart = ContinuousClock.now
        var effectivePrompt = prompt

        if !skipMemoryInjection, let memoryService {
            let memoryStart = ContinuousClock.now
            let memoryContext = await memoryService.retrieveRelevantMemories(for: text)
            try Task.checkCancellation()
            logger.info("Prompt memory retrieval finished in \(ContinuousClock.now - memoryStart)")
            if !memoryContext.isEmpty {
                effectivePrompt = memoryContext + "\n\n" + prompt
            }
        } else if skipMemoryInjection {
            logger.info("Prompt memory retrieval skipped")
        }

        let explicitProviderId = Self.trimmedOrNil(providerOverride)
        let usesFallbackList = explicitProviderId == nil
        let candidates: [LLMFallbackPriorityItem]
        if let explicitProviderId {
            candidates = [
                LLMFallbackPriorityItem(
                    providerId: normalizeProviderId(explicitProviderId),
                    modelId: Self.normalizedModelId(cloudModelOverride)
                )
            ]
        } else {
            candidates = fallbackPriorityList
        }

        guard !candidates.isEmpty else {
            throw LLMFallbackExhaustedError(failures: [])
        }

        var localProvidersUsed: [any LLMProviderPlugin] = []
        var localProviderIdentities: Set<ObjectIdentifier> = []
        defer {
            for provider in localProvidersUsed {
                modelManagerService?.endAutoUnloadProtectedUse(of: provider)
            }
        }

        var failures: [LLMFallbackAttemptFailure] = []
        for (index, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            let providerId = normalizeProviderId(candidate.providerId)
            let attemptText = inputText(
                for: processingKind,
                providerId: providerId,
                fallbackText: text
            )
            logger.info("Trying LLM fallback \(index + 1, privacy: .public) of \(candidates.count, privacy: .public): \(providerId, privacy: .public)")

            do {
                let providerResult = try await processSingleProvider(
                    providerId: providerId,
                    requestedModelId: candidate.modelId,
                    prompt: effectivePrompt,
                    text: attemptText,
                    temperatureDirective: temperatureDirective,
                    onLocalProviderUsed: { provider in
                        let identity = ObjectIdentifier(provider)
                        guard localProviderIdentities.insert(identity).inserted else { return }
                        localProvidersUsed.append(provider)
                        modelManagerService?.beginAutoUnloadProtectedUse(of: provider)
                    }
                )
                try Task.checkCancellation()

                let result = outputText(
                    providerResult,
                    for: processingKind,
                    providerId: providerId
                )
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LLMFallbackAttemptError.emptyResult
                }

                logger.info("Prompt processing complete in \(ContinuousClock.now - totalStart), result length: \(result.count)")
                return result
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if Self.isCancellation(error) {
                    throw error
                }
                guard usesFallbackList else {
                    throw error
                }

                let failure = LLMFallbackAttemptFailure(
                    providerId: providerId,
                    modelId: candidate.modelId,
                    reason: Self.failureReason(for: error)
                )
                failures.append(failure)
                logger.warning("LLM fallback \(index + 1, privacy: .public) failed for \(providerId, privacy: .public): \(failure.reason, privacy: .private(mask: .hash))")
            }
        }

        throw LLMFallbackExhaustedError(failures: failures)
    }

    private func processSingleProvider(
        providerId: String,
        requestedModelId: String?,
        prompt: String,
        text: String,
        temperatureDirective: PluginLLMTemperatureDirective,
        onLocalProviderUsed: (any LLMProviderPlugin) -> Void
    ) async throws -> String {
        if providerId == Self.appleIntelligenceId {
            guard let provider = appleIntelligenceProvider, provider.isAvailable else {
                throw LLMError.notAvailable
            }

            logger.info("Processing prompt with Apple Intelligence")
            let providerStart = ContinuousClock.now
            do {
                let result = try await provider.process(systemPrompt: prompt, userText: text)
                logger.info("Prompt provider call finished in \(ContinuousClock.now - providerStart)")
                return result
            } catch {
                logger.error("Prompt provider call failed after \(ContinuousClock.now - providerStart): \(error.localizedDescription)")
                throw error
            }
        }

        guard let plugin = PluginManager.shared?.llmProvider(for: providerId) else {
            throw LLMError.noProviderConfigured
        }
        if Self.requiresProcessActivityBudget(for: plugin) {
            onLocalProviderUsed(plugin)
        }
        try await restoreLocalProviderIfNeeded(plugin)
        guard plugin.isAvailable else {
            if let setupStatus = plugin as? any LLMProviderSetupStatusProviding,
               !setupStatus.requiresExternalCredentials {
                throw LLMError.providerNotReady(
                    setupStatus.unavailableReason ?? "This provider is not ready yet."
                )
            }
            throw LLMError.noApiKey
        }

        let model = try resolvedModelId(
            for: plugin,
            providerId: providerId,
            requestedModelId: requestedModelId
        )
        logger.info("Processing prompt with plugin \(providerId)")
        let providerStart = ContinuousClock.now
        do {
            let result = try await withProcessActivityIfNeeded(for: plugin, providerId: providerId) {
                try await processWithPlugin(
                    plugin,
                    prompt: prompt,
                    text: text,
                    model: model,
                    temperatureDirective: temperatureDirective
                )
            }
            logger.info("Prompt provider call finished in \(ContinuousClock.now - providerStart)")
            return result
        } catch {
            logger.error("Prompt provider call failed after \(ContinuousClock.now - providerStart): \(error.localizedDescription)")
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

    private func restoreLocalProviderIfNeeded(_ plugin: any LLMProviderPlugin) async throws {
        guard Self.requiresProcessActivityBudget(for: plugin),
              !plugin.isAvailable,
              let nsPlugin = plugin as? NSObject else { return }

        let selector = NSSelectorFromString("triggerRestoreModel")
        guard nsPlugin.responds(to: selector) else { return }

        nsPlugin.perform(selector)
        for _ in 0..<300 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
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

    /// The provider plugin's recommended fallback when a priority entry has no
    /// explicit model selection. This is a runtime hint, never persisted back
    /// into the priority list.
    func defaultModelId(for providerId: String) -> String? {
        (PluginManager.shared?.llmProvider(for: providerId) as? LLMModelSelectable)?.defaultModelId as? String
    }

    private func resolvedModelId(
        for plugin: any LLMProviderPlugin,
        providerId: String,
        requestedModelId: String?
    ) throws -> String? {
        let availableModels = modelsForProvider(providerId)
        if let requestedModelId = Self.normalizedModelId(requestedModelId) {
            guard availableModels.isEmpty || availableModels.contains(where: { $0.id == requestedModelId }) else {
                throw LLMFallbackAttemptError.modelUnavailable(requestedModelId)
            }
            return requestedModelId
        }

        guard !availableModels.isEmpty else { return nil }
        let validIds = Set(availableModels.map(\.id))
        let preferredModelId = (plugin as? LLMModelSelectable)?.preferredModelId as? String
        if let preferredModelId, validIds.contains(preferredModelId) {
            return preferredModelId
        }
        if let providerDefaultModelId = defaultModelId(for: providerId),
           validIds.contains(providerDefaultModelId) {
            return providerDefaultModelId
        }
        return availableModels.first?.id
    }

    private func inputText(
        for processingKind: ProcessingKind,
        providerId: String,
        fallbackText: String
    ) -> String {
        switch processingKind {
        case .prompt:
            fallbackText
        case .workflow(let originalText):
            providerId == Self.appleIntelligenceId
                ? originalText
                : TypeWhisperDictatedTextBoundary.wrap(originalText)
        }
    }

    private func outputText(
        _ result: String,
        for processingKind: ProcessingKind,
        providerId: String
    ) -> String {
        switch processingKind {
        case .prompt:
            result
        case .workflow(let originalText):
            providerId == Self.appleIntelligenceId
                ? result
                : TypeWhisperDictatedTextBoundary.sanitize(
                    result,
                    originalUserText: originalText,
                    fallbackToOriginalUserText: false
                )
        }
    }

    // MARK: - Persistence and migration

    private func replacePrimaryFallback(providerId: String, modelId: String?) {
        let normalizedProviderId = normalizeProviderId(providerId)
        guard !normalizedProviderId.isEmpty else { return }
        var items = fallbackPriorityList
        if let first = items.first {
            items[0] = LLMFallbackPriorityItem(
                id: first.id,
                providerId: normalizedProviderId,
                modelId: Self.normalizedModelId(modelId)
            )
        } else {
            items = [
                LLMFallbackPriorityItem(
                    providerId: normalizedProviderId,
                    modelId: Self.normalizedModelId(modelId)
                )
            ]
        }
        setFallbackPriorityList(items, normalizeProviderIds: true)
    }

    private func setFallbackPriorityList(
        _ items: [LLMFallbackPriorityItem],
        normalizeProviderIds: Bool
    ) {
        let normalized = normalizedFallbackPriorityList(
            items,
            normalizeProviderIds: normalizeProviderIds
        )
        guard normalized != fallbackPriorityList else {
            synchronizeLegacySelection()
            return
        }

        fallbackPriorityList = normalized
        persistFallbackPriorityList(normalized)
        synchronizeLegacySelection()
    }

    private func normalizedFallbackPriorityList(
        _ items: [LLMFallbackPriorityItem],
        normalizeProviderIds: Bool
    ) -> [LLMFallbackPriorityItem] {
        let normalizedItems = items.compactMap { item -> LLMFallbackPriorityItem? in
            let rawProviderId = item.providerId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawProviderId.isEmpty else { return nil }
            return LLMFallbackPriorityItem(
                id: item.id,
                providerId: normalizeProviderIds ? normalizeProviderId(rawProviderId) : rawProviderId,
                modelId: Self.normalizedModelId(item.modelId)
            )
        }
        return Self.deduplicatedFallbackPriorityList(normalizedItems)
    }

    private func synchronizeLegacySelection() {
        isSynchronizingLegacySelection = true
        selectedProviderId = fallbackPriorityList.first?.providerId ?? Self.appleIntelligenceId
        selectedCloudModel = fallbackPriorityList.first?.modelId ?? ""
        isSynchronizingLegacySelection = false
    }

    private func persistFallbackPriorityList(_ items: [LLMFallbackPriorityItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        userDefaults.set(data, forKey: UserDefaultsKeys.llmFallbackPriorityList)
    }

    private static func loadInitialFallbackPriorityList(from defaults: UserDefaults) -> [LLMFallbackPriorityItem] {
        if let data = defaults.data(forKey: UserDefaultsKeys.llmFallbackPriorityList),
           let decoded = try? JSONDecoder().decode([LLMFallbackPriorityItem].self, from: data) {
            let normalized = deduplicatedFallbackPriorityList(decoded.compactMap { item in
                let providerId = item.providerId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !providerId.isEmpty else { return nil }
                return LLMFallbackPriorityItem(
                    id: item.id,
                    providerId: providerId,
                    modelId: normalizedModelId(item.modelId)
                )
            })
            persistInitialFallbackPriorityList(normalized, to: defaults)
            return normalized
        }

        return migratedFallbackPriorityList(from: defaults)
    }

    private static func migratedFallbackPriorityList(from defaults: UserDefaults) -> [LLMFallbackPriorityItem] {
        var migrated: [LLMFallbackPriorityItem] = []
        if let workflowDefault = legacyFallbackItem(
            providerKey: UserDefaultsKeys.workflowDefaultLLMProviderId,
            modelKey: UserDefaultsKeys.workflowDefaultLLMCloudModel,
            defaults: defaults
        ) {
            migrated.append(workflowDefault)
        }
        if let promptDefault = legacyFallbackItem(
            providerKey: legacyPromptProviderKey,
            modelKey: legacyPromptModelKey,
            defaults: defaults
        ) {
            migrated.append(promptDefault)
        }
        if migrated.isEmpty {
            migrated = [LLMFallbackPriorityItem(providerId: appleIntelligenceId)]
        }

        let normalized = deduplicatedFallbackPriorityList(migrated)
        persistInitialFallbackPriorityList(normalized, to: defaults)
        return normalized
    }

    private static func legacyFallbackItem(
        providerKey: String,
        modelKey: String,
        defaults: UserDefaults
    ) -> LLMFallbackPriorityItem? {
        guard let providerId = trimmedOrNil(defaults.string(forKey: providerKey)) else { return nil }
        return LLMFallbackPriorityItem(
            providerId: providerId,
            modelId: normalizedModelId(defaults.string(forKey: modelKey))
        )
    }

    private static func persistInitialFallbackPriorityList(
        _ items: [LLMFallbackPriorityItem],
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: UserDefaultsKeys.llmFallbackPriorityList)
    }

    private static func deduplicatedFallbackPriorityList(
        _ items: [LLMFallbackPriorityItem]
    ) -> [LLMFallbackPriorityItem] {
        var seenPairs = Set<String>()
        var seenIDs = Set<UUID>()
        var result: [LLMFallbackPriorityItem] = []

        for item in items {
            let pairKey = "\(item.providerId)\u{001F}\(item.modelId ?? "")"
            guard seenPairs.insert(pairKey).inserted else { continue }
            let identifier = seenIDs.insert(item.id).inserted ? item.id : UUID()
            result.append(
                LLMFallbackPriorityItem(
                    id: identifier,
                    providerId: item.providerId,
                    modelId: item.modelId
                )
            )
        }
        return result
    }

    private static func normalizedModelId(_ modelId: String?) -> String? {
        trimmedOrNil(modelId)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func failureReason(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "Unknown provider failure." : description
    }

    struct ModelResolution: Equatable {
        let modelId: String?
        /// Historical resolution signal retained for the pure compatibility
        /// helper below. The fallback executor never writes it to persistence.
        let persistGlobally: Bool
    }

    /// Retained as a pure compatibility helper for existing model-resolution
    /// tests. The new fallback executor resolves models per list item and never
    /// writes a provider's transient choice into global state.
    static func resolveModel(
        requestedModel: String?,
        preferredModelId: String?,
        selectedCloudModel: String,
        availableModelIds: [String],
        providerDefaultModelId: String? = nil
    ) -> ModelResolution {
        guard !availableModelIds.isEmpty else {
            return ModelResolution(modelId: requestedModel, persistGlobally: false)
        }

        let validIds = Set(availableModelIds)
        if let requestedModel, validIds.contains(requestedModel) {
            return ModelResolution(modelId: requestedModel, persistGlobally: false)
        }

        if let preferredModelId, validIds.contains(preferredModelId) {
            return ModelResolution(modelId: preferredModelId, persistGlobally: true)
        }

        if !selectedCloudModel.isEmpty, validIds.contains(selectedCloudModel) {
            return ModelResolution(modelId: selectedCloudModel, persistGlobally: false)
        }

        let fallbackModelId = providerDefaultModelId.flatMap { validIds.contains($0) ? $0 : nil }
            ?? availableModelIds.first
        let isRepairingInvalidSelection = !selectedCloudModel.isEmpty
        return ModelResolution(
            modelId: fallbackModelId,
            persistGlobally: isRepairingInvalidSelection
        )
    }
}
