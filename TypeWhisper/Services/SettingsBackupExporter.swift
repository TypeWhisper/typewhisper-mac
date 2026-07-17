import AppKit
import Foundation
import UniformTypeIdentifiers

/// Exports/imports a single JSON backup of user configuration (workflows,
/// dictionary, snippets, profiles, prompt actions, hotkeys, installed
/// community plugins, and transcription history) so it can be migrated to
/// another Mac.
///
/// History is exported as text/metadata only — saved audio recordings
/// (`TranscriptionRecord.audioFileName`) are never included, since they can
/// be large (~1MB/30s) and would require a very different file format than
/// plain JSON.
///
/// Deliberately out of scope: provider API keys, usage statistics, and
/// general `UserDefaults` preferences (indicator style, sound toggles,
/// selected microphone/model, etc.) — API keys must be re-entered on the new
/// Mac, and the rest is either per-machine or low value to migrate. See
/// `TypeWhisper/App/UserDefaultsKeys.swift` for the full preferences surface
/// if that scope ever expands.
@MainActor
enum SettingsBackupExporter {
    static let schemaVersion = 1

    /// Global hotkey slots stored as JSON-encoded `[UnifiedHotkey]` arrays in
    /// `UserDefaults`. Mirrors `HotkeySlotType.hotkeysDefaultsKey` in
    /// `HotkeyService.swift`, duplicated here so backup/restore doesn't need to
    /// instantiate the singleton `HotkeyService` (which owns live Carbon event
    /// taps) just to read/write plain `UserDefaults` arrays.
    static let hotkeySlotKeys: [String] = [
        UserDefaultsKeys.hybridHotkeys,
        UserDefaultsKeys.pttHotkeys,
        UserDefaultsKeys.toggleHotkeys,
        UserDefaultsKeys.promptPaletteHotkeys,
        UserDefaultsKeys.recentTranscriptionsHotkeys,
        UserDefaultsKeys.copyLastTranscriptionHotkeys,
        UserDefaultsKeys.recorderToggleHotkeys,
    ]

    // MARK: - DTOs

    struct WorkflowDTO: Codable {
        let name: String
        let isEnabled: Bool
        let sortOrder: Int
        let template: WorkflowTemplate
        let trigger: WorkflowTrigger
        let behavior: WorkflowBehavior
        let output: WorkflowOutput
    }

    struct DictionaryEntryDTO: Codable {
        let type: DictionaryEntryType
        let original: String
        let replacement: String?
        let caseSensitive: Bool
        let isEnabled: Bool
        let ctcMinSimilarity: Float?
        let source: DictionaryEntrySource
    }

    struct SnippetDTO: Codable {
        let trigger: String
        let replacement: String
        let caseSensitive: Bool
        let isEnabled: Bool
    }

    struct PromptActionDTO: Codable {
        /// The prompt action's original UUID string, used only to remap
        /// `ProfileDTO.promptActionId` during import (imported records always get
        /// a fresh UUID, so the original id can't be reused directly).
        let localId: String
        let name: String
        let prompt: String
        let icon: String
        let isEnabled: Bool
        let providerType: String?
        let cloudModel: String?
        let temperatureModeRaw: String
        let temperatureValue: Double?
        let targetActionPluginId: String?
    }

    struct ProfileDTO: Codable {
        let name: String
        let isEnabled: Bool
        let priority: Int
        let bundleIdentifiers: [String]
        let urlPatterns: [String]
        let inputLanguage: String?
        let translationEnabled: Bool?
        let translationTargetLanguage: String?
        let selectedTask: String?
        let engineOverride: String?
        let cloudModelOverride: String?
        /// References `PromptActionDTO.localId`, remapped to the newly-imported
        /// prompt action's UUID on import.
        let promptActionId: String?
        let memoryEnabled: Bool
        let outputFormat: String?
        let hotkey: UnifiedHotkey?
        let inlineCommandsEnabled: Bool
        let autoEnterEnabled: Bool
    }

