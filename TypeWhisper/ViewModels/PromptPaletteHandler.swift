import AppKit
import ApplicationServices
import Foundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "PromptPaletteHandler")

@MainActor
final class PromptPaletteHandler {
    private let promptPaletteController = PromptPaletteController()

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

    private let textInsertionService: TextInsertionService
    private let promptActionService: PromptActionService
    private let promptProcessingService: PromptProcessingService
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
        promptActionService: PromptActionService,
        promptProcessingService: PromptProcessingService,
        soundService: SoundService,
        accessibilityAnnouncementService: AccessibilityAnnouncementService
    ) {
        self.textInsertionService = textInsertionService
        self.promptActionService = promptActionService
        self.promptProcessingService = promptProcessingService
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

        guard promptProcessingService.isCurrentProviderReady else {
            soundService.play(.error, enabled: soundFeedbackEnabled)
            onShowError?(String(localized: "noLLMProvider"))
            return
        }

        let actions = promptActionService.getEnabledActions()
        guard !actions.isEmpty else { return }

        // Capture active app BEFORE the palette steals focus
        let activeApp = textInsertionService.captureActiveApp()

        // Start resolving browser URL + title asynchronously
        var browserInfoTask: Task<(url: String?, title: String?), Never>?
        if let bundleId = activeApp.bundleId {
            let tis = textInsertionService
            browserInfoTask = Task {
                await tis.resolveBrowserInfo(bundleId: bundleId)
            }
        }

        // 3-tier fallback: AX selection -> Cmd+C simulation -> clipboard
        if let sel = textInsertionService.getTextSelection() {
            logger.info("[PromptPalette] Got selected text via AX: \(sel.text.prefix(80))")
            showPalette(
                text: sel.text, selection: sel, focusedElement: nil,
                selectionViaCopy: false, activeApp: activeApp,
                browserInfoTask: browserInfoTask, actions: actions,
                soundFeedbackEnabled: soundFeedbackEnabled
            )
        } else {
            // AX failed - try Cmd+C simulation (async) before falling back to clipboard
            let tis = textInsertionService
            Task {
                if let copied = await tis.getTextSelectionViaCopy() {
                    logger.info("[PromptPalette] Got selected text via Cmd+C: \(copied.prefix(80))")
                    showPalette(
                        text: copied, selection: nil, focusedElement: nil,
                        selectionViaCopy: true, activeApp: activeApp,
                        browserInfoTask: browserInfoTask, actions: actions,
                        soundFeedbackEnabled: soundFeedbackEnabled
                    )
                } else if let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty {
                    let focusedElement = tis.getFocusedTextElement()
                    logger.info("[PromptPalette] No selection, using clipboard: \(clipboard.prefix(80))")
                    showPalette(
                        text: clipboard, selection: nil, focusedElement: focusedElement,
                        selectionViaCopy: false, activeApp: activeApp,
                        browserInfoTask: browserInfoTask, actions: actions,
                        soundFeedbackEnabled: soundFeedbackEnabled
                    )
                } else {
                    logger.info("[PromptPalette] No text available, aborting")
                    let message = "Please select or copy some text first."
                    soundService.play(.error, enabled: soundFeedbackEnabled)
                    self.accessibilityAnnouncementService.announceError(message)
                    self.onShowNotchFeedback?(message, "xmark.circle.fill", 2.5, true, "prompt")
                    self.onShowError?(message)
                }
            }
        }
    }

    private func showPalette(
        text: String,
        selection: TextInsertionService.TextSelection?,
        focusedElement: AXUIElement?,
        selectionViaCopy: Bool,
        activeApp: (name: String?, bundleId: String?, url: String?),
        browserInfoTask: Task<(url: String?, title: String?), Never>?,
        actions: [PromptAction],
        soundFeedbackEnabled: Bool
    ) {
        paletteContext = PaletteContext(
            text: text,
            selection: selection,
            focusedElement: focusedElement,
            activeApp: activeApp,
            browserInfoTask: browserInfoTask,
            selectionViaCopy: selectionViaCopy
        )

        promptPaletteController.show(actions: actions, sourceText: text) { [weak self] action in
            self?.processStandalonePrompt(action: action, soundFeedbackEnabled: soundFeedbackEnabled)
        }
    }

    private func processStandalonePrompt(action: PromptAction, soundFeedbackEnabled: Bool) {
        guard let ctx = paletteContext else { return }
        paletteContext = nil

        onShowNotchFeedback?(action.name + "...", "ellipsis.circle", 30, false, nil)
        accessibilityAnnouncementService.announcePromptProcessing(action.name)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await promptProcessingService.process(
                    prompt: action.prompt,
                    text: ctx.text,
                    providerOverride: action.providerType,
                    cloudModelOverride: action.cloudModel
                )
                guard !Task.isCancelled else { return }

                // Route to action plugin if configured
                if let actionPluginId = action.targetActionPluginId,
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
                onShowNotchFeedback?(error.localizedDescription, "xmark.circle.fill", 2.5, true, "prompt")
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
