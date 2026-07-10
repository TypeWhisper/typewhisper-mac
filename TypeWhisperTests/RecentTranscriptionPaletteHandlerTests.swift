import AppKit
import TypeWhisperPluginSDK
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

    func testWorkflowPaletteIncludesManualWorkflows() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

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
            name: "Manual Summary",
            template: .summary,
            trigger: .manual()
        )
        let recentTranscriptionStore = RecentTranscriptionStore()
        recentTranscriptionStore.recordTranscription(
            id: UUID(),
            finalText: "Recovered field text",
            timestamp: Date(),
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes"
        )

        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: recentTranscriptionStore,
            promptProcessingService: PromptProcessingService(),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        handler.triggerSelection(currentState: .idle, soundFeedbackEnabled: false)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.lastEntryDescriptions, ["workflow:Manual Summary", "recent:Recovered field text"])
        XCTAssertEqual(controller.lastSourceText, "Selected text")
    }
}

@MainActor
final class PromptPaletteHandlerTests: XCTestCase {
    func testDirectWorkflowHotkeyProcessesAccessibilitySelectionWithoutShowingPalette() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        let selectedElement = AXUIElementCreateSystemWide()
        textInsertionService.textSelectionOverride = {
            TextInsertionService.TextSelection(text: "Selected source", element: selectedElement)
        }

        var insertedText: String?
        textInsertionService.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = Workflow(
            name: "Direct Summary",
            template: .summary,
            trigger: .hotkeys([
                UnifiedHotkey(keyCode: 17, modifierFlags: 0, isFn: false)
            ], behavior: .processSelectedText)
        )
        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: PromptProcessingService(),
            workflowTextProcessingService: WorkflowTextProcessingService(
                promptProcessor: { _, _, _, _, _ in "Processed: Selected source" },
                appleTranslator: nil
            ),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        handler.processWorkflowDirectly(
            workflow: workflow,
            currentState: .idle,
            soundFeedbackEnabled: false
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(insertedText, "Processed: Selected source")
    }

    func testDirectWorkflowHotkeyAutoRichTextUsesResolvedPasteboardPayload() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Pages", "com.apple.iWork.Pages", nil) }
        let selectedElement = AXUIElementCreateSystemWide()
        textInsertionService.textSelectionOverride = {
            TextInsertionService.TextSelection(text: "Selected source", element: selectedElement)
        }

        var insertedText: String?
        textInsertionService.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        let pasteboard = NSPasteboard.general
        let savedClipboard = textInsertionService.saveClipboard(from: pasteboard)
        defer { textInsertionService.restoreClipboard(savedClipboard, to: pasteboard) }
        pasteboard.clearContents()

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = Workflow(
            name: "Direct Rich Summary",
            template: .summary,
            trigger: .hotkeys([
                UnifiedHotkey(keyCode: 17, modifierFlags: 0, isFn: false)
            ], behavior: .processSelectedText),
            output: WorkflowOutput(format: "auto")
        )