    /// A non-bundled (community/manually-installed) plugin. Reinstall always
    /// fetches whichever version is currently latest-compatible in the
    /// registry — there is no supported way to pin the exact backed-up
    /// `version`, so it's kept for informational/diagnostic purposes only.
    struct PluginDTO: Codable {
        let id: String
        let name: String
        let version: String
        let wasEnabled: Bool
    }

    /// Text/metadata only — never includes the saved audio recording, if any.
    struct HistoryEntryDTO: Codable {
        let timestamp: Date
        let rawText: String
        let finalText: String
        let appName: String?
        let appBundleIdentifier: String?
        let appURL: String?
        let durationSeconds: Double
        let language: String?
        let engineUsed: String
        let modelUsed: String?
        let pipelineSteps: [String]
    }

    struct SettingsBackup: Codable {
        let schemaVersion: Int
        let exportedAt: Date
        let appVersion: String
        let workflows: [WorkflowDTO]
        let dictionaryEntries: [DictionaryEntryDTO]
        let snippets: [SnippetDTO]
        let promptActions: [PromptActionDTO]
        let profiles: [ProfileDTO]
        let hotkeys: [String: [UnifiedHotkey]]
        let plugins: [PluginDTO]
        let history: [HistoryEntryDTO]
    }

    struct ImportResult {
        var workflowsImported = 0
        var dictionaryImported = 0
        var dictionarySkipped = 0
        var snippetsImported = 0
        var snippetsSkipped = 0
        var promptActionsImported = 0
        var profilesImported = 0
        var hotkeysApplied = 0
        var hotkeysSkipped = 0
        var pluginsInstalled = 0
        var pluginsSkipped = 0
        var historyImported = 0
    }

