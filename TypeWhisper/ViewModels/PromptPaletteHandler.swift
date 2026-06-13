import AppKit
import ApplicationServices
import Foundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "PromptPaletteHandler")

@MainActor
final class PromptPaletteHandler {
    private enum InsertionOutcome {
        case failed
        case insertedViaAccessibility
        case insertedViaPaste
    }

    private struct PaletteContext {
        let text: String
        let selection: TextInsertionService.TextSelection?
        let focusedElement: AXUIElement?
        let activeApp: (name: String?, bundleId: String?, url: String?)
        let browserInfoTask: Task<(url: String?, title: String?), Never>?
        let selectionViaCopy: Bool
        let deferredClipboardRestore: TextInsertionService.DeferredClipboardRestore?
    }
    private var paletteContext: PaletteContext?

    private let promptPaletteController: any PromptPaletteControlling
    private let textInsertionService: TextInsertionService
    private let workflowService: WorkflowService
    private let historyService: HistoryService
    private let recentTranscriptionStore: RecentTranscriptionStore
    private let workflowTextProcessingService: WorkflowTextProcessingService
    private let soundService: SoundService
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService

    var onShowNotchFeedback: ((String, String, TimeInterval, Bool, String?) -> Void)?
    var onShowError: ((String) -> Void)?
    var executeActionPlugin: ((any ActionPlugin, String, String,
        (name: String?, bundleId: String?, url: String?), String?, String?) async throws -> Void)?
    var getActionFeedback: (() -> (message: String?, icon: String?, duration: TimeInterval))?
    var getPreserveClipboard: (() -> Bool)?
    var activateAppForInsertionOverride: ((String) async -> Bool)?

    var isVisible: Bool { promptPaletteController.isVisible }

    init(
        textInsertionService: TextInsertionService,
        workflowService: WorkflowService,
        historyService: HistoryService,
        recentTranscriptionStore: RecentTranscriptionStore,
        promptProcessingService: PromptProcessingService,
        workflowTextProcessingService: WorkflowTextProcessingService? = nil,
        soundService: SoundService,
        accessibilityAnnouncementService: AccessibilityAnnouncementService,
        promptPaletteController: any PromptPaletteControlling = PromptPaletteController()
    ) {
        self.promptPaletteController = promptPaletteController
        self.textInsertionService = textInsertionService
        self.workflowService = workflowService
        self.historyService = historyService
        self.recentTranscriptionStore = recentTranscriptionStore
        self.workflowTextProcessingService = workflowTextProcessingService
            ?? WorkflowTextProcessingService(
                promptProcessingService: promptProcessingService,
                translationService: nil,
                workflowService: workflowService
            )
        self.soundService = soundService
        self.accessibilityAnnouncementService = accessibilityAnnouncementService
    }

    func hide() {
        promptPaletteController.hide()
    }