        var capturedPrompt: String?
        var pasteCount = 0
        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: PromptProcessingService(),
            workflowTextProcessingService: WorkflowTextProcessingService(
                promptProcessor: { prompt, _, _, _, _ in
                    capturedPrompt = prompt
                    return "**Launch**\n- Budget"
                },
                appleTranslator: nil
            ),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller,
            activateAppForInsertionOverride: { _ in
                return true
            }
        )
        textInsertionService.pasteSimulatorOverride = {
            pasteCount += 1
        }

        handler.processWorkflowDirectly(
            workflow: workflow,
            currentState: .idle,
            soundFeedbackEnabled: false
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(insertedText)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertTrue(capturedPrompt?.contains("Return Markdown-compatible text for rich-text conversion.") == true)
        XCTAssertEqual(pasteboard.string(forType: .string), "Launch\n- Budget")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
    }

    func testDirectWorkflowHotkeyRoutesProcessedTextToActionPluginInsteadOfInsertion() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let previousPluginManager = PluginManager.shared
        let actionPlugin = PromptPaletteActionPluginSpy()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: PromptPaletteActionPluginSpy.pluginId,
                    name: PromptPaletteActionPluginSpy.pluginName,
                    version: "1.0.0",
                    principalClass: "PromptPaletteActionPluginSpy",
                    requiresAPIKey: false
                ),
                instance: actionPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        defer { PluginManager.shared = previousPluginManager }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        let selectedElement = AXUIElementCreateSystemWide()
        textInsertionService.textSelectionOverride = {
            TextInsertionService.TextSelection(text: "Selected source", element: selectedElement)
        }

        var insertedText: String?
        textInsertionService.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = Workflow(
            name: "Send to Action",
            template: .summary,
            trigger: .hotkeys([
                UnifiedHotkey(keyCode: 17, modifierFlags: 0, isFn: false)
            ], behavior: .processSelectedText),
            output: WorkflowOutput(targetActionPluginId: actionPlugin.actionId)
        )
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: PromptProcessingService(),
            workflowTextProcessingService: WorkflowTextProcessingService(
                promptProcessor: { _, _, _, _, _ in "Processed: Selected source" },
                appleTranslator: nil
            ),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: PromptPaletteControllerSpy()
        )

        var routedInput: String?
        var routedOriginalText: String?
        handler.executeActionPlugin = { plugin, pluginId, text, _, originalText, _ in
            routedInput = text
            routedOriginalText = originalText
            XCTAssertEqual(pluginId, actionPlugin.actionId)
            XCTAssertTrue(plugin === actionPlugin)
        }

        handler.processWorkflowDirectly(
            workflow: workflow,
            currentState: .idle,
            soundFeedbackEnabled: false
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(routedInput, "Processed: Selected source")
        XCTAssertEqual(routedOriginalText, "Selected source")
        XCTAssertNil(insertedText)
    }

    func testDirectWorkflowHotkeyUsesClipboardFallbackWhenSelectionIsUnavailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        textInsertionService.textSelectionOverride = { nil }
        textInsertionService.textSelectionViaCopyOverride = { nil }
        textInsertionService.focusedTextElementOverride = { AXUIElementCreateSystemWide() }

        var insertedText: String?
        textInsertionService.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        let pasteboard = NSPasteboard.general
        let savedClipboard = textInsertionService.saveClipboard(from: pasteboard)
        defer { textInsertionService.restoreClipboard(savedClipboard, to: pasteboard) }
        pasteboard.clearContents()
        pasteboard.setString("Clipboard source", forType: .string)

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = Workflow(
            name: "Direct Cleanup",
            template: .cleanedText,
            trigger: .hotkeys([
                UnifiedHotkey(keyCode: 17, modifierFlags: 0, isFn: false)
            ], behavior: .processSelectedText)
        )
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: PromptProcessingService(),
            workflowTextProcessingService: WorkflowTextProcessingService(
                promptProcessor: { _, _, _, _, _ in "Processed: Clipboard source" },
                appleTranslator: nil
            ),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: PromptPaletteControllerSpy()
        )

        handler.processWorkflowDirectly(
            workflow: workflow,
            currentState: .idle,
            soundFeedbackEnabled: false
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(insertedText, "Processed: Clipboard source")
    }

    func testDirectWorkflowHotkeyShowsErrorWhenNoSelectionOrClipboardIsAvailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        textInsertionService.textSelectionOverride = { nil }
        textInsertionService.textSelectionViaCopyOverride = { nil }

        let pasteboard = NSPasteboard.general
        let savedClipboard = textInsertionService.saveClipboard(from: pasteboard)
        defer { textInsertionService.restoreClipboard(savedClipboard, to: pasteboard) }
        pasteboard.clearContents()

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let workflow = Workflow(
            name: "Direct Empty",
            template: .cleanedText,
            trigger: .hotkeys([
                UnifiedHotkey(keyCode: 17, modifierFlags: 0, isFn: false)
            ], behavior: .processSelectedText)
        )

        var processedText: String?
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: PromptProcessingService(),
            workflowTextProcessingService: WorkflowTextProcessingService(
                promptProcessor: { _, text, _, _, _ in
                    processedText = text
                    return "Processed: \(text)"
                },
                appleTranslator: nil
            ),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: PromptPaletteControllerSpy()
        )

        var feedbackMessage: String?
        var errorMessage: String?
        handler.onShowNotchFeedback = { message, _, _, _, _ in
            feedbackMessage = message
        }
        handler.onShowError = { message in
            errorMessage = message
        }

        handler.processWorkflowDirectly(
            workflow: workflow,
            currentState: .idle,
            soundFeedbackEnabled: false
        )

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(processedText)
        XCTAssertEqual(feedbackMessage, "Please select or copy some text first.")
        XCTAssertEqual(errorMessage, "Please select or copy some text first.")
    }

    func testWorkflowPaletteShowsRecentTranscriptionsWhenNoTextContextExists() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        var didCaptureActiveApp = false
        textInsertionService.captureActiveAppOverride = {
            didCaptureActiveApp = true
            return ("Notes", "com.apple.Notes", nil)
        }
        textInsertionService.textSelectionOverride = { nil }
        textInsertionService.textSelectionViaCopyOverride = { nil }

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)

        let recentTranscriptionStore = RecentTranscriptionStore()
        recentTranscriptionStore.recordTranscription(
            id: UUID(),
            finalText: "Recovered field text",
            timestamp: Date(),
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes"
        )

        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: recentTranscriptionStore,
            promptProcessingService: PromptProcessingService(),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        var shownError: String?
        handler.onShowError = { shownError = $0 }

        handler.triggerSelection(currentState: .idle, soundFeedbackEnabled: false)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.lastEntryDescriptions, ["recent:Recovered field text"])
        XCTAssertNil(controller.lastSourceText)
        XCTAssertNil(shownError)
        XCTAssertFalse(didCaptureActiveApp)
    }

    func testWorkflowPaletteRecentSelectionInsertsWithoutAutoEnter() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Messages", "com.apple.MobileSMS", nil) }
        textInsertionService.textSelectionOverride = { nil }
        textInsertionService.textSelectionViaCopyOverride = { nil }

        let generalPasteboard = NSPasteboard.general
        let savedClipboard = textInsertionService.saveClipboard(from: generalPasteboard)
        defer { textInsertionService.restoreClipboard(savedClipboard, to: generalPasteboard) }
        generalPasteboard.clearContents()

        let insertionPasteboard = NSPasteboard.withUniqueName()
        textInsertionService.pasteboardProvider = { insertionPasteboard }

        var pasteCount = 0
        var returnCount = 0
        textInsertionService.pasteSimulatorOverride = { pasteCount += 1 }
        textInsertionService.returnSimulatorOverride = { returnCount += 1 }

        let recentTranscriptionStore = RecentTranscriptionStore()
        let recentID = UUID()
        recentTranscriptionStore.recordTranscription(
            id: recentID,
            finalText: "Insert recovered text",
            timestamp: Date(),
            appName: "Messages",
            appBundleIdentifier: "com.apple.MobileSMS"
        )

        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: WorkflowService(appSupportDirectory: appSupportDirectory),
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: recentTranscriptionStore,
            promptProcessingService: PromptProcessingService(),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        handler.triggerSelection(currentState: .idle, soundFeedbackEnabled: false)
        try await Task.sleep(for: .milliseconds(50))
        controller.selectRecent(id: recentID)

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(returnCount, 0)
        XCTAssertEqual(insertionPasteboard.string(forType: .string), "Insert recovered text")
    }

    func testWorkflowPaletteWorkflowSelectionProcessesOriginalTextContext() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let textInsertionService = TextInsertionService()
        textInsertionService.accessibilityGrantedOverride = true
        textInsertionService.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        let selectedElement = AXUIElementCreateSystemWide()
        textInsertionService.textSelectionOverride = {
            TextInsertionService.TextSelection(text: "Selected source", element: selectedElement)
        }

        var insertedText: String?
        textInsertionService.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        _ = workflowService.addWorkflow(
            name: "Palette Cleanup",
            template: .cleanedText,
            trigger: .manual()
        )

        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: PromptProcessingService(),
            workflowTextProcessingService: WorkflowTextProcessingService(
                promptProcessor: { _, _, _, _, _ in "Processed: Selected source" },
                appleTranslator: nil
            ),
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        handler.triggerSelection(currentState: .idle, soundFeedbackEnabled: false)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.lastEntryDescriptions, ["workflow:Palette Cleanup"])
        controller.selectWorkflow(named: "Palette Cleanup")

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(insertedText, "Processed: Selected source")
    }

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

        let suiteName = "RecentTranscriptionPaletteHandlerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let promptProcessingService = PromptProcessingService(userDefaults: defaults)
        promptProcessingService.selectedProviderId = "missing-provider"

        let controller = PromptPaletteControllerSpy()
        let handler = PromptPaletteHandler(
            textInsertionService: textInsertionService,
            workflowService: workflowService,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            promptProcessingService: promptProcessingService,
            soundService: SoundService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            promptPaletteController: controller
        )

        var shownError: String?
        handler.onShowError = { shownError = $0 }

        handler.triggerSelection(currentState: .idle, soundFeedbackEnabled: false)

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.lastEntryDescriptions, ["workflow:Translate"])
        XCTAssertEqual(controller.lastSourceText, "Selected text")
        XCTAssertNil(shownError)
    }
}

