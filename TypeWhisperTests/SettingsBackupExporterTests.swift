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
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.pluginsInstalled, 0)
        XCTAssertEqual(result.pluginsSkipped, 1)
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
            userDefaults: destination.userDefaults
        )

        XCTAssertEqual(result.pluginsInstalled, 0)
        XCTAssertEqual(result.pluginsSkipped, 1)
    }
}
