import AppKit
import Combine
import SwiftUI
import TypeWhisperModuleKit
import XCTest
@testable import TypeWhisper

/// The app's side of the module interface, exercised through a test module.
@MainActor
final class ModuleHostTests: XCTestCase {
    // MARK: - Contributions

    func testContributionsOfALaterModuleSkipIdentifiersAnEarlierOneUses() {
        TestModulesEntry.modules = [
            TestModule(identifier: "test.first", contributions: TestModule.contributions(prefix: "shared")),
            TestModule(identifier: "test.second", contributions: TestModule.contributions(prefix: "shared")),
            TestModule(identifier: "test.third", contributions: TestModule.contributions(prefix: "third")),
        ]
        defer { TestModulesEntry.modules = [] }

        let registry = ModuleRegistry(entry: TestModulesEntry.self, host: AppModuleHost())

        let contributions = registry.contributions
        XCTAssertEqual(contributions.hotkeyActions.map(\.id), ["shared.hotkey", "third.hotkey"])
        XCTAssertEqual(contributions.menuItems.map(\.id), ["shared.menu", "third.menu"])
        XCTAssertEqual(contributions.panels.map(\.id), ["shared.panel", "third.panel"])
        XCTAssertEqual(contributions.recordActions.map(\.id), ["shared.record", "third.record"])
        XCTAssertEqual(contributions.premiumCards.map(\.id), ["shared.card", "third.card"])
    }

    func testHotkeyActionRunsThroughTheRegistry() {
        let performed = Log()
        TestModulesEntry.modules = [TestModule(identifier: "test", contributions: ModuleContributions(
            hotkeyActions: [
                ModuleHotkeyAction(id: "test.open", title: "Open") { performed.items.append("test.open") },
                // Its shortcuts could not be stored or restored from a backup.
                ModuleHotkeyAction(id: "test/open", title: "Invalid") { performed.items.append("test/open") },
            ]
        ))]
        defer { TestModulesEntry.modules = [] }
        let registry = ModuleRegistry(entry: TestModulesEntry.self, host: AppModuleHost())

        registry.performHotkeyAction(withID: "test.open")
        registry.performHotkeyAction(withID: "test.unknown")

        XCTAssertEqual(performed.items, ["test.open"])
        XCTAssertEqual(registry.contributions.hotkeyActions.map(\.id), ["test.open"])
        XCTAssertEqual(registry.hotkeyAction(withID: "test.open")?.title, "Open")
    }

    func testMenuEntriesOfModulesFollowHistory() {
        XCTAssertEqual(
            MenuBarMenuSection.general.items(hasRecoverableRecording: true, moduleItemIDs: ["test.menu"]),
            [.settings, .history, .askHistory, .module("test.menu"), .errorLog]
        )
        XCTAssertEqual(
            MenuBarMenuSection.general.items(hasRecoverableRecording: true),
            [.settings, .history, .askHistory, .errorLog]
        )
    }

    func testPanelShowsHidesAndReportsBoth() {
        let events = Log()
        let host = AppModuleHost()
        TestModulesEntry.modules = [TestModule(identifier: "test", contributions: ModuleContributions(panels: [
            ModulePanel(
                id: "test.panel",
                title: "Test Panel",
                makeContent: { AnyView(Text("Panel").frame(width: 200, height: 100)) },
                didShow: { events.items.append("show") },
                didHide: { events.items.append("hide") }
            ),
        ]))]
        defer { TestModulesEntry.modules = [] }
        _ = ModuleRegistry(entry: TestModulesEntry.self, host: host)

        host.togglePanel(withID: "test.panel")
        XCTAssertTrue(host.isPanelVisible(withID: "test.panel"))
        host.togglePanel(withID: "test.panel")
        XCTAssertFalse(host.isPanelVisible(withID: "test.panel"))
        host.hidePanel(withID: "test.panel")
        host.showPanel(withID: "test.unknown")

        XCTAssertEqual(events.items, ["show", "hide"])
        XCTAssertFalse(host.isPanelVisible(withID: "test.unknown"))
    }

    // MARK: - Hotkey actions