private final class PromptPaletteActionPluginSpy: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = "plugin.action"
    static let pluginName = "Action Plugin"

    let actionName = "Send to Action"
    let actionId = "plugin.action"
    let actionIcon = "paperplane"

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {}

    func deactivate() {}

    func execute(input: String, context: ActionContext) async throws -> ActionResult {
        ActionResult(success: true, message: "Done")
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

    func testArrowKeysWrapSelectionAtListEdges() throws {
        let items = [
            SelectionPaletteItem(id: UUID(), title: "First"),
            SelectionPaletteItem(id: UUID(), title: "Second"),
            SelectionPaletteItem(id: UUID(), title: "Third"),
        ]
        let model = SelectionPaletteInteractionModel(
            configuration: SelectionPaletteConfiguration(emptyStateTitle: "Empty"),
            items: items,
            onSelect: { _ in },
            onDismiss: {}
        )

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 126, characters: "")))
        XCTAssertEqual(model.selectedIndex, 2)

        XCTAssertTrue(model.handleKeyDown(try keyEvent(keyCode: 125, characters: "")))
        XCTAssertEqual(model.selectedIndex, 0)
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
    private(set) var lastEntries: [PromptPaletteEntry]?
    private(set) var lastSourceText: String?
    private var onSelect: ((PromptPaletteEntry) -> Void)?

    var lastEntryDescriptions: [String] {
        lastEntries?.map { entry in
            switch entry {
            case .workflow(let workflow):
                return "workflow:\(workflow.name)"
            case .recentTranscription(let recentEntry):
                return "recent:\(recentEntry.finalText)"
            }
        } ?? []
    }

    func show(entries: [PromptPaletteEntry], sourceText: String?, onSelect: @escaping (PromptPaletteEntry) -> Void) {
        isVisible = true
        lastEntries = entries
        lastSourceText = sourceText
        self.onSelect = onSelect
    }

    func hide() {
        isVisible = false
    }

    func selectWorkflow(named name: String) {
        guard let entry = lastEntries?.first(where: { entry in
            if case .workflow(let workflow) = entry {
                return workflow.name == name
            }
            return false
        }) else { return }
        onSelect?(entry)
    }

    func selectRecent(id: UUID) {
        guard let entry = lastEntries?.first(where: { entry in
            if case .recentTranscription(let recentEntry) = entry {
                return recentEntry.id == id
            }
            return false
        }) else { return }
        onSelect?(entry)
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
