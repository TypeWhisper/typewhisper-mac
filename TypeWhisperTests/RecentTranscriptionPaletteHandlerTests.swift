import AppKit
import XCTest
@testable import TypeWhisper

@MainActor
final class RecentTranscriptionPaletteHandlerTests: XCTestCase {
    func testTriggerSelectionOpensOnlyWhenIdle() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let textInsertionService = TextInsertionService()
        let store = RecentTranscriptionStore()
        let controller = SelectionPaletteControllerSpy()
        let handler = RecentTranscriptionPaletteHandler(
            textInsertionService: textInsertionService,
            historyService: historyService,
            recentTranscriptionStore: store,
            paletteController: controller
        )

        store.recordTranscription(
            id: UUID(),
            finalText: "Recent session entry",
            timestamp: Date(),
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes"
        )

        handler.triggerSelection(currentState: .processing)
        XCTAssertFalse(controller.isVisible)

        handler.triggerSelection(currentState: .idle)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.lastItems?.count, 1)
    }

    func testTriggerSelectionShowsFeedbackWhenNoEntriesExist() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let handler = RecentTranscriptionPaletteHandler(
            textInsertionService: TextInsertionService(),
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            paletteController: SelectionPaletteControllerSpy()
        )

        var feedbackMessage: String?
        handler.onShowNotchFeedback = { message, _, _, _, _ in
            feedbackMessage = message
        }

        handler.triggerSelection(currentState: .idle)

        XCTAssertEqual(
            feedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "No recent transcriptions")
        )
    }

    func testTriggerSelectionSortsNewestEntriesFirst() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let store = RecentTranscriptionStore()
        let controller = SelectionPaletteControllerSpy()
        let handler = RecentTranscriptionPaletteHandler(
            textInsertionService: TextInsertionService(),
            historyService: historyService,
            recentTranscriptionStore: store,
            paletteController: controller
        )

        historyService.addRecord(
            id: UUID(),
            rawText: "History newest",
            finalText: "History newest",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            durationSeconds: 1,
            language: "en",
            engineUsed: "mock"
        )
        let historyRecord = try XCTUnwrap(historyService.records.first)
        historyRecord.timestamp = Date().addingTimeInterval(-10)
        historyService.updateRecord(historyRecord, finalText: historyRecord.finalText)

        store.recordTranscription(
            id: UUID(),
            finalText: "Session older",
            timestamp: Date().addingTimeInterval(-120),
            appName: "Mail",
            appBundleIdentifier: "com.apple.mail"
        )

        handler.triggerSelection(currentState: .idle)

        XCTAssertEqual(controller.lastItems?.map(\.title), ["History newest", "Session older"])
    }

    func testSelectingItemInsertsWithoutAutoEnter() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let pasteboard = NSPasteboard.withUniqueName()
        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.pasteboardProvider = { pasteboard }
        textInsertionService.focusedTextFieldOverride = { true }

        var pasteCount = 0
        var returnCount = 0
        textInsertionService.pasteSimulatorOverride = { pasteCount += 1 }
        textInsertionService.returnSimulatorOverride = { returnCount += 1 }

        let store = RecentTranscriptionStore()
        let controller = SelectionPaletteControllerSpy()
        let handler = RecentTranscriptionPaletteHandler(
            textInsertionService: textInsertionService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: store,
            paletteController: controller
        )

        let id = UUID()
        store.recordTranscription(
            id: id,
            finalText: "Insert me",
            timestamp: Date(),
            appName: "Messages",
            appBundleIdentifier: "com.apple.MobileSMS"
        )

        handler.triggerSelection(currentState: .idle)
        controller.select(id: id)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(returnCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Insert me")
    }
}

@MainActor
final class PromptPaletteHandlerTests: XCTestCase {
    func testTriggerSelectionStillOpensPaletteWhenCurrentProviderIsNotReady() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let previousPluginManager = PluginManager.shared
        PluginManager.shared = PluginManager()
        defer { PluginManager.shared = previousPluginManager }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Notes", nil, nil) }
        textInsertionService.textSelectionOverride = {
            TextInsertionService.TextSelection(
                text: "Selected text",
                element: AXUIElementCreateSystemWide()
            )
        }

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        _ = workflowService.addWorkflow(
            name: "Translate",
            template: .translation,
            trigger: .hotkey(UnifiedHotkey(keyCode: 17, modifierFlags: 0, isFn: false)),
            behavior: WorkflowBehavior(settings: ["targetLanguage": "German"])
        )