    func testModuleHotkeyActionsKeepTheirShortcutsAndFireOnKeyDown() throws {
        let ids = ["test.first", "test.second"]
        clearModuleHotkeys(ids)
        defer { clearModuleHotkeys(ids) }
        let service = HotkeyService()
        service.suspendMonitoring()
        service.registerModuleHotkeyActions(ids)
        var fired: [String] = []
        service.onModuleHotkeyAction = { fired.append($0) }

        service.setHotkeys([commandShiftK], forModuleAction: "test.first")
        service.setHotkeys([commandShiftL], forModuleAction: "test.second")
        // A shortcut one action takes leaves the other.
        service.setHotkeys([commandShiftK, commandShiftL], forModuleAction: "test.first")

        XCTAssertEqual(service.hotkeys(forModuleAction: "test.first"), [commandShiftK, commandShiftL])
        XCTAssertEqual(service.hotkeys(forModuleAction: "test.second"), [])
        // Every row rereads its shortcuts, also the one that lost one.
        let revision = service.moduleActionHotkeysRevision
        service.removeConflictingHotkey(commandShiftL, for: .moduleAction)
        XCTAssertNotEqual(service.moduleActionHotkeysRevision, revision)
        service.setHotkeys([commandShiftK, commandShiftL], forModuleAction: "test.first")
        XCTAssertEqual(service.moduleAction(assignedTo: commandShiftL), "test.first")
        XCTAssertEqual(service.isHotkeyAssignedToGlobalSlot(commandShiftK), .moduleAction)

        let keyDown = try keyboardEvent(keyCode: 0x28, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(fired, ["test.first"])
        XCTAssertNil(service.currentMode)
    }

    func testASlotThatTakesAModuleShortcutRemovesItFromTheAction() {
        let ids = ["test.first"]
        clearModuleHotkeys(ids)
        defer { clearModuleHotkeys(ids) }
        let service = HotkeyService()
        service.suspendMonitoring()
        service.registerModuleHotkeyActions(ids)
        service.setHotkeys([commandShiftK, commandShiftL], forModuleAction: "test.first")

        service.removeConflictingHotkey(commandShiftK, for: .moduleAction)

        XCTAssertEqual(service.hotkeys(forModuleAction: "test.first"), [commandShiftL])
        XCTAssertNil(service.moduleAction(assignedTo: commandShiftK))
    }

    func testShortcutsOfActionsThatAreNotRegisteredStayStoredButUnarmed() {
        let ids = ["test.absent"]
        clearModuleHotkeys(ids)
        defer { clearModuleHotkeys(ids) }
        let service = HotkeyService()
        service.suspendMonitoring()
        service.registerModuleHotkeyActions(ids)
        service.setHotkeys([commandShiftK], forModuleAction: "test.absent")

        service.registerModuleHotkeyActions([])

        XCTAssertNil(service.moduleAction(assignedTo: commandShiftK))
        XCTAssertNil(service.isHotkeyAssignedToGlobalSlot(commandShiftK))
        XCTAssertEqual(service.hotkeys(forModuleAction: "test.absent"), [commandShiftK])

        // A slot that took the shortcut meanwhile keeps it when the action returns.
        service.setHotkeysForTesting([commandShiftK], for: .toggle)
        service.registerModuleHotkeyActions(ids)
        XCTAssertNil(service.moduleAction(assignedTo: commandShiftK))
        XCTAssertEqual(service.isHotkeyAssignedToGlobalSlot(commandShiftK), .toggle)
    }

    func testShortcutHeldByASlotStaysStoredAndReturnsWhenTheSlotLetsGo() {
        let ids = ["test.first", "test.second"]
        clearModuleHotkeys(ids)
        let toggleKeys = [UserDefaultsKeys.toggleHotkey, UserDefaultsKeys.toggleHotkeys]
        let savedToggle = toggleKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            clearModuleHotkeys(ids)
            for (key, value) in zip(toggleKeys, savedToggle) { UserDefaults.standard.set(value, forKey: key) }
        }
        let service = HotkeyService()
        service.suspendMonitoring()
        UserDefaults.standard.set(try? JSONEncoder().encode([commandShiftK]), forKey: HotkeyService.moduleActionDefaultsKey(for: "test.first"))
        service.setHotkeysForTesting([commandShiftK], for: .toggle)
        service.registerModuleHotkeyActions(ids)
        service.setHotkeys([commandShiftL], forModuleAction: "test.second")

        // Another slot takes L: the first action keeps its hidden K.
        service.removeConflictingHotkey(commandShiftL, for: .moduleAction)
        XCTAssertEqual(service.hotkeys(forModuleAction: "test.first"), [commandShiftK])
        XCTAssertEqual(service.hotkeys(forModuleAction: "test.second"), [])

        // Toggle lets K go: the first action's K is armed again.
        service.clearHotkey(for: .toggle)
        XCTAssertEqual(service.moduleAction(assignedTo: commandShiftK), "test.first")

        // A workflow that has K keeps it, also when it registers after the modules.
        service.registerWorkflowHotkeys([(id: UUID(), hotkey: commandShiftK, behavior: .startDictation)])
        XCTAssertNil(service.moduleAction(assignedTo: commandShiftK))
        service.registerWorkflowHotkeys([])
        XCTAssertEqual(service.moduleAction(assignedTo: commandShiftK), "test.first")
    }

    func testSettingsBackupAcceptsModuleShortcutKeys() {
        XCTAssertTrue(SettingsBackupExporter.isHotkeyKey(UserDefaultsKeys.toggleHotkeys))
        XCTAssertTrue(SettingsBackupExporter.isHotkeyKey("moduleHotkeys.com.example.open-panel_1"))
        XCTAssertFalse(SettingsBackupExporter.isHotkeyKey("moduleHotkeys."))
        XCTAssertFalse(SettingsBackupExporter.isHotkeyKey("moduleHotkeys.a/b"))
        XCTAssertFalse(SettingsBackupExporter.isHotkeyKey("selectedEngine"))
    }

    // MARK: - Managed settings

