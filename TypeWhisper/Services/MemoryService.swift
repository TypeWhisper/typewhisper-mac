import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MemoryService")

enum MemoryCaptureScope: String, CaseIterable, Identifiable, Hashable {
    case allDictations
    case workflowDictationsOnly

    static let defaultScope: MemoryCaptureScope = .allDictations

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .allDictations:
            return String(localized: "All dictations")
        case .workflowDictationsOnly:
            return String(localized: "Workflow dictations only")
        }
    }

    var localizedDescription: String {
        switch self {
        case .allDictations:
            return String(localized: "Memory extraction runs for every eligible transcription after the minimum text length and cooldown checks.")
        case .workflowDictationsOnly:
            return String(localized: "Memory extraction runs only when the transcription was produced by a known workflow.")
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> MemoryCaptureScope {
        guard let rawValue = defaults.string(forKey: UserDefaultsKeys.memoryCaptureScope),
              let scope = MemoryCaptureScope(rawValue: rawValue) else {
            return defaultScope
        }
        return scope
    }
}

struct MemoryExtractionDiagnosticsSnapshot: Encodable, Equatable, Sendable {
    let inFlight: Bool
    let skippedWhileBusy: Int
    let totalStarted: Int
    let totalCompleted: Int
    let totalFailed: Int
    let lastStartedAt: Date?
    let lastFinishedAt: Date?
}

typealias MemoryExtractionPromptProcessor = @MainActor (
    _ prompt: String,
    _ text: String,
    _ providerId: String,
    _ model: String?
) async throws -> String

@MainActor
final class MemoryService: ObservableObject, MemoryRetrieving {
    nonisolated static let rawMemoryTypeMetadataKey = "rawMemoryType"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: UserDefaultsKeys.memoryEnabled) }
    }
    @Published var extractionProviderId: String {
        didSet { UserDefaults.standard.set(extractionProviderId, forKey: UserDefaultsKeys.memoryExtractionProvider) }
    }
    @Published var extractionModel: String {
        didSet { UserDefaults.standard.set(extractionModel, forKey: UserDefaultsKeys.memoryExtractionModel) }
    }
    @Published var minimumTextLength: Int {
        didSet { UserDefaults.standard.set(minimumTextLength, forKey: UserDefaultsKeys.memoryMinTextLength) }
    }
    @Published var extractionPrompt: String {
        didSet { UserDefaults.standard.set(extractionPrompt, forKey: UserDefaultsKeys.memoryExtractionPrompt) }
    }
    @Published var captureScope: MemoryCaptureScope {
        didSet { UserDefaults.standard.set(captureScope.rawValue, forKey: UserDefaultsKeys.memoryCaptureScope) }
    }

    static let defaultExtractionPrompt = """
You extract ONLY lasting personal facts about the speaker from transcribed speech. \
Return [] in 95% of cases - most speech contains nothing worth remembering permanently.

ONLY extract if the speaker explicitly reveals:
- Their name, job title, or employer
- A long-term project they work on
- A strong repeated preference ("I always...", "I prefer...")
- Names of close colleagues or family members

NEVER extract:
- What the speaker is dictating (emails, notes, messages, tasks, questions)
- Temporary plans ("meeting tomorrow", "need to call X")
- Opinions, thoughts, or statements about any topic
- Anything that sounds like content being dictated rather than self-revelation

When in doubt: return []

JSON format: [{"content": "...", "type": "fact", "confidence": 0.9}]
Return ONLY the JSON array, nothing else.
"""

    private let promptProcessingService: PromptProcessingService
    private let promptProcessor: MemoryExtractionPromptProcessor
    private let workflowNameProvider: @MainActor () -> [String]
    private var eventSubscriptionId: UUID?
    private var lastExtractionTime: Date = .distantPast
    private var extractionCooldown: TimeInterval = 30
    private var extractionTask: Task<Void, Never>?
    private var activeExtractionID: UUID?
    private var skippedWhileBusy = 0
    private var totalStarted = 0
    private var totalCompleted = 0
    private var totalFailed = 0
    private var lastStartedAt: Date?
    private var lastFinishedAt: Date?

    init(
        promptProcessingService: PromptProcessingService,
        promptProcessor: MemoryExtractionPromptProcessor? = nil,
        workflowNameProvider: @escaping @MainActor () -> [String] = {
            ServiceContainer.shared.workflowService.workflows.map(\.name)
        }
    ) {
        self.promptProcessingService = promptProcessingService
        self.promptProcessor = promptProcessor ?? { prompt, text, providerId, model in
            try await promptProcessingService.process(
                prompt: prompt,
                text: text,
                providerOverride: providerId,
                cloudModelOverride: model,
                skipMemoryInjection: true
            )
        }
        self.workflowNameProvider = workflowNameProvider
        self.isEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.memoryEnabled)
        self.extractionProviderId = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionProvider) ?? ""
        self.extractionModel = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionModel) ?? ""
        self.minimumTextLength = UserDefaults.standard.object(forKey: UserDefaultsKeys.memoryMinTextLength) as? Int ?? 50
        let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionPrompt) ?? ""
        self.extractionPrompt = saved.isEmpty ? Self.defaultExtractionPrompt : saved
        self.captureScope = MemoryCaptureScope.load()
    }

    // MARK: - Lifecycle

    func startListening() {
        guard eventSubscriptionId == nil else { return }
        eventSubscriptionId = EventBus.shared.subscribe { [weak self] event in
            if case .transcriptionCompleted(let payload) = event {
                await MainActor.run { self?.handleTranscription(payload) }
            }
        }
        logger.info("Memory service started listening")
    }

    func stopListening() {
        if let id = eventSubscriptionId {
            EventBus.shared.unsubscribe(id: id)
            eventSubscriptionId = nil
        }
        extractionTask?.cancel()
        activeExtractionID = nil
        extractionTask = nil
    }

    // MARK: - Extraction

    nonisolated static func shouldAttemptExtraction(
        payload: TranscriptionCompletedPayload,
        isEnabled: Bool,
        minimumTextLength: Int,
        captureScope: MemoryCaptureScope,
        knownWorkflowNames: [String]
    ) -> Bool {
        guard isEnabled, payload.finalText.count >= minimumTextLength else { return false }

        switch captureScope {
        case .allDictations:
            return true
        case .workflowDictationsOnly:
            guard let ruleName = payload.ruleName else { return false }
            return knownWorkflowNames.contains(ruleName)
        }
    }

    private func handleTranscription(_ payload: TranscriptionCompletedPayload) {
        let knownWorkflowNames = captureScope == .workflowDictationsOnly ? workflowNameProvider() : []
        guard Self.shouldAttemptExtraction(
            payload: payload,
            isEnabled: isEnabled,
            minimumTextLength: minimumTextLength,
            captureScope: captureScope,
            knownWorkflowNames: knownWorkflowNames
        ) else { return }

        let providerId = extractionProviderId
        guard !providerId.isEmpty else { return }

        if extractionTask != nil {
            skippedWhileBusy += 1
            logger.info("Memory extraction skipped because a previous extraction is still running")
            return
        }

        // Cooldown
        let now = Date()
        guard now.timeIntervalSince(lastExtractionTime) >= extractionCooldown else { return }
        lastExtractionTime = now
        totalStarted += 1
        lastStartedAt = now

        // Capture all MainActor properties before detaching
        let prompt = extractionPrompt
        let model = extractionModel
        let extractionID = UUID()
        activeExtractionID = extractionID

        extractionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.extractAndStore(payload: payload, providerId: providerId, prompt: prompt, model: model)
                self.finishExtraction(extractionID: extractionID, didFail: false)
            } catch is CancellationError {
                self.finishExtraction(extractionID: extractionID, didFail: false)
            } catch {
                self.finishExtraction(extractionID: extractionID, didFail: true)
                logger.error("Memory extraction failed: \(error.localizedDescription)")
            }
        }
    }

    private func finishExtraction(extractionID: UUID, didFail: Bool) {
        guard activeExtractionID == extractionID else { return }
        if didFail {
            totalFailed += 1
        } else {
            totalCompleted += 1
        }
        lastFinishedAt = Date()
        extractionTask = nil
        activeExtractionID = nil
    }

    private func extractAndStore(payload: TranscriptionCompletedPayload, providerId: String, prompt: String, model: String) async throws {
        let result = try await promptProcessor(
            prompt,
            payload.finalText,
            providerId,
            model.isEmpty ? nil : model
        )
        try Task.checkCancellation()

        let entries = parseExtractedMemories(result, source: MemorySource(
            appName: payload.appName,
            bundleIdentifier: payload.bundleIdentifier,
            ruleName: payload.ruleName,
            timestamp: payload.timestamp
        ))
        guard !entries.isEmpty else {
            logger.info("Memory extraction produced no storable entries")
            return
        }

        let plugins = PluginManager.shared.memoryStoragePlugins
        guard !plugins.isEmpty else {
            logger.warning("Memory extraction produced entries, but no memory storage plugins are loaded")
            return
        }

        let deduped = await deduplicate(entries: entries, using: plugins)
        try Task.checkCancellation()
        guard !deduped.isEmpty else {
            logger.info("Memory extraction produced only duplicate entries")
            return
        }

        var storedInReadyPlugin = false
        for plugin in plugins where plugin.isReady {
            try Task.checkCancellation()
            do {
                try await plugin.store(deduped)
                storedInReadyPlugin = true
                logger.info("Stored \(deduped.count) memories in \(plugin.storageName)")
            } catch {
                logger.error("Failed to store memories in \(plugin.storageName): \(error.localizedDescription)")
            }
        }

        if !storedInReadyPlugin {
            logger.warning("Memory extraction produced entries, but no ready memory storage plugin accepted them")
        }
    }

    nonisolated static func memoryType(for rawValue: String) -> MemoryType {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MemoryType(rawValue: normalized) ?? .context
    }

    private func parseExtractedMemories(_ json: String, source: MemorySource) -> [MemoryEntry] {
        let cleaned = json
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        struct RawMemory: Codable {
            let content: String
            let type: String
            let confidence: Double?
        }

        guard let data = cleaned.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawMemory].self, from: data) else {
            logger.info("Memory extraction response was not a JSON array of memory entries")
            return []
        }

        return raw.compactMap { item in
            let type = Self.memoryType(for: item.type)
            let normalizedType = item.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var metadata: [String: String] = [:]
            if MemoryType(rawValue: normalizedType) == nil {
                logger.info("Memory extraction returned unknown type '\(item.type, privacy: .public)'; storing it as context")
                metadata[Self.rawMemoryTypeMetadataKey] = normalizedType
            }
            let conf = item.confidence ?? 0.8
            guard conf >= 0.8 else { return nil }
            return MemoryEntry(content: item.content, type: type, source: source, metadata: metadata, confidence: conf)
        }
    }

    func extractionDiagnosticsSnapshot() -> MemoryExtractionDiagnosticsSnapshot {
        MemoryExtractionDiagnosticsSnapshot(
            inFlight: extractionTask != nil,
            skippedWhileBusy: skippedWhileBusy,
            totalStarted: totalStarted,
            totalCompleted: totalCompleted,
            totalFailed: totalFailed,
            lastStartedAt: lastStartedAt,
            lastFinishedAt: lastFinishedAt
        )
    }

    #if DEBUG
    func handleTranscriptionForTesting(_ payload: TranscriptionCompletedPayload) {
        handleTranscription(payload)
    }

    func setExtractionCooldownForTesting(_ cooldown: TimeInterval) {
        extractionCooldown = cooldown
    }
    #endif

    // MARK: - Deduplication

    private func deduplicate(entries: [MemoryEntry], using plugins: [MemoryStoragePlugin]) async -> [MemoryEntry] {
        var unique: [MemoryEntry] = []
        for entry in entries {
            let query = MemoryQuery(text: entry.content, maxResults: 1, minConfidence: 0.0)
            var isDuplicate = false

            for plugin in plugins where plugin.isReady {
                if let results = try? await plugin.search(query),
                   let best = results.first,
                   Self.shouldTreatAsDuplicate(
                       newEntry: entry,
                       existingEntry: best.entry,
                       relevanceScore: best.relevanceScore
                   ) {
                    var updated = best.entry
                    updated.lastAccessedAt = Date()
                    updated.accessCount += 1
                    try? await plugin.update(updated)
                    isDuplicate = true
                    break
                }
            }
            if !isDuplicate { unique.append(entry) }
        }
        return unique
    }

    nonisolated static func shouldTreatAsDuplicate(
        newEntry: MemoryEntry,
        existingEntry: MemoryEntry,
        relevanceScore: Double
    ) -> Bool {
        guard relevanceScore > 0.85 else { return false }

        if newEntry.metadata[rawMemoryTypeMetadataKey] != nil || existingEntry.metadata[rawMemoryTypeMetadataKey] != nil {
            let newContent = newEntry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let existingContent = existingEntry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return newContent.caseInsensitiveCompare(existingContent) == .orderedSame
        }

        return true
    }

    // MARK: - Retrieval

    func retrieveRelevantMemories(for text: String) async -> String {
        guard isEnabled else { return "" }

        let plugins = PluginManager.shared.memoryStoragePlugins
        guard !plugins.isEmpty else { return "" }

        let query = MemoryQuery(text: text, maxResults: 10, minConfidence: 0.3)

        // Collect results with their source plugin for targeted updates
        var pluginResults: [(plugin: MemoryStoragePlugin, result: MemorySearchResult)] = []
        for plugin in plugins where plugin.isReady {
            if let results = try? await plugin.search(query) {
                for r in results { pluginResults.append((plugin, r)) }
            }
        }
        guard !pluginResults.isEmpty else { return "" }

        // Deduplicate by content, keep highest relevance
        var seen = Set<String>()
        let unique = pluginResults
            .sorted { $0.result.relevanceScore > $1.result.relevanceScore }
            .filter { seen.insert($0.result.entry.content.lowercased()).inserted }

        let top = Array(unique.prefix(10))

        // Update access timestamps only in the originating plugin
        for item in top {
            var updated = item.result.entry
            updated.lastAccessedAt = Date()
            updated.accessCount += 1
            try? await item.plugin.update(updated)
        }

        let lines = top.map { "- \($0.result.entry.content)" }
        return """
        <memory_context>
        The following is known about the user from previous interactions:
        \(lines.joined(separator: "\n"))
        </memory_context>
        """
    }

    // MARK: - Correction Tracking

    func storeCorrections(_ corrections: [(original: String, replacement: String)], appName: String? = nil, bundleIdentifier: String? = nil) {
        guard isEnabled else { return }

        let plugins = PluginManager.shared.memoryStoragePlugins
        guard !plugins.isEmpty else { return }

        let entries = corrections.map {
            MemoryEntry(
                content: "\($0.replacement) (not \($0.original))",
                type: .correction,
                source: MemorySource(appName: appName, bundleIdentifier: bundleIdentifier),
                confidence: 1.0
            )
        }
        guard !entries.isEmpty else { return }

        Task {
            for plugin in plugins where plugin.isReady {
                try? await plugin.store(entries)
                logger.info("Stored \(entries.count) correction(s) in \(plugin.storageName)")
            }
        }
    }

    // MARK: - Management

    func clearAllMemories() async {
        for plugin in PluginManager.shared.memoryStoragePlugins {
            try? await plugin.deleteAll()
            logger.info("Cleared all memories in \(plugin.storageName)")
        }
    }
}