    enum ImportError: LocalizedError {
        case invalidFile

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return String(localized: "The file is not a valid TypeWhisper settings backup.")
            }
        }
    }

    // MARK: - Export

    static func buildBackup(
        workflowService: WorkflowService,
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        profileService: ProfileService,
        promptActionService: PromptActionService,
        pluginManager: PluginManager,
        historyService: HistoryService,
        userDefaults: UserDefaults = .standard
    ) -> SettingsBackup {
        let workflows = workflowService.workflows.map { workflow in
            WorkflowDTO(
                name: workflow.name,
                isEnabled: workflow.isEnabled,
                sortOrder: workflow.sortOrder,
                template: workflow.template,
                trigger: workflow.trigger ?? .manual(),
                behavior: workflow.behavior,
                output: workflow.output
            )
        }

        let dictionaryEntries = dictionaryService.entries.map { entry in
            DictionaryEntryDTO(
                type: entry.type,
                original: entry.original,
                replacement: entry.replacement,
                caseSensitive: entry.caseSensitive,
                isEnabled: entry.isEnabled,
                ctcMinSimilarity: entry.ctcMinSimilarity,
                source: entry.source
            )
        }

        let snippets = snippetService.snippets.map { snippet in
            SnippetDTO(
                trigger: snippet.trigger,
                replacement: snippet.replacement,
                caseSensitive: snippet.caseSensitive,
                isEnabled: snippet.isEnabled
            )
        }

        let promptActions = promptActionService.promptActions
            .filter { !$0.isPreset }
            .map { action in
                PromptActionDTO(
                    localId: action.id.uuidString,
                    name: action.name,
                    prompt: action.prompt,
                    icon: action.icon,
                    isEnabled: action.isEnabled,
                    providerType: action.providerType,
                    cloudModel: action.cloudModel,
                    temperatureModeRaw: action.temperatureModeRaw,
                    temperatureValue: action.temperatureValue,
                    targetActionPluginId: action.targetActionPluginId
                )
            }

        let profiles = profileService.profiles.map { profile in
            ProfileDTO(
                name: profile.name,
                isEnabled: profile.isEnabled,
                priority: profile.priority,
                bundleIdentifiers: profile.bundleIdentifiers,
                urlPatterns: profile.urlPatterns,
                inputLanguage: profile.inputLanguage,
                translationEnabled: profile.translationEnabled,
                translationTargetLanguage: profile.translationTargetLanguage,
                selectedTask: profile.selectedTask,
                engineOverride: profile.engineOverride,
                cloudModelOverride: profile.cloudModelOverride,
                promptActionId: profile.promptActionId,
                memoryEnabled: profile.memoryEnabled,
                outputFormat: profile.outputFormat,
                hotkey: profile.hotkey,
                inlineCommandsEnabled: profile.inlineCommandsEnabled,
                autoEnterEnabled: profile.autoEnterEnabled
            )
        }

        var hotkeys: [String: [UnifiedHotkey]] = [:]
        for key in hotkeySlotKeys {
            guard let data = userDefaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([UnifiedHotkey].self, from: data),
                  !decoded.isEmpty else { continue }
            hotkeys[key] = decoded
        }

        // Bundled first-party plugins always ship with the app and don't need
        // reinstalling. Everything else (community-installed or manually
        // installed from file) is recorded; manual-install plugins simply
        // won't be found in the registry on import and are reported as skipped.
        let plugins = pluginManager.loadedPlugins
            .filter { !$0.isBundled }
            .map { plugin in
                PluginDTO(
                    id: plugin.id,
                    name: plugin.manifest.name,
                    version: plugin.manifest.version,
                    wasEnabled: plugin.isEnabled
                )
            }

        let history = historyService.records.map { record in
            HistoryEntryDTO(
                timestamp: record.timestamp,
                rawText: record.rawText,
                finalText: record.finalText,
                appName: record.appName,
                appBundleIdentifier: record.appBundleIdentifier,
                appURL: record.appURL,
                durationSeconds: record.durationSeconds,
                language: record.language,
                engineUsed: record.engineUsed,
                modelUsed: record.modelUsed,
                pipelineSteps: record.pipelineStepList
            )
        }

        return SettingsBackup(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            appVersion: AppConstants.appVersion,
            workflows: workflows,
            dictionaryEntries: dictionaryEntries,
            snippets: snippets,
            promptActions: promptActions,
            profiles: profiles,
            hotkeys: hotkeys,
            plugins: plugins,
            history: history
        )
    }

    static func encodedJSON(_ backup: SettingsBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    static func saveToFile(_ backup: SettingsBackup, to url: URL) throws {
        let data = try encodedJSON(backup)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Import

    static func parse(_ data: Data) throws -> SettingsBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(SettingsBackup.self, from: data) else {
            throw ImportError.invalidFile
        }
        return backup
    }

    @discardableResult
    static func importBackup(
        _ backup: SettingsBackup,
        workflowService: WorkflowService,
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        profileService: ProfileService,
        promptActionService: PromptActionService,
        pluginManager: PluginManager,
        pluginRegistryService: PluginRegistryService,
        historyService: HistoryService,
        userDefaults: UserDefaults = .standard
    ) async -> ImportResult {
        var result = ImportResult()

        for workflow in backup.workflows {
            workflowService.addWorkflow(
                name: workflow.name,
                template: workflow.template,
                trigger: workflow.trigger,
                behavior: workflow.behavior,
                output: workflow.output,
                isEnabled: workflow.isEnabled
            )
            result.workflowsImported += 1
        }

        let dictionaryItems = backup.dictionaryEntries.map {
            (type: $0.type, original: $0.original, replacement: $0.replacement,
             caseSensitive: $0.caseSensitive, isEnabled: $0.isEnabled,
             ctcMinSimilarity: $0.ctcMinSimilarity, source: $0.source)
        }
        let beforeDictionaryCount = dictionaryService.entries.count
        dictionaryService.importEntries(dictionaryItems)
        let dictionaryImported = dictionaryService.entries.count - beforeDictionaryCount
        result.dictionaryImported = dictionaryImported
        result.dictionarySkipped = backup.dictionaryEntries.count - dictionaryImported

        for snippet in backup.snippets {
            let beforeCount = snippetService.snippets.count
            snippetService.addSnippet(
                trigger: snippet.trigger,
                replacement: snippet.replacement,
                caseSensitive: snippet.caseSensitive
            )
            guard snippetService.snippets.count > beforeCount else {
                result.snippetsSkipped += 1
                continue
            }
            result.snippetsImported += 1
            if !snippet.isEnabled, let added = snippetService.snippets.first(where: { $0.trigger == snippet.trigger }) {
                snippetService.toggleSnippet(added)
            }
        }

        // Prompt actions must be imported first so profiles can remap their
        // promptActionId references to the freshly-generated UUIDs below.
        var promptActionIdMap: [String: String] = [:]
        for action in backup.promptActions {
            guard let imported = promptActionService.addAction(
                name: action.name,
                prompt: action.prompt,
                icon: action.icon,
                isEnabled: action.isEnabled,
                providerType: action.providerType,
                cloudModel: action.cloudModel,
                temperatureModeRaw: action.temperatureModeRaw,
                temperatureValue: action.temperatureValue,
                targetActionPluginId: action.targetActionPluginId
            ) else { continue }
            promptActionIdMap[action.localId] = imported.id.uuidString
            result.promptActionsImported += 1
        }

        for profile in backup.profiles {
            let remappedPromptActionId = profile.promptActionId.flatMap { promptActionIdMap[$0] }
            profileService.addProfile(
                name: profile.name,
                isEnabled: profile.isEnabled,
                bundleIdentifiers: profile.bundleIdentifiers,
                urlPatterns: profile.urlPatterns,
                inputLanguage: profile.inputLanguage,
                translationEnabled: profile.translationEnabled,
                translationTargetLanguage: profile.translationTargetLanguage,
                selectedTask: profile.selectedTask,
                engineOverride: profile.engineOverride,
                cloudModelOverride: profile.cloudModelOverride,
                promptActionId: remappedPromptActionId,
                memoryEnabled: profile.memoryEnabled,
                outputFormat: profile.outputFormat,
                hotkeyData: profile.hotkey.flatMap { try? JSONEncoder().encode($0) },
                inlineCommandsEnabled: profile.inlineCommandsEnabled,
                autoEnterEnabled: profile.autoEnterEnabled,
                priority: profile.priority
            )
            result.profilesImported += 1
        }

        // Only fill empty hotkey slots; never overwrite the destination Mac's
        // existing bindings.
        for (key, hotkeys) in backup.hotkeys {
            let isSlotEmpty = userDefaults.data(forKey: key) == nil
            guard isSlotEmpty, !hotkeys.isEmpty else {
                result.hotkeysSkipped += 1
                continue
            }
            if let data = try? JSONEncoder().encode(hotkeys) {
                userDefaults.set(data, forKey: key)
                result.hotkeysApplied += 1
            } else {
                result.hotkeysSkipped += 1
            }
        }

        if !backup.plugins.isEmpty {
            _ = await pluginRegistryService.fetchRegistry()
            for plugin in backup.plugins {
                let alreadyInstalled = pluginManager.loadedPlugins.contains { $0.id == plugin.id }
                guard !alreadyInstalled else {
                    result.pluginsSkipped += 1
                    continue
                }
                guard let registryPlugin = pluginRegistryService.registry.first(where: { $0.id == plugin.id }) else {
                    result.pluginsSkipped += 1
                    continue
                }
                let installed = await pluginRegistryService.downloadAndInstall(registryPlugin)
                guard installed else {
                    result.pluginsSkipped += 1
                    continue
                }
                pluginManager.setPluginEnabled(plugin.id, enabled: plugin.wasEnabled)
                result.pluginsInstalled += 1
            }
        }

        let beforeHistoryCount = historyService.records.count
        for entry in backup.history {
            historyService.addRecord(
                timestamp: entry.timestamp,
                rawText: entry.rawText,
                finalText: entry.finalText,
                appName: entry.appName,
                appBundleIdentifier: entry.appBundleIdentifier,
                appURL: entry.appURL,
                durationSeconds: entry.durationSeconds,
                language: entry.language,
                engineUsed: entry.engineUsed,
                modelUsed: entry.modelUsed,
                pipelineSteps: entry.pipelineSteps
            )
        }
        result.historyImported = historyService.records.count - beforeHistoryCount

        return result
    }

    // MARK: - Panels

    static func presentSavePanel(suggestedName: String = defaultFilename()) -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Settings")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Settings")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "typewhisper-backup-\(formatter.string(from: Date())).json"
    }
}