    func testModuleKeysAreValidatedAndReportedLikeTheAppsOwn() throws {
        TestModulesEntry.modules = [TestModule(identifier: "test", contributions: ModuleContributions(managedPolicyKeys: [
            ModuleManagedPolicyKey(name: "AllowTestFeature", kind: .boolean, allowsRecommendation: true),
            ModuleManagedPolicyKey(name: "TestMode", kind: .enumeration, enumerationMaximum: 2),
            ModuleManagedPolicyKey(name: "TestSecret", kind: .text, sensitive: true),
            ModuleManagedPolicyKey(name: "TestSites", kind: .list),
            ModuleManagedPolicyKey(name: "TestHiddenSwitch", kind: .boolean, sensitive: true),
            // The app's key and profile metadata stay the app's.
            ModuleManagedPolicyKey(name: "AllowCloudTranscription", kind: .text),
            ModuleManagedPolicyKey(name: "PayloadTest", kind: .boolean),
        ]))]
        defer {
            TestModulesEntry.modules = []
            ManagedPolicyKeys.setModuleDefinitions([])
        }
        let registry = ModuleRegistry(entry: TestModulesEntry.self, host: AppModuleHost())

        registry.registerManagedPolicyKeys()

        XCTAssertEqual(
            ManagedPolicyKeys.moduleDefinitions.map(\.name),
            ["AllowTestFeature", "TestMode", "TestSecret", "TestSites", "TestHiddenSwitch"]
        )
        XCTAssertEqual(ManagedPolicyKeys.definition(named: "AllowCloudTranscription")?.kind, .boolean)
        XCTAssertEqual(ManagedPolicyKeys.definition(named: "TestMode")?.enumerationMaximum, 2)

        let snapshot = ManagedPolicyValidator.validate(
            ManagedPolicyRawReading(forcedValues: [
                "AllowTestFeature": .boolean(false),
                "TestMode": .integer(3),
                "TestSecret": .string("fixture-secret"),
                "TestSites": .array([.string("example.com")]),
                "TestHiddenSwitch": .boolean(true),
                "Recommended": .dictionary(["AllowTestFeature": .boolean(true), "TestSites": .array([])]),
            ]),
            revision: 1,
            readAt: Date()
        )
        XCTAssertEqual(snapshot.status, .present)
        XCTAssertEqual(snapshot.enforced("AllowTestFeature"), .boolean(false))
        XCTAssertEqual(snapshot.recommended("AllowTestFeature"), .boolean(true))
        XCTAssertNil(snapshot.recommended("TestSites"))
        XCTAssertTrue(snapshot.isBlocked("TestMode"))
        XCTAssertEqual(snapshot.enforced("TestSites"), .list(["example.com"]))
        XCTAssertTrue(snapshot.issues.contains { $0.key == "TestSites" && $0.scope == .recommended })

        let diagnostics = ManagedPolicyDiagnostics(snapshot: snapshot)
        XCTAssertEqual(diagnostics.enforced.first { $0.name == "TestSecret" }?.value, "[set]")
        XCTAssertEqual(diagnostics.enforced.first { $0.name == "AllowTestFeature" }?.value, "false")
        XCTAssertEqual(diagnostics.enforced.first { $0.name == "TestHiddenSwitch" }?.value, "[set]")
        let encoded = String(decoding: try JSONEncoder().encode(diagnostics), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-secret"))
    }

    func testModuleReadsOnlyTheKeysModulesDeclared() {
        ManagedPolicyKeys.setModuleDefinitions([
            ManagedPolicyDefinition(ModuleManagedPolicyKey(name: "AllowTestFeature", kind: .boolean)),
        ])
        defer { ManagedPolicyKeys.setModuleDefinitions([]) }
        let source = TestPolicySource(ManagedPolicyRawReading(forcedValues: [
            "AllowTestFeature": .boolean(false),
            "AllowCloudTranscription": .boolean(false),
        ]))
        let service = ManagedPolicyService(source: source)
        let reading = AppModuleManagedPolicyReading(service: service)

        reading.refresh()

        XCTAssertEqual(reading.state(ofKey: "AllowTestFeature"), ModuleManagedPolicyState(enforced: .boolean(false)))
        XCTAssertFalse(reading.state(ofKey: "AllowTestFeature").booleanValue(default: true))
        XCTAssertEqual(reading.state(ofKey: "AllowCloudTranscription"), ModuleManagedPolicyState())

        source.reading = ManagedPolicyRawReading(forcedValues: ["AllowTestFeature": .integer(1)])
        let changed = expectation(description: "change")
        let observation = reading.observeChanges { changed.fulfill() }
        reading.refresh()
        wait(for: [changed], timeout: 2)
        observation.cancel()
        XCTAssertTrue(reading.state(ofKey: "AllowTestFeature").isBlocked)
    }

    func testModuleReadsAnAppKeyItDeclaresWithTheSameKind() {
        let skipped = ManagedPolicyKeys.setModuleDefinitions([
            ManagedPolicyDefinition(ModuleManagedPolicyKey(name: "AllowCloudTranscription", kind: .boolean)),
            ManagedPolicyDefinition(ModuleManagedPolicyKey(name: "UpdateMode", kind: .text)),
            ManagedPolicyDefinition(ModuleManagedPolicyKey(name: "allowCloudTextProcessing", kind: .boolean)),
        ])
        defer { ManagedPolicyKeys.setModuleDefinitions([]) }
        let source = TestPolicySource(ManagedPolicyRawReading(forcedValues: [
            "AllowCloudTranscription": .boolean(false),
            "UpdateMode": .integer(1),
        ]))
        let reading = AppModuleManagedPolicyReading(service: ManagedPolicyService(source: source))

        reading.refresh()

        // Another kind or another spelling stays the app's alone.
        XCTAssertEqual(skipped, ["UpdateMode", "allowCloudTextProcessing"])
        XCTAssertEqual(reading.state(ofKey: "AllowCloudTranscription"), ModuleManagedPolicyState(enforced: .boolean(false)))
        XCTAssertEqual(reading.state(ofKey: "UpdateMode"), ModuleManagedPolicyState())
        // The app keeps its own definition, once.
        XCTAssertTrue(ManagedPolicyKeys.moduleDefinitions.isEmpty)
        XCTAssertEqual(ManagedPolicyKeys.all.filter { $0.name == "AllowCloudTranscription" }.count, 1)
    }

    // MARK: - Premium access

    func testPremiumAccessReportsOnlyRealChanges() {
        let hasAccess = Flag(false)
        let changes = PassthroughSubject<Void, Never>()
        var shown = 0
        let reading = AppPremiumAccessReading(
            hasAccess: { hasAccess.value },
            accessChanges: changes.eraseToAnyPublisher(),
            showAccess: { shown += 1 }
        )
        var reported: [Bool] = []
        let observation = reading.observeChanges { reported.append($0) }

        changes.send()
        hasAccess.value = true
        changes.send()
        changes.send()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        reading.showPremiumAccess()

        XCTAssertTrue(reading.hasPremiumAccess)
        XCTAssertEqual(reported, [true])
        XCTAssertEqual(shown, 1)
        observation.cancel()
    }

    // MARK: - User data

    func testUserDataIsErasedAndExportedPerModule() async throws {
        let lifecycle = AppModuleUserDataLifecycle()
        let erased = Log()
        lifecycle.register(ModuleUserData(
            id: "com.example.first",
            erase: { erased.items.append("first") },
            export: { ["consents.json": Data("[]".utf8), "Meeting Notes.txt": Data(), "../escape.txt": Data(), "..": Data()] }
        ))
        lifecycle.register(ModuleUserData(
            id: "com.example.second",
            erase: { throw CocoaError(.fileWriteNoPermission) },
            export: { [:] }
        ))
        lifecycle.register(ModuleUserData(id: "../outside", erase: {}, export: { ["a.txt": Data()] }))

        let failures = await lifecycle.eraseAll()
        let files = try await lifecycle.exportFiles()

        XCTAssertEqual(erased.items, ["first"])
        XCTAssertEqual(failures.map(\.item), ["com.example.second"])
        XCTAssertEqual(
            Set(files.keys),
            ["Modules/com.example.first/consents.json", "Modules/com.example.first/Meeting Notes.txt"]
        )

        lifecycle.register(ModuleUserData(
            id: "com.example.first",
            erase: {},
            export: { ["state.json": Data(), "STATE.json": Data()] }
        ))
        do {
            _ = try await lifecycle.exportFiles()
            XCTFail("Two names that differ only in case share one file")
        } catch UserDataExportService.ExportError.duplicateModuleFile {
        }

        // Also across modules whose identifiers differ only in case.
        let modules = AppModuleUserDataLifecycle()
        modules.register(ModuleUserData(id: "com.example.notes", erase: {}, export: { ["state.json": Data()] }))
        modules.register(ModuleUserData(id: "com.example.Notes", erase: {}, export: { ["state.json": Data()] }))
        do {
            _ = try await modules.exportFiles()
            XCTFail("Two modules' folders that differ only in case share one folder")
        } catch UserDataExportService.ExportError.duplicateModuleFile {
        }
    }

    // MARK: - History sidebar groups

    func testStubBuildShowsNoHistorySidebarGroup() throws {
        let registry = ModuleRegistry(host: AppModuleHost())
        let fixture = try HistorySidebarFixture()
        defer { fixture.remove() }

        fixture.viewModel.setModuleSidebarGroups(registry.contributions.historySidebarGroups)
        fixture.viewModel.activate()

        XCTAssertTrue(registry.contributions.historySidebarGroups.isEmpty)
        XCTAssertTrue(fixture.viewModel.moduleGroups.isEmpty)
    }

    func testHistorySidebarGroupShowsEntriesNewestFirstAndFollowsChanges() throws {
        let store = TestSidebarStore()
        TestModulesEntry.modules = [
            TestModule(identifier: "test.first", contributions: ModuleContributions(historySidebarGroups: [store.group()])),
            TestModule(identifier: "test.second", contributions: ModuleContributions(historySidebarGroups: [
                TestSidebarStore().group(), TestSidebarStore().group(id: "test.other"),
            ])),
        ]
        defer { TestModulesEntry.modules = [] }
        let registry = ModuleRegistry(entry: TestModulesEntry.self, host: AppModuleHost())
        XCTAssertEqual(registry.contributions.historySidebarGroups.map(\.id), ["test.group", "test.other"])

        let fixture = try HistorySidebarFixture()
        defer { fixture.remove() }
        let viewModel = fixture.viewModel
        store.entries = [store.entry("old", daysAgo: 3), store.entry("new", daysAgo: 0), store.entry("mid", daysAgo: 1)]
        viewModel.setModuleSidebarGroups([store.group()])

        // Nothing is read before History opens.
        XCTAssertTrue(viewModel.moduleGroups.isEmpty)
        XCTAssertEqual(store.entryReads, 0)

        viewModel.activate()
        XCTAssertEqual(viewModel.moduleGroups.map(\.id), ["test.group"])
        XCTAssertEqual(viewModel.moduleGroups.first?.entries.map(\.id), ["new", "mid", "old"])

        store.entries.append(store.entry("newest", daysAgo: -1))
        store.changed()
        XCTAssertEqual(viewModel.moduleGroups.first?.entries.map(\.id), ["newest", "new", "mid", "old"])

        viewModel.requestNavigationSelection(.moduleGroup("test.group"))
        viewModel.requestModuleEntrySelection("mid")
        XCTAssertEqual(viewModel.navigationTitle, "Notes")
        XCTAssertEqual(viewModel.moduleEntryContent?.id, "mid")
        XCTAssertEqual(store.madeContent, ["mid"])

        // An entry the module no longer lists is no longer selected.
        store.entries.removeAll { $0.id == "mid" }
        store.changed()
        XCTAssertNil(viewModel.selectedModuleEntryID)
        XCTAssertNil(viewModel.moduleEntryContent)

        // A hidden group leaves the sidebar, and History shows all records again.
        store.isVisible = false
        store.changed()
        XCTAssertTrue(viewModel.moduleGroups.isEmpty)
        XCTAssertEqual(viewModel.navigationSelection, .smartMailbox(.all))
        XCTAssertEqual(viewModel.filteredRecords.count, 1)

        store.isVisible = true
        store.changed()
        XCTAssertEqual(viewModel.moduleGroups.map(\.id), ["test.group"])
    }

    func testSearchFieldFiltersTheEntriesOfTheSelectedGroup() throws {
        let store = TestSidebarStore()
        store.entries = [
            ModuleHistorySidebarEntry(id: "a", title: "Café budget", subtitle: "Second quarter", date: Date()),
            ModuleHistorySidebarEntry(id: "b", title: "Hiring plan", subtitle: "Budget for two roles", date: Date(timeIntervalSinceNow: -60)),
            ModuleHistorySidebarEntry(id: "c", title: "Travel", subtitle: nil, date: Date(timeIntervalSinceNow: -120)),
        ]
        let fixture = try HistorySidebarFixture()
        defer { fixture.remove() }
        let viewModel = fixture.viewModel
        viewModel.setModuleSidebarGroups([store.group()])
        viewModel.activate()
        viewModel.requestNavigationSelection(.moduleGroup("test.group"))

        viewModel.searchQuery = "BUDGET"
        XCTAssertEqual(viewModel.filteredModuleEntries.map(\.id), ["a", "b"])
        XCTAssertEqual(viewModel.navigationSummary, String.localizedStringWithFormat(String(localized: "%lld entries"), Int64(2)))

        viewModel.searchQuery = "cafe second"
        XCTAssertEqual(viewModel.filteredModuleEntries.map(\.id), ["a"])

        viewModel.searchQuery = "  "
        XCTAssertEqual(viewModel.filteredModuleEntries.map(\.id), ["a", "b", "c"])
        // The sidebar counts all entries, whatever the search.
        XCTAssertEqual(viewModel.moduleGroups.first?.entries.count, 3)
    }

    func testNewEntryIsSelectedAndDeletedEntryLeavesTheGroup() throws {
        let store = TestSidebarStore()
        store.entries = [store.entry("first", daysAgo: 1)]
        let fixture = try HistorySidebarFixture()
        defer { fixture.remove() }
        let viewModel = fixture.viewModel
        viewModel.setModuleSidebarGroups([store.group()])
        viewModel.activate()
        viewModel.requestNavigationSelection(.moduleGroup("test.group"))
        viewModel.searchQuery = "first"

        // The new entry stays selected until the module lists it.
        store.listsNewEntriesLater = true
        viewModel.createModuleEntry()
        XCTAssertEqual(viewModel.selectedModuleEntryID, "created-1")
        XCTAssertEqual(viewModel.moduleEntryContent?.id, "created-1")
        XCTAssertEqual(viewModel.searchQuery, "")
        store.changed()
        XCTAssertEqual(viewModel.selectedModuleEntryID, "created-1")
        store.publishPendingEntries()
        XCTAssertEqual(viewModel.moduleGroups.first?.entries.map(\.id), ["created-1", "first"])
        XCTAssertEqual(viewModel.selectedModuleEntryID, "created-1")

        viewModel.deleteModuleEntry(withID: "created-1")
        XCTAssertEqual(store.deleted, ["created-1"])
        XCTAssertNil(viewModel.selectedModuleEntryID)
        XCTAssertEqual(viewModel.moduleGroups.first?.entries.map(\.id), ["first"])

        // An entry the module lists right away leaves the selection once it is removed.
        store.listsNewEntriesLater = false
        viewModel.createModuleEntry()
        XCTAssertEqual(viewModel.selectedModuleEntryID, "created-2")
        store.removeEntry("created-2")
        XCTAssertNil(viewModel.selectedModuleEntryID)
        XCTAssertNil(viewModel.moduleEntryContent)

        // A group without deletion deletes nothing.
        let readOnly = TestSidebarStore(offersDeletion: false)
        readOnly.entries = [readOnly.entry("kept", daysAgo: 0)]
        viewModel.setModuleSidebarGroups([readOnly.group(id: "test.readOnly")])
        viewModel.requestNavigationSelection(.moduleGroup("test.readOnly"))
        XCTAssertFalse(try XCTUnwrap(viewModel.selectedModuleGroup).group.canDelete)
        viewModel.deleteModuleEntry(withID: "kept")
        XCTAssertEqual(readOnly.entries.map(\.id), ["kept"])
    }

    func testSwitchingToAGroupKeepsUnsavedChangesUntilTheUserDecides() throws {
        let store = TestSidebarStore()
        let fixture = try HistorySidebarFixture()
        defer { fixture.remove() }
        let viewModel = fixture.viewModel
        viewModel.setModuleSidebarGroups([store.group()])
        viewModel.activate()
        viewModel.requestRecordSelection([fixture.recordID])
        viewModel.editedText = "Unsaved correction"

        viewModel.requestNavigationSelection(.moduleGroup("test.group"))
        XCTAssertTrue(viewModel.showsUnsavedChangesPrompt)
        XCTAssertEqual(viewModel.navigationSelection, .smartMailbox(.all))

        viewModel.discardAndContinue()
        XCTAssertEqual(viewModel.navigationSelection, .moduleGroup("test.group"))
        XCTAssertTrue(viewModel.isShowingModuleGroup)
        // Record actions in the toolbar have nothing to act on.
        XCTAssertTrue(viewModel.selectedRecordIDs.isEmpty)
        XCTAssertNil(viewModel.selectedRecord)

        // A group that went away while the prompt was open is not opened.
        viewModel.requestNavigationSelection(.smartMailbox(.all))
        viewModel.requestRecordSelection([fixture.recordID])
        viewModel.editedText = "Another correction"
        viewModel.requestNavigationSelection(.moduleGroup("test.group"))
        XCTAssertTrue(viewModel.showsUnsavedChangesPrompt)
        store.isVisible = false
        store.changed()
        viewModel.discardAndContinue()
        XCTAssertEqual(viewModel.navigationSelection, .smartMailbox(.all))
        XCTAssertFalse(viewModel.isShowingModuleGroup)
        store.isVisible = true
        store.changed()
        viewModel.requestNavigationSelection(.moduleGroup("test.group"))

        // Opening a record, for example from a module, leaves the group.
        viewModel.requestOpenRecord(withID: fixture.recordID)
        XCTAssertEqual(viewModel.navigationSelection, .smartMailbox(.all))
        XCTAssertEqual(viewModel.selectedRecordIDs, [fixture.recordID])
    }

    // MARK: - History

    func testHistoryReadingReturnsReadyRecordsAndReportsChanges() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        var shown: [(UUID, TimeInterval?)] = []
        let reading = AppHistoryReading(historyService: history) { shown.append(($0, $1)) }
        var changes: [ModuleHistoryChange] = []
        let observation = reading.observeChanges { changes.append($0) }
        let id = UUID()

        XCTAssertTrue(history.addRecord(
            id: id, rawText: "Budget meeting", finalText: "Budget meeting.", appName: "Notes",
            appBundleIdentifier: "com.apple.Notes", durationSeconds: 3, language: "en", engineUsed: "test"
        ))
        let records = try await reading.records(withIDs: [id, UUID()])
        let existing = try await reading.existingRecordIDs(among: [id, UUID()])
        reading.showRecord(withID: id, atSeconds: 12)

        XCTAssertEqual(changes, [.upserted([id])])
        XCTAssertEqual(records.map(\.id), [id])
        XCTAssertEqual(records.first?.text, "Budget meeting.")
        XCTAssertEqual(records.first?.appName, "Notes")
        XCTAssertEqual(records.first?.bundleID, "com.apple.Notes")
        XCTAssertNil(records.first?.title)
        XCTAssertEqual(existing, [id])
        XCTAssertEqual(shown.first?.0, id)
        XCTAssertEqual(shown.first?.1, 12)
        observation.cancel()
    }