    func triggerSelection(currentState: DictationViewModel.State, soundFeedbackEnabled: Bool) {
        // Toggle behavior
        if promptPaletteController.isVisible {
            promptPaletteController.hide()
            return
        }
        guard currentState == .idle else { return }

        let workflows = workflowService.workflows.filter { $0.isEnabled && $0.isManuallyRunnable }
        let recentEntries = recentTranscriptionStore.mergedEntries(historyRecords: historyService.records)
        guard !workflows.isEmpty || !recentEntries.isEmpty else { return }

        if workflows.isEmpty {
            showPalette(
                context: nil,
                workflows: [],
                recentEntries: recentEntries,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
            return
        }

        let activeApp = textInsertionService.captureActiveApp()
        let browserInfoTask = makeBrowserInfoTask(activeApp: activeApp)

        resolveTextContext(
            activeApp: activeApp,
            browserInfoTask: browserInfoTask,
            deferClipboardRestoreForCopyFallback: false,
            allowCopyFallback: true,
            allowClipboardFallback: !(getPreserveClipboard?() ?? false),
            onUnavailable: { [weak self] in
                guard let self else { return }
                guard !recentEntries.isEmpty else {
                    self.showMissingTextFeedback(soundFeedbackEnabled: soundFeedbackEnabled)
                    return
                }
                self.showPalette(
                    context: nil,
                    workflows: [],
                    recentEntries: recentEntries,
                    soundFeedbackEnabled: soundFeedbackEnabled
                )
            }
        ) { [weak self] context in
            self?.showPalette(
                context: context,
                workflows: workflows,
                recentEntries: recentEntries,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        }
    }

    func processWorkflowDirectly(
        workflow: Workflow,
        currentState: DictationViewModel.State,
        soundFeedbackEnabled: Bool
    ) {
        guard currentState == .idle,
              workflow.isEnabled,
              workflow.isManuallyRunnable else {
            return
        }

        let activeApp = textInsertionService.captureActiveApp()
        let browserInfoTask = makeBrowserInfoTask(activeApp: activeApp)

        resolveTextContext(
            activeApp: activeApp,
            browserInfoTask: browserInfoTask,
            deferClipboardRestoreForCopyFallback: getPreserveClipboard?() ?? false,
            allowCopyFallback: true,
            allowClipboardFallback: !(getPreserveClipboard?() ?? false),
            onUnavailable: { [weak self] in
                self?.showMissingTextFeedback(soundFeedbackEnabled: soundFeedbackEnabled)
            }
        ) { [weak self] context in
            self?.processStandaloneWorkflow(
                workflow: workflow,
                context: context,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        }
    }

    private func makeBrowserInfoTask(
        activeApp: (name: String?, bundleId: String?, url: String?)
    ) -> Task<(url: String?, title: String?), Never>? {
        guard let bundleId = activeApp.bundleId else { return nil }
        let tis = textInsertionService
        return Task {
            await tis.resolveBrowserInfo(bundleId: bundleId)
        }
    }

    private func resolveTextContext(
        activeApp: (name: String?, bundleId: String?, url: String?),
        browserInfoTask: Task<(url: String?, title: String?), Never>?,
        deferClipboardRestoreForCopyFallback: Bool,
        allowCopyFallback: Bool,
        allowClipboardFallback: Bool,
        onUnavailable: @escaping () -> Void,
        completion: @escaping (PaletteContext) -> Void
    ) {
        if let sel = textInsertionService.getTextSelection() {
            completion(PaletteContext(
                text: sel.text,
                selection: sel,
                focusedElement: nil,
                activeApp: activeApp,
                browserInfoTask: browserInfoTask,
                selectionViaCopy: false,
                deferredClipboardRestore: nil
            ))
        } else {
            let tis = textInsertionService
            Task {
                if allowCopyFallback,
                   deferClipboardRestoreForCopyFallback,
                   let copied = await tis.getTextSelectionViaCopyPreservingClipboardForInsertion() {
                    completion(PaletteContext(
                        text: copied.text,
                        selection: nil,
                        focusedElement: nil,
                        activeApp: activeApp,
                        browserInfoTask: browserInfoTask,
                        selectionViaCopy: true,
                        deferredClipboardRestore: copied.deferredClipboardRestore
                    ))
                } else if allowCopyFallback,
                          !deferClipboardRestoreForCopyFallback,
                          let copied = await tis.getTextSelectionViaCopy() {
                    completion(PaletteContext(
                        text: copied,
                        selection: nil,
                        focusedElement: nil,
                        activeApp: activeApp,
                        browserInfoTask: browserInfoTask,
                        selectionViaCopy: true,
                        deferredClipboardRestore: nil
                    ))
                } else if allowClipboardFallback,
                          let clipboard = NSPasteboard.general.string(forType: .string),
                          !clipboard.isEmpty {
                    let focusedElement = tis.getFocusedTextElement()
                    completion(PaletteContext(
                        text: clipboard,
                        selection: nil,
                        focusedElement: focusedElement,
                        activeApp: activeApp,
                        browserInfoTask: browserInfoTask,
                        selectionViaCopy: false,
                        deferredClipboardRestore: nil
                    ))
                } else {
                    logger.info("[PromptPalette] No text available")
                    onUnavailable()
                }
            }
        }
    }

    private func showPalette(
        context: PaletteContext?,
        workflows: [Workflow],
        recentEntries: [RecentTranscriptionStore.Entry],
        soundFeedbackEnabled: Bool
    ) {
        paletteContext = context

        var entries: [PromptPaletteEntry] = []
        if context != nil {
            entries.append(contentsOf: workflows.map { .workflow($0) })
        }
        entries.append(contentsOf: recentEntries.map { .recentTranscription($0) })
        guard !entries.isEmpty else { return }

        promptPaletteController.show(entries: entries, sourceText: context?.text) { [weak self] entry in
            guard let self else { return }
            switch entry {
            case .workflow(let workflow):
                self.processStandaloneWorkflow(workflow: workflow, soundFeedbackEnabled: soundFeedbackEnabled)
            case .recentTranscription(let recentEntry):
                self.paletteContext = nil
                Task { @MainActor in
                    await self.insertRecentTranscription(recentEntry)
                }
            }
        }
    }

    private func showMissingTextFeedback(soundFeedbackEnabled: Bool) {
        let message = "Please select or copy some text first."
        soundService.play(.error, enabled: soundFeedbackEnabled)
        accessibilityAnnouncementService.announceError(message)
        onShowNotchFeedback?(message, "xmark.circle.fill", 2.5, true, "workflow")
        onShowError?(message)
    }

    private func processStandaloneWorkflow(workflow: Workflow, soundFeedbackEnabled: Bool) {
        guard let ctx = paletteContext else { return }
        paletteContext = nil

        processStandaloneWorkflow(
            workflow: workflow,
            context: ctx,
            soundFeedbackEnabled: soundFeedbackEnabled
        )
    }

    private func insertRecentTranscription(_ entry: RecentTranscriptionStore.Entry) async {
        do {
            _ = try await textInsertionService.insertText(
                entry.finalText,
                preserveClipboard: getPreserveClipboard?() ?? false,
                autoEnter: false
            )
            onShowNotchFeedback?(String(localized: "Text inserted"), "checkmark.circle.fill", 2.5, false, nil)
        } catch {
            onShowNotchFeedback?(error.localizedDescription, "xmark.circle.fill", 2.5, true, "recentTranscriptions")
        }
    }

    private func processStandaloneWorkflow(
        workflow: Workflow,
        context ctx: PaletteContext,
        soundFeedbackEnabled: Bool
    ) {
        onShowNotchFeedback?(workflow.name + "...", "ellipsis.circle", 30, false, nil)
        accessibilityAnnouncementService.announcePromptProcessing(workflow.name)

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.textInsertionService.restoreClipboardIfNeeded(ctx.deferredClipboardRestore)
            }
            do {
                let outputFormat = workflow.output.resolvedFormat(for: ctx.activeApp.bundleId)
                let result = try await workflowTextProcessingService.process(
                    workflow: workflow,
                    text: ctx.text,
                    activeBundleIdentifier: ctx.activeApp.bundleId
                )
                guard !Task.isCancelled else { return }

                // Route to action plugin if configured
                if let actionPluginId = workflow.output.targetActionPluginId,
                   let actionPlugin = PluginManager.shared.actionPlugin(for: actionPluginId) {
                    let browserInfo = await ctx.browserInfoTask?.value
                    let resolvedUrl = browserInfo?.url ?? ctx.activeApp.url
                    let resolvedApp = (name: browserInfo?.title ?? ctx.activeApp.name,
                                       bundleId: ctx.activeApp.bundleId, url: resolvedUrl)
                    try await executeActionPlugin?(
                        actionPlugin, actionPluginId, result,
                        resolvedApp, ctx.text, nil
                    )
                    soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                    self.accessibilityAnnouncementService.announcePromptComplete()
                    let feedback = getActionFeedback?() ?? (message: nil, icon: nil, duration: 3.5)
                    onShowNotchFeedback?(
                        feedback.0 ?? "Done",
                        feedback.1 ?? "checkmark.circle.fill",
                        feedback.2,
                        false,
                        nil
                    )
                    return
                }

                let preserveClipboard = getPreserveClipboard?() ?? false

                let insertionOutcome: InsertionOutcome
                let requiresPasteboardInsertion = ClipboardContentFormatter.requiresPasteboardInsertion(
                    outputFormat: outputFormat
                )
                if requiresPasteboardInsertion {
                    if preserveClipboard {
                        let accessibilityText = ClipboardContentFormatter.payload(
                            for: result,
                            outputFormat: outputFormat
                        )?.plainText ?? result
                        if let selection = ctx.selection {
                            insertionOutcome = await insertViaAXWithPasteFallback(
                                selection: selection,
                                result: accessibilityText,
                                originalText: ctx.text,
                                bundleId: ctx.activeApp.bundleId,
                                preserveClipboard: preserveClipboard,
                                autoEnter: workflow.output.autoEnter,
                                outputFormat: nil,
                                deferredClipboardRestore: ctx.deferredClipboardRestore,
                                pasteFallbackText: result,
                                pasteFallbackOutputFormat: outputFormat
                            )
                        } else if ctx.selectionViaCopy {
                            insertionOutcome = try await activateAndInsertText(
                                result,
                                bundleId: ctx.activeApp.bundleId,
                                preserveClipboard: preserveClipboard,
                                autoEnter: workflow.output.autoEnter,
                                outputFormat: outputFormat,
                                deferredClipboardRestore: ctx.deferredClipboardRestore
                            )
                        } else if let element = ctx.focusedElement {
                            let pasteOutcome = try await activateAndInsertText(
                                result,
                                bundleId: ctx.activeApp.bundleId,
                                preserveClipboard: preserveClipboard,
                                autoEnter: workflow.output.autoEnter,
                                outputFormat: outputFormat,
                                deferredClipboardRestore: ctx.deferredClipboardRestore
                            )
                            insertionOutcome = pasteOutcome != .failed
                                ? pasteOutcome
                                : (
                                    textInsertionService.insertTextAt(element: element, text: accessibilityText)
                                        ? .insertedViaAccessibility
                                        : .failed
                                )
                        } else {
                            insertionOutcome = .failed
                        }
                    } else {
                        insertionOutcome = try await activateAndInsertText(
                            result,
                            bundleId: ctx.activeApp.bundleId,
                            preserveClipboard: preserveClipboard,
                            autoEnter: workflow.output.autoEnter,
                            outputFormat: outputFormat,
                            deferredClipboardRestore: ctx.deferredClipboardRestore
                        )
                    }
                } else if let selection = ctx.selection {
                    insertionOutcome = await insertViaAXWithPasteFallback(
                        selection: selection,
                        result: result,
                        originalText: ctx.text,
                        bundleId: ctx.activeApp.bundleId,
                        preserveClipboard: preserveClipboard,
                        autoEnter: workflow.output.autoEnter,
                        outputFormat: outputFormat,
                        deferredClipboardRestore: ctx.deferredClipboardRestore
                    )
                } else if ctx.selectionViaCopy {
                    insertionOutcome = try await activateAndInsertText(
                        result,
                        bundleId: ctx.activeApp.bundleId,
                        preserveClipboard: preserveClipboard,
                        autoEnter: workflow.output.autoEnter,
                        outputFormat: outputFormat,
                        deferredClipboardRestore: ctx.deferredClipboardRestore
                    )
                } else if let element = ctx.focusedElement {
                    insertionOutcome = textInsertionService.insertTextAt(element: element, text: result)
                        ? .insertedViaAccessibility
                        : .failed
                } else {
                    insertionOutcome = .failed
                }

                if workflow.output.autoEnter,
                   insertionOutcome != .failed,
                   !requiresPasteboardInsertion,
                   ctx.selectionViaCopy == false {
                    try? await Task.sleep(for: .milliseconds(50))
                    textInsertionService.simulateReturn()
                }

                soundService.play(.transcriptionSuccess, enabled: soundFeedbackEnabled)
                self.accessibilityAnnouncementService.announcePromptComplete()
                let feedbackMessage: String
                let feedbackIcon: String
                if insertionOutcome == .failed && preserveClipboard {
                    feedbackMessage = String(localized: "Insertion failed")
                    feedbackIcon = "xmark.circle"
                } else if insertionOutcome == .failed {
                    feedbackMessage = String(localized: "Copied to clipboard")
                    feedbackIcon = "doc.on.clipboard.fill"
                } else {
                    feedbackMessage = String(localized: "Text replaced")
                    feedbackIcon = "checkmark.circle.fill"
                }
                onShowNotchFeedback?(feedbackMessage, feedbackIcon, 2.5, false, nil)
            } catch {
                guard !Task.isCancelled else { return }
                soundService.play(.error, enabled: soundFeedbackEnabled)
                self.accessibilityAnnouncementService.announceError(error.localizedDescription)
                onShowNotchFeedback?(error.localizedDescription, "xmark.circle.fill", 2.5, true, "workflow")
            }
        }
    }

    private func insertViaAXWithoutPasteFallback(
        selection: TextInsertionService.TextSelection,
        result: String,
        originalText: String
    ) -> InsertionOutcome {
        let replaced = textInsertionService.replaceSelectedText(in: selection, with: result)

        guard replaced else {
            return .failed
        }

        var currentText: AnyObject?
        AXUIElementCopyAttributeValue(selection.element, kAXSelectedTextAttribute as CFString, &currentText)
        if let text = currentText as? String, text == originalText {
            logger.warning("[PromptPalette] AX replace silently ignored and paste fallback is disabled")
            return .failed
        }

        return .insertedViaAccessibility
    }

    /// Try AX replace, verify it worked, fall back to activate+paste if silently ignored (Electron apps).
    private func insertViaAXWithPasteFallback(
        selection: TextInsertionService.TextSelection,
        result: String,
        originalText: String,
        bundleId: String?,
        preserveClipboard: Bool,
        autoEnter: Bool,
        outputFormat: String?,
        deferredClipboardRestore: TextInsertionService.DeferredClipboardRestore? = nil,
        pasteFallbackText: String? = nil,
        pasteFallbackOutputFormat: String? = nil
    ) async -> InsertionOutcome {
        let replaced = textInsertionService.replaceSelectedText(in: selection, with: result)

        // Verify AX replace actually worked (Electron apps report success but silently ignore it)
        if replaced {
            var currentText: AnyObject?
            AXUIElementCopyAttributeValue(selection.element, kAXSelectedTextAttribute as CFString, &currentText)
            if let text = currentText as? String, text == originalText {
                logger.warning("[PromptPalette] AX replace silently ignored, falling back to paste")
            } else {
                return .insertedViaAccessibility
            }
        }

        do {
            return try await activateAndInsertText(
                pasteFallbackText ?? result,
                bundleId: bundleId,
                preserveClipboard: preserveClipboard,
                autoEnter: autoEnter,
                outputFormat: pasteFallbackOutputFormat ?? outputFormat,
                deferredClipboardRestore: deferredClipboardRestore
            )
        } catch {
            logger.error("[PromptPalette] Paste fallback failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// Activate the source app before delegating to the shared insertion service.
    private func activateAndInsertText(
        _ text: String,
        bundleId: String?,
        preserveClipboard: Bool,
        autoEnter: Bool,
        outputFormat: String?,
        deferredClipboardRestore: TextInsertionService.DeferredClipboardRestore? = nil
    ) async throws -> InsertionOutcome {
        if let bundleId, let activateAppForInsertionOverride {
            guard await activateAppForInsertionOverride(bundleId) else {
                return .failed
            }
            let result = try await textInsertionService.insertText(
                text,
                preserveClipboard: preserveClipboard,
                autoEnter: autoEnter,
                outputFormat: outputFormat,
                deferredClipboardRestore: deferredClipboardRestore
            )
            logger.info("[PromptPalette] Shared insertion completed after test activation for \(bundleId): \(String(describing: result), privacy: .public)")

            switch result {
            case .insertedViaAccessibility:
                return .insertedViaAccessibility
            case .pasted:
                return .insertedViaPaste
            }
        }

        guard let bundleId,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            logger.warning("[PromptPalette] No running app for bundleId: \(bundleId ?? "nil")")
            return .failed
        }

        let initialFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if initialFrontmost == bundleId {
            logger.info("[PromptPalette] Source app already frontmost for insertion: \(bundleId)")
        } else {
            let activated = app.activate(from: NSRunningApplication.current)
            logger.info("[PromptPalette] activate(from:) for \(bundleId): \(activated)")
            try? await Task.sleep(for: .milliseconds(200))

            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard frontmost == bundleId else {
                logger.warning("[PromptPalette] Could not activate \(bundleId), frontmost: \(frontmost ?? "nil")")
                return .failed
            }
        }

        let result = try await textInsertionService.insertText(
            text,
            preserveClipboard: preserveClipboard,
            autoEnter: autoEnter,
            outputFormat: outputFormat,
            deferredClipboardRestore: deferredClipboardRestore
        )

        switch result {
        case .insertedViaAccessibility:
            return .insertedViaAccessibility
        case .pasted:
            return .insertedViaPaste
        }
    }
}
