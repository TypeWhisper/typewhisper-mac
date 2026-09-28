import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "SnippetService")

@MainActor
final class SnippetService: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published private(set) var snippets: [Snippet] = []
    private var hasDeferredUsageCountChanges = false

    var enabledSnippetsCount: Int {
        snippets.filter { $0.isEnabled }.count
    }

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        guard let (container, context) = try? SwiftDataStoreFactory.create(
            for: [Snippet.self],
            storeName: "snippets",
            in: appSupportDirectory
        ) else { return }

        modelContainer = container
        modelContext = context

        loadSnippets()
    }

    func loadSnippets() {
        guard let context = modelContext else { return }

        do {
            let descriptor = FetchDescriptor<Snippet>(
                sortBy: [SortDescriptor(\.trigger, order: .forward)]
            )
            snippets = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch snippets: \(error.localizedDescription)")
        }
    }

    func addSnippet(trigger: String, replacement: String, caseSensitive: Bool = false) {
        guard let context = modelContext else { return }

        // Check for duplicate trigger
        if snippets.contains(where: { $0.trigger == trigger }) {
            return
        }

        let now = Date()
        let snippet = Snippet(
            trigger: trigger,
            replacement: replacement,
            caseSensitive: caseSensitive,
            createdAt: now,
            updatedAt: now
        )

        context.insert(snippet)

        do {
            try context.save()
            loadSnippets()
        } catch {
            logger.error("Failed to save snippet: \(error.localizedDescription)")
        }
    }

    func updateSnippet(_ snippet: Snippet, trigger: String, replacement: String, caseSensitive: Bool) {
        guard let context = modelContext else { return }

        snippet.trigger = trigger
        snippet.replacement = replacement
        snippet.caseSensitive = caseSensitive
        snippet.updatedAt = Date()

        do {
            try context.save()
            loadSnippets()
        } catch {
            logger.error("Failed to update snippet: \(error.localizedDescription)")
        }
    }

    func deleteSnippet(_ snippet: Snippet) {
        guard let context = modelContext else { return }

        context.delete(snippet)

        do {
            try context.save()
            loadSnippets()
        } catch {
            logger.error("Failed to delete snippet: \(error.localizedDescription)")
        }
    }

    func toggleSnippet(_ snippet: Snippet) {
        guard let context = modelContext else { return }

        snippet.isEnabled.toggle()
        snippet.updatedAt = Date()

        do {
            try context.save()
            loadSnippets()
        } catch {
            logger.error("Failed to toggle snippet: \(error.localizedDescription)")
        }
    }

    /// Apply all enabled snippets without matching inside words.
    ///
    /// With `deferUsageCountSave`, usage counters stay unsaved until `saveDeferredUsageCounts()`
    /// so the dictation pipeline does not block insertion on a SwiftData save.
    func applySnippets(to text: String, deferUsageCountSave: Bool = false) -> String {
        var result = text
        var needsSave = false

        for snippet in snippets where snippet.isEnabled {
            guard !snippet.trigger.isEmpty else { continue }

            let ranges = snippetMatchRanges(for: snippet, in: result)
            if !ranges.isEmpty {
                let replacement = snippet.processedReplacement()
                for range in ranges.reversed() {
                    result.replaceSubrange(range, with: replacement)
                }

                snippet.usageCount += 1
                needsSave = true
            }
        }

        if needsSave {
            if deferUsageCountSave {
                hasDeferredUsageCountChanges = true
            } else {
                saveUsageCounts()
            }
        }

        return result
    }

    private func snippetMatchRanges(for snippet: Snippet, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        let options: String.CompareOptions = snippet.caseSensitive ? [] : [.caseInsensitive]

        // Foundation string search preserves canonical equivalence without
        // changing the Unicode representation of surrounding text.
        while searchStart < text.endIndex,
              let range = text.range(of: snippet.trigger, options: options, range: searchStart..<text.endIndex) {
            guard !range.isEmpty else { break }
            // Only whole-grapheme matches may be used for Character subscripting.
            guard String.Index(range.lowerBound, within: text) != nil,
                  String.Index(range.upperBound, within: text) != nil else {
                searchStart = range.upperBound
                continue
            }
            let previous = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let next = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !isSnippetWordCharacter(previous), !isSnippetWordCharacter(next) {
                ranges.append(range)
                searchStart = range.upperBound
            } else {
                // A rejected occurrence can overlap a later valid symbol trigger.
                searchStart = text.index(after: range.lowerBound)
            }
        }
        return ranges
    }

    private func isSnippetWordCharacter(_ character: Character?) -> Bool {
        guard let character, let base = character.unicodeScalars.first else { return false }
        // Keycap emoji contain a digit but separate words like other emoji.
        if character.unicodeScalars.contains("\u{20E3}") { return false }
        if character.isLetter || character.isNumber { return true }

        // Inspect the grapheme's base so emoji variation selectors and combining
        // marks do not turn a preceding symbol into a word character.
        switch base.properties.generalCategory {
        case .connectorPunctuation, .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return base == "\u{200C}" || base == "\u{200D}"
        }
    }

    /// Saves usage counters left unsaved by `applySnippets(to:deferUsageCountSave:)`.
    func saveDeferredUsageCounts() {
        guard hasDeferredUsageCountChanges else { return }
        saveUsageCounts()
    }

    private func saveUsageCounts() {
        hasDeferredUsageCountChanges = false
        do {
            try modelContext?.save()
        } catch {
            logger.error("Failed to update usage count: \(error.localizedDescription)")
        }
    }

    func userDataSyncSnippets() -> [UserDataSyncSnippet] {
        snippets.map { snippet in
            UserDataSyncSnippet(
                trigger: snippet.trigger,
                replacement: snippet.replacement,
                caseSensitive: snippet.caseSensitive,
                isEnabled: snippet.isEnabled,
                createdAt: snippet.createdAt,
                updatedAt: snippet.effectiveUpdatedAt
            )
        }
    }

    func applyUserDataSyncMutations(_ mutations: [UserDataSyncMutation]) throws {
        guard let context = modelContext else { return }
        guard !mutations.isEmpty else { return }

        for mutation in mutations {
            switch mutation {
            case .upsertSnippet(let synced):
                upsertSyncedSnippet(synced, context: context)
            case .deleteSnippet(let itemID):
                deleteSyncedSnippet(itemID: itemID, context: context)
            case .upsertDictionary,
                 .deleteDictionary,
                 .upsertHistoryContent,
                 .upsertHistoryInbox,
                 .upsertHistoryAudio,
                 .deleteHistory:
                continue
            }
        }

        do {
            try context.save()
            loadSnippets()
        } catch {
            logger.error("Failed to apply snippet sync mutations: \(error.localizedDescription)")
            throw error
        }
    }

    private func upsertSyncedSnippet(_ synced: UserDataSyncSnippet, context: ModelContext) {
        let targetID = UserDataSyncIdentity.snippetItemID(trigger: synced.trigger)
        if let snippet = snippets.first(where: {
            UserDataSyncIdentity.snippetItemID(trigger: $0.trigger) == targetID
        }) {
            snippet.trigger = synced.trigger
            snippet.replacement = synced.replacement
            snippet.caseSensitive = synced.caseSensitive
            snippet.isEnabled = synced.isEnabled
            snippet.updatedAt = synced.updatedAt
            return
        }

        context.insert(Snippet(
            trigger: synced.trigger,
            replacement: synced.replacement,
            caseSensitive: synced.caseSensitive,
            isEnabled: synced.isEnabled,
            createdAt: synced.createdAt,
            updatedAt: synced.updatedAt
        ))
    }

    private func deleteSyncedSnippet(itemID: String, context: ModelContext) {
        guard let snippet = snippets.first(where: {
            UserDataSyncIdentity.snippetItemID(trigger: $0.trigger) == itemID
        }) else {
            return
        }
        context.delete(snippet)
    }
}
