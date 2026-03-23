import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PromptActionService")

@MainActor
class PromptActionService: ObservableObject {
    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published private(set) var promptActions: [PromptAction] = []

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        let schema = Schema([PromptAction.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("prompt-actions.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Incompatible schema - delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("prompt-actions.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create prompt-actions ModelContainer after reset: \(error)")
            }
        }
        modelContext = ModelContext(modelContainer!)
        modelContext?.autosaveEnabled = true

        loadActions()
    }

    func loadActions() {
        guard let context = modelContext else { return }

        do {
            let descriptor = FetchDescriptor<PromptAction>(
                sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
            )
            promptActions = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch prompt actions: \(error.localizedDescription)")
        }
    }

    var availablePresets: [PromptAction] {
        let existingNames = Set(promptActions.map(\.name))
        return PromptAction.presets.filter { !existingNames.contains($0.name) }
    }

    func seedPresetsIfNeeded() {
        guard let context = modelContext else { return }

        let newPresets = availablePresets
        guard !newPresets.isEmpty else { return }

        let isInitialSeed = promptActions.isEmpty
        let nextSortOrder = (promptActions.map(\.sortOrder).max() ?? -1) + 1

        for (offset, preset) in newPresets.enumerated() {
            if isInitialSeed {
                context.insert(preset)
            } else {
                let newAction = PromptAction(
                    name: preset.name,
                    prompt: preset.prompt,
                    icon: preset.icon,
                    isPreset: true,
                    sortOrder: nextSortOrder + offset
                )
                context.insert(newAction)
            }
        }

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to seed presets: \(error.localizedDescription)")
        }
    }

    func addPreset(_ preset: PromptAction) {
        guard let context = modelContext else { return }

        let maxOrder = promptActions.map(\.sortOrder).max() ?? -1
        let newAction = PromptAction(
            name: preset.name,
            prompt: preset.prompt,
            icon: preset.icon,
            isPreset: true,
            sortOrder: maxOrder + 1
        )

        context.insert(newAction)

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to add preset: \(error.localizedDescription)")
        }
    }

    func addAction(name: String, prompt: String, icon: String = "sparkles", providerType: String? = nil, cloudModel: String? = nil, targetActionPluginId: String? = nil) {
        guard let context = modelContext else { return }

        let maxOrder = promptActions.map(\.sortOrder).max() ?? -1
        let action = PromptAction(
            name: name,
            prompt: prompt,
            icon: icon,
            sortOrder: maxOrder + 1,
            providerType: providerType,
            cloudModel: cloudModel,
            targetActionPluginId: targetActionPluginId
        )

        context.insert(action)

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to save prompt action: \(error.localizedDescription)")
        }
    }

    func updateAction(_ action: PromptAction, name: String, prompt: String, icon: String, providerType: String? = nil, cloudModel: String? = nil, targetActionPluginId: String? = nil) {
        guard let context = modelContext else { return }

        action.name = name
        action.prompt = prompt
        action.icon = icon
        action.providerType = providerType
        action.cloudModel = cloudModel
        action.targetActionPluginId = targetActionPluginId
        action.updatedAt = Date()

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to update prompt action: \(error.localizedDescription)")
        }
    }

    func deleteAction(_ action: PromptAction) {
        guard let context = modelContext else { return }

        context.delete(action)

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to delete prompt action: \(error.localizedDescription)")
        }
    }

    func toggleAction(_ action: PromptAction) {
        guard let context = modelContext else { return }

        action.isEnabled.toggle()

        do {
            try context.save()
            loadActions()
        } catch {
            logger.error("Failed to toggle prompt action: \(error.localizedDescription)")
        }
    }

    func getEnabledActions() -> [PromptAction] {
        promptActions.filter { $0.isEnabled }
    }

    func action(byId id: String) -> PromptAction? {
        promptActions.first { $0.id.uuidString == id }
    }
}
