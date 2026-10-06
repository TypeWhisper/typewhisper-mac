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

        let backup = try SettingsBackupExporter.buildBackup(
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

        let backup = try SettingsBackupExporter.buildBackup(
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
            trigger: .app("com.apple.mail"),
            output: WorkflowOutput(autoEnterMode: .duringDictation)
        )
        source.dictionaryService.addEntry(type: .term, original: "Kubernetes")
        source.dictionaryService.addEntry(type: .correction, original: "teh", replacement: "the")
        source.snippetService.addSnippet(trigger: ";sig", replacement: "Best, Alex")

        let backup = try SettingsBackupExporter.buildBackup(
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
        XCTAssertEqual(destination.workflowService.workflows.first?.output.autoEnterMode, .duringDictation)
        XCTAssertEqual(destination.workflowService.workflows.first?.output.autoEnter, false)
        XCTAssertEqual(destination.snippetService.snippets.first?.trigger, ";sig")
    }

    func testRoundTripPreservesSegmentedPostProcessingFlag() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.workflowService.addWorkflow(
            name: "Long Cleanup",
            template: .cleanedText,
            trigger: .manual(),
            behavior: WorkflowBehavior(segmentedPostProcessingEnabled: true)
        )
        source.workflowService.addWorkflow(name: "Summary", template: .summary, trigger: .manual())

        let backup = try SettingsBackupExporter.buildBackup(
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
        // Workflows that keep the default write no new key, so older builds read them unchanged.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(json.components(separatedBy: "segmentedPostProcessingEnabled").count - 1, 1)

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            try SettingsBackupExporter.parse(data),
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

        XCTAssertEqual(result.workflowsImported, 2)
        let imported = Dictionary(uniqueKeysWithValues: destination.workflowService.workflows.map { ($0.name, $0) })
        XCTAssertEqual(imported["Long Cleanup"]?.behavior.segmentedPostProcessingEnabled, true)
        XCTAssertEqual(imported["Long Cleanup"]?.usesSegmentedPostProcessing, true)
        XCTAssertNil(imported["Summary"]?.behavior.segmentedPostProcessingEnabled)
        XCTAssertEqual(imported["Summary"]?.usesSegmentedPostProcessing, false)
    }

    func testImportingWorkflowBackupWithoutSegmentedFlagKeepsItOff() async throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.workflowService.addWorkflow(
            name: "Long Cleanup",
            template: .cleanedText,
            trigger: .manual(),
            behavior: WorkflowBehavior(segmentedPostProcessingEnabled: true)
        )
        let backup = try SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        // Simulate a backup written by a build that predates the field.
        let data = try SettingsBackupExporter.encodedJSON(backup)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var workflows = try XCTUnwrap(root["workflows"] as? [[String: Any]])
        var behavior = try XCTUnwrap(workflows[0]["behavior"] as? [String: Any])
        XCTAssertEqual(behavior.removeValue(forKey: "segmentedPostProcessingEnabled") as? Bool, true)
        workflows[0]["behavior"] = behavior
        root["workflows"] = workflows
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let destination = try makeFixture()
        defer { teardown(destination) }

        let result = await SettingsBackupExporter.importBackup(
            try SettingsBackupExporter.parse(legacyData),
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
        let workflow = try XCTUnwrap(destination.workflowService.workflows.first)
        XCTAssertNil(workflow.behavior.segmentedPostProcessingEnabled)
        XCTAssertFalse(workflow.usesSegmentedPostProcessing)
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

        let backup = try SettingsBackupExporter.buildBackup(
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

        let backup = try SettingsBackupExporter.buildBackup(
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

        let backup = try SettingsBackupExporter.buildBackup(
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

        let backup = try SettingsBackupExporter.buildBackup(
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

        let backup = try SettingsBackupExporter.buildBackup(
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
        let importedRecord = try XCTUnwrap(destination.historyService.recentRecords.first)
        XCTAssertEqual(importedRecord.finalText, "Hello, world.")
        XCTAssertEqual(importedRecord.timestamp.timeIntervalSince1970, originalTimestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(importedRecord.audioFileName)

        // UsageStatisticsService only backfills from history once, at launch, so
        // importing history mid-session must explicitly feed it too, or the
        // Statistics tab silently shows no data for the imported entries.
        XCTAssertTrue(destination.usageStatisticsService.hasAnyStatistics)
    }

    func testCancellationBehaviorBackupCompatibility() async throws {
        let source = try makeFixture()
        defer { teardown(source) }
        let backup = try SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )
        let cases: [(String?, Bool?, CancellationBehavior?)] = [
            ("doubleEscape", nil, .doubleEscape),
            ("singleEscape", nil, .singleEscape),
            ("instant", true, .instant),
            (nil, true, .doubleEscape),
            (nil, false, .singleEscape),
            ("unknown", false, .singleEscape),
            ("unknown", nil, nil),
            (nil, nil, nil)
        ]
        for (rawValue, legacyValue, expected) in cases {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as? [String: Any])
            var preferences: [String: Any] = [:]
            preferences["cancellationBehavior"] = rawValue
            preferences["requireSecondEscapeToCancelRecording"] = legacyValue
            json["preferences"] = preferences
            let decoded = try JSONDecoder().decode(SettingsBackupExporter.SettingsBackup.self, from: JSONSerialization.data(withJSONObject: json))
            let destination = try makeFixture()
            defer { teardown(destination) }
            destination.userDefaults.set("instant", forKey: UserDefaultsKeys.cancellationBehavior)
            var applied: CancellationBehavior?
            let result = await SettingsBackupExporter.importBackup(
                decoded,
                workflowService: destination.workflowService,
                dictionaryService: destination.dictionaryService,
                snippetService: destination.snippetService,
                profileService: destination.profileService,
                promptActionService: destination.promptActionService,
                pluginManager: destination.pluginManager,
                pluginRegistryService: destination.pluginRegistryService,
                historyService: destination.historyService,
                usageStatisticsService: destination.usageStatisticsService,
                userDefaults: destination.userDefaults,
                cancellationBehaviorDidChange: { applied = $0 }
            )
            XCTAssertEqual(applied, expected)
            XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: destination.userDefaults), expected ?? .instant)
            XCTAssertEqual(result.preferencesApplied, expected == nil ? 0 : 1)
        }
    }

    func testNumberNormalizationPreferencesRoundTrip() async throws {
        for minimumValue in [0, 10, 100] {
            let source = try makeFixture()
            let destination = try makeFixture()
            defer { teardown(source); teardown(destination) }
            let enabled = minimumValue == 10
            source.userDefaults.set(enabled, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            source.userDefaults.set(minimumValue, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            let backup = try SettingsBackupExporter.buildBackup(
                workflowService: source.workflowService,
                dictionaryService: source.dictionaryService,
                snippetService: source.snippetService,
                profileService: source.profileService,
                promptActionService: source.promptActionService,
                pluginManager: source.pluginManager,
                historyService: source.historyService,
                userDefaults: source.userDefaults
            )
            let decoded = try SettingsBackupExporter.parse(SettingsBackupExporter.encodedJSON(backup))
            XCTAssertEqual(decoded.preferences.transcriptionNumberNormalizationEnabled, enabled)
            XCTAssertEqual(decoded.preferences.transcriptionNumberNormalizationMinimumValue, minimumValue)
            destination.userDefaults.set(!enabled, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            destination.userDefaults.set(999, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            await SettingsBackupExporter.importBackup(
                decoded,
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
            XCTAssertEqual(destination.userDefaults.bool(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled), enabled)
            XCTAssertEqual(destination.userDefaults.integer(forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue), minimumValue)
            var preferences = SettingsBackupExporter.PreferencesDTO.empty
            preferences.transcriptionNumberNormalizationEnabled = enabled
            preferences.transcriptionNumberNormalizationMinimumValue = minimumValue
            XCTAssertEqual(preferences.nonNilCount, 2)
        }
    }

    func testMissingAndInvalidBackupThresholdsPreserveDestinationPreferences() async throws {
        for minimumValue: Int? in [nil, -1, 3, 999] {
            let destination = try makeFixture()
            defer { teardown(destination) }
            destination.userDefaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
            destination.userDefaults.set(100, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            var preferences = SettingsBackupExporter.PreferencesDTO.empty
            preferences.transcriptionNumberNormalizationMinimumValue = minimumValue
            let backup = SettingsBackupExporter.SettingsBackup(
                schemaVersion: SettingsBackupExporter.schemaVersion,
                exportedAt: Date(), appVersion: "1.0",
                workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
                hotkeys: [:], plugins: [], history: [], updateChannel: nil, preferences: preferences
            )
            // Optional fields are omitted from JSON, matching older settings backups.
            let decoded = try SettingsBackupExporter.parse(SettingsBackupExporter.encodedJSON(backup))
            let result = await SettingsBackupExporter.importBackup(
                decoded,
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
            XCTAssertEqual(result.preferencesApplied, 0)
            XCTAssertFalse(destination.userDefaults.bool(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled))
            XCTAssertEqual(destination.userDefaults.integer(forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue), 100)
        }
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
        source.userDefaults.set("glass", forKey: UserDefaultsKeys.indicatorTheme)
        source.userDefaults.set("instant", forKey: UserDefaultsKeys.cancellationBehavior)
        source.userDefaults.set(false, forKey: UserDefaultsKeys.indicatorVisibleInScreenCaptures)
        source.userDefaults.set(true, forKey: UserDefaultsKeys.liveFieldTranscriptEnabled)
        source.userDefaults.set(true, forKey: UserDefaultsKeys.recorderSystemAudioEnabled)
        source.userDefaults.set(7, forKey: UserDefaultsKeys.dictationRecoveryRetentionDays)
        // Deliberately excluded: engine/model selections must not be exported.
        source.userDefaults.set("com.typewhisper.some-engine", forKey: UserDefaultsKeys.fileTranscriptionEngine)

        let backup = try SettingsBackupExporter.buildBackup(
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
        XCTAssertEqual(backup.preferences.indicatorTheme, "glass")
        XCTAssertEqual(backup.preferences.cancellationBehavior, "instant")
        XCTAssertEqual(backup.preferences.indicatorVisibleInScreenCaptures, false)
        XCTAssertEqual(backup.preferences.liveFieldTranscriptEnabled, true)
        XCTAssertEqual(backup.preferences.recorderSystemAudioEnabled, true)
        XCTAssertEqual(backup.preferences.dictationRecoveryRetentionDays, 7)

        let destination = try makeFixture()
        defer { teardown(destination) }
        var appliedRecoveryRetentionPolicy: DictationRecoveryRetentionPolicy?
        var appliedLiveFieldTranscriptEnabled: Bool?
        var appliedCancellationBehavior: CancellationBehavior?
        var appliedIndicatorTheme: IndicatorTheme?

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
            userDefaults: destination.userDefaults,
            liveFieldTranscriptEnabledDidChange: { appliedLiveFieldTranscriptEnabled = $0 },
            cancellationBehaviorDidChange: { appliedCancellationBehavior = $0 },
            indicatorThemeDidChange: { appliedIndicatorTheme = $0 },
            recoveryRetentionPolicyDidChange: { appliedRecoveryRetentionPolicy = $0 }
        )

        XCTAssertTrue(result.updateChannelApplied)
        XCTAssertGreaterThanOrEqual(result.preferencesApplied, 8)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.updateChannel), AppConstants.ReleaseChannel.daily.rawValue)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.selectedLanguage), "de")
        XCTAssertEqual(destination.userDefaults.bool(forKey: UserDefaultsKeys.translationEnabled), true)
        XCTAssertEqual(destination.userDefaults.bool(forKey: UserDefaultsKeys.showMenuBarIcon), false)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.indicatorStyle), "overlay")
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.indicatorTheme), "glass")
        XCTAssertEqual(appliedIndicatorTheme, .glass)
        XCTAssertEqual(
            destination.userDefaults.object(forKey: UserDefaultsKeys.indicatorVisibleInScreenCaptures) as? Bool,
            false
        )
        XCTAssertEqual(destination.userDefaults.bool(forKey: UserDefaultsKeys.liveFieldTranscriptEnabled), true)
        XCTAssertEqual(appliedLiveFieldTranscriptEnabled, true)
        XCTAssertEqual(appliedCancellationBehavior, .instant)
        XCTAssertEqual(DictationViewModel.loadCancellationBehavior(defaults: destination.userDefaults), .instant)
        XCTAssertEqual(destination.userDefaults.integer(forKey: UserDefaultsKeys.dictationRecoveryRetentionDays), 7)
        XCTAssertEqual(appliedRecoveryRetentionPolicy, .sevenDays)
        XCTAssertNil(destination.userDefaults.string(forKey: UserDefaultsKeys.fileTranscriptionEngine))
    }

    func testUnknownIndicatorThemeInBackupPreservesDestinationTheme() async throws {
        let destination = try makeFixture()
        defer { teardown(destination) }
        destination.userDefaults.set("light", forKey: UserDefaultsKeys.indicatorTheme)
        var preferences = SettingsBackupExporter.PreferencesDTO.empty
        preferences.indicatorTheme = "neon"
        let backup = SettingsBackupExporter.SettingsBackup(
            schemaVersion: SettingsBackupExporter.schemaVersion,
            exportedAt: Date(), appVersion: "1.0",
            workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
            hotkeys: [:], plugins: [], history: [], updateChannel: nil, preferences: preferences
        )
        var appliedIndicatorTheme: IndicatorTheme?

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
            userDefaults: destination.userDefaults,
            indicatorThemeDidChange: { appliedIndicatorTheme = $0 }
        )

        XCTAssertEqual(result.preferencesApplied, 0)
        XCTAssertEqual(destination.userDefaults.string(forKey: UserDefaultsKeys.indicatorTheme), "light")
        XCTAssertNil(appliedIndicatorTheme)
    }

    func testBuildBackupExportsEffectiveRegisteredRecoveryRetentionPolicy() throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.userDefaults.register(defaults: [
            UserDefaultsKeys.dictationRecoveryRetentionDays: DictationRecoveryRetentionPolicy.thirtyDays.rawValue,
        ])
        XCTAssertNil(
            source.userDefaults.persistentDomain(forName: source.suiteName)?[
                UserDefaultsKeys.dictationRecoveryRetentionDays
            ]
        )

        let backup = try SettingsBackupExporter.buildBackup(
            workflowService: source.workflowService,
            dictionaryService: source.dictionaryService,
            snippetService: source.snippetService,
            profileService: source.profileService,
            promptActionService: source.promptActionService,
            pluginManager: source.pluginManager,
            historyService: source.historyService,
            userDefaults: source.userDefaults
        )

        XCTAssertEqual(backup.preferences.dictationRecoveryRetentionDays, 30)
    }

    func testCategoryCountsReflectBackupContents() throws {
        let source = try makeFixture()
        defer { teardown(source) }

        source.workflowService.addWorkflow(name: "Cleanup", template: .cleanedText, trigger: .app("com.apple.mail"))
        source.dictionaryService.addEntry(type: .term, original: "Kubernetes")
        source.userDefaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)
        source.userDefaults.set("de", forKey: UserDefaultsKeys.selectedLanguage)

        let backup = try SettingsBackupExporter.buildBackup(
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
        // The update channel is folded into the Preferences category rather than
        // being its own selectable entry, so it contributes to the preferences count.
        XCTAssertEqual(backup.updateChannel, AppConstants.ReleaseChannel.daily.rawValue)
        // At least selectedLanguage + the update channel; some UserDefaults suites in this environment
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

        let backup = try SettingsBackupExporter.buildBackup(
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

    func testImportNotifiesWhenRecoveryPreferencesWereApplied() async throws {
        func makeBackup(_ configure: (inout SettingsBackupExporter.PreferencesDTO) -> Void) -> SettingsBackupExporter.SettingsBackup {
            var preferences = SettingsBackupExporter.PreferencesDTO.empty
            configure(&preferences)
            return SettingsBackupExporter.SettingsBackup(
                schemaVersion: SettingsBackupExporter.schemaVersion,
                exportedAt: Date(),
                appVersion: "1.0",
                workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
                hotkeys: [:], plugins: [],
                history: [],
                updateChannel: nil,
                preferences: preferences
            )
        }
        let destination = try makeFixture()
        defer { teardown(destination) }

        var notifications = 0
        func importing(_ backup: SettingsBackupExporter.SettingsBackup) async {
            _ = await SettingsBackupExporter.importBackup(
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
                userDefaults: destination.userDefaults,
                dictationRecoveryPreferencesDidChange: { notifications += 1 }
            )
        }

        await importing(makeBackup { _ in })
        XCTAssertEqual(notifications, 0, "no recovery preference in the backup, nothing to reload")

        await importing(makeBackup { $0.dictationRecoveryHedgeThresholdSeconds = 7.5 })
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(destination.userDefaults.double(forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds), 7.5)

        await importing(makeBackup { $0.dictationRecoveryHedgeEnabled = true })
        XCTAssertEqual(notifications, 2)

        await importing(makeBackup { $0.dictationRecoveryRetentionDays = 7 })
        XCTAssertEqual(notifications, 3, "a retention-only import must also reload the view model")
    }

    func testAutomationImportForwardsRecoveryPreferencesReload() async throws {
        // The local HTTP API imports through SettingsBackupAutomationService; it
        // must forward the live-reload callbacks like the settings view does.
        var preferences = SettingsBackupExporter.PreferencesDTO.empty
        preferences.dictationRecoveryHedgeThresholdSeconds = 6.5
        let backup = SettingsBackupExporter.SettingsBackup(
            schemaVersion: SettingsBackupExporter.schemaVersion,
            exportedAt: Date(),
            appVersion: "1.0",
            workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
            hotkeys: [:], plugins: [],
            history: [],
            updateChannel: nil,
            preferences: preferences
        )
        let destination = try makeFixture()
        defer { teardown(destination) }

        var reloads = 0
        let service = SettingsBackupAutomationService(
            workflowService: destination.workflowService,
            dictionaryService: destination.dictionaryService,
            snippetService: destination.snippetService,
            profileService: destination.profileService,
            promptActionService: destination.promptActionService,
            pluginManager: destination.pluginManager,
            pluginRegistryService: destination.pluginRegistryService,
            historyService: destination.historyService,
            usageStatisticsService: destination.usageStatisticsService,
            userDefaults: destination.userDefaults,
            dictationRecoveryPreferencesDidChange: { reloads += 1 }
        )

        _ = try await service.importData(SettingsBackupExporter.encodedJSON(backup))

        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(destination.userDefaults.double(forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds), 6.5)
    }

    func testImportRejectsOutOfRangeHedgeThreshold() async throws {
        // A backup is user-editable JSON; a value the UI could never produce must
        // not reach the hedge timer (1e308 seconds would overflow the sleep).
        func makeBackup(threshold: Double?) -> SettingsBackupExporter.SettingsBackup {
            var preferences = SettingsBackupExporter.PreferencesDTO.empty
            preferences.dictationRecoveryHedgeThresholdSeconds = threshold
            return SettingsBackupExporter.SettingsBackup(
                schemaVersion: SettingsBackupExporter.schemaVersion,
                exportedAt: Date(),
                appVersion: "1.0",
                workflows: [], dictionaryEntries: [], snippets: [], promptActions: [], profiles: [],
                hotkeys: [:], plugins: [],
                history: [],
                updateChannel: nil,
                preferences: preferences
            )
        }

        let destination = try makeFixture()
        defer { teardown(destination) }
        destination.userDefaults.set(4.5, forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds)

        for invalid in [1e308, -1, 0.0, 16, Double.infinity] {
            _ = await SettingsBackupExporter.importBackup(
                makeBackup(threshold: invalid),
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
            XCTAssertEqual(
                destination.userDefaults.double(forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds),
                4.5,
                "threshold \(invalid) must be rejected"
            )
        }

        _ = await SettingsBackupExporter.importBackup(
            makeBackup(threshold: 7.5),
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
        XCTAssertEqual(destination.userDefaults.double(forKey: UserDefaultsKeys.dictationRecoveryHedgeThresholdSeconds), 7.5)
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
        XCTAssertTrue(destination.historyService.recentRecords.isEmpty)
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
        XCTAssertEqual(destination.historyService.recentRecords.first?.finalText, "recent")
    }

    func testProfileImportAppendsRatherThanReusingSourcePriority() async throws {
        let source = try makeFixture()
        defer { teardown(source) }
        source.profileService.addProfile(name: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], priority: 0)

        let backup = try SettingsBackupExporter.buildBackup(
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

        let backup = try SettingsBackupExporter.buildBackup(
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

    // MARK: - Re-import and replace (#1491)

    private func exportBackup(from fixture: Fixture) throws -> SettingsBackupExporter.SettingsBackup {
        let backup = try SettingsBackupExporter.buildBackup(
            workflowService: fixture.workflowService,
            dictionaryService: fixture.dictionaryService,
            snippetService: fixture.snippetService,
            profileService: fixture.profileService,
            promptActionService: fixture.promptActionService,
            pluginManager: fixture.pluginManager,
            historyService: fixture.historyService,
            userDefaults: fixture.userDefaults
        )
        // Round-trip through the file format, which drops fractional seconds.
        return try SettingsBackupExporter.parse(SettingsBackupExporter.encodedJSON(backup))
    }

    private func importBackup(
        _ backup: SettingsBackupExporter.SettingsBackup,
        into fixture: Fixture,
        mode: SettingsBackupExporter.ImportMode = .merge,
        hotkeysDidChange: (() -> Void)? = nil
    ) async -> SettingsBackupExporter.ImportResult {
        await SettingsBackupExporter.importBackup(
            backup,
            mode: mode,
            workflowService: fixture.workflowService,
            dictionaryService: fixture.dictionaryService,
            snippetService: fixture.snippetService,
            profileService: fixture.profileService,
            promptActionService: fixture.promptActionService,
            pluginManager: fixture.pluginManager,
            pluginRegistryService: fixture.pluginRegistryService,
            historyService: fixture.historyService,
            usageStatisticsService: fixture.usageStatisticsService,
            userDefaults: fixture.userDefaults,
            hotkeysDidChange: hotkeysDidChange
        )
    }

    private func editedBackup(
        _ backup: SettingsBackupExporter.SettingsBackup,
        workflows: [SettingsBackupExporter.WorkflowDTO]? = nil,
        promptActions: [SettingsBackupExporter.PromptActionDTO]? = nil,
        profiles: [SettingsBackupExporter.ProfileDTO]? = nil,
        hotkeys: [String: [UnifiedHotkey]]? = nil
    ) -> SettingsBackupExporter.SettingsBackup {
        SettingsBackupExporter.SettingsBackup(
            schemaVersion: backup.schemaVersion,
            exportedAt: backup.exportedAt,
            appVersion: backup.appVersion,
            workflows: workflows ?? backup.workflows,
            dictionaryEntries: backup.dictionaryEntries,
            snippets: backup.snippets,
            promptActions: promptActions ?? backup.promptActions,
            profiles: profiles ?? backup.profiles,
            hotkeys: hotkeys ?? backup.hotkeys,
            plugins: backup.plugins,
            history: backup.history,
            updateChannel: backup.updateChannel,
            preferences: backup.preferences
        )
    }

    private func seedReimportFixture(_ fixture: Fixture) throws -> PromptAction {
        fixture.workflowService.addWorkflow(name: "Email", template: .cleanedText, trigger: .app("com.apple.mail"))
        let action = try XCTUnwrap(fixture.promptActionService.addAction(name: "Summarize", prompt: "Summarize the text"))
        fixture.profileService.addProfile(
            name: "Slack",
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            promptActionId: action.id.uuidString
        )
        fixture.historyService.addRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.75),
            rawText: "helo world",
            finalText: "Hello, world.",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 2,
            language: "en",
            engineUsed: "whisperkit"
        )
        fixture.userDefaults.set(
            try JSONEncoder().encode([UnifiedHotkey(keyCode: 8, modifierFlags: 0x100, isFn: false)]),
            forKey: UserDefaultsKeys.toggleHotkeys
        )
        return action
    }

    func testReimportingBackupOnSameMacChangesNothing() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        let action = try seedReimportFixture(fixture)
        let backup = try exportBackup(from: fixture)

        for mode in [SettingsBackupExporter.ImportMode.merge, .replace] {
            var hotkeysChanged = false
            let result = await importBackup(backup, into: fixture, mode: mode) { hotkeysChanged = true }

            XCTAssertEqual(result.workflowsImported, 0, "\(mode)")
            XCTAssertEqual(result.workflowsUpdated, 0, "\(mode)")
            XCTAssertEqual(result.workflowsSkipped, 1, "\(mode)")
            XCTAssertEqual(result.promptActionsImported, 0, "\(mode)")
            XCTAssertEqual(result.promptActionsSkipped, 1, "\(mode)")
            XCTAssertEqual(result.profilesImported, 0, "\(mode)")
            XCTAssertEqual(result.profilesSkipped, 1, "\(mode)")
            XCTAssertEqual(result.historyImported, 0, "\(mode)")
            XCTAssertEqual(result.historySkippedAsDuplicate, 1, "\(mode)")
            XCTAssertEqual(result.hotkeysApplied, 0, "\(mode)")
            XCTAssertFalse(hotkeysChanged, "\(mode)")
        }

        XCTAssertEqual(fixture.workflowService.workflows.count, 1)
        XCTAssertEqual(fixture.promptActionService.promptActions.filter { !$0.isPreset }.count, 1)
        XCTAssertEqual(fixture.profileService.profiles.count, 1)
        XCTAssertEqual(fixture.profileService.profiles.first?.promptActionId, action.id.uuidString)
        XCTAssertEqual(try fixture.historyService.allRecordsThrowing().count, 1)
    }

    func testHistoryWithSameTextAtDifferentTimeIsStillImported() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        _ = try seedReimportFixture(fixture)
        let backup = try exportBackup(from: fixture)
        let entry = try XCTUnwrap(backup.history.first)
        let laterEntry = SettingsBackupExporter.HistoryEntryDTO(
            timestamp: entry.timestamp.addingTimeInterval(60),
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
        let backupWithLaterEntry = SettingsBackupExporter.SettingsBackup(
            schemaVersion: backup.schemaVersion,
            exportedAt: backup.exportedAt,
            appVersion: backup.appVersion,
            workflows: [],
            dictionaryEntries: [],
            snippets: [],
            promptActions: [],
            profiles: [],
            hotkeys: [:],
            plugins: [],
            history: [entry, laterEntry, laterEntry],
            updateChannel: nil,
            preferences: .empty
        )

        let result = await importBackup(backupWithLaterEntry, into: fixture)

        XCTAssertEqual(result.historyImported, 1)
        XCTAssertEqual(result.historySkippedAsDuplicate, 2)
        XCTAssertEqual(try fixture.historyService.allRecordsThrowing().count, 2)
    }

    func testMergeAddsEditedItemsAndKeepsHotkeysAndEnabledState() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        _ = try seedReimportFixture(fixture)
        let backup = try exportBackup(from: fixture)
        let workflow = try XCTUnwrap(backup.workflows.first)
        let edited = editedBackup(
            backup,
            workflows: [SettingsBackupExporter.WorkflowDTO(
                name: workflow.name,
                isEnabled: workflow.isEnabled,
                sortOrder: workflow.sortOrder,
                template: .summary,
                trigger: workflow.trigger,
                behavior: workflow.behavior,
                output: workflow.output
            )],
            hotkeys: [UserDefaultsKeys.toggleHotkeys: [UnifiedHotkey(keyCode: 9, modifierFlags: 0x200, isFn: false)]]
        )
        // Disabling an item on this Mac after the export doesn't make it a different item.
        let existingWorkflow = try XCTUnwrap(fixture.workflowService.workflows.first)
        fixture.workflowService.toggleWorkflow(existingWorkflow)
        let existingProfile = try XCTUnwrap(fixture.profileService.profiles.first)
        fixture.profileService.toggleProfile(existingProfile)

        let result = await importBackup(edited, into: fixture)

        XCTAssertEqual(result.workflowsImported, 1)
        XCTAssertEqual(result.workflowsSkipped, 0)
        XCTAssertEqual(result.profilesSkipped, 1)
        XCTAssertEqual(result.hotkeysApplied, 0)
        XCTAssertEqual(fixture.workflowService.workflows.map(\.template).sorted { $0.rawValue < $1.rawValue }, [.cleanedText, .summary])
        XCTAssertEqual(fixture.profileService.profiles.map(\.isEnabled), [false])
        let hotkeyData = try XCTUnwrap(fixture.userDefaults.data(forKey: UserDefaultsKeys.toggleHotkeys))
        XCTAssertEqual(
            try JSONDecoder().decode([UnifiedHotkey].self, from: hotkeyData),
            [UnifiedHotkey(keyCode: 8, modifierFlags: 0x100, isFn: false)]
        )
    }

    func testReplaceUpdatesSameNameItemsAndHotkeysWithoutDuplicating() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        let action = try seedReimportFixture(fixture)
        fixture.profileService.addProfile(name: "Other", priority: 5)
        let backup = try exportBackup(from: fixture)
        let slackPriority = try XCTUnwrap(fixture.profileService.profiles.first { $0.name == "Slack" }?.priority)

        let workflow = try XCTUnwrap(backup.workflows.first)
        let promptAction = try XCTUnwrap(backup.promptActions.first)
        let profile = try XCTUnwrap(backup.profiles.first { $0.name == "Slack" })
        let newHotkey = UnifiedHotkey(keyCode: 9, modifierFlags: 0x200, isFn: false)
        let edited = editedBackup(
            backup,
            workflows: [SettingsBackupExporter.WorkflowDTO(
                name: workflow.name,
                isEnabled: false,
                sortOrder: 99,
                template: .summary,
                trigger: .app("com.microsoft.Outlook"),
                behavior: workflow.behavior,
                output: workflow.output
            )],
            promptActions: [SettingsBackupExporter.PromptActionDTO(
                localId: promptAction.localId,
                name: "Summarize briefly",
                prompt: "Summarize in one sentence",
                icon: promptAction.icon,
                isEnabled: promptAction.isEnabled,
                providerType: promptAction.providerType,
                cloudModel: promptAction.cloudModel,
                temperatureModeRaw: promptAction.temperatureModeRaw,
                temperatureValue: promptAction.temperatureValue,
                targetActionPluginId: promptAction.targetActionPluginId
            )],
            profiles: [SettingsBackupExporter.ProfileDTO(
                name: profile.name,
                isEnabled: profile.isEnabled,
                priority: 42,
                bundleIdentifiers: ["com.hnc.Discord"],
                urlPatterns: profile.urlPatterns,
                inputLanguage: "de",
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
            )],
            hotkeys: [
                UserDefaultsKeys.toggleHotkeys: [newHotkey],
                "AppleLanguages": [newHotkey],
            ]
        )

        var hotkeysChanged = false
        let result = await importBackup(edited, into: fixture, mode: .replace) { hotkeysChanged = true }

        XCTAssertEqual(result.workflowsUpdated, 1)
        XCTAssertEqual(result.workflowsImported, 0)
        XCTAssertEqual(result.promptActionsUpdated, 1)
        XCTAssertEqual(result.promptActionsImported, 0)
        XCTAssertEqual(result.profilesUpdated, 1)
        XCTAssertEqual(result.profilesImported, 0)
        XCTAssertEqual(result.hotkeysApplied, 1)
        XCTAssertEqual(result.hotkeysSkipped, 1)
        XCTAssertTrue(hotkeysChanged)

        let updatedWorkflow = try XCTUnwrap(fixture.workflowService.workflows.first)
        XCTAssertEqual(fixture.workflowService.workflows.count, 1)
        XCTAssertEqual(updatedWorkflow.template, .summary)
        XCTAssertEqual(updatedWorkflow.trigger, .app("com.microsoft.Outlook"))
        XCTAssertFalse(updatedWorkflow.isEnabled)
        XCTAssertNotEqual(updatedWorkflow.sortOrder, 99)

        // Matched by its exported id although the name changed.
        let customActions = fixture.promptActionService.promptActions.filter { !$0.isPreset }
        XCTAssertEqual(customActions.map(\.id), [action.id])
        XCTAssertEqual(customActions.first?.name, "Summarize briefly")
        XCTAssertEqual(customActions.first?.prompt, "Summarize in one sentence")

        let updatedProfile = try XCTUnwrap(fixture.profileService.profiles.first { $0.name == "Slack" })
        XCTAssertEqual(fixture.profileService.profiles.count, 2)
        XCTAssertEqual(updatedProfile.bundleIdentifiers, ["com.hnc.Discord"])
        XCTAssertEqual(updatedProfile.inputLanguage, "de")
        XCTAssertEqual(updatedProfile.priority, slackPriority)
        XCTAssertEqual(updatedProfile.promptActionId, action.id.uuidString)

        let hotkeyData = try XCTUnwrap(fixture.userDefaults.data(forKey: UserDefaultsKeys.toggleHotkeys))
        XCTAssertEqual(try JSONDecoder().decode([UnifiedHotkey].self, from: hotkeyData), [newHotkey])
        XCTAssertNil(fixture.userDefaults.data(forKey: "AppleLanguages"))
    }

    func testReplaceUpdatesOnlyOneOfSeveralSameNameWorkflows() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        fixture.workflowService.addWorkflow(name: "Email", template: .cleanedText, trigger: .manual())
        fixture.workflowService.addWorkflow(name: "Email", template: .emailReply, trigger: .manual())
        let backup = try exportBackup(from: fixture)
        let edited = editedBackup(backup, workflows: [SettingsBackupExporter.WorkflowDTO(
            name: "Email",
            isEnabled: true,
            sortOrder: 0,
            template: .summary,
            trigger: .manual(),
            behavior: WorkflowBehavior(),
            output: WorkflowOutput()
        )])

        let result = await importBackup(edited, into: fixture, mode: .replace)

        XCTAssertEqual(result.workflowsUpdated, 1)
        XCTAssertEqual(fixture.workflowService.workflows.count, 2)
        XCTAssertEqual(fixture.workflowService.workflows.filter { $0.template == .summary }.count, 1)
    }

    func testReimportKeepsProfileReferenceToBuiltInPreset() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        fixture.promptActionService.addPreset(PromptAction.presets[0])
        let preset = try XCTUnwrap(fixture.promptActionService.promptActions.first { $0.isPreset })
        fixture.profileService.addProfile(
            name: "Mail",
            bundleIdentifiers: ["com.apple.mail", "com.microsoft.Outlook"],
            promptActionId: preset.id.uuidString
        )
        let backup = try exportBackup(from: fixture)
        XCTAssertTrue(backup.promptActions.isEmpty)
        let profile = try XCTUnwrap(backup.profiles.first)
        // The same apps in another order are still the same profile.
        let reordered = editedBackup(backup, profiles: [SettingsBackupExporter.ProfileDTO(
            name: profile.name,
            isEnabled: profile.isEnabled,
            priority: profile.priority,
            bundleIdentifiers: profile.bundleIdentifiers.reversed(),
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
        )])

        for mode in [SettingsBackupExporter.ImportMode.merge, .replace] {
            let result = await importBackup(reordered, into: fixture, mode: mode)

            XCTAssertEqual(result.profilesSkipped, 1, "\(mode)")
            XCTAssertEqual(fixture.profileService.profiles.count, 1, "\(mode)")
            XCTAssertEqual(fixture.profileService.profiles.first?.promptActionId, preset.id.uuidString, "\(mode)")
        }
    }

    func testReplacePrefersExportedPromptActionIdOverMatchingContent() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        let first = try XCTUnwrap(fixture.promptActionService.addAction(name: "Shorten", prompt: "Shorten the text"))
        let second = try XCTUnwrap(fixture.promptActionService.addAction(name: "Translate", prompt: "Translate to English"))
        let backup = try exportBackup(from: fixture)
        let exportedFirst = try XCTUnwrap(backup.promptActions.first { $0.localId == first.id.uuidString })
        // The first action is edited to look exactly like the second one.
        let edited = editedBackup(backup, promptActions: [SettingsBackupExporter.PromptActionDTO(
            localId: exportedFirst.localId,
            name: second.name,
            prompt: second.prompt,
            icon: second.icon,
            isEnabled: exportedFirst.isEnabled,
            providerType: exportedFirst.providerType,
            cloudModel: exportedFirst.cloudModel,
            temperatureModeRaw: exportedFirst.temperatureModeRaw,
            temperatureValue: exportedFirst.temperatureValue,
            targetActionPluginId: exportedFirst.targetActionPluginId
        )])

        let result = await importBackup(edited, into: fixture, mode: .replace)

        XCTAssertEqual(result.promptActionsUpdated, 1)
        let actions = fixture.promptActionService.promptActions.filter { !$0.isPreset }
        XCTAssertEqual(actions.first { $0.id == first.id }?.prompt, "Translate to English")
        XCTAssertEqual(actions.first { $0.id == second.id }?.prompt, "Translate to English")
        XCTAssertEqual(actions.count, 2)
    }

    func testImportedHotkeyThatConflictsWithAnotherSlotIsSkipped() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        let pttHotkey = UnifiedHotkey(keyCode: 9, modifierFlags: 0x200, isFn: false)
        let toggleHotkey = UnifiedHotkey(keyCode: 8, modifierFlags: 0x100, isFn: false)
        fixture.userDefaults.set(try JSONEncoder().encode([pttHotkey]), forKey: UserDefaultsKeys.pttHotkeys)
        fixture.userDefaults.set(try JSONEncoder().encode([toggleHotkey]), forKey: UserDefaultsKeys.toggleHotkeys)
        let backup = try exportBackup(from: fixture)
        let edited = editedBackup(backup, hotkeys: [
            UserDefaultsKeys.toggleHotkeys: [pttHotkey],
            UserDefaultsKeys.hybridHotkeys: [UnifiedHotkey(keyCode: 5, modifierFlags: 0x100, isFn: false)],
        ])

        let result = await importBackup(edited, into: fixture, mode: .replace)

        XCTAssertEqual(result.hotkeysApplied, 1)
        XCTAssertEqual(result.hotkeysSkipped, 1)
        let toggleData = try XCTUnwrap(fixture.userDefaults.data(forKey: UserDefaultsKeys.toggleHotkeys))
        XCTAssertEqual(try JSONDecoder().decode([UnifiedHotkey].self, from: toggleData), [toggleHotkey])
        XCTAssertNotNil(fixture.userDefaults.data(forKey: UserDefaultsKeys.hybridHotkeys))
    }

    func testDroppedHotkeyDoesNotLeaveAConflictWithItsOldBinding() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        let y = UnifiedHotkey(keyCode: 16, modifierFlags: 0x100, isFn: false)
        let z = UnifiedHotkey(keyCode: 6, modifierFlags: 0x100, isFn: false)
        fixture.userDefaults.set(try JSONEncoder().encode([y]), forKey: UserDefaultsKeys.toggleHotkeys)
        fixture.userDefaults.set(try JSONEncoder().encode([z]), forKey: UserDefaultsKeys.recorderToggleHotkeys)
        let backup = try exportBackup(from: fixture)
        // Toggle=Z collides with the Recorder, so Toggle keeps Y and Hybrid=Y must not be written either.
        let edited = editedBackup(backup, hotkeys: [
            UserDefaultsKeys.toggleHotkeys: [z],
            UserDefaultsKeys.hybridHotkeys: [y],
        ])

        let result = await importBackup(edited, into: fixture, mode: .replace)

        XCTAssertEqual(result.hotkeysApplied, 0)
        XCTAssertEqual(result.hotkeysSkipped, 2)
        XCTAssertNil(fixture.userDefaults.data(forKey: UserDefaultsKeys.hybridHotkeys))
    }

    func testReplaceSwapsHotkeysBetweenSlots() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        let y = UnifiedHotkey(keyCode: 16, modifierFlags: 0x100, isFn: false)
        let z = UnifiedHotkey(keyCode: 6, modifierFlags: 0x100, isFn: false)
        fixture.userDefaults.set(try JSONEncoder().encode([y]), forKey: UserDefaultsKeys.toggleHotkeys)
        fixture.userDefaults.set(try JSONEncoder().encode([z]), forKey: UserDefaultsKeys.pttHotkeys)
        let backup = try exportBackup(from: fixture)
        let edited = editedBackup(backup, hotkeys: [
            UserDefaultsKeys.toggleHotkeys: [z],
            UserDefaultsKeys.pttHotkeys: [y],
        ])

        let result = await importBackup(edited, into: fixture, mode: .replace)

        XCTAssertEqual(result.hotkeysApplied, 2)
        let toggleData = try XCTUnwrap(fixture.userDefaults.data(forKey: UserDefaultsKeys.toggleHotkeys))
        XCTAssertEqual(try JSONDecoder().decode([UnifiedHotkey].self, from: toggleData), [z])
    }

    func testWorkflowWithReorderedAppsIsTheSameWorkflow() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }
        fixture.workflowService.addWorkflow(
            name: "Chat",
            template: .cleanedText,
            trigger: WorkflowTrigger(kind: .app, appBundleIdentifiers: ["com.tinyspeck.slackmacgap", "com.hnc.Discord"])
        )
        let backup = try exportBackup(from: fixture)
        let workflow = try XCTUnwrap(backup.workflows.first)
        let edited = editedBackup(backup, workflows: [SettingsBackupExporter.WorkflowDTO(
            name: workflow.name,
            isEnabled: workflow.isEnabled,
            sortOrder: workflow.sortOrder,
            template: workflow.template,
            trigger: WorkflowTrigger(kind: .app, appBundleIdentifiers: ["com.hnc.Discord", "com.tinyspeck.slackmacgap"]),
            behavior: workflow.behavior,
            output: workflow.output
        )])

        let result = await importBackup(edited, into: fixture)

        XCTAssertEqual(result.workflowsSkipped, 1)
        XCTAssertEqual(fixture.workflowService.workflows.count, 1)
    }
}
