import AppKit
import ApplicationServices

extension TextInsertionService {
    /// Capture the actual selected field before transform UI can take focus.
    /// Missing document/range information permits preview and Copy, never Replace.
    @MainActor
    func captureVoiceTransformTarget() async throws -> VoiceTransformTarget {
        guard isAccessibilityGranted else {
            throw VoiceTransformError.message("TypeWhisper needs Accessibility permission. Enable the installed app in System Settings → Privacy & Security → Accessibility. After replacing a locally signed build, remove and re-add it if permission no longer works.")
        }
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let lease = beginFocusedApplicationAccessibilityObservation()
        var leaseTransferred = false
        defer { if !leaseTransferred { lease?.end() } }
        var selected = getTextSelection()
        if selected == nil, lease != nil {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(50))
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else {
                    throw VoiceTransformError.message("The active app changed while capturing the selection. Select the text and try again.")
                }
                selected = getTextSelection()
                if selected != nil { break }
            }
        }
        guard let selection = selected, !selection.text.isEmpty else {
            guard let copied = try await copySelectionForVoiceTransform(sourcePID: sourcePID) else {
                throw VoiceTransformError.message("No selection could be read or copied. Select text in the source app and try again; check that Command-C copies it normally.")
            }
            return VoiceTransformTarget(text: copied, supportsReplacement: false) { _ in
                throw VoiceTransformError.message("This selection was captured through Copy. Copy the result back manually.")
            }
        }
        let initial = captureFocusedTextState(for: selection.element)
        var pid: pid_t = 0
        AXUIElementGetPid(selection.element, &pid)
        let application = NSRunningApplication(processIdentifier: pid)
        let launchDate = application?.launchDate
        let supportsReplacement: Bool
        if let value = initial?.value, let range = initial?.selectedRange,
           let selectedRange = Range(range, in: value), String(value[selectedRange]) == selection.text,
           application != nil, launchDate != nil {
            supportsReplacement = true
        } else {
            supportsReplacement = false
        }
        leaseTransferred = true
        return VoiceTransformTarget(text: selection.text, supportsReplacement: supportsReplacement, release: { lease?.end() }) { [weak self] replacement in
            guard let self,
                  let application, !application.isTerminated,
                  let launchDate,
                  NSRunningApplication(processIdentifier: pid)?.launchDate == launchDate,
                  let initial, let value = initial.value, let range = initial.selectedRange,
                  let swiftRange = Range(range, in: value), String(value[swiftRange]) == selection.text
            else {
                throw VoiceTransformError.message("The original target cannot be verified. Copy the result instead.")
            }
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard frontPID == pid || frontPID == ProcessInfo.processInfo.processIdentifier else {
                throw VoiceTransformError.message("The active app changed. Copy the result instead.")
            }
            guard application.activate() else {
                throw VoiceTransformError.message("Could not activate the original app. Copy the result instead.")
            }
            // Activation is asynchronous. Poll only for focus; never relax the
            // captured selection/document preconditions while waiting.
            for _ in 0..<20 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                   getFocusedTextElement() == selection.element { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  getFocusedTextElement() == selection.element,
                  let current = captureFocusedTextState(for: selection.element),
                  current.value == value, current.selectedRange == range,
                  current.selectedText == initial.selectedText else {
                throw VoiceTransformError.message("The original field, selection, or document changed. Copy the result instead.")
            }
            let captured = VoiceTransformSelectionSnapshot(value: value, range: range, selectedText: initial.selectedText)
            let expected = try captured.replacementDocument(
                original: selection.text, replacement: replacement,
                current: VoiceTransformSelectionSnapshot(value: current.value ?? "", range: current.selectedRange ?? NSRange(), selectedText: current.selectedText)
            )
            if expected == value { return }
            let accepted = insertTextAt(element: selection.element, text: replacement)
            let after = captureFocusedTextState(for: selection.element)
            guard accepted, after?.value == expected else {
                throw VoiceTransformError.message("Replacement could not be verified. Check the original app before using Copy; no second write was attempted.")
            }
        }
    }

    /// Accept only a fresh copy event, never pre-existing clipboard text. Copy
    /// capture enables preview only; it is not proof of a replaceable AX target.
    @MainActor
    private func copySelectionForVoiceTransform(sourcePID: pid_t?) async throws -> String? {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        for _ in 0..<40 {
            if NSEvent.modifierFlags.intersection(modifiers).isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard NSEvent.modifierFlags.intersection(modifiers).isEmpty else {
            throw VoiceTransformError.message("Release the transform shortcut keys, then try again.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else {
            throw VoiceTransformError.message("The active app changed while capturing the selection. Try again.")
        }
        let pasteboard = pasteboardProvider()
        let saved = saveClipboard(from: pasteboard)
        let initialCount = pasteboard.changeCount
        // Cmd+C is asynchronous. Finish this bounded wait even if the caller
        // cancels, so its eventual clipboard write can still be restored.
        let copiedCount = await Task<Int?, Never> { @MainActor in
            simulateCopy()
            for _ in 0..<100 {
                if pasteboard.changeCount != initialCount { return pasteboard.changeCount }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }.value
        defer {
            if let copiedCount, pasteboard.changeCount == copiedCount {
                restoreClipboard(saved, to: pasteboard)
            }
        }
        try Task.checkCancellation()
        guard let copiedCount else { return nil }
        try await Task.sleep(for: copySelectionReadSettleDelay)
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID,
              pasteboard.changeCount == copiedCount else {
            throw VoiceTransformError.message("The app or clipboard changed during selection capture. Try again.")
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}
