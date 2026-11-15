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
            hotkeyActions: [ModuleHotkeyAction(id: "test.open", title: "Open") { performed.items.append("test.open") }]
        ))]
        defer { TestModulesEntry.modules = [] }
        let registry = ModuleRegistry(entry: TestModulesEntry.self, host: AppModuleHost())

        registry.performHotkeyAction(withID: "test.open")
        registry.performHotkeyAction(withID: "test.unknown")

        XCTAssertEqual(performed.items, ["test.open"])
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
            ["AllowTestFeature", "TestMode", "TestSecret", "TestSites"]
        )
        XCTAssertEqual(ManagedPolicyKeys.definition(named: "AllowCloudTranscription")?.kind, .boolean)
        XCTAssertEqual(ManagedPolicyKeys.definition(named: "TestMode")?.enumerationMaximum, 2)

        let snapshot = ManagedPolicyValidator.validate(
            ManagedPolicyRawReading(forcedValues: [
                "AllowTestFeature": .boolean(false),
                "TestMode": .integer(3),
                "TestSecret": .string("fixture-secret"),
                "TestSites": .array([.string("example.com")]),
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

    // MARK: - Premium access

    func testPremiumAccessReportsOnlyRealChanges() {
        var hasAccess = false
        let changes = PassthroughSubject<Void, Never>()
        var shown = 0
        let reading = AppPremiumAccessReading(
            hasAccess: { hasAccess },
            accessChanges: changes.eraseToAnyPublisher(),
            showAccess: { shown += 1 }
        )
        var reported: [Bool] = []
        let observation = reading.observeChanges { reported.append($0) }

        changes.send()
        hasAccess = true
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
            export: { ["consents.json": Data("[]".utf8), "../escape.txt": Data()] }
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
        XCTAssertEqual(Array(files.keys), ["Modules/com.example.first/consents.json"])
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
        let searching = AppHistorySearching(index: index) {
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
        PluginManager.shared.applySelectionPolicy(ManagedSelectionPolicy(isLlmBlocked: true))
        defer { PluginManager.shared.applySelectionPolicy(.unmanaged) }
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