    func testHistorySearchingFindsIndexedRecordsInScope() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        let index = HistorySearchIndex(directory: directory.appendingPathComponent(HistorySearchIndex.directoryName))
        let indexer = HistorySearchIndexer(
            historyService: history, index: index, isEnabled: { true }, isBusy: { false }
        )
        let isEnabled = Flag(true)
        let searching = AppHistorySearching(index: index, isEnabled: { isEnabled.value }) {
            await indexer.reconcile()
            await indexer.waitForQueuedWork()
        }
        let budget = UUID()
        let other = UUID()
        XCTAssertTrue(history.addRecord(
            id: budget, rawText: "We moved the budget review to Friday", finalText: "We moved the budget review to Friday.",
            appName: "Notes", appBundleIdentifier: "com.apple.Notes", durationSeconds: 3, language: "en", engineUsed: "test"
        ))
        XCTAssertTrue(history.addRecord(
            id: other, rawText: "Lunch at noon", finalText: "Lunch at noon.",
            appName: "Mail", appBundleIdentifier: "com.apple.mail", durationSeconds: 2, language: "en", engineUsed: "test"
        ))

        await searching.prepare()
        let hits = try await searching.search(ModuleHistorySearchQuery(words: ["budget"]))
        let scoped = try await searching.search(ModuleHistorySearchQuery(
            words: ["budget"], scope: ModuleHistorySearchScope(recordIDs: [other])
        ))
        let newest = try await searching.newestRecords(in: ModuleHistorySearchScope(), limit: 1)
        let transcript = try await searching.transcript(ofRecord: budget)
        let contentHash = try XCTUnwrap(transcript?.contentHash)
        try await searching.setSummary("Review moved", providerId: "test", ofRecord: budget, contentHash: contentHash, language: "")
        let summary = try await searching.summary(ofRecord: budget, language: "")
        let vocabulary = try await searching.vocabulary()