        let promptProcessingService = PromptProcessingService()
        promptProcessingService.selectedProviderId = "missing-provider"

        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            promptProcessingService: promptProcessingService,
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        var shownError: String?
        handler.onShowError = { shownError = $0 }

        handler.triggerSelection(currentState: .idle, soundFeedbackEnabled: false)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.lastWorkflows?.map(\.name), ["Translate"])
        XCTAssertEqual(controller.lastSourceText, "Selected text")
        XCTAssertNil(shownError)
    }
}

@MainActor
final class SelectionPaletteInteractionModelTests: XCTestCase {
    func testArrowKeysMoveSelectionAndReturnSelectsCurrentItem() throws {
        let items = [
            SelectionPaletteItem(id: UUID(), title: "First"),
            SelectionPaletteItem(id: UUID(), title: "Second"),
            SelectionPaletteItem(id: UUID(), title: "Third"),
        ]
        var selectedID: UUID?
        let model = SelectionPaletteInteractionModel(
            configuration: SelectionPaletteConfiguration(emptyStateTitle: "Empty"),
            items: items,
            onSelect: { selectedID = $0.id },
            onDismiss: {}
        )

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 125, characters: "")))
        XCTAssertEqual(model.selectedIndex, 1)

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 36, characters: "\r")))
        XCTAssertEqual(selectedID, items[1].id)
    }

    func testTypingAndDeleteUpdateSearchTextAndFilteredItems() throws {
        let items = [
            SelectionPaletteItem(id: UUID(), title: "Translate"),
            SelectionPaletteItem(id: UUID(), title: "Summarize"),
        ]
        let model = SelectionPaletteInteractionModel(
            configuration: SelectionPaletteConfiguration(
                searchPrompt: "Search",
                emptyStateTitle: "Empty"
            ),
            items: items,
            onSelect: { _ in },
            onDismiss: {}
        )

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 1, characters: "s")))
        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 17, characters: "u")))
        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 46, characters: "m")))
        XCTAssertEqual(model.searchText, "sum")
        XCTAssertEqual(model.filteredItems.map(\.title), ["Summarize"])

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 51, characters: "")))
        XCTAssertEqual(model.searchText, "su")
        XCTAssertEqual(model.filteredItems.map(\.title), ["Summarize"])
    }

    func testEscapeDismissesPalette() throws {
        var dismissCount = 0
        let model = SelectionPaletteInteractionModel(
            configuration: SelectionPaletteConfiguration(emptyStateTitle: "Empty"),
            items: [SelectionPaletteItem(id: UUID(), title: "Only")],
            onSelect: { _ in },
            onDismiss: { dismissCount += 1 }
        )

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 53, characters: "")))
        XCTAssertEqual(dismissCount, 1)
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}

@MainActor
private final class PromptPaletteControllerSpy: PromptPaletteControlling {
    private(set) var isVisible = false
    private(set) var lastWorkflows: [Workflow]?
    private(set) var lastSourceText: String?
    private var onSelect: ((Workflow) -> Void)?

    func show(workflows: [Workflow], sourceText: String, onSelect: @escaping (Workflow) -> Void) {
        isVisible = true
        lastWorkflows = workflows
        lastSourceText = sourceText
        self.onSelect = onSelect
    }

    func hide() {
        isVisible = false
    }
}

@MainActor
private final class SelectionPaletteControllerSpy: SelectionPaletteControlling {
    private(set) var isVisible = false
    private(set) var lastConfiguration: SelectionPaletteConfiguration?
    private(set) var lastItems: [SelectionPaletteItem]?
    private var onSelect: ((SelectionPaletteItem) -> Void)?

    func show(
        configuration: SelectionPaletteConfiguration,
        items: [SelectionPaletteItem],
        onSelect: @escaping (SelectionPaletteItem) -> Void
    ) {
        isVisible = true
        lastConfiguration = configuration
        lastItems = items
        self.onSelect = onSelect
    }

    func hide() {
        isVisible = false
    }

    func select(id: UUID) {
        guard let item = lastItems?.first(where: { $0.id == id }) else { return }
        onSelect?(item)
    }
}
