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

enum DictionaryCorrectionMatchPolicy {
    case exact
    case boundary
    case substring
}

struct LearnedDictionaryCorrection: Identifiable, Equatable, Sendable {
    let id: UUID
    let original: String
    let replacement: String
}

@MainActor
final class DictionaryService: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published private(set) var entries: [DictionaryEntry] = []
    @Published private(set) var terms: [DictionaryEntry] = []
    @Published private(set) var corrections: [DictionaryEntry] = []
    @Published private(set) var termsCount: Int = 0
    @Published private(set) var correctionsCount: Int = 0
    @Published private(set) var enabledTermsCount: Int = 0
    @Published private(set) var enabledCorrectionsCount: Int = 0

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        guard let (container, context) = try? SwiftDataStoreFactory.create(
            for: [DictionaryEntry.self],
            storeName: "dictionary",
            in: appSupportDirectory
        ) else { return }

        modelContainer = container
        modelContext = context

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

            var newTerms: [DictionaryEntry] = []
            var newCorrections: [DictionaryEntry] = []
            var newTermsCount = 0
            var newCorrectionsCount = 0
            var newEnabledTermsCount = 0
            var newEnabledCorrectionsCount = 0

            for entry in entries {
                if entry.type == .term {
                    newTermsCount += 1
                    if entry.isEnabled {
                        newTerms.append(entry)
                        newEnabledTermsCount += 1
                    }
                } else if entry.type == .correction {
                    newCorrectionsCount += 1
                    if entry.isEnabled {
                        newCorrections.append(entry)
                        newEnabledCorrectionsCount += 1
                    }
                }
            }

            terms = newTerms
            corrections = newCorrections
            termsCount = newTermsCount
            correctionsCount = newCorrectionsCount
            enabledTermsCount = newEnabledTermsCount
            enabledCorrectionsCount = newEnabledCorrectionsCount
        } catch {
            logger.error("Failed to fetch entries: \(error.localizedDescription)")
        }
    }

    func addEntry(
        type: DictionaryEntryType,
        original: String,
        replacement: String? = nil,
        caseSensitive: Bool = false,
        ctcMinSimilarity: Float? = nil,
        source: DictionaryEntrySource = .manual
    ) {
        guard let context = modelContext else { return }

        // Check for duplicate
        if entries.contains(where: { $0.original.lowercased() == original.lowercased() && $0.type == type }) {
            return
        }

        let now = Date()
        let entry = DictionaryEntry(
            type: type,
            original: original,
            replacement: replacement,
            caseSensitive: caseSensitive,
            ctcMinSimilarity: Self.normalizedCtcMinSimilarity(type == .term ? ctcMinSimilarity : nil),
            source: source,
            createdAt: now,
            updatedAt: now
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
        entry.updatedAt = Date()

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
        entry.updatedAt = Date()

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to toggle entry: \(error.localizedDescription)")
        }
    }

    func setEntryEnabled(_ entry: DictionaryEntry, enabled: Bool) {
        guard let context = modelContext else { return }
        guard entry.isEnabled != enabled else { return }

        let previousEnabled = entry.isEnabled
        let previousUpdatedAt = entry.updatedAt
        entry.isEnabled = enabled
        entry.updatedAt = Date()

        do {
            try context.save()
            loadEntries()
        } catch {
            entry.isEnabled = previousEnabled
            entry.updatedAt = previousUpdatedAt
            logger.error("Failed to set entry enabled state: \(error.localizedDescription)")
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
        addEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, ctcMinSimilarity: $0.ctcMinSimilarity,
             source: DictionaryEntrySource.manual)
        })
    }

    /// Batch add multiple entries with a single save+reload
    func addEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, ctcMinSimilarity: Float?, source: DictionaryEntrySource)]) {
        guard let context = modelContext, !items.isEmpty else { return }

        var existingOriginals = Set(entries.map { "\($0.type.rawValue):\($0.original.lowercased())" })

        for item in items {
            let key = "\(item.type.rawValue):\(item.original.lowercased())"
            guard !existingOriginals.contains(key) else { continue }
            let now = Date()

            let entry = DictionaryEntry(
                type: item.type,
                original: item.original,
                replacement: item.replacement,
                caseSensitive: item.caseSensitive,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity(item.type == .term ? item.ctcMinSimilarity : nil),
                source: item.source,
                createdAt: now,
                updatedAt: now
            )
            context.insert(entry)
            existingOriginals.insert(key)
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
        importEntries(items.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled,
             ctcMinSimilarity: $0.ctcMinSimilarity, source: DictionaryEntrySource.manual)
        })
    }

    /// Import entries preserving all fields including isEnabled state
    func importEntries(_ items: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool, ctcMinSimilarity: Float?, source: DictionaryEntrySource)]) {
        guard let context = modelContext, !items.isEmpty else { return }

        var existingOriginals = Set(entries.map { "\($0.type.rawValue):\($0.original.lowercased())" })

        for item in items {
            let key = "\(item.type.rawValue):\(item.original.lowercased())"
            guard !existingOriginals.contains(key) else { continue }
            let now = Date()

            let entry = DictionaryEntry(
                type: item.type,
                original: item.original,
                replacement: item.replacement,
                caseSensitive: item.caseSensitive,
                isEnabled: item.isEnabled,
                ctcMinSimilarity: Self.normalizedCtcMinSimilarity(item.type == .term ? item.ctcMinSimilarity : nil),
                source: item.source,
                createdAt: now,
                updatedAt: now
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
                entry.updatedAt = Date()
            } else if replaceExisting {
                context.delete(entry)
            }
        }

        let existingKeys = Set(existingTerms.map {
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        for term in normalized where !existingKeys.contains(term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            let now = Date()
            context.insert(DictionaryEntry(type: .term, original: term, replacement: nil, caseSensitive: false, isEnabled: true, createdAt: now, updatedAt: now))
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
                entry.updatedAt = Date()
            } else if replaceExisting {
                context.delete(entry)
            }
        }

        let existingKeys = Set(existingTerms.map {
            $0.original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        })

        for term in normalized where !existingKeys.contains(term.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            let now = Date()
            context.insert(DictionaryEntry(
                type: .term,
                original: term.text,
                replacement: nil,
                caseSensitive: false,
                isEnabled: true,
                ctcMinSimilarity: term.ctcMinSimilarity,
                createdAt: now,
                updatedAt: now
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
              let plugin = PluginManager.shared?.transcriptionEngine(for: providerId) else {
            return PluginDictionaryTerms.prompt(from: terms)
        }

        if (plugin as? any DictionaryTermsCapabilityProviding)?.dictionaryTermsSupport == .unsupported {
            return nil
        }

        guard let budget = (plugin as? any DictionaryTermsBudgetProviding)?.dictionaryTermsBudget else {
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
        var needsSave = false

        for correction in corrections {
            guard let replacement = correction.replacement else { continue }

            let before = result
            result = applyCorrection(correction, to: result, replacement: replacement)

            if result != before {
                correction.usageCount += 1
                needsSave = true
            }
        }

        if needsSave {
            do {
                try modelContext?.save()
            } catch {
                logger.error("Failed to update usage count: \(error.localizedDescription)")
            }
        }

        return result
    }

    private func applyCorrection(_ correction: DictionaryEntry, to text: String, replacement: String) -> String {
        switch matchPolicy(for: correction) {
        case .exact:
            return textMatches(text, correction.original, caseSensitive: correction.caseSensitive) ? replacement : text
        case .boundary:
            return replacingBoundaryMatches(
                of: correction.original,
                in: text,
                with: replacement,
                caseSensitive: correction.caseSensitive
            )
        case .substring:
            if correction.caseSensitive {
                return text.replacingOccurrences(of: correction.original, with: replacement)
            }
            return text.replacingOccurrences(
                of: correction.original,
                with: replacement,
                options: .caseInsensitive
            )
        }
    }

    private func matchPolicy(for correction: DictionaryEntry) -> DictionaryCorrectionMatchPolicy {
        let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return .exact }
        return original.containsWordLikeCharacter ? .boundary : .substring
    }

    private func textMatches(_ text: String, _ original: String, caseSensitive: Bool) -> Bool {
        if caseSensitive {
            return text == original
        }
        return text.compare(original, options: [.caseInsensitive], locale: .current) == .orderedSame
    }

    private func replacingBoundaryMatches(
        of original: String,
        in text: String,
        with replacement: String,
        caseSensitive: Bool
    ) -> String {
        guard !original.isEmpty else { return text }

        var result = ""
        var searchStart = text.startIndex
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]

        while let range = text.range(of: original, options: options, range: searchStart..<text.endIndex, locale: .current) {
            guard range.lowerBound < range.upperBound else { break }

            if isBoundaryMatch(range, in: text, original: original) {
                result += text[searchStart..<range.lowerBound]
                result += replacement
            } else {
                result += text[searchStart..<range.upperBound]
            }
            searchStart = range.upperBound
        }

        result += text[searchStart..<text.endIndex]
        return result
    }

    private func isBoundaryMatch(_ range: Range<String.Index>, in text: String, original: String) -> Bool {
        let previous = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil

        if original.isAllKatakana {
            return previous?.isKatakana != true && next?.isKatakana != true
        }

        if original.isAllLatinOrNumber {
            return previous?.isLatinOrNumber != true && next?.isLatinOrNumber != true
        }

        let startsAtBoundary = previous?.isWordLike != true || previous?.isJapaneseParticleBoundary == true
        let endsAtBoundary = next?.isWordLike != true ||
            next?.isJapaneseParticleBoundary == true ||
            (original.count > 1 && String(text[range.upperBound...]).startsWithJapaneseParticleBoundary)
        return startsAtBoundary && endsAtBoundary
    }

    /// Add a correction learned from history edits
    func learnCorrection(original: String, replacement: String) {
        _ = learnCorrections([CorrectionSuggestion(original: original, replacement: replacement)])
    }

    /// Batch add corrections learned from user edits. Existing corrections are never overwritten.
    @discardableResult
    func learnCorrections(_ suggestions: [CorrectionSuggestion]) -> [LearnedDictionaryCorrection] {
        guard let context = modelContext, !suggestions.isEmpty else { return [] }

        var existingOriginals = Set(
            entries
                .filter { $0.type == .correction }
                .map { $0.original.lowercased() }
        )
        let now = Date()
        var learned: [LearnedDictionaryCorrection] = []

        for suggestion in suggestions {
            let original = suggestion.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = suggestion.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalKey = original.lowercased()

            guard !original.isEmpty,
                  originalKey != replacement.lowercased(),
                  !existingOriginals.contains(originalKey) else {
                continue
            }

            let entry = DictionaryEntry(
                type: .correction,
                original: original,
                replacement: replacement,
                caseSensitive: false,
                source: .autoLearned,
                createdAt: now,
                updatedAt: now
            )
            context.insert(entry)
            existingOriginals.insert(originalKey)
            learned.append(LearnedDictionaryCorrection(
                id: entry.id,
                original: original,
                replacement: replacement
            ))
        }

        guard !learned.isEmpty else { return [] }

        do {
            try context.save()
            loadEntries()
            return learned
        } catch {
            logger.error("Failed to learn corrections: \(error.localizedDescription)")
            return []
        }
    }

    func undoLearnedCorrections(_ learned: [LearnedDictionaryCorrection]) {
        guard let context = modelContext, !learned.isEmpty else { return }

        let learnedByID = Dictionary(uniqueKeysWithValues: learned.map { ($0.id, $0) })
        let entriesToDelete = entries.filter { entry in
            guard entry.type == .correction,
                  let learned = learnedByID[entry.id] else {
                return false
            }

            return entry.original == learned.original &&
                (entry.replacement ?? "") == learned.replacement
        }

        guard !entriesToDelete.isEmpty else { return }

        for entry in entriesToDelete {
            context.delete(entry)
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to undo learned corrections: \(error.localizedDescription)")
        }
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
            entry.source = .manual
            entry.updatedAt = Date()
        } else {
            let now = Date()
            let entry = DictionaryEntry(
                type: .correction,
                original: original,
                replacement: replacement,
                caseSensitive: caseSensitive,
                isEnabled: true,
                source: .manual,
                createdAt: now,
                updatedAt: now
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

    func userDataSyncEntries(
        excludingTermItemIDs: Set<String> = [],
        excludingCorrectionItemIDs: Set<String> = []
    ) -> [UserDataSyncDictionaryEntry] {
        entries.compactMap { entry in
            let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.type, original: entry.original)
            if entry.type == .term, excludingTermItemIDs.contains(itemID) {
                return nil
            }
            if entry.type == .correction, excludingCorrectionItemIDs.contains(itemID) {
                return nil
            }

            return UserDataSyncDictionaryEntry(
                entryType: UserDataSyncDictionaryEntryType(entry.type),
                original: entry.original,
                replacement: entry.type == .correction ? (entry.replacement ?? "") : nil,
                caseSensitive: entry.caseSensitive,
                isEnabled: entry.isEnabled,
                source: entry.source == .manual ? nil : entry.source,
                createdAt: entry.createdAt,
                updatedAt: entry.effectiveUpdatedAt
            )
        }
    }

    func applyUserDataSyncMutations(_ mutations: [UserDataSyncMutation]) throws {
        guard let context = modelContext else {
            throw DictionaryServiceMutationError.unavailable
        }
        guard !mutations.isEmpty else { return }

        for mutation in mutations {
            switch mutation {
            case .upsertDictionary(let synced):
                upsertSyncedDictionaryEntry(synced, context: context)
            case .deleteDictionary(let itemID):
                deleteSyncedDictionaryEntry(itemID: itemID, context: context)
            case .upsertSnippet, .deleteSnippet:
                continue
            }
        }

        do {
            try context.save()
            loadEntries()
        } catch {
            logger.error("Failed to apply dictionary sync mutations: \(error.localizedDescription)")
            throw DictionaryServiceMutationError.saveFailed(error)
        }
    }

    private func upsertSyncedDictionaryEntry(_ synced: UserDataSyncDictionaryEntry, context: ModelContext) {
        let targetType = DictionaryEntryType(synced.entryType)
        let targetID = UserDataSyncIdentity.dictionaryItemID(entryType: synced.entryType, original: synced.original)
        let replacement = targetType == .correction ? (synced.replacement ?? "") : nil

        if let entry = entries.first(where: {
            $0.type == targetType &&
            UserDataSyncIdentity.dictionaryItemID(entryType: $0.type, original: $0.original) == targetID
        }) {
            entry.original = synced.original
            entry.replacement = replacement
            entry.caseSensitive = synced.caseSensitive
            entry.isEnabled = synced.isEnabled
            entry.source = synced.source ?? .manual
            entry.updatedAt = synced.updatedAt
            return
        }

        context.insert(DictionaryEntry(
            type: targetType,
            original: synced.original,
            replacement: replacement,
            caseSensitive: synced.caseSensitive,
            isEnabled: synced.isEnabled,
            source: synced.source ?? .manual,
            createdAt: synced.createdAt,
            updatedAt: synced.updatedAt
        ))
    }

    private func deleteSyncedDictionaryEntry(itemID: String, context: ModelContext) {
        guard let entry = entries.first(where: {
            UserDataSyncIdentity.dictionaryItemID(entryType: $0.type, original: $0.original) == itemID
        }) else {
            return
        }
        context.delete(entry)
    }

    private static func normalizedCtcMinSimilarity(_ value: Float?) -> Float? {
        guard let value, value.isFinite else { return nil }
        return Swift.min(Swift.max(value, 0), 1)
    }

}

private extension Character {
    var isKatakana: Bool {
        unicodeScalars.allSatisfy { scalar in
            (0x30A0...0x30FF).contains(Int(scalar.value)) ||
            (0x31F0...0x31FF).contains(Int(scalar.value)) ||
            (0xFF66...0xFF9D).contains(Int(scalar.value))
        }
    }

    var isLatinOrNumber: Bool {
        unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.value < 0x3000 }
    }

    var isWordLike: Bool {
        unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            (0x3040...0x30FF).contains(Int(scalar.value)) ||
            (0x3400...0x9FFF).contains(Int(scalar.value)) ||
            (0xF900...0xFAFF).contains(Int(scalar.value)) ||
            (0x20000...0x323AF).contains(Int(scalar.value)) ||
            (0xFF66...0xFF9D).contains(Int(scalar.value))
        }
    }

    var isJapaneseParticleBoundary: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3067, // で
             0x306B, // に
             0x306E, // の
             0x306F, // は
             0x3092, // を
             0x304C, // が
             0x3082, // も
             0x3068, // と
             0x3078, // へ
             0x3088: // よ
            return true
        default:
            return false
        }
    }
}

private extension String {
    var startsWithJapaneseParticleBoundary: Bool {
        [
            "から",
            "まで",
            "より",
            "には",
            "では",
            "にも",
            "でも",
            "とは",
            "との",
            "へは",
            "への",
            "だけ",
            "など",
        ].contains { hasPrefix($0) }
    }

    var containsWordLikeCharacter: Bool {
        contains { $0.isWordLike }
    }

    var isAllKatakana: Bool {
        !isEmpty && allSatisfy { character in
            character.isKatakana || character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }

    var isAllLatinOrNumber: Bool {
        !isEmpty && allSatisfy { character in
            character.isLatinOrNumber || character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }
}
