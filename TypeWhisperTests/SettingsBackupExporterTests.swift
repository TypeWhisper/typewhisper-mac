import XCTest
@testable import TypeWhisper
import TypeWhisperPluginSDK

private final class BackupTestPlugin: NSObject, TypeWhisperPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.test.backup-plugin"
    static let pluginName = "Backup Test Plugin"

    func activate(host: HostServices) {}
    func deactivate() {}
}

@MainActor
final class SettingsBackupExporterTests: XCTestCase {

    private struct Fixture {
        let dir: URL
        let workflowService: WorkflowService
        let dictionaryService: DictionaryService
        let snippetService: SnippetService
        let profileService: ProfileService
        let promptActionService: PromptActionService
        let pluginManager: PluginManager
        let pluginRegistryService: PluginRegistryService
        let historyService: HistoryService
        let usageStatisticsService: UsageStatisticsService
        let userDefaults: UserDefaults
        let suiteName: String
    }

    private func makeFixture() throws -> Fixture {
        let dir = try TestSupport.makeTemporaryDirectory()
        let suiteName = "SettingsBackupExporterTests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return Fixture(
            dir: dir,
            workflowService: WorkflowService(appSupportDirectory: dir, userDefaults: userDefaults),
            dictionaryService: DictionaryService(appSupportDirectory: dir),
            snippetService: SnippetService(appSupportDirectory: dir),
            profileService: ProfileService(appSupportDirectory: dir),
            promptActionService: PromptActionService(appSupportDirectory: dir),
            pluginManager: PluginManager(appSupportDirectory: dir),
            pluginRegistryService: PluginRegistryService(
                cacheDirectory: dir.appendingPathComponent("MarketplaceCache", isDirectory: true),
                userDefaults: userDefaults,
                fetchData: { _ in throw URLError(.notConnectedToInternet) }
            ),
            historyService: HistoryService(appSupportDirectory: dir),
            usageStatisticsService: UsageStatisticsService(appSupportDirectory: dir),
            userDefaults: userDefaults,
            suiteName: suiteName
        )
    }

    private func teardown(_ fixture: Fixture) {
        TestSupport.remove(fixture.dir)
        fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName)
    }

    private func makeLoadedPlugin(id: String, name: String, version: String, isEnabled: Bool, bundled: Bool) -> LoadedPlugin {
        LoadedPlugin(
            manifest: PluginManifest(
                id: id,
                name: name,
                version: version,
                principalClass: "BackupTestPlugin"
            ),
            instance: BackupTestPlugin(),
            bundle: Bundle.main,
            sourceURL: bundled ? Bundle.main.builtInPlugInsURL! : URL(fileURLWithPath: "/tmp/\(UUID().uuidString)"),
            isEnabled: isEnabled
        )
    }

    func testBuildBackupExcludesPresetPromptActions() throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }

        fixture.promptActionService.addPreset(PromptAction.presets[0])
        fixture.promptActionService.addAction(name: "Custom", prompt: "Do the thing")

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: fixture.workflowService,
            dictionaryService: fixture.dictionaryService,
            snippetService: fixture.snippetService,
            profileService: fixture.profileService,
            promptActionService: fixture.promptActionService,
            pluginManager: fixture.pluginManager,
            historyService: fixture.historyService,
            userDefaults: fixture.userDefaults
        )

        XCTAssertEqual(backup.promptActions.count, 1)
        XCTAssertEqual(backup.promptActions.first?.name, "Custom")
    }

    func testBuildBackupExcludesBundledPlugins() throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }

        fixture.pluginManager.loadedPlugins = [
            makeLoadedPlugin(id: "com.typewhisper.bundled", name: "Bundled", version: "1.0.0", isEnabled: true, bundled: true),
            makeLoadedPlugin(id: "com.typewhisper.community", name: "Community", version: "2.1.0", isEnabled: false, bundled: false),
        ]

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: fixture.workflowService,
            dictionaryService: fixture.dictionaryService,
            snippetService: fixture.snippetService,
            profileService: fixture.profileService,
            promptActionService: fixture.promptActionService,
            pluginManager: fixture.pluginManager,
            historyService: fixture.historyService,
            userDefaults: fixture.userDefaults
        )

        XCTAssertEqual(backup.plugins.count, 1)
        let plugin = try XCTUnwrap(backup.plugins.first)
        XCTAssertEqual(plugin.id, "com.typewhisper.community")
        XCTAssertEqual(plugin.version, "2.1.0")
        XCTAssertFalse(plugin.wasEnabled)
    }

    func testRoundTripWorkflowsDictionarySnippets() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.workflowService.addWorkflow(
            name: "Cleanup",
            template: .cleanedText,
            trigger: .app("com.apple.mail")
        )
        source.dictionaryService.addEntry(type: .term, original: "Kubernetes")
        source.dictionaryService.addEntry(type: .correction, original: "teh", replacement: "the")
        source.snippetService.addSnippet(trigger: ";sig", replacement: "Best, Alex")

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        let data = try SettingsBackupExporter.encodedJSON(backup)
        let parsed = try SettingsBackupExporter.parse(data)

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            parsed,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.workflowsImported, 1)
        XCTAssertEqual(result.dictionaryImported, 2)
        XCTAssertEqual(result.snippetsImported, 1)
        XCTAssertEqual(destination.workflowService.workflows.first?.name, "Cleanup")
        XCTAssertEqual(destination.snippetService.snippets.first?.trigger, ";sig")
    }

    func testProfilePromptActionIdIsRemappedOnImport() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        let action = try XCTUnwrap(source.promptActionService.addAction(name: "Summarize", prompt: "Summarize the text"))
        source.profileService.addProfile(
            name: "Slack",
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            promptActionId: action.id.uuidString
        )

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.promptActionsImported, 1)
        XCTAssertEqual(result.profilesImported, 1)

        let importedProfile = try XCTUnwrap(destination.profileService.profiles.first)
        let importedAction = try XCTUnwrap(destination.promptActionService.promptActions.first { !$0.isPreset })
        XCTAssertEqual(importedProfile.promptActionId, importedAction.id.uuidString)
        XCTAssertNotEqual(importedProfile.promptActionId, action.id.uuidString)
    }

    func testHotkeyImportOnlyFillsEmptySlots() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        let hotkey = UnifiedHotkey(keyCode: 8, modifierFlags: 0x100, isFn: false)
        source.userDefaults.set(try JSONEncoder().encode([hotkey]), forKey: UserDefaultsKeys.toggleHotkeys)

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )
        XCTAssertEqual(backup.hotkeys[UserDefaultsKeys.toggleHotkeys]?.first, hotkey)

        let destinationEmpty = try makeFixture()
        defer { teardown(destinationEmpty) }
        let emptyResult = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destinationEmpty.workflowService,
            dictionaryService: destinationEmpty.dictionaryService,
            snippetService: destinationEmpty.snippetService,
            profileService: destinationEmpty.profileService,
            promptActionService: destinationEmpty.promptActionService,
            pluginManager: destinationEmpty.pluginManager,
            pluginRegistryService: destinationEmpty.pluginRegistryService,
            historyService: destinationEmpty.historyService,
            usageStatisticsService: destinationEmpty.usageStatisticsService,
            userDefaults: destinationEmpty.userDefaults
        )
        XCTAssertEqual(emptyResult.hotkeysApplied, 1)
        XCTAssertEqual(emptyResult.hotkeysSkipped, 0)
        let importedData = try XCTUnwrap(destinationEmpty.userDefaults.data(forKey: UserDefaultsKeys.toggleHotkeys))
        let importedHotkeys = try JSONDecoder().decode([UnifiedHotkey].self, from: importedData)
        XCTAssertEqual(importedHotkeys.first, hotkey)

        let destinationOccupied = try makeFixture()
        defer { teardown(destinationOccupied) }
        let existingHotkey = UnifiedHotkey(keyCode: 9, modifierFlags: 0x200, isFn: false)
        destinationOccupied.userDefaults.set(
            try JSONEncoder().encode([existingHotkey]),
            forKey: UserDefaultsKeys.toggleHotkeys
        )
        let occupiedResult = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destinationOccupied.workflowService,
            dictionaryService: destinationOccupied.dictionaryService,
            snippetService: destinationOccupied.snippetService,
            profileService: destinationOccupied.profileService,
            promptActionService: destinationOccupied.promptActionService,
            pluginManager: destinationOccupied.pluginManager,
            pluginRegistryService: destinationOccupied.pluginRegistryService,
            historyService: destinationOccupied.historyService,
            usageStatisticsService: destinationOccupied.usageStatisticsService,
            userDefaults: destinationOccupied.userDefaults
        )
        XCTAssertEqual(occupiedResult.hotkeysApplied, 0)
        XCTAssertEqual(occupiedResult.hotkeysSkipped, 1)
        let unchangedData = try XCTUnwrap(destinationOccupied.userDefaults.data(forKey: UserDefaultsKeys.toggleHotkeys))
        let unchangedHotkeys = try JSONDecoder().decode([UnifiedHotkey].self, from: unchangedData)
        XCTAssertEqual(unchangedHotkeys.first, existingHotkey)
    }

    func testImportSkipsPluginNotFoundInRegistry() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.pluginManager.loadedPlugins = [
            makeLoadedPlugin(id: "com.typewhisper.gone", name: "Gone Plugin", version: "1.0.0", isEnabled: true, bundled: false),
        ]

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )
        XCTAssertEqual(backup.plugins.count, 1)

        let destination = try makeFixture()
        defer { teardown(destination) }
        // The mocked pluginRegistryService's fetchData always throws, so fetchRegistry()
        // resolves to an empty registry and the plugin can never be found.
        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.pluginsInstalled, 0)
        XCTAssertEqual(result.pluginsSkipped, 1)
        // The mocked registry fetch always fails, so this must be flagged
        // distinctly from "plugin genuinely removed from the marketplace".
        XCTAssertTrue(result.pluginsRegistryFetchFailed)
    }

    func testImportSkipsPluginAlreadyInstalled() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.pluginManager.loadedPlugins = [
            makeLoadedPlugin(id: "com.typewhisper.already", name: "Already Installed", version: "1.0.0", isEnabled: true, bundled: false),
        ]

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        let destination = try makeFixture()
        defer { teardown(destination) }
        destination.pluginManager.loadedPlugins = [
            makeLoadedPlugin(id: "com.typewhisper.already", name: "Already Installed", version: "1.0.0", isEnabled: false, bundled: false),
        ]

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.pluginsInstalled, 0)
        XCTAssertEqual(result.pluginsSkipped, 1)
    }

    func testHistoryRoundTripPreservesTimestampAndExcludesAudio() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        source.historyService.addRecord(
            timestamp: originalTimestamp,
            rawText: "helo world",
            finalText: "Hello, world.",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 3.5,
            language: "en",
            engineUsed: "whisperkit",
            audioSamples: [0.1, 0.2, 0.3],
            pipelineSteps: ["dictionary", "formatting"]
        )

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        XCTAssertEqual(backup.history.count, 1)
        let entry = try XCTUnwrap(backup.history.first)
        XCTAssertEqual(entry.finalText, "Hello, world.")
        XCTAssertEqual(entry.pipelineSteps, ["dictionary", "formatting"])

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.historyImported, 1)
        let importedRecord = try XCTUnwrap(destination.historyService.records.first)
        XCTAssertEqual(importedRecord.finalText, "Hello, world.")
        XCTAssertEqual(importedRecord.timestamp.timeIntervalSince1970, originalTimestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(importedRecord.audioFileName)

        // UsageStatisticsService only backfills from history once, at launch, so
        // importing history mid-session must explicitly feed it too, or the
        // Statistics tab silently shows no data for the imported entries.
        XCTAssertTrue(destination.usageStatisticsService.hasAnyStatistics)
    }

    func testUpdateChannelAndPreferencesRoundTrip() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.userDefaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)
        source.userDefaults.set("de", forKey: UserDefaultsKeys.selectedLanguage)
        source.userDefaults.set(true, forKey: UserDefaultsKeys.translationEnabled)
        source.userDefaults.set(false, forKey: UserDefaultsKeys.showMenuBarIcon)
        source.userDefaults.set(0.35, forKey: UserDefaultsKeys.audioDuckingLevel)
        source.userDefaults.set(3, forKey: UserDefaultsKeys.indicatorTranscriptPreviewFontSizeOffset)
        source.userDefaults.set("overlay", forKey: UserDefaultsKeys.indicatorStyle)
        source.userDefaults.set(true, forKey: UserDefaultsKeys.recorderSystemAudioEnabled)
        // Deliberately excluded: engine/model selections must not be exported.
        source.userDefaults.set("com.typewhisper.some-engine", forKey: UserDefaultsKeys.fileTranscriptionEngine)

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        XCTAssertEqual(backup.updateChannel, AppConstants.ReleaseChannel.daily.rawValue)
        XCTAssertEqual(backup.preferences.selectedLanguage, "de")
        XCTAssertEqual(backup.preferences.translationEnabled, true)
        XCTAssertEqual(backup.preferences.showMenuBarIcon, false)
        XCTAssertEqual(backup.preferences.audioDuckingLevel, 0.35)
        XCTAssertEqual(backup.preferences.indicatorTranscriptPreviewFontSizeOffset, 3)
        XCTAssertEqual(backup.preferences.indicatorStyle, "overlay")
        XCTAssertEqual(backup.preferences.recorderSystemAudioEnabled, true)

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertTrue(result.updateChannelApplied)
        XCTAssertGreaterThanOrEqual(result.preferencesApplied, 7)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.updateChannel), AppConstants.ReleaseChannel.daily.rawValue)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.selectedLanguage), "de")
        XCTAssertEqual(destination.userDefaults.bool(forKey: UserDefaultsKeys.translationEnabled), true)
        XCTAssertEqual(destination.userDefaults.bool(forKey: UserDefaultsKeys.showMenuBarIcon), false)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.indicatorStyle), "overlay")
        XCTAssertNil(destination.userDefaults.string(forKey: UserDefaultsKeys.fileTranscriptionEngine))
    }

    func testCategoryCountsReflectBackupContents() throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.workflowService.addWorkflow(name: "Cleanup", template: .cleanedText, trigger: .app("com.apple.mail"))
        source.dictionaryService.addEntry(type: .term, original: "Kubernetes")
        source.userDefaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)
        source.userDefaults.set("de", forKey: UserDefaultsKeys.selectedLanguage)

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        XCTAssertEqual(SettingsBackupExporter.Category.count(.workflows, in: backup), 1)
        XCTAssertEqual(SettingsBackupExporter.Category.count(.dictionary, in: backup), 1)
        XCTAssertEqual(SettingsBackupExporter.Category.count(.snippets, in: backup), 0)
        XCTAssertEqual(SettingsBackupExporter.Category.count(.updateChannel, in: backup), 1)
        // At least selectedLanguage; some UserDefaults suites in this environment
        // also surface a non-nil dockIconBehaviorWhenMenuBarHidden by default (see
        // testUpdateChannelAndPreferencesRoundTrip), so this isn't pinned to 1.
        XCTAssertGreaterThanOrEqual(SettingsBackupExporter.Category.count(.preferences, in: backup), 1)
        XCTAssertEqual(SettingsBackupExporter.Category.count(.history, in: backup), 0)
    }

    func testFilteredOnlyImportsSelectedCategories() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.workflowService.addWorkflow(name: "Cleanup", template: .cleanedText, trigger: .app("com.apple.mail"))
        source.dictionaryService.addEntry(type: .term, original: "Kubernetes")
        source.snippetService.addSnippet(trigger: ";sig", replacement: "Best, Alex")
        source.userDefaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        let filtered = SettingsBackupExporter.filtered(backup, to: [.workflows])
        XCTAssertEqual(filtered.workflows.count, 1)
        XCTAssertEqual(filtered.dictionaryEntries.count, 0)
        XCTAssertEqual(filtered.snippets.count, 0)
        XCTAssertNil(filtered.updateChannel)

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            filtered,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.workflowsImported, 1)
        XCTAssertEqual(result.dictionaryImported, 0)
        XCTAssertEqual(result.snippetsImported, 0)
        XCTAssertFalse(result.updateChannelApplied)
    }

    func testUsageStatisticsNotRecordedWhenHistoryRecordSkipped() async throws {
        // rawText/finalText of only NUL characters sanitizes to an empty
        // string in HistoryService, so addRecord silently declines to insert
        // it — usage statistics must not be recorded for it either.
        let backup = SettingsBackupExporter.SettingsBackup(
            schemaVersion: SettingsBackupExporter.schemaVersion,
            exportedAt: Date(),
            appVersion: "1.0",
            workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
            hotkeys: [:], plugins: [],
            history: [
                SettingsBackupExporter.HistoryEntryDTO(
                    timestamp: Date(),
                    rawText: "\0",
                    finalText: "\0",
                    appName: nil,
                    appBundleIdentifier: nil,
                    appURL: nil,
                    durationSeconds: 1,
                    language: nil,
                    engineUsed: "whisperkit",
                    modelUsed: nil,
                    pipelineSteps: []
                ),
            ],
            updateChannel: nil,
            preferences: .empty
        )

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.historyImported, 0)
        XCTAssertTrue(destination.historyService.records.isEmpty)
        XCTAssertFalse(destination.usageStatisticsService.hasAnyStatistics)
    }

    func testHistoryImportSkipsEntriesOlderThanRetentionWindow() async throws {
        let oldTimestamp = Calendar.current.date(byAdding: .day, value: -400, to: Date())!
        let recentTimestamp = Date()
        let backup = SettingsBackupExporter.SettingsBackup(
            schemaVersion: SettingsBackupExporter.schemaVersion,
            exportedAt: Date(),
            appVersion: "1.0",
            workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
            hotkeys: [:], plugins: [],
            history: [
                SettingsBackupExporter.HistoryEntryDTO(
                    timestamp: oldTimestamp, rawText: "old", finalText: "old",
                    appName: nil, appBundleIdentifier: nil, appURL: nil,
                    durationSeconds: 1, language: nil, engineUsed: "whisperkit", modelUsed: nil, pipelineSteps: []
                ),
                SettingsBackupExporter.HistoryEntryDTO(
                    timestamp: recentTimestamp, rawText: "recent", finalText: "recent",
                    appName: nil, appBundleIdentifier: nil, appURL: nil,
                    durationSeconds: 1, language: nil, engineUsed: "whisperkit", modelUsed: nil, pipelineSteps: []
                ),
            ],
            updateChannel: nil,
            preferences: .empty
        )

        let destination = try makeFixture()
        defer { teardown(destination) }
        destination.userDefaults.set(30, forKey: UserDefaultsKeys.historyRetentionDays)

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.historyImported, 1)
        XCTAssertEqual(result.historySkippedByRetention, 1)
        XCTAssertEqual(destination.historyService.records.first?.finalText, "recent")
    }

    func testProfileImportAppendsRatherThanReusingSourcePriority() async throws {
        let source = try makeFixture()
        defer { teardown(source) }
        source.profileService.addProfile(name: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], priority: 0)

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )
        XCTAssertEqual(backup.profiles.first?.priority, 0)

        let destination = try makeFixture()
        defer { teardown(destination) }
        destination.profileService.addProfile(name: "Existing", bundleIdentifiers: ["com.apple.Notes"], priority: 0)

        let result = await SettingsBackupExporter.importBackup(
            backup,
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.profilesImported, 1)
        let imported = try XCTUnwrap(destination.profileService.profiles.first { $0.name == "Slack" })
        let existing = try XCTUnwrap(destination.profileService.profiles.first { $0.name == "Existing" })
        // Must not collide with the destination's existing priority-0 profile.
        XCTAssertNotEqual(imported.priority, existing.priority)
    }

    func testFilteredAutoIncludesReferencedPromptActionAndPlugin() throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.pluginManager.loadedPlugins = [
            makeLoadedPlugin(id: "com.typewhisper.action-plugin", name: "Action Plugin", version: "1.0.0", isEnabled: true, bundled: false),
        ]
        let action = try XCTUnwrap(source.promptActionService.addAction(
            name: "Summarize",
            prompt: "Summarize the text",
            targetActionPluginId: "com.typewhisper.action-plugin"
        ))
        source.profileService.addProfile(
            name: "Slack",
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            promptActionId: action.id.uuidString
        )

        let backup = SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )
        XCTAssertEqual(backup.promptActions.count, 1)
        XCTAssertEqual(backup.plugins.count, 1)

        // Only "Profiles" selected — neither Prompt Actions nor Plugins.
        let filtered = SettingsBackupExporter.filtered(backup, to: [.profiles])
        XCTAssertEqual(filtered.profiles.count, 1)
        XCTAssertEqual(filtered.promptActions.count, 1, "the profile's referenced prompt action should be auto-included")
        XCTAssertEqual(filtered.plugins.count, 1, "the plugin referenced by the auto-included prompt action should be auto-included")

        // Deselecting Profiles entirely drops the chain again.
        let filteredNoProfiles = SettingsBackupExporter.filtered(backup, to: [])
        XCTAssertEqual(filteredNoProfiles.profiles.count, 0)
        XCTAssertEqual(filteredNoProfiles.promptActions.count, 0)
        XCTAssertEqual(filteredNoProfiles.plugins.count, 0)
    }
}