        XCTAssertEqual(hits.map(\.recordID), [budget])
        XCTAssertEqual(hits.first?.passage.kind, .transcript)
        XCTAssertTrue(hits.first?.passage.text.contains("budget") == true)
        XCTAssertTrue(scoped.isEmpty)
        XCTAssertEqual(newest.total, 2)
        XCTAssertEqual(newest.hits.map(\.recordID), [other])
        XCTAssertEqual(summary, ModuleHistorySummary(text: "Review moved", providerId: "test"))
        XCTAssertEqual(Set(vocabulary.apps.map(\.bundleID)), ["com.apple.Notes", "com.apple.mail"])
        XCTAssertEqual(ModuleHistorySearchQuery.words(in: "Budget-Review, 2026!"), HistoryFullTextQuery.words(in: "Budget-Review, 2026!"))
        XCTAssertTrue(ModuleHistorySearchScope(recordIDs: [budget]).includes(try XCTUnwrap(hits.first)))

        // Off, for example by a managed policy, the index answers nothing.
        isEnabled.value = false
        let hitsWhileOff = try await searching.search(ModuleHistorySearchQuery(words: ["budget"]))
        let transcriptWhileOff = try await searching.transcript(ofRecord: budget)
        let newestWhileOff = try await searching.newestRecords(in: ModuleHistorySearchScope(), limit: 1)
        XCTAssertTrue(hitsWhileOff.isEmpty)
        XCTAssertNil(transcriptWhileOff)
        XCTAssertEqual(newestWhileOff.total, 0)
    }

    // MARK: - Language models

    func testLanguageModelProvidersAndAnswers() async throws {
        let suiteName = "ModuleHostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode([LLMFallbackPriorityItem(providerId: PromptProcessingService.appleIntelligenceId)]),
            forKey: UserDefaultsKeys.llmFallbackPriorityList
        )
        let service = PromptProcessingService(userDefaults: defaults)
        let model = EchoModel()
        service.testingSetAppleIntelligenceProvider(model)
        // Not the dictated-text path, which must not answer.
        service.isHistoryAskAllowed = { false }
        let answering = AppLanguageModelAnswering(service: service)

        let providers = try answering.providers()
        let provider = try XCTUnwrap(providers.first)
        let reply = try await answering.answer(instructions: "Be brief.", prompt: "  What is due?  ", using: provider)
        let tokens = await answering.inputTokens(instructions: "Be brief.", prompt: "What is due?", using: provider)
        model.reply = " "
        var emptyError: (any Error)?
        do {
            _ = try await answering.answer(instructions: "", prompt: "x", using: provider)
        } catch {
            emptyError = error
        }

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(provider.id, PromptProcessingService.appleIntelligenceId)
        XCTAssertEqual(provider.kind, .local)
        XCTAssertNil(provider.pluginId)
        XCTAssertEqual(reply, "Be brief.|What is due?")
        XCTAssertEqual(tokens, ModuleTokenCount(count: 3, contextSize: 4096))
        XCTAssertEqual(emptyError as? ModuleLanguageModelError, .emptyReply)

        // A pair the organization enforces later stops a provider read before.
        let previousPluginManager = PluginManager.shared
        let pluginDirectory = try TestSupport.makeTemporaryDirectory()
        PluginManager.shared = PluginManager(appSupportDirectory: pluginDirectory)
        defer {
            PluginManager.shared = previousPluginManager
            TestSupport.remove(pluginDirectory)
        }
        PluginManager.shared.applySelectionPolicy(ManagedSelectionPolicy(isLlmBlocked: true))
        var refusal: (any Error)?
        do {
            _ = try await answering.answer(instructions: "", prompt: "x", using: provider)
        } catch {
            refusal = error
        }
        XCTAssertEqual(refusal as? ModuleLanguageModelError, .refused(ManagedProviderPolicy.blockedMessage))
        XCTAssertThrowsError(try answering.providers())
    }

    func testLanguageModelErrorsBecomeModuleErrors() {
        func mapped(_ error: any Error) -> ModuleLanguageModelError? {
            AppLanguageModelAnswering.moduleError(for: error) as? ModuleLanguageModelError
        }

        XCTAssertEqual(mapped(ManagedPolicyRefusal(reason: "Off")), .refused("Off"))
        XCTAssertEqual(mapped(LLMError.inputTooLong), .contextExceeded)
        XCTAssertEqual(mapped(LLMError.noApiKey), .notSetUp(LLMError.noApiKey.localizedDescription))
        XCTAssertEqual(mapped(LLMError.providerError("Boom")), .failed("LLM error: Boom"))
        XCTAssertTrue(AppLanguageModelAnswering.moduleError(for: CancellationError()) is CancellationError)
    }

    // MARK: - Helpers

    private let commandShiftK = UnifiedHotkey(
        keyCode: 0x28, modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue, isFn: false
    )
    private let commandShiftL = UnifiedHotkey(
        keyCode: 0x25, modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue, isFn: false
    )

    private func clearModuleHotkeys(_ ids: [String]) {
        for id in ids {
            UserDefaults.standard.removeObject(forKey: HotkeyService.moduleActionDefaultsKey(for: id))
        }
    }

    private func keyboardEvent(keyCode: UInt16, keyDown: Bool) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown))
        event.flags = [.maskCommand, .maskShift]
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
}

