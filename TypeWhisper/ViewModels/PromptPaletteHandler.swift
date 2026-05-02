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
    }
    private var paletteContext: PaletteContext?

    private let promptPaletteController: any PromptPaletteControlling
    private let textInsertionService: TextInsertionService
    private let workflowService: WorkflowService
    private let workflowTextProcessingService: WorkflowTextProcessingService
    private let soundService: SoundService
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService

    var onShowNotchFeedback: ((String, String, TimeInterval, Bool, String?) -> Void)?
    var onShowError: ((String) -> Void)?
    var executeActionPlugin: ((any ActionPlugin, String, String,
        (name: String?, bundleId: String?, url: String?), String?, String?) async throws -> Void)?
    var getActionFeedback: (() -> (message: String?, icon: String?, duration: TimeInterval))?
    var getPreserveClipboard: (() -> Bool)?

    var isVisible: Bool { promptPaletteController.isVisible }

    init(
        textInsertionService: TextInsertionService,
        workflowService: WorkflowService,
        promptProcessingService: PromptProcessingService,
        workflowTextProcessingService: WorkflowTextProcessingService? = nil,
        soundService: SoundService,
        accessibilityAnnouncementService: AccessibilityAnnouncementService,
        promptPaletteController: any PromptPaletteControlling = PromptPaletteController()
    ) {
        self.promptPaletteController = promptPaletteController
        self.textInsertionService = textInsertionService
        self.workflowService = workflowService
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
        guard !workflows.isEmpty else { return }

        let activeApp = textInsertionService.captureActiveApp()
        let browserInfoTask = makeBrowserInfoTask(activeApp: activeApp)

        resolveTextContext(
            activeApp: activeApp,
            browserInfoTask: browserInfoTask,
            soundFeedbackEnabled: soundFeedbackEnabled
        ) { [weak self] context in
            self?.showPalette(
                context: context,
                workflows: workflows,
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
            soundFeedbackEnabled: soundFeedbackEnabled
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
        soundFeedbackEnabled: Bool,
        completion: @escaping (PaletteContext) -> Void
    ) {
        if let sel = textInsertionService.getTextSelection() {
            logger.info("[PromptPalette] Got selected text via AX: \(sel.text.prefix(80))")
            completion(PaletteContext(
                text: sel.text,
                selection: sel,
                focusedElement: nil,
                activeApp: activeApp,
                browserInfoTask: browserInfoTask,
                selectionViaCopy: false
            ))
        } else {
            let tis = textInsertionService
            Task {
                if let copied = await tis.getTextSelectionViaCopy() {
                    logger.info("[PromptPalette] Got selected text via Cmd+C: \(copied.prefix(80))")
                    completion(PaletteContext(
                        text: copied,
                        selection: nil,
                        focusedElement: nil,
                        activeApp: activeApp,
                        browserInfoTask: browserInfoTask,
                        selectionViaCopy: true
                    ))
                } else if let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty {
                    let focusedElement = tis.getFocusedTextElement()
                    logger.info("[PromptPalette] No selection, using clipboard: \(clipboard.prefix(80))")
                    completion(PaletteContext(
                        text: clipboard,
                        selection: nil,
                        focusedElement: focusedElement,
                        activeApp: activeApp,
                        browserInfoTask: browserInfoTask,
                        selectionViaCopy: false
                    ))
                } else {
                    logger.info("[PromptPalette] No text available, aborting")
                    let message = "Please select or copy some text first."
                    soundService.play(.error, enabled: soundFeedbackEnabled)
                    self.accessibilityAnnouncementService.announceError(message)
                    self.onShowNotchFeedback?(message, "xmark.circle.fill", 2.5, true, "workflow")
                    self.onShowError?(message)
                }
            }
        }
    }

    private func showPalette(
        context: PaletteContext,
        workflows: [Workflow],
        soundFeedbackEnabled: Bool
    ) {
        paletteContext = context

        promptPaletteController.show(workflows: workflows, sourceText: context.text) { [weak self] workflow in
            self?.processStandaloneWorkflow(workflow: workflow, soundFeedbackEnabled: soundFeedbackEnabled)
        }
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

    private func processStandaloneWorkflow(
        workflow: Workflow,
        context ctx: PaletteContext,
        soundFeedbackEnabled: Bool
    ) {
        onShowNotchFeedback?(workflow.name + "...", "ellipsis.circle", 30, false, nil)
        accessibilityAnnouncementService.announcePromptProcessing(workflow.name)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await workflowTextProcessingService.process(
                    workflow: workflow,
                    text: ctx.text
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

                // Save clipboard if preservation is enabled
                let preserveClipboard = getPreserveClipboard?() ?? false
                let savedClipboard = preserveClipboard ? textInsertionService.saveClipboard() : []

                // Always put result on clipboard so the user can paste it
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result, forType: .string)

                let insertionOutcome: InsertionOutcome
                if let selection = ctx.selection {
                    insertionOutcome = await insertViaAXWithPasteFallback(
                        selection: selection,
                        result: result,
                        originalText: ctx.text,
                        bundleId: ctx.activeApp.bundleId
                    )
                } else if ctx.selectionViaCopy {
                    insertionOutcome = await activateAndPaste(bundleId: ctx.activeApp.bundleId) ? .insertedViaPaste : .failed
                } else if let element = ctx.focusedElement {
                    insertionOutcome = textInsertionService.insertTextAt(element: element, text: result)
                        ? .insertedViaAccessibility
                        : .failed
                } else {
                    insertionOutcome = .failed
                }

                // Restore clipboard unconditionally when preservation is enabled
                if preserveClipboard {
                    if insertionOutcome == .insertedViaPaste {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    textInsertionService.restoreClipboard(savedClipboard)
                }

                if workflow.output.autoEnter, insertionOutcome != .failed {
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

    /// Try AX replace, verify it worked, fall back to activate+paste if silently ignored (Electron apps).
    private func insertViaAXWithPasteFallback(
        selection: TextInsertionService.TextSelection,
        result: String,
        originalText: String,
        bundleId: String?
    ) async -> InsertionOutcome {
        let replaced = textInsertionService.replaceSelectedText(in: selection, with: result)
        logger.info("[PromptPalette] replaceSelectedText reported: \(replaced)")

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

        return await activateAndPaste(bundleId: bundleId) ? .insertedViaPaste : .failed
    }

    /// Activate the source app and paste from clipboard. Result must already be on the clipboard.
    private func activateAndPaste(bundleId: String?) async -> Bool {
        guard let bundleId,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
            logger.warning("[PromptPalette] No running app for bundleId: \(bundleId ?? "nil")")
            return false
        }

        let activated = app.activate(from: NSRunningApplication.current)
        logger.info("[PromptPalette] activate(from:) for \(bundleId): \(activated)")
        try? await Task.sleep(for: .milliseconds(200))

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard frontmost == bundleId else {
            logger.warning("[PromptPalette] Could not activate \(bundleId), frontmost: \(frontmost ?? "nil")")
            return false
        }

        textInsertionService.pasteFromClipboard()
        logger.info("[PromptPalette] Pasted into \(bundleId)")
        return true
    }
}
