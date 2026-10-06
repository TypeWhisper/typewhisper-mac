import AppKit
import Foundation
import UniformTypeIdentifiers

/// Exports/imports a single JSON backup of user configuration (workflows,
/// dictionary, snippets, profiles, prompt actions, hotkeys, installed
/// community plugins, transcription history, the update channel, and a
/// handful of General-tab preferences) so it can be migrated to another Mac.
///
/// History is exported as text/metadata only — saved audio recordings
/// (`TranscriptionRecord.audioFileName`) are never included, since they can
/// be large (~1MB/30s) and would require a very different file format than
/// plain JSON.
///
/// "Launch at Login" is deliberately excluded from General preferences: it's
/// an `SMAppService` login-item registration, not a plain `UserDefaults`
/// value, so it can't be migrated by copying data — it must be re-enabled on
/// each Mac.
///
/// Deliberately out of scope: provider API keys, license/activation state,
/// usage statistics, and machine-specific preferences (selected
/// microphone/model, indicator style, sound toggles, etc.) — API keys and
/// the license must be re-entered/re-activated on the new Mac, and the rest
/// is either per-machine or low value to migrate. See
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
        UserDefaultsKeys.pasteLastTranscriptionHotkeys,
        UserDefaultsKeys.recorderToggleHotkeys,
        UserDefaultsKeys.undoLastDictationHotkeys,
        UserDefaultsKeys.restoreRawTranscriptHotkeys,
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

    /// Simple, portable preferences from the General, Dictation, Dictation
    /// Recovery, File Transcription, and Recorder settings tabs.
    ///
    /// Deliberately excludes:
    /// - Engine/model selections (`dictationRecoveryEngine`/`Model`,
    ///   `fileTranscriptionEngine`/`Model`, `recorderTranscriptionEngine`/
    ///   `Model`) — these can reference a plugin or local model that isn't
    ///   installed on the destination Mac.
    /// - "Launch at Login" (an `SMAppService` registration, not portable data).
    /// - The app UI language (changing it also requires setting the special
    ///   `"AppleLanguages"` default and prompting a restart, which isn't
    ///   something an import should trigger unprompted).
    /// - Hardware-specific settings (selected microphone, audio device
    ///   priority) and transient/live state (e.g. `dictationHotkeysPaused`).
    struct PreferencesDTO: Codable {
        // Fields use `var` (not `let`) so a default value on the declaration
        // is picked up by the synthesized memberwise init as a default
        // parameter — Swift only does this for `var` properties, so a `let`
        // with a default is instead treated as fixed and dropped from the
        // init parameter list entirely.
        // General
        var selectedLanguage: String? = nil
        var selectedTask: String? = nil
        var translationEnabled: Bool? = nil
        var translationTargetLanguage: String? = nil
        var showMenuBarIcon: Bool? = nil
        var dockIconBehaviorWhenMenuBarHidden: String? = nil
        // Dictation
        var audioDuckingEnabled: Bool? = nil
        var audioDuckingLevel: Double? = nil
        var soundFeedbackEnabled: Bool? = nil
        var soundRecordingStarted: Bool? = nil
        var soundTranscriptionSuccess: Bool? = nil
        var soundError: Bool? = nil
        var indicatorStyle: String? = nil
        var indicatorTheme: String? = nil
        var indicatorVisibleInScreenCaptures: Bool? = nil
        var indicatorTranscriptPreviewEnabled: Bool? = nil
        var liveFieldTranscriptEnabled: Bool? = nil
        var indicatorTranscriptPreviewFontSizeOffset: Int? = nil
        var preserveClipboard: Bool? = nil
        var transcriptionNumberNormalizationEnabled: Bool? = nil
        var transcriptionNumberNormalizationMinimumValue: Int? = nil
        var mediaPauseEnabled: Bool? = nil
        var transcribeShortQuietClipsAggressively: Bool? = nil
        var microphoneBoostEnabled: Bool? = nil
        var cancellationBehavior: String? = nil
        var requireSecondEscapeToCancelRecording: Bool? = nil
        // Dictation Recovery
        var dictationRecoveryLanguage: String? = nil
        var dictationRecoveryAutomaticFallbackEnabled: Bool? = nil
        var dictationRecoveryHedgeEnabled: Bool? = nil
        var dictationRecoveryHedgeThresholdSeconds: Double? = nil
        var dictationRecoveryRetentionDays: Int? = nil
        // File Transcription
        var fileTranscriptionLanguage: String? = nil
        // Recorder
        var recorderMicEnabled: Bool? = nil
        var recorderSystemAudioEnabled: Bool? = nil
        var recorderOutputFormat: String? = nil
        var recorderTranscriptionEnabled: Bool? = nil
        var recorderLivePreviewEnabled: Bool? = nil
        var recorderMicDuckingMode: String? = nil
        var recorderTrackMode: String? = nil

        /// Every field defaults to `nil`, so the synthesized memberwise init
        /// doubles as an "all preferences absent" value (used by `filtered`
        /// when the Preferences category is deselected) without hand-listing
        /// every `nil` argument.
        static let empty = PreferencesDTO()

        /// Number of non-nil fields, used to show a count in the category
        /// selection sheets. Listed explicitly (rather than via `Mirror`) to
        /// keep the count trivially auditable against the field list above.
        var nonNilCount: Int {
            var count = 0
            if selectedLanguage != nil { count += 1 }
            if selectedTask != nil { count += 1 }
            if translationEnabled != nil { count += 1 }
            if translationTargetLanguage != nil { count += 1 }
            if showMenuBarIcon != nil { count += 1 }
            if dockIconBehaviorWhenMenuBarHidden != nil { count += 1 }
            if audioDuckingEnabled != nil { count += 1 }
            if audioDuckingLevel != nil { count += 1 }
            if soundFeedbackEnabled != nil { count += 1 }
            if soundRecordingStarted != nil { count += 1 }
            if soundTranscriptionSuccess != nil { count += 1 }
            if soundError != nil { count += 1 }
            if indicatorStyle != nil { count += 1 }
            if indicatorTheme != nil { count += 1 }
            if indicatorVisibleInScreenCaptures != nil { count += 1 }
            if indicatorTranscriptPreviewEnabled != nil { count += 1 }
            if liveFieldTranscriptEnabled != nil { count += 1 }
            if indicatorTranscriptPreviewFontSizeOffset != nil { count += 1 }
            if preserveClipboard != nil { count += 1 }
            if transcriptionNumberNormalizationEnabled != nil { count += 1 }
            if transcriptionNumberNormalizationMinimumValue != nil { count += 1 }
            if mediaPauseEnabled != nil { count += 1 }
            if transcribeShortQuietClipsAggressively != nil { count += 1 }
            if microphoneBoostEnabled != nil { count += 1 }
            if cancellationBehavior != nil || requireSecondEscapeToCancelRecording != nil { count += 1 }
            if dictationRecoveryLanguage != nil { count += 1 }
            if dictationRecoveryAutomaticFallbackEnabled != nil { count += 1 }
            if dictationRecoveryHedgeEnabled != nil { count += 1 }
            if dictationRecoveryHedgeThresholdSeconds != nil { count += 1 }
            if dictationRecoveryRetentionDays != nil { count += 1 }
            if fileTranscriptionLanguage != nil { count += 1 }
            if recorderMicEnabled != nil { count += 1 }
            if recorderSystemAudioEnabled != nil { count += 1 }
            if recorderOutputFormat != nil { count += 1 }
            if recorderTranscriptionEnabled != nil { count += 1 }
            if recorderLivePreviewEnabled != nil { count += 1 }
            if recorderMicDuckingMode != nil { count += 1 }
            if recorderTrackMode != nil { count += 1 }
            return count
        }
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
        /// Raw `ReleaseChannel` value (see `AppConstants.ReleaseChannel`), if the
        /// user has explicitly picked one (`UserDefaultsKeys.updateChannel`).
        let updateChannel: String?
        let preferences: PreferencesDTO
    }

    struct ImportResult: Encodable, Sendable {
        var workflowsImported = 0
        /// Existing workflows overwritten in `.replace` mode.
        var workflowsUpdated = 0
        /// Backup workflows that already exist unchanged on this Mac.
        var workflowsSkipped = 0
        var dictionaryImported = 0
        var dictionarySkipped = 0
        var snippetsImported = 0
        var snippetsSkipped = 0
        var promptActionsImported = 0
        var promptActionsUpdated = 0
        var promptActionsSkipped = 0
        var profilesImported = 0
        var profilesUpdated = 0
        var profilesSkipped = 0
        var hotkeysApplied = 0
        var hotkeysSkipped = 0
        var pluginsInstalled = 0
        var pluginsSkipped = 0
        /// True if `PluginRegistryService.fetchRegistry()` failed (e.g. no
        /// network). When true, `pluginsSkipped` may include plugins that
        /// simply couldn't be looked up rather than ones genuinely missing
        /// from the marketplace.
        var pluginsRegistryFetchFailed = false
        var historyImported = 0
        /// Entries older than the destination Mac's current history
        /// retention window, excluded so they wouldn't just be silently
        /// purged again on the next launch.
        var historySkippedByRetention = 0
        /// Entries already in this Mac's history, e.g. when a backup is
        /// imported onto the Mac it was exported from.
        var historySkippedAsDuplicate = 0
        /// Entries not imported because this Mac's history could not be read
        /// to check for duplicates.
        var historySkippedUnreadableDestination = 0
        var updateChannelApplied = false
        var preferencesApplied = 0
    }

    /// How an import treats workflows, profiles, prompt actions, and hotkeys
    /// that already exist on this Mac. The backup stores no IDs for them, so
    /// existing items are recognized by content or, in `.replace`, by name.
    enum ImportMode: String, Sendable {
        /// Skip items that already exist with the same content, add the
        /// rest, and only fill empty hotkey slots.
        case merge
        /// Additionally overwrite existing items with the same name and the
        /// hotkey slots contained in the backup. Nothing is deleted.
        case replace
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

    // MARK: - Categories

    /// One row in the export/import category-selection sheets. Cases are
    /// ordered to match the display order in those sheets.
    enum Category: String, CaseIterable, Identifiable, Hashable {
        case workflows, dictionary, snippets, profiles, promptActions, hotkeys, plugins, history, preferences

        var id: String { rawValue }

        var title: String {
            switch self {
            case .workflows: return String(localized: "Workflows")
            case .dictionary: return String(localized: "Dictionary")
            case .snippets: return String(localized: "Snippets")
            case .profiles: return String(localized: "Profiles")
            case .promptActions: return String(localized: "Prompt Actions")
            case .hotkeys: return String(localized: "Hotkeys")
            case .plugins: return String(localized: "Plugins")
            case .history: return String(localized: "History")
            case .preferences: return String(localized: "Preferences")
            }
        }

        var icon: String {
            switch self {
            case .workflows: return "bolt.fill"
            case .dictionary: return "character.book.closed.fill"
            case .snippets: return "text.badge.plus"
            case .profiles: return "person.crop.circle.fill"
            case .promptActions: return "sparkles"
            case .hotkeys: return "keyboard.fill"
            case .plugins: return "puzzlepiece.extension.fill"
            case .history: return "clock.arrow.circlepath"
            case .preferences: return "slider.horizontal.3"
            }
        }

        var infoText: String {
            switch self {
            case .workflows: return String(localized: "Custom workflow triggers, templates, and output rules.")
            case .dictionary: return String(localized: "Recognition corrections and replacement terms.")
            case .snippets: return String(localized: "Trigger-to-text expansion shortcuts.")
            case .profiles: return String(localized: "Per-app / per-URL settings profiles.")
            case .promptActions: return String(localized: "Custom AI prompt actions. Built-in presets are never exported.")
            case .hotkeys: return localizedAppText(
                    "Global keyboard shortcuts. Only fills empty slots on import unless Replace existing items is on.",
                    de: "Globale Tastenkombinationen. Beim Import werden nur leere Plätze befüllt, außer „Vorhandene Einträge ersetzen“ ist eingeschaltet.",
                    ja: "アプリ共通のキーボードショートカット。「既存の項目を置き換える」がオフの場合、取込み時は未設定の項目にのみ適用します。",
                    zh: "全局键盘快捷键。除非开启“替换现有项目”，导入时仅填充空白位置。"
                )
            case .plugins: return localizedAppText(
                    "Installed community plugins. Reinstalling requires network access and fetches the latest marketplace version.",
                    de: "Installierte Community-Plugins. Die Neuinstallation erfordert eine Internetverbindung und lädt die aktuelle Marketplace-Version."
                )
            case .history: return String(localized: "Transcription history text and metadata. Saved audio is never included.")
            case .preferences: return String(localized: "Portable preferences from the General, Dictation, Dictation Recovery, File Transcription, and Recorder tabs, plus the selected update channel.")
            }
        }

        static func count(_ category: Category, in backup: SettingsBackup) -> Int {
            switch category {
            case .workflows: return backup.workflows.count
            case .dictionary: return backup.dictionaryEntries.count
            case .snippets: return backup.snippets.count
            case .profiles: return backup.profiles.count
            case .promptActions: return backup.promptActions.count
            case .hotkeys: return backup.hotkeys.values.reduce(0) { $0 + $1.count }
            case .plugins: return backup.plugins.count
            case .history: return backup.history.count
            case .preferences: return backup.preferences.nonNilCount + (backup.updateChannel != nil ? 1 : 0)
            }
        }
    }

    /// Returns a copy of `backup` with every category not in `categories`
    /// emptied out, so `importBackup`/`saveToFile` only see the data the user
    /// chose to include.
    ///
    /// Profiles → Prompt Actions → Plugins form a reference chain
    /// (`ProfileDTO.promptActionId` → `PromptActionDTO.localId`,
    /// `PromptActionDTO.targetActionPluginId` → `PluginDTO.id`). Deselecting
    /// an upstream category while keeping a downstream one would otherwise
    /// silently drop the link (e.g. a profile's custom prompt action reset to
    /// the default) with no way to warn the user in the selection sheet, so
    /// referenced items are pulled in automatically regardless of whether
    /// their own category is selected.
    static func filtered(_ backup: SettingsBackup, to categories: Set<Category>) -> SettingsBackup {
        let profiles = categories.contains(.profiles) ? backup.profiles : []

        let promptActionLocalIds: Set<String>
        if categories.contains(.promptActions) {
            promptActionLocalIds = Set(backup.promptActions.map(\.localId))
        } else {
            promptActionLocalIds = Set(profiles.compactMap(\.promptActionId))
        }
        let promptActions = backup.promptActions.filter { promptActionLocalIds.contains($0.localId) }

        let pluginIds: Set<String>
        if categories.contains(.plugins) {
            pluginIds = Set(backup.plugins.map(\.id))
        } else {
            pluginIds = Set(promptActions.compactMap(\.targetActionPluginId))
        }
        let plugins = backup.plugins.filter { pluginIds.contains($0.id) }

        return SettingsBackup(
            schemaVersion: backup.schemaVersion,
            exportedAt: backup.exportedAt,
            appVersion: backup.appVersion,
            workflows: categories.contains(.workflows) ? backup.workflows : [],
            dictionaryEntries: categories.contains(.dictionary) ? backup.dictionaryEntries : [],
            snippets: categories.contains(.snippets) ? backup.snippets : [],
            promptActions: promptActions,
            profiles: profiles,
            hotkeys: categories.contains(.hotkeys) ? backup.hotkeys : [:],
            plugins: plugins,
            history: categories.contains(.history) ? backup.history : [],
            updateChannel: categories.contains(.preferences) ? backup.updateChannel : nil,
            preferences: categories.contains(.preferences) ? backup.preferences : .empty
        )
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
    ) throws -> SettingsBackup {
        let workflows = workflowService.workflows.map(WorkflowDTO.init)

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
            .map(PromptActionDTO.init)

        let profiles = profileService.profiles.map(ProfileDTO.init)

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

        let history = try historyService.allRecordsThrowing().map { record in
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
            history: history,
            updateChannel: userDefaults.string(forKey: UserDefaultsKeys.updateChannel),
            preferences: PreferencesDTO(
                selectedLanguage: userDefaults.string(forKey: UserDefaultsKeys.selectedLanguage),
                selectedTask: userDefaults.string(forKey: UserDefaultsKeys.selectedTask),
                translationEnabled: userDefaults.object(forKey: UserDefaultsKeys.translationEnabled) as? Bool,
                translationTargetLanguage: userDefaults.string(forKey: UserDefaultsKeys.translationTargetLanguage),
                showMenuBarIcon: userDefaults.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool,
                dockIconBehaviorWhenMenuBarHidden: userDefaults.string(forKey: UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden),
                audioDuckingEnabled: userDefaults.object(forKey: UserDefaultsKeys.audioDuckingEnabled) as? Bool,
                audioDuckingLevel: userDefaults.object(forKey: UserDefaultsKeys.audioDuckingLevel) as? Double,
                soundFeedbackEnabled: userDefaults.object(forKey: UserDefaultsKeys.soundFeedbackEnabled) as? Bool,
                soundRecordingStarted: userDefaults.object(forKey: UserDefaultsKeys.soundRecordingStarted) as? Bool,
                soundTranscriptionSuccess: userDefaults.object(forKey: UserDefaultsKeys.soundTranscriptionSuccess) as? Bool,
                soundError: userDefaults.object(forKey: UserDefaultsKeys.soundError) as? Bool,
                indicatorStyle: userDefaults.string(forKey: UserDefaultsKeys.indicatorStyle),
                indicatorTheme: userDefaults.string(forKey: UserDefaultsKeys.indicatorTheme),
                indicatorVisibleInScreenCaptures: userDefaults.object(forKey: UserDefaultsKeys.indicatorVisibleInScreenCaptures) as? Bool,
                indicatorTranscriptPreviewEnabled: userDefaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled) as? Bool,
                liveFieldTranscriptEnabled: userDefaults.object(forKey: UserDefaultsKeys.liveFieldTranscriptEnabled) as? Bool,
                indicatorTranscriptPreviewFontSizeOffset: userDefaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset) as? Int,
                preserveClipboard: userDefaults.object(forKey: UserDefaultsKeys.preserveClipboard) as? Bool,
                transcriptionNumberNormalizationEnabled: userDefaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) as? Bool,
                transcriptionNumberNormalizationMinimumValue: userDefaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue) == nil
                    ? nil
                    : TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: userDefaults),
                mediaPauseEnabled: userDefaults.object(forKey: UserDefaultsKeys.mediaPauseEnabled) as? Bool,
                transcribeShortQuietClipsAggressively: userDefaults.object(forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively) as? Bool,
                microphoneBoostEnabled: userDefaults.object(forKey: UserDefaultsKeys.microphoneBoostEnabled) as? Bool,
                cancellationBehavior: DictationViewModel.loadCancellationBehavior(defaults: userDefaults).rawValue,
                dictationRecoveryLanguage: userDefaults.string(forKey: UserDefaultsKeys.dictationRecoveryLanguage),
                dictationRecoveryAutomaticFallbackEnabled: userDefaults.object(forKey: UserDefaultsKeys.dictationRecoveryAutomaticFallbackEnabled) as? Bool,
                dictationRecoveryHedgeEnabled: userDefaults.object(forKey: UserDefaultsKeys.dictationRecoveryHedgeEnabled) as? Bool,
                dictationRecoveryHedgeThresholdSeconds: userDefaults.object(forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds) as? Double,
                dictationRecoveryRetentionDays: userDefaults.object(forKey: UserDefaultsKeys.dictationRecoveryRetentionDays) == nil
                    ? nil
                    : DictationRecoveryRetentionPolicy.load(from: userDefaults).rawValue,
                fileTranscriptionLanguage: userDefaults.string(forKey: UserDefaultsKeys.fileTranscriptionLanguage),
                recorderMicEnabled: userDefaults.object(forKey: UserDefaultsKeys.recorderMicEnabled) as? Bool,
                recorderSystemAudioEnabled: userDefaults.object(forKey: UserDefaultsKeys.recorderSystemAudioEnabled) as? Bool,
                recorderOutputFormat: userDefaults.string(forKey: UserDefaultsKeys.recorderOutputFormat),
                recorderTranscriptionEnabled: userDefaults.object(forKey: UserDefaultsKeys.recorderTranscriptionEnabled) as? Bool,
                recorderLivePreviewEnabled: userDefaults.object(forKey: UserDefaultsKeys.recorderLivePreviewEnabled) as? Bool,
                recorderMicDuckingMode: userDefaults.string(forKey: UserDefaultsKeys.recorderMicDuckingMode),
                recorderTrackMode: userDefaults.string(forKey: UserDefaultsKeys.recorderTrackMode)
            )
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
        mode: ImportMode = .merge,
        workflowService: WorkflowService,
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        profileService: ProfileService,
        promptActionService: PromptActionService,
        pluginManager: PluginManager,
        pluginRegistryService: PluginRegistryService,
        historyService: HistoryService,
        usageStatisticsService: UsageStatisticsService,
        userDefaults: UserDefaults = .standard,
        liveFieldTranscriptEnabledDidChange: ((Bool) -> Void)? = nil,
        cancellationBehaviorDidChange: ((CancellationBehavior) -> Void)? = nil,
        indicatorThemeDidChange: ((IndicatorTheme) -> Void)? = nil,
        recoveryRetentionPolicyDidChange: ((DictationRecoveryRetentionPolicy) -> Void)? = nil,
        dictationRecoveryPreferencesDidChange: (() -> Void)? = nil,
        hotkeysDidChange: (() -> Void)? = nil
    ) async -> ImportResult {
        var result = ImportResult()

        var matchedWorkflowIds = Set<UUID>()
        for workflow in backup.workflows {
            if let match = existingMatch(
                in: workflowService.workflows,
                excluding: matchedWorkflowIds,
                name: workflow.name,
                mode: mode,
                id: \.id,
                itemName: \.name,
                hasSameContent: { WorkflowDTO($0).hasSameContent(as: workflow) }
            ) {
                matchedWorkflowIds.insert(match.item.id)
                guard mode == .replace, !(match.hasSameContent && match.item.isEnabled == workflow.isEnabled) else {
                    result.workflowsSkipped += 1
                    continue
                }
                let existing = match.item
                existing.name = workflow.name
                existing.isEnabled = workflow.isEnabled
                existing.template = workflow.template
                existing.trigger = workflow.trigger
                existing.behavior = workflow.behavior
                existing.output = workflow.output
                workflowService.updateWorkflow(existing)
                result.workflowsUpdated += 1
                continue
            }

            if let added = workflowService.addWorkflow(
                name: workflow.name,
                template: workflow.template,
                trigger: workflow.trigger,
                behavior: workflow.behavior,
                output: workflow.output,
                isEnabled: workflow.isEnabled
            ) {
                matchedWorkflowIds.insert(added.id)
            }
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
        // promptActionId references to the matched or freshly-generated
        // UUIDs below. Built-in presets are never exported, so they are never
        // matched or overwritten either.
        var promptActionIdMap: [String: String] = [:]
        var matchedPromptActionIds = Set<UUID>()
        for action in backup.promptActions {
            if let match = existingMatch(
                in: promptActionService.promptActions.filter { !$0.isPreset },
                excluding: matchedPromptActionIds,
                name: action.name,
                mode: mode,
                id: \.id,
                itemName: \.name,
                // On the Mac the backup came from, the exported id still
                // identifies the action even after a rename.
                preferredId: UUID(uuidString: action.localId),
                hasSameContent: { PromptActionDTO($0).hasSameContent(as: action) }
            ) {
                matchedPromptActionIds.insert(match.item.id)
                promptActionIdMap[action.localId] = match.item.id.uuidString
                guard mode == .replace, !(match.hasSameContent && match.item.isEnabled == action.isEnabled) else {
                    result.promptActionsSkipped += 1
                    continue
                }
                promptActionService.updateAction(
                    match.item,
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
                result.promptActionsUpdated += 1
                continue
            }

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
            matchedPromptActionIds.insert(imported.id)
            promptActionIdMap[action.localId] = imported.id.uuidString
            result.promptActionsImported += 1
        }

        var matchedProfileIds = Set<UUID>()
        for profile in backup.profiles {
            let remappedPromptActionId = profile.promptActionId.flatMap { localId in
                // Built-in presets are never exported. On the Mac the backup
                // came from, a reference to one is still valid as it is.
                promptActionIdMap[localId]
                    ?? (promptActionService.promptActions.contains { $0.id.uuidString == localId } ? localId : nil)
            }
            let remappedProfile = profile.withPromptActionId(remappedPromptActionId)
            if let match = existingMatch(
                in: profileService.profiles,
                excluding: matchedProfileIds,
                name: profile.name,
                mode: mode,
                id: \.id,
                itemName: \.name,
                hasSameContent: { ProfileDTO($0).hasSameContent(as: remappedProfile) }
            ) {
                matchedProfileIds.insert(match.item.id)
                guard mode == .replace, !(match.hasSameContent && match.item.isEnabled == profile.isEnabled) else {
                    result.profilesSkipped += 1
                    continue
                }
                // The destination keeps its own priority, as on append below.
                remappedProfile.apply(to: match.item)
                profileService.updateProfile(match.item)
                result.profilesUpdated += 1
                continue
            }

            let added = profileService.addProfile(
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
                // Append rather than reuse the source Mac's raw priority
                // (mirrors how workflow import always appends via
                // nextSortOrder()) — reusing it verbatim could collide with
                // an existing profile's priority and silently change which
                // one wins for a shared app/URL match.
                priority: profileService.nextPriority()
            )
            matchedProfileIds.insert(added.id)
            result.profilesImported += 1
        }

        // Merge only fills empty hotkey slots and never overwrites the
        // destination Mac's existing bindings; replace overwrites the slots
        // contained in the backup. A backup is user-editable JSON, so only
        // known hotkey slots are written.
        var hotkeysBySlot: [String: [UnifiedHotkey]] = [:]
        for key in hotkeySlotKeys {
            hotkeysBySlot[key] = userDefaults.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([UnifiedHotkey].self, from: $0) } ?? []
        }
        var hotkeyWrites: [String: [UnifiedHotkey]] = [:]
        for (key, hotkeys) in backup.hotkeys {
            let canWrite = switch mode {
            case .merge: userDefaults.data(forKey: key) == nil
            case .replace: hotkeysBySlot[key] != hotkeys
            }
            guard hotkeySlotKeys.contains(key), canWrite, !hotkeys.isEmpty else {
                result.hotkeysSkipped += 1
                continue
            }
            hotkeyWrites[key] = hotkeys
        }
        // Every slot reacts to a matching key press, so a slot whose imported
        // bindings another slot uses afterwards would trigger both actions.
        // Such a slot keeps its current bindings. Repeat until nothing else is
        // dropped: a dropped slot's current bindings can conflict in turn.
        let proposedWriteCount = hotkeyWrites.count
        var droppedWrite = true
        while droppedWrite {
            droppedWrite = false
            let finalHotkeys = hotkeysBySlot.merging(hotkeyWrites) { _, imported in imported }
            for (key, hotkeys) in hotkeyWrites {
                let otherHotkeys = finalHotkeys.filter { $0.key != key }.values.flatMap { $0 }
                guard hotkeys.contains(where: { hotkey in otherHotkeys.contains { $0.conflicts(with: hotkey) } }) else {
                    continue
                }
                hotkeyWrites[key] = nil
                droppedWrite = true
                break
            }
        }
        result.hotkeysSkipped += proposedWriteCount - hotkeyWrites.count
        for (key, hotkeys) in hotkeyWrites {
            guard let data = try? JSONEncoder().encode(hotkeys) else {
                result.hotkeysSkipped += 1
                continue
            }
            userDefaults.set(data, forKey: key)
            result.hotkeysApplied += 1
        }
        if result.hotkeysApplied > 0 {
            hotkeysDidChange?()
        }

        if !backup.plugins.isEmpty {
            let fetched = await pluginRegistryService.fetchRegistry()
            result.pluginsRegistryFetchFailed = !fetched
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

        // If the destination Mac has history retention enabled, importing
        // entries older than that window would otherwise get silently purged
        // again on the very next launch (ServiceContainer.swift) while their
        // usage-statistics counters (recorded below) live on forever —
        // leaving Statistics showing data for history the user can no longer
        // find. Exclude those entries up front instead.
        let retentionDays = userDefaults.integer(forKey: UserDefaultsKeys.historyRetentionDays)
        let retentionCutoff: Date? = retentionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
            : nil

        // History entries have no stable id in the backup, so an entry counts
        // as already present when its texts match and its timestamp is within
        // a second: the ISO 8601 export drops fractional seconds.
        var existingHistory = HistoryDuplicateIndex()
        var historyToImport = backup.history
        if !historyToImport.isEmpty {
            do {
                existingHistory = HistoryDuplicateIndex(try historyService.allRecordsThrowing())
            } catch {
                // Without the existing entries every backup entry would look
                // new and could be inserted a second time.
                result.historySkippedUnreadableDestination = historyToImport.count
                historyToImport = []
            }
        }

        for (index, entry) in historyToImport.enumerated() {
            // A large imported history is a tight, otherwise-uninterrupted
            // loop of SwiftData work on the main actor; yield periodically so
            // the UI (the import spinner, in particular) stays responsive,
            // also when most entries are skipped.
            if index % 25 == 24 {
                await Task.yield()
            }
            if let retentionCutoff, entry.timestamp < retentionCutoff {
                result.historySkippedByRetention += 1
                continue
            }
            if existingHistory.contains(entry) {
                result.historySkippedAsDuplicate += 1
                continue
            }

            let inserted = historyService.addRecord(
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
            // UsageStatisticsService only backfills from history once, at app
            // launch (ServiceContainer), so an import happening mid-session
            // would otherwise leave the Statistics tab showing no data for
            // these entries. Only record stats for entries HistoryService
            // actually inserted — it silently skips empty/invalid ones, and
            // counting those anyway would inflate Statistics beyond what's
            // visible in History.
            if inserted {
                result.historyImported += 1
                existingHistory.insert(entry)
                usageStatisticsService.recordTranscription(
                    timestamp: entry.timestamp,
                    wordsCount: entry.finalText.split(separator: " ").count,
                    durationSeconds: entry.durationSeconds,
                    appBundleIdentifier: entry.appBundleIdentifier,
                    appName: entry.appName,
                    engineUsed: entry.engineUsed,
                    modelUsed: entry.modelUsed
                )
            }
        }
        if let updateChannel = backup.updateChannel,
           AppConstants.ReleaseChannel(rawValue: updateChannel) != nil {
            userDefaults.set(updateChannel, forKey: UserDefaultsKeys.updateChannel)
            result.updateChannelApplied = true
        }

        let preferences = backup.preferences
        func apply<Value>(_ value: Value?, forKey key: String) {
            guard let value else { return }
            userDefaults.set(value, forKey: key)
            result.preferencesApplied += 1
        }
        apply(preferences.selectedLanguage, forKey: UserDefaultsKeys.selectedLanguage)
        apply(preferences.selectedTask, forKey: UserDefaultsKeys.selectedTask)
        apply(preferences.translationEnabled, forKey: UserDefaultsKeys.translationEnabled)
        apply(preferences.translationTargetLanguage, forKey: UserDefaultsKeys.translationTargetLanguage)
        apply(preferences.showMenuBarIcon, forKey: UserDefaultsKeys.showMenuBarIcon)
        apply(preferences.dockIconBehaviorWhenMenuBarHidden, forKey: UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden)
        apply(preferences.audioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled)
        apply(preferences.audioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel)
        apply(preferences.soundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled)
        apply(preferences.soundRecordingStarted, forKey: UserDefaultsKeys.soundRecordingStarted)
        apply(preferences.soundTranscriptionSuccess, forKey: UserDefaultsKeys.soundTranscriptionSuccess)
        apply(preferences.soundError, forKey: UserDefaultsKeys.soundError)
        apply(preferences.indicatorStyle, forKey: UserDefaultsKeys.indicatorStyle)
        // A backup is user-editable JSON: only a known theme is restored and
        // handed to the live view model, anything else keeps the current one.
        if let indicatorTheme = preferences.indicatorTheme.flatMap(IndicatorTheme.init(rawValue:)) {
            apply(indicatorTheme.rawValue, forKey: UserDefaultsKeys.indicatorTheme)
            indicatorThemeDidChange?(indicatorTheme)
        }
        apply(preferences.indicatorVisibleInScreenCaptures, forKey: UserDefaultsKeys.indicatorVisibleInScreenCaptures)
        apply(preferences.indicatorTranscriptPreviewEnabled, forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)
        apply(preferences.liveFieldTranscriptEnabled, forKey: UserDefaultsKeys.liveFieldTranscriptEnabled)
        if let liveFieldTranscriptEnabled = preferences.liveFieldTranscriptEnabled {
            liveFieldTranscriptEnabledDidChange?(liveFieldTranscriptEnabled)
        }
        apply(preferences.indicatorTranscriptPreviewFontSizeOffset, forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset)
        apply(preferences.preserveClipboard, forKey: UserDefaultsKeys.preserveClipboard)
        apply(preferences.transcriptionNumberNormalizationEnabled, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        if let minimumValue = preferences.transcriptionNumberNormalizationMinimumValue,
           [0, 10, 100].contains(minimumValue) {
            apply(minimumValue, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        }
        apply(preferences.mediaPauseEnabled, forKey: UserDefaultsKeys.mediaPauseEnabled)
        apply(preferences.transcribeShortQuietClipsAggressively, forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively)
        apply(preferences.microphoneBoostEnabled, forKey: UserDefaultsKeys.microphoneBoostEnabled)
        let cancellationBehavior = preferences.cancellationBehavior.flatMap(CancellationBehavior.init(rawValue:))
            ?? preferences.requireSecondEscapeToCancelRecording.map { $0 ? .doubleEscape : .singleEscape }
        if let cancellationBehavior {
            apply(cancellationBehavior.rawValue, forKey: UserDefaultsKeys.cancellationBehavior)
            cancellationBehaviorDidChange?(cancellationBehavior)
        }
        apply(preferences.dictationRecoveryLanguage, forKey: UserDefaultsKeys.dictationRecoveryLanguage)
        apply(preferences.dictationRecoveryAutomaticFallbackEnabled, forKey: UserDefaultsKeys.dictationRecoveryAutomaticFallbackEnabled)
        apply(preferences.dictationRecoveryHedgeEnabled, forKey: UserDefaultsKeys.dictationRecoveryHedgeEnabled)
        // A backup is user-editable JSON: only a finite value inside the range
        // the UI offers is restored, anything else keeps the current setting.
        apply(
            preferences.dictationRecoveryHedgeThresholdSeconds.flatMap { value -> Double? in
                guard value.isFinite,
                      DictationRecoveryViewModel.hedgeThresholdRange.contains(value) else { return nil }
                return value
            },
            forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds
        )
        apply(preferences.dictationRecoveryRetentionDays, forKey: UserDefaultsKeys.dictationRecoveryRetentionDays)
        if preferences.dictationRecoveryLanguage != nil
            || preferences.dictationRecoveryAutomaticFallbackEnabled != nil
            || preferences.dictationRecoveryHedgeEnabled != nil
            || preferences.dictationRecoveryHedgeThresholdSeconds != nil
            || preferences.dictationRecoveryRetentionDays != nil {
            dictationRecoveryPreferencesDidChange?()
        }
        if preferences.dictationRecoveryRetentionDays != nil {
            recoveryRetentionPolicyDidChange?(DictationRecoveryRetentionPolicy.load(from: userDefaults))
        }
        apply(preferences.fileTranscriptionLanguage, forKey: UserDefaultsKeys.fileTranscriptionLanguage)
        apply(preferences.recorderMicEnabled, forKey: UserDefaultsKeys.recorderMicEnabled)
        apply(preferences.recorderSystemAudioEnabled, forKey: UserDefaultsKeys.recorderSystemAudioEnabled)
        apply(preferences.recorderOutputFormat, forKey: UserDefaultsKeys.recorderOutputFormat)
        apply(preferences.recorderTranscriptionEnabled, forKey: UserDefaultsKeys.recorderTranscriptionEnabled)
        apply(preferences.recorderLivePreviewEnabled, forKey: UserDefaultsKeys.recorderLivePreviewEnabled)
        apply(preferences.recorderMicDuckingMode, forKey: UserDefaultsKeys.recorderMicDuckingMode)
        apply(preferences.recorderTrackMode, forKey: UserDefaultsKeys.recorderTrackMode)

        return result
    }

    // MARK: - Import matching

    /// Finds the existing item a backup entry corresponds to, skipping items
    /// already matched by an earlier entry. In `.replace` mode the item with
    /// `preferredId` wins. Otherwise an item with the same content matches,
    /// and in `.replace` mode the first item with the same name as well.
    private static func existingMatch<Item>(
        in items: [Item],
        excluding matchedIds: Set<UUID>,
        name: String,
        mode: ImportMode,
        id: (Item) -> UUID,
        itemName: (Item) -> String,
        preferredId: UUID? = nil,
        hasSameContent: (Item) -> Bool
    ) -> (item: Item, hasSameContent: Bool)? {
        let candidates = items.filter { !matchedIds.contains(id($0)) }
        if mode == .replace, let preferredId, let item = candidates.first(where: { id($0) == preferredId }) {
            return (item, hasSameContent(item))
        }
        if let item = candidates.first(where: hasSameContent) {
            return (item, true)
        }
        guard mode == .replace else { return nil }
        if let item = candidates.first(where: { itemName($0) == name }) {
            return (item, false)
        }
        return nil
    }

    private struct HistoryDuplicateIndex {
        private struct Texts: Hashable {
            let rawText: String
            let finalText: String
        }

        private var timestampsByTexts: [Texts: [Date]] = [:]

        init(_ records: [TranscriptionRecord] = []) {
            for record in records {
                timestampsByTexts[Texts(rawText: record.rawText, finalText: record.finalText), default: []]
                    .append(record.timestamp)
            }
        }

        func contains(_ entry: HistoryEntryDTO) -> Bool {
            let timestamps = timestampsByTexts[Texts(rawText: entry.rawText, finalText: entry.finalText)] ?? []
            return timestamps.contains { abs($0.timeIntervalSince(entry.timestamp)) < 1 }
        }

        mutating func insert(_ entry: HistoryEntryDTO) {
            timestampsByTexts[Texts(rawText: entry.rawText, finalText: entry.finalText), default: []]
                .append(entry.timestamp)
        }
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

// MARK: - DTO mapping

// Content comparisons ignore the enabled state and the position, which the
// destination Mac may have changed since the export without making the item a
// different one.

extension SettingsBackupExporter.WorkflowDTO {
    init(_ workflow: Workflow) {
        self.init(
            name: workflow.name,
            isEnabled: workflow.isEnabled,
            sortOrder: workflow.sortOrder,
            template: workflow.template,
            trigger: workflow.trigger ?? .manual(),
            behavior: workflow.behavior,
            output: workflow.output
        )
    }

    func hasSameContent(as other: Self) -> Bool {
        name == other.name
            && template == other.template
            && Self.hasSameSelectors(trigger, other.trigger)
            && behavior == other.behavior
            && output == other.output
    }

    /// Workflow matching checks apps, websites, and hotkeys with `contains`,
    /// so their order doesn't change which workflow runs.
    private static func hasSameSelectors(_ lhs: WorkflowTrigger, _ rhs: WorkflowTrigger) -> Bool {
        lhs.kind == rhs.kind
            && lhs.hotkeyBehavior == rhs.hotkeyBehavior
            && Set(lhs.appBundleIdentifiers) == Set(rhs.appBundleIdentifiers)
            && Set(lhs.websitePatterns) == Set(rhs.websitePatterns)
            && Set(lhs.hotkeys) == Set(rhs.hotkeys)
    }
}

extension SettingsBackupExporter.PromptActionDTO {
    init(_ action: PromptAction) {
        self.init(
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

    func hasSameContent(as other: Self) -> Bool {
        name == other.name
            && prompt == other.prompt
            && icon == other.icon
            && providerType == other.providerType
            && cloudModel == other.cloudModel
            && temperatureModeRaw == other.temperatureModeRaw
            && temperatureValue == other.temperatureValue
            && targetActionPluginId == other.targetActionPluginId
    }
}

extension SettingsBackupExporter.ProfileDTO {
    init(_ profile: Profile) {
        self.init(
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

    /// Profiles reference prompt actions by id, so a backup profile is
    /// compared after its reference has been remapped to this Mac.
    func withPromptActionId(_ promptActionId: String?) -> Self {
        Self(
            name: name,
            isEnabled: isEnabled,
            priority: priority,
            bundleIdentifiers: bundleIdentifiers,
            urlPatterns: urlPatterns,
            inputLanguage: inputLanguage,
            translationEnabled: translationEnabled,
            translationTargetLanguage: translationTargetLanguage,
            selectedTask: selectedTask,
            engineOverride: engineOverride,
            cloudModelOverride: cloudModelOverride,
            promptActionId: promptActionId,
            memoryEnabled: memoryEnabled,
            outputFormat: outputFormat,
            hotkey: hotkey,
            inlineCommandsEnabled: inlineCommandsEnabled,
            autoEnterEnabled: autoEnterEnabled
        )
    }

    func hasSameContent(as other: Self) -> Bool {
        name == other.name
            && Set(bundleIdentifiers) == Set(other.bundleIdentifiers)
            && Set(urlPatterns) == Set(other.urlPatterns)
            && inputLanguage == other.inputLanguage
            && translationEnabled == other.translationEnabled
            && translationTargetLanguage == other.translationTargetLanguage
            && selectedTask == other.selectedTask
            && engineOverride == other.engineOverride
            && cloudModelOverride == other.cloudModelOverride
            && promptActionId == other.promptActionId
            && memoryEnabled == other.memoryEnabled
            && outputFormat == other.outputFormat
            && hotkey == other.hotkey
            && inlineCommandsEnabled == other.inlineCommandsEnabled
            && autoEnterEnabled == other.autoEnterEnabled
    }

    /// Writes every field except the priority onto an existing profile.
    func apply(to profile: Profile) {
        profile.name = name
        profile.isEnabled = isEnabled
        profile.bundleIdentifiers = bundleIdentifiers
        profile.urlPatterns = urlPatterns
        profile.inputLanguage = inputLanguage
        profile.translationEnabled = translationEnabled
        profile.translationTargetLanguage = translationTargetLanguage
        profile.selectedTask = selectedTask
        profile.engineOverride = engineOverride
        profile.cloudModelOverride = cloudModelOverride
        profile.promptActionId = promptActionId
        profile.memoryEnabled = memoryEnabled
        profile.outputFormat = outputFormat
        profile.hotkey = hotkey
        profile.inlineCommandsEnabled = inlineCommandsEnabled
        profile.autoEnterEnabled = autoEnterEnabled
    }
}

/// Main-actor bridge used by headless automation surfaces. It keeps the HTTP
/// layer independent from the individual settings stores while guaranteeing
/// that exports and imports use the same schema and side effects as the UI.
@MainActor
final class SettingsBackupAutomationService {
    private let workflowService: WorkflowService
    private let dictionaryService: DictionaryService
    private let snippetService: SnippetService
    private let profileService: ProfileService
    private let promptActionService: PromptActionService
    private let pluginManager: PluginManager
    private let pluginRegistryService: PluginRegistryService
    private let historyService: HistoryService
    private let usageStatisticsService: UsageStatisticsService
    private let userDefaults: UserDefaults
    private let liveFieldTranscriptEnabledDidChange: ((Bool) -> Void)?
    private let recoveryRetentionPolicyDidChange: ((DictationRecoveryRetentionPolicy) -> Void)?
    private let cancellationBehaviorDidChange: ((CancellationBehavior) -> Void)?
    private let indicatorThemeDidChange: ((IndicatorTheme) -> Void)?
    private let dictationRecoveryPreferencesDidChange: (() -> Void)?
    private let hotkeysDidChange: (() -> Void)?

    init(
        workflowService: WorkflowService,
        dictionaryService: DictionaryService,
        snippetService: SnippetService,
        profileService: ProfileService,
        promptActionService: PromptActionService,
        pluginManager: PluginManager,
        pluginRegistryService: PluginRegistryService,
        historyService: HistoryService,
        usageStatisticsService: UsageStatisticsService,
        userDefaults: UserDefaults = .standard,
        liveFieldTranscriptEnabledDidChange: ((Bool) -> Void)? = nil,
        recoveryRetentionPolicyDidChange: ((DictationRecoveryRetentionPolicy) -> Void)? = nil,
        cancellationBehaviorDidChange: ((CancellationBehavior) -> Void)? = nil,
        indicatorThemeDidChange: ((IndicatorTheme) -> Void)? = nil,
        dictationRecoveryPreferencesDidChange: (() -> Void)? = nil,
        hotkeysDidChange: (() -> Void)? = nil
    ) {
        self.workflowService = workflowService
        self.dictionaryService = dictionaryService
        self.snippetService = snippetService
        self.profileService = profileService
        self.promptActionService = promptActionService
        self.pluginManager = pluginManager
        self.pluginRegistryService = pluginRegistryService
        self.historyService = historyService
        self.usageStatisticsService = usageStatisticsService
        self.userDefaults = userDefaults
        self.liveFieldTranscriptEnabledDidChange = liveFieldTranscriptEnabledDidChange
        self.recoveryRetentionPolicyDidChange = recoveryRetentionPolicyDidChange
        self.cancellationBehaviorDidChange = cancellationBehaviorDidChange
        self.indicatorThemeDidChange = indicatorThemeDidChange
        self.dictationRecoveryPreferencesDidChange = dictationRecoveryPreferencesDidChange
        self.hotkeysDidChange = hotkeysDidChange
    }

    func exportData() throws -> Data {
        let backup = try SettingsBackupExporter.buildBackup(
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            profileService: profileService,
            promptActionService: promptActionService,
            pluginManager: pluginManager,
            historyService: historyService,
            userDefaults: userDefaults
        )
        return try SettingsBackupExporter.encodedJSON(backup)
    }

    func importData(
        _ data: Data,
        mode: SettingsBackupExporter.ImportMode = .merge
    ) async throws -> SettingsBackupExporter.ImportResult {
        let backup = try SettingsBackupExporter.parse(data)
        return await SettingsBackupExporter.importBackup(
            backup,
            mode: mode,
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            profileService: profileService,
            promptActionService: promptActionService,
            pluginManager: pluginManager,
            pluginRegistryService: pluginRegistryService,
            historyService: historyService,
            usageStatisticsService: usageStatisticsService,
            userDefaults: userDefaults,
            liveFieldTranscriptEnabledDidChange: liveFieldTranscriptEnabledDidChange,
            cancellationBehaviorDidChange: cancellationBehaviorDidChange,
            indicatorThemeDidChange: indicatorThemeDidChange,
            recoveryRetentionPolicyDidChange: recoveryRetentionPolicyDidChange,
            dictationRecoveryPreferencesDidChange: dictationRecoveryPreferencesDidChange,
            hotkeysDidChange: hotkeysDidChange
        )
    }
}