@MainActor
private final class Log {
    var items: [String] = []
}

@MainActor
private final class Flag {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

@MainActor
private final class TestSidebarStore {
    var entries: [ModuleHistorySidebarEntry] = []
    var isVisible = true
    /// Lists created entries only after `publishPendingEntries()`.
    var listsNewEntriesLater = false
    private(set) var deleted: [String] = []
    private(set) var madeContent: [String] = []
    private(set) var entryReads = 0
    private var pendingEntries: [ModuleHistorySidebarEntry] = []
    private var created = 0
    private let offersDeletion: Bool
    private let subject = PassthroughSubject<Void, Never>()

    init(offersDeletion: Bool = true) {
        self.offersDeletion = offersDeletion
    }

    func entry(_ id: String, daysAgo: Double) -> ModuleHistorySidebarEntry {
        ModuleHistorySidebarEntry(id: id, title: id, date: Date(timeIntervalSinceNow: -daysAgo * 86_400))
    }

    func changed() {
        subject.send()
    }

    /// Removes an entry without the app, as a sync would.
    func removeEntry(_ id: String) {
        entries.removeAll { $0.id == id }
        changed()
    }

    func publishPendingEntries() {
        entries += pendingEntries
        pendingEntries = []
        changed()
    }

    func group(id: String = "test.group") -> ModuleHistorySidebarGroup {
        let newEntry = ModuleHistorySidebarGroup.NewEntry(title: "New Note") { [unowned self] () -> String? in
            self.createEntry()
        }
        var delete: (@MainActor @Sendable (String) -> Void)?
        if offersDeletion {
            delete = { [unowned self] (entryID: String) in self.deleteEntry(entryID) }
        }
        return ModuleHistorySidebarGroup(
            id: id,
            title: "Notes",
            systemImage: "note.text",
            isVisible: { [unowned self] () -> Bool in self.isVisible },
            entries: { [unowned self] () -> [ModuleHistorySidebarEntry] in self.readEntries() },
            observeChanges: { [unowned self] (handler: @escaping @MainActor () -> Void) -> AnyCancellable in
                self.subject.sink { MainActor.assumeIsolated { handler() } }
            },
            makeContent: { [unowned self] (entryID: String) -> AnyView in self.makeContent(entryID) },
            newEntry: newEntry,
            delete: delete
        )
    }

