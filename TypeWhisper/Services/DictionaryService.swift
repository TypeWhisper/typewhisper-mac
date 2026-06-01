import Foundation
import SwiftData
import Combine
import os.log
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "DictionaryService")

enum DictionaryServiceMutationError: LocalizedError {
    case unavailable
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Dictionary storage is unavailable"
        case .saveFailed(let error):
            return error.localizedDescription
        }
    }
}

@MainActor
final class DictionaryService: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published private(set) var entries: [DictionaryEntry] = []

    var terms: [DictionaryEntry] {
        entries.filter { $0.type == .term && $0.isEnabled }
    }

    var corrections: [DictionaryEntry] {
        entries.filter { $0.type == .correction && $0.isEnabled }
    }

    var termsCount: Int {
        entries.filter { $0.type == .term }.count
    }

    var correctionsCount: Int {
        entries.filter { $0.type == .correction }.count
    }

    var enabledTermsCount: Int {
        terms.count
    }

    var enabledCorrectionsCount: Int {
        corrections.count
    }

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        let schema = Schema([DictionaryEntry.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("dictionary.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Incompatible schema — delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("dictionary.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create dictionary ModelContainer after reset: \(error)")
            }
        }
        modelContext = ModelContext(modelContainer!)
        modelContext?.autosaveEnabled = true

        loadEntries()
    }

    func loadEntries() {
        guard let context = modelContext else { return }

        do {
            let descriptor = FetchDescriptor<DictionaryEntry>(
                sortBy: [
                    SortDescriptor(\.entryType, order: .forward),
                    SortDescriptor(\.original, order: .forward)
                ]
            )
            entries = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch entries: \(error.localizedDescription)")
        }
    }

    func addEntry(
        type: DictionaryEntryType,
        original: String,
        replacement: String? = nil,
        caseSensitive: Bool = false,
        ctcMinSimilarity: Float? = nil
    ) {
        guard let context = modelContext else { return }

        // Check for duplicate
        if entries.contains(where: { $0.original.lowercased() == original.lowercased() && $0.type == type }) {
            return
        }

        let entry = DictionaryEntry(
            type: type,
            original: original,
            replacement: replacement,
            caseSensitive: caseSensitive,
            ctcMinSimilarity: Self.normalizedCtcMinSimilarity(type == .term ? ctcMinSimilarity : nil)
        )

        context.insert(entry)

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to save entry: \(error.localizedDescription)")
        }
    }

    func updateEntry(
        _ entry: DictionaryEntry,
        original: String,
        replacement: String?,
        caseSensitive: Bool,
        ctcMinSimilarity: Float? = nil
    ) {
        guard let context = modelContext else { return }

        entry.original = original
        entry.replacement = replacement
        entry.caseSensitive = caseSensitive
        entry.ctcMinSimilarity = Self.normalizedCtcMinSimilarity(entry.type == .term ? ctcMinSimilarity : nil)

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to update entry: \(error.localizedDescription)")
        }
    }

    func deleteEntry(_ entry: DictionaryEntry) {
        guard let context = modelContext else { return }

        context.delete(entry)

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to delete entry: \(error.localizedDescription)")
        }
    }

    func toggleEntry(_ entry: DictionaryEntry) {
        guard let context = modelContext else { return }

        entry.isEnabled.toggle()

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to toggle entry: \(error.localizedDescription)")
        }
    }

    /// Batch add multiple entries with a single save+reload
    func addEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool)]) {
        addEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, ctcMinSimilarity: nil as Float?)
        })
    }

    /// Batch add multiple entries with a single save+reload
    func addEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, ctcMinSimilarity: Float?)]) {
        guard let context = modelContext, !items.isEmpty else { return }

        let existingOriginals = Set(entries.map { "\($0.type.rawValue):\($0.original.lowercased())" })

        for item in items {
            let key = "\(item.type.rawValue):\(item.original.lowercased())"
            guard !existingOriginals.contains(key) else { continue }

            let entry = DictionaryEntry(
                type: item.type,
                original: item.original,
                replacement: item.replacement,
                caseSensitive: item.caseSensitive,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity(item.type == .term ? item.ctcMinSimilarity : nil)
            )
            context.insert(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to batch save entries: \(error.localizedDescription)")
        }
    }

    /// Import entries preserving all fields including isEnabled state
    func importEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool)]) {
        importEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled, ctcMinSimilarity: nil as Float?)
        })
    }

    /// Import entries preserving all fields including isEnabled state
    func importEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool, ctcMinSimilarity: Float?)]) {
        guard let context = modelContext, !items.isEmpty else { return }

        var existingOriginals = Set(entries.map { "\($0.type.rawValue):\($0.original.lowercased())" })

        for item in items {
            let key = "\(item.type.rawValue):\(item.original.lowercased())"
            guard !existingOriginals.contains(key) else { continue }

            let entry = DictionaryEntry(
                type: item.type,
                original: item.original,
                replacement: item.replacement,
                caseSensitive: item.caseSensitive,
                isEnabled: item.isEnabled,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity(item.type == .term ? item.ctcMinSimilarity : nil)
            )
            context.insert(entry)
            existingOriginals.insert(key)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to import entries: \(error.localizedDescription)")
        }
    }

    /// Batch delete multiple entries
    func deleteEntries(_ entriesToDelete: [DictionaryEntry]) {
        guard let context = modelContext, !entriesToDelete.isEmpty else { return }

        for entry in entriesToDelete {
            context.delete(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to batch delete entries: \(error.localizedDescription)")
        }
    }

    /// Get all enabled terms as a comma-separated string for Whisper prompt.
    /// Truncates at 600 characters to stay within the API's 224-token limit.
    func enabledTerms() -> [String] {
        PluginDictionaryTerms.normalizedTerms(from: terms.map(\.original))
    }

    func enabledTermHints() -> [PluginDictionaryTermHint] {
        PluginDictionaryTerms.normalizedTermHints(from: terms.map {
            PluginDictionaryTermHint(text: $0.original, ctcMinSimilarity: $0.ctcMinSimilarity)
        })
    }

    func setTerms(_ rawTerms: [String], replaceExisting: Bool) {
        do {
            try setAPITerms(rawTerms, replaceExisting: replaceExisting)
        } catch {
            logger.error("Failed to set terms: \(error.localizedDescription)")
        }
    }

    func setAPITerms(_ rawTerms: [String], replaceExisting: Bool) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        let normalized = PluginDictionaryTerms.normalizedTerms(from: rawTerms)
        let normalizedByKey = Dictionary(uniqueKeysWithValues: normalized.map {
            ($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0)
        })
        let desiredKeys = Set(normalizedByKey.keys)
        let existingTerms = entries.filter { $0.type == .term }

        for entry in existingTerms {
            let key = entry.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if let desiredTerm = normalizedByKey[key] {
                entry.original = desiredTerm
                entry.isEnabled = true
            } else if replaceExisting {
                context.delete(entry)
            }
        }

        let existingKeys = Set(existingTerms.map {
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        for term in normalized where !existingKeys.contains(term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            context.insert(DictionaryEntry(type: .term, original: term, replacement: nil, caseSensitive: false, isEnabled: true))
        }

        if replaceExisting || !desiredKeys.isEmpty {
            do {
                try context.save()
                loadEntries()
            } catch {
                logger.error("Failed to set terms: \(error.localizedDescription)")
                throw DictionaryServiceMutationError.saveFailed(error)
            }
        }
    }

    func setAPITermEntries(_ rawTerms: [(term: String, ctcMinSimilarity: Float?)], replaceExisting: Bool) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        let normalized = PluginDictionaryTerms.normalizedTermHints(from: rawTerms.map {
            PluginDictionaryTermHint(
                text: $0.term,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity($0.ctcMinSimilarity)
            )
        })
        let normalizedByKey = Dictionary(uniqueKeysWithValues: normalized.map {
            ($0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0)
        })
        let desiredKeys = Set(normalizedByKey.keys)
        let existingTerms = entries.filter { $0.type == .term }

        for entry in existingTerms {
            let key = entry.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if let desiredTerm = normalizedByKey[key] {
                entry.original = desiredTerm.text
                entry.isEnabled = true
                entry.ctcMinSimilarity = desiredTerm.ctcMinSimilarity
            } else if replaceExisting {
                context.delete(entry)
            }
        }

        let existingKeys = Set(existingTerms.map {
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        for term in normalized where !existingKeys.contains(term.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            context.insert(DictionaryEntry(
                type: .term,
                original: term.text,
                replacement: nil,
                caseSensitive: false,
                isEnabled: true,
                ctcMinSimilarity: term.ctcMinSimilarity
            ))
        }

        if replaceExisting || !desiredKeys.isEmpty {
            do {
                try context.save()
                loadEntries()
            } catch {
                logger.error("Failed to set term entries: \(error.localizedDescription)")
                throw DictionaryServiceMutationError.saveFailed(error)
            }
        }
    }

    func deleteAPITerm(_ rawTerm: String) throws -> Bool {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        guard let normalizedTerm = PluginDictionaryTerms.normalizedTerms(from: [rawTerm]).first else {
            return false
        }

        let desiredKey = normalizedTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard let entry = entries.first(where: {
            $0.type == .term &&
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == desiredKey
        }) else {
            return false
        }

        context.delete(entry)

        do {
            try context.save()
            loadEntries()
            return true
        } catch {
            logger.error("Failed to delete term: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    func removeAllTerms() {
        guard let context = modelContext else { return }

        for entry in entries where entry.type == .term {
            context.delete(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to remove all terms: \(error.localizedDescription)")
        }
    }

    func getTermsForPrompt(providerId: String?) -> String? {
        let terms = enabledTerms()
        guard !terms.isEmpty else { return nil }

        guard let providerId,
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId),
              let budget = (plugin as? any DictionaryTermsBudgetProviding)?.dictionaryTermsBudget else {
            return PluginDictionaryTerms.prompt(from: terms)
        }

        return PluginDictionaryTerms.prompt(from: terms, budget: budget)
    }

    func getTermHints(providerId: String?) -> [PluginDictionaryTermHint] {
        let hints = enabledTermHints()
        guard !hints.isEmpty else { return [] }

        guard let providerId,
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId),
              let budget = (plugin as? any DictionaryTermsBudgetProviding)?.dictionaryTermsBudget else {
            return PluginDictionaryTerms.clippedTermHints(
                from: hints,
                budget: DictionaryTermsBudget(maxTotalChars: 600)
            )
        }

        return PluginDictionaryTerms.clippedTermHints(from: hints, budget: budget)
    }

    /// Apply all enabled corrections to the given text
    func applyCorrections(to text: String) -> String {
        var result = text

        for correction in corrections {
            guard let replacement = correction.replacement else { continue }

            let before = result
            if correction.caseSensitive {
                result = result.replacingOccurrences(of: correction.original, with: replacement)
            } else {
                result = result.replacingOccurrences(
                    of: correction.original,
                    with: replacement,
                    options: .caseInsensitive
                )
            }

            if result != before {
                incrementUsageCount(for: correction)
            }
        }

        return result
    }

    /// Add a correction learned from history edits
    func learnCorrection(original: String, replacement: String) {
        guard original.lowercased() != replacement.lowercased() else { return }

        if entries.contains(where: {
            $0.type == .correction &&
            $0.original.lowercased() == original.lowercased()
        }) {
            return
        }

        addEntry(
            type: .correction,
            original: original,
            replacement: replacement,
            caseSensitive: false
        )
    }

    func upsertAPICorrection(original: String, replacement: String, caseSensitive: Bool) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        if let entry = entries.first(where: {
            $0.type == .correction &&
            $0.original.caseInsensitiveCompare(original) == .orderedSame
        }) {
            entry.original = original
            entry.replacement = replacement
            entry.caseSensitive = caseSensitive
            entry.isEnabled = true
        } else {
            let entry = DictionaryEntry(
                type: .correction,
                original: original,
                replacement: replacement,
                caseSensitive: caseSensitive,
                isEnabled: true
            )
            context.insert(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to upsert correction: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    func deleteAPICorrection(original: String) throws -> Bool {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }

        guard let entry = entries.first(where: {
            $0.type == .correction &&
            $0.original.caseInsensitiveCompare(original) == .orderedSame
        }) else {
            return false
        }

        context.delete(entry)

        do {
            try context.save()
            loadEntries()
            return true
        } catch {
            logger.error("Failed to delete correction: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    private func incrementUsageCount(for entry: DictionaryEntry) {
        guard let context = modelContext else { return }

        entry.usageCount += 1

        do {
            try context.save()
        } catch {
            logger.error("Failed to update usage count: \(error.localizedDescription)")
        }
    }

    private static func normalizedCtcMinSimilarity(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}
