import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MemoryService")

@MainActor
final class MemoryService: ObservableObject {
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
    private var eventSubscriptionId: UUID?
    private var lastExtractionTime: Date = .distantPast
    private let extractionCooldown: TimeInterval = 30

    init(promptProcessingService: PromptProcessingService) {
        self.promptProcessingService = promptProcessingService
        self.isEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.memoryEnabled)
        self.extractionProviderId = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionProvider) ?? ""
        self.extractionModel = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionModel) ?? ""
        self.minimumTextLength = UserDefaults.standard.object(forKey: UserDefaultsKeys.memoryMinTextLength) as? Int ?? 50
        let saved = UserDefaults.standard.string(forKey: UserDefaultsKeys.memoryExtractionPrompt) ?? ""
        self.extractionPrompt = saved.isEmpty ? Self.defaultExtractionPrompt : saved
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
    }

    // MARK: - Extraction

    private func handleTranscription(_ payload: TranscriptionCompletedPayload) {
        guard isEnabled, payload.finalText.count >= minimumTextLength else { return }

        // Per-rule gate
        if let ruleName = payload.ruleName,
           let profile = ServiceContainer.shared.profileService.profiles.first(where: { $0.name == ruleName }) {
            guard profile.memoryEnabled else { return }
        } else {
            return
        }

        // Cooldown
        let now = Date()
        guard now.timeIntervalSince(lastExtractionTime) >= extractionCooldown else { return }
        lastExtractionTime = now

        let providerId = extractionProviderId
        guard !providerId.isEmpty else { return }

        // Capture all MainActor properties before detaching
        let prompt = extractionPrompt
        let model = extractionModel

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.extractAndStore(payload: payload, providerId: providerId, prompt: prompt, model: model)
            } catch {
                logger.error("Memory extraction failed: \(error.localizedDescription)")
            }
        }
    }

    private func extractAndStore(payload: TranscriptionCompletedPayload, providerId: String, prompt: String, model: String) async throws {
        let result = try await promptProcessingService.process(
            prompt: prompt,
            text: payload.finalText,
            providerOverride: providerId,
            cloudModelOverride: model.isEmpty ? nil : model,
            skipMemoryInjection: true
        )

        let entries = parseExtractedMemories(result, source: MemorySource(
            appName: payload.appName,
            bundleIdentifier: payload.bundleIdentifier,
            ruleName: payload.ruleName,
            timestamp: payload.timestamp
        ))
        guard !entries.isEmpty else { return }

        let plugins = PluginManager.shared.memoryStoragePlugins
        guard !plugins.isEmpty else { return }

        let deduped = await deduplicate(entries: entries, using: plugins)
        guard !deduped.isEmpty else { return }

        for plugin in plugins where plugin.isReady {
            try? await plugin.store(deduped)
            logger.info("Stored \(deduped.count) memories in \(plugin.storageName)")
        }
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
              let raw = try? JSONDecoder().decode([RawMemory].self, from: data) else { return [] }

        return raw.compactMap { item in
            guard let type = MemoryType(rawValue: item.type) else { return nil }
            let conf = item.confidence ?? 0.8
            guard conf >= 0.8 else { return nil }
            return MemoryEntry(content: item.content, type: type, source: source, confidence: conf)
        }
    }

    // MARK: - Deduplication

    private func deduplicate(entries: [MemoryEntry], using plugins: [MemoryStoragePlugin]) async -> [MemoryEntry] {
        var unique: [MemoryEntry] = []
        for entry in entries {
            let query = MemoryQuery(text: entry.content, maxResults: 1, minConfidence: 0.0)
            var isDuplicate = false

            for plugin in plugins where plugin.isReady {
                if let results = try? await plugin.search(query),
                   let best = results.first,
                   best.relevanceScore > 0.85 {
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