    private func readEntries() -> [ModuleHistorySidebarEntry] {
        entryReads += 1
        return entries
    }

    private func makeContent(_ entryID: String) -> AnyView {
        madeContent.append(entryID)
        return AnyView(Text(entryID))
    }

    private func createEntry() -> String {
        created += 1
        let entry = ModuleHistorySidebarEntry(id: "created-\(created)", title: "Untitled", date: Date())
        if listsNewEntriesLater {
            pendingEntries.append(entry)
        } else {
            entries.append(entry)
            changed()
        }
        return entry.id
    }

    private func deleteEntry(_ entryID: String) {
        deleted.append(entryID)
        entries.removeAll { $0.id == entryID }
        changed()
    }
}

/// History with one record and its view model.
@MainActor
private struct HistorySidebarFixture {
    let directory: URL
    let viewModel: HistoryViewModel
    let recordID = UUID()

    init() throws {
        directory = try TestSupport.makeTemporaryDirectory(prefix: "HistorySidebar")
        let history = HistoryService(appSupportDirectory: directory)
        _ = history.addRecord(
            id: recordID, rawText: "Budget meeting", finalText: "Budget meeting.", appName: "Notes",
            appBundleIdentifier: "com.apple.Notes", durationSeconds: 3, language: "en", engineUsed: "test"
        )
        viewModel = HistoryViewModel(
            historyService: history,
            textDiffService: TextDiffService(),
            dictionaryService: DictionaryService(appSupportDirectory: directory)
        )
    }

