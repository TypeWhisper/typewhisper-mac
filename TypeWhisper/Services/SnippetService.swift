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

    /// Apply all enabled snippets to the given text
    func applySnippets(to text: String) -> String {
        var result = text
        var needsSave = false

        for snippet in snippets where snippet.isEnabled {
            let searchTrigger = snippet.caseSensitive ? snippet.trigger : snippet.trigger.lowercased()
            let searchText = snippet.caseSensitive ? result : result.lowercased()

            if searchText.contains(searchTrigger) {
                let replacement = snippet.processedReplacement()

                if snippet.caseSensitive {
                    result = result.replacingOccurrences(of: snippet.trigger, with: replacement)
                } else {
                    result = result.replacingOccurrences(
                        of: snippet.trigger,
                        with: replacement,
                        options: .caseInsensitive
                    )
                }

                snippet.usageCount += 1
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
            case .upsertDictionary, .deleteDictionary:
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