    func remove() {
        TestSupport.remove(directory)
    }
}

private enum TestModulesEntry: ModuleEntryPoint {
    nonisolated(unsafe) static var modules: [any HostModule] = []

    static var isStub: Bool { false }
    static var requiredModuleKitVersion: ModuleKitVersion { .current }

    static func makeModules() -> [any HostModule] { modules }
}

private final class TestModule: HostModule {
    let identifier: String
    private let provided: ModuleContributions

    init(identifier: String, contributions: ModuleContributions) {
        self.identifier = identifier
        provided = contributions
    }

    func contributions(for host: any ModuleHost) -> ModuleContributions {
        provided
    }

    static func contributions(prefix: String) -> ModuleContributions {
        ModuleContributions(
            hotkeyActions: [ModuleHotkeyAction(id: "\(prefix).hotkey", title: "Hotkey") {}],
            menuItems: [ModuleMenuItem(id: "\(prefix).menu", title: "Menu") {}],
            panels: [ModulePanel(id: "\(prefix).panel", title: "Panel") { AnyView(EmptyView()) }],
            recordActions: [ModuleRecordAction(id: "\(prefix).record", title: "Record", systemImage: "star") { _ in }],
            premiumCards: [ModulePremiumCard(id: "\(prefix).card", title: "Card", summary: "Summary", systemImage: "star")]
        )
    }
}

private final class TestPolicySource: ManagedPolicySource, @unchecked Sendable {
    var reading: ManagedPolicyRawReading

    init(_ reading: ManagedPolicyRawReading) {
        self.reading = reading
    }

    func read() -> ManagedPolicyRawReading { reading }
}

/// Answers with its instructions and prompt; counts three tokens of 4096.
private final class EchoModel: LLMProvider, @unchecked Sendable {
    var isAvailable = true
    var reply: String?

    func process(systemPrompt: String, userText: String) async throws -> String {
        XCTFail("A module's request must not take the dictated-text path")
        return userText
    }

    func answer(instructions: String, prompt: String) async throws -> String {
        reply ?? "\(instructions)|\(prompt.trimmingCharacters(in: .whitespaces))"
    }

    func inputTokens(instructions: String, prompt: String) async -> (count: Int, contextSize: Int)? {
        (3, 4096)
    }
}
