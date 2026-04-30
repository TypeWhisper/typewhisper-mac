import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "TextInsertionService")

struct CursorContext {
    let leftContext: String?
    let rightContext: String?
}

/// Inserts transcribed text into the active application via clipboard + simulated Cmd+V.
@MainActor
final class TextInsertionService {
    typealias FocusedTextSnapshot = (value: String?, selectedText: String?, selectedRange: NSRange?)

    var accessibilityGrantedOverride: Bool?
    // Cached flag — set to false when AX permission is revoked at runtime.
    // Avoids repeated AX calls that hang the system after permission removal.
    private var accessibilityAvailable = true
    var pasteboardProvider: () -> NSPasteboard = { .general }
    var focusedTextFieldOverride: (() -> Bool)?
    var focusedTextElementOverride: (() -> AXUIElement?)?
    var focusedTextStateOverride: ((AXUIElement) -> FocusedTextSnapshot?)?
    var textSelectionOverride: (() -> TextSelection?)?
    var insertTextAtOverride: ((AXUIElement, String) -> Bool)?
    var pasteSimulatorOverride: (() -> Void)?
    var returnSimulatorOverride: (() -> Void)?
    var captureActiveAppOverride: (() -> (name: String?, bundleId: String?, url: String?))?
    var selectedTextOverride: (() -> String?)?
    var surroundingContextOverride: (() -> CursorContext?)?

    enum InsertionResult {
        case pasted
    }

    enum TextInsertionError: LocalizedError {
        case accessibilityNotGranted
        case pasteFailed(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                "Accessibility permission not granted. Please enable it in System Settings → Privacy & Security → Accessibility."
            case let .pasteFailed(detail):
                "Failed to paste text: \(detail)"
            }
        }
    }

    var isAccessibilityGranted: Bool {
        if let override = accessibilityGrantedOverride { return override }
        guard accessibilityAvailable else { return false }
        let granted = AXIsProcessTrusted()
        if !granted {
            accessibilityAvailable = false
            logger.warning("Accessibility permission lost — disabling AX operations")
        }
        return granted
    }

    /// Call on app foreground to re-enable AX if permission was restored in System Settings.
    func revalidateAccessibilityOnForeground() {
        guard !accessibilityAvailable else { return }
        if AXIsProcessTrusted() {
            accessibilityAvailable = true
            logger.info("Accessibility permission restored — re-enabling AX operations")
        }
    }

    func requestAccessibilityPermission() {
        // Try the prompt first
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        // Also open System Settings directly (prompt alone may not work in sandbox)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func captureActiveApp() -> (name: String?, bundleId: String?, url: String?) {
        if let captureActiveAppOverride {
            return captureActiveAppOverride()
        }
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier
        return (app?.localizedName, bundleId, nil)
    }

    func resolveBrowserURL(bundleId: String) async -> String? {
        await Task.detached(priority: .utility) {
            Self.getBrowserURL(bundleId: bundleId)
        }.value
    }

    func resolveBrowserInfo(bundleId: String) async -> (url: String?, title: String?) {
        await Task.detached(priority: .utility) {
            Self.getBrowserURLAndTitle(bundleId: bundleId)
        }.value
    }

    // MARK: - Browser URL Detection

    private enum BrowserType: String {
        case safari, arc, chromiumBased, firefox, notABrowser
    }

    private nonisolated static func identifyBrowser(_ bundleId: String) -> BrowserType {
        let normalized = bundleId.lowercased()
        if normalized.contains("wavebox") {
            return .chromiumBased
        }

        switch bundleId {
        case "com.apple.Safari":
            return .safari
        case "company.thebrowser.Browser":
            return .arc
        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "com.operasoftware.Opera",
             "com.vivaldi.Vivaldi",
             "org.chromium.Chromium":
            return .chromiumBased
        case "org.mozilla.firefox":
            return .firefox
        default:
            return .notABrowser
        }
    }

    private nonisolated static func getBrowserURL(bundleId: String) -> String? {
        let browserType = identifyBrowser(bundleId)
        guard browserType != .notABrowser else { return nil }

        // Firefox doesn't support AppleScript for URL access
        guard browserType != .firefox else { return nil }

        // Resolve app name for AppleScript (required in sandbox - "tell application id" doesn't work)
        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
            ?? bundleId

        let script: String
        switch browserType {
        case .safari:
            script = """
            tell application "\(appName)"
                if (count of windows) > 0 then
                    return URL of current tab of front window
                end if
            end tell
            return ""
            """
        case .arc, .chromiumBased:
            script = """
            tell application "\(appName)"
                if (count of windows) > 0 then
                    return URL of active tab of front window
                end if
            end tell
            return ""
            """
        default:
            return nil
        }

        return executeAppleScript(script, timeout: 2.5)
    }

    private nonisolated static func getBrowserURLAndTitle(bundleId: String) -> (url: String?, title: String?) {
        let browserType = identifyBrowser(bundleId)
        guard browserType != .notABrowser, browserType != .firefox else { return (nil, nil) }

        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
            ?? bundleId

        let script: String
        switch browserType {
        case .safari:
            script = """
            tell application "\(appName)"
                if (count of windows) > 0 then
                    set tabURL to URL of current tab of front window
                    set tabTitle to name of current tab of front window
                    return tabURL & "\\n" & tabTitle
                end if
            end tell
            return ""
            """
        case .arc, .chromiumBased:
            script = """
            tell application "\(appName)"
                if (count of windows) > 0 then
                    set tabURL to URL of active tab of front window
                    set tabTitle to title of active tab of front window
                    return tabURL & "\\n" & tabTitle
                end if
            end tell
            return ""
            """
        default:
            return (nil, nil)
        }

        guard let result = executeAppleScript(script, timeout: 2.5, validateURL: false) else { return (nil, nil) }
        let parts = result.components(separatedBy: "\n")
        let url = parts.first.flatMap { isValidURL($0) ? $0 : nil }
        let title = parts.count > 1 ? parts.dropFirst().joined(separator: "\n") : nil
        return (url, title?.isEmpty == true ? nil : title)
    }

    private nonisolated static func executeAppleScript(_ source: String, timeout: TimeInterval, validateURL: Bool = true) -> String? {
        let resultState = OSAllocatedUnfairLock(initialState: String?.none)
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            let descriptor = script?.executeAndReturnError(&error)
            if let errorDict = error {
                logger.warning("NSAppleScript error: \(errorDict)")
            }
            if let stringValue = descriptor?.stringValue {
                resultState.withLock { $0 = stringValue }
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            logger.warning("NSAppleScript timed out after \(timeout)s")
            return nil
        }

        guard let result = resultState.withLock({ $0 }), !result.isEmpty else { return nil }
        if validateURL {
            guard isValidURL(result) else { return nil }
        }
        return result
    }

    private nonisolated static func isValidURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, trimmed.count < 2048 else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://")
    }

    /// Captures the selected text and the AXUIElement it belongs to.
    struct TextSelection: @unchecked Sendable {
        let text: String
        let element: AXUIElement
    }

    typealias ClipboardItemSnapshot = [NSPasteboard.PasteboardType: Data]
    typealias ClipboardSnapshot = [ClipboardItemSnapshot]

    struct PasteVerificationState {
        fileprivate let focusedTextState: FocusedTextState?
    }

    fileprivate struct FocusedTextState: Equatable {
        let element: AXUIElement
        let value: String?
        let selectedText: String?
        let selectedRange: NSRange?
    }

    func getSelectedText() -> String? {
        if let selectedTextOverride {
            return selectedTextOverride()
        }
        return getTextSelection()?.text
    }

    /// Returns the selected text and the AXUIElement, so the selection can be replaced later.
    func getTextSelection() -> TextSelection? {
        if let textSelectionOverride {
            return textSelectionOverride()
        }
        guard isAccessibilityGranted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        var selectedText: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success else {
            return nil
        }

        guard let text = selectedText as? String, !text.isEmpty else { return nil }
        return TextSelection(text: text, element: element)
    }

    /// Returns the focused text element (even without selection), for later insertion.
    func getFocusedTextElement() -> AXUIElement? {
        if let focusedTextElementOverride {
            return focusedTextElementOverride()
        }
        guard isAccessibilityGranted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        let element = focusedElement as! AXUIElement
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return nil }

        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard textRoles.contains(role) else { return nil }
        return element
    }

    /// Replaces the selected text on a previously captured AXUIElement.
    func replaceSelectedText(in selection: TextSelection, with text: String) -> Bool {
        insertTextAt(element: selection.element, text: text)
    }

    /// Inserts text at the cursor position of a previously captured AXUIElement.
    func insertTextAt(element: AXUIElement, text: String) -> Bool {
        if let insertTextAtOverride {
            return insertTextAtOverride(element, text)
        }
        guard accessibilityAvailable else { return false }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    /// Inserts via Accessibility only when we can verify that the focused text state changed.
    /// This avoids silently dropping text in apps that report AX success but ignore the write.
    func insertTextAtAndVerifyChange(element: AXUIElement, text: String) -> Bool {
        guard let initialState = captureFocusedTextState(for: element) else {
            return false
        }
        guard insertTextAt(element: element, text: text),
              let currentState = captureFocusedTextState(for: element)
        else {
            return false
        }
        return Self.focusedTextDidChange(
            from: (
                value: initialState.value,
                selectedText: initialState.selectedText,
                selectedRange: initialState.selectedRange
            ),
            to: (
                value: currentState.value,
                selectedText: currentState.selectedText,
                selectedRange: currentState.selectedRange
            )
        )
    }

    /// Saves all current clipboard contents for later restoration.
    func saveClipboard(from pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        Self.clipboardSnapshot(from: pasteboard.pasteboardItems ?? [])
    }

    /// Restores previously saved clipboard contents.
    func restoreClipboard(_ savedItems: ClipboardSnapshot, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        if !savedItems.isEmpty {
            pasteboard.writeObjects(Self.pasteboardItems(from: savedItems))
        }
    }

    func capturePasteVerificationState() -> PasteVerificationState {
        PasteVerificationState(focusedTextState: captureFocusedTextState())
    }

    func canRestoreClipboard(afterPasteUsing state: PasteVerificationState) -> Bool {
        guard let initialState = state.focusedTextState,
              let currentState = captureFocusedTextState(for: initialState.element)
        else {
            return false
        }
        return Self.focusedTextDidChange(
            from: (
                value: initialState.value,
                selectedText: initialState.selectedText,
                selectedRange: initialState.selectedRange
            ),
            to: (
                value: currentState.value,
                selectedText: currentState.selectedText,
                selectedRange: currentState.selectedRange
            )
        )
    }

    func insertText(
        _ text: String,
        preserveClipboard: Bool = false,
        autoEnter: Bool = false,
        cursorContext: CursorContext? = nil
    ) async throws -> InsertionResult {
        guard isAccessibilityGranted else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let resolvedContext = cursorContext ?? captureSurroundingCursorContext()
        let text = applyContextAwareCapitalization(to: text, context: resolvedContext)

        let hadFocusedTextField = autoEnter && hasFocusedTextField()

        if preserveClipboard,
           let focusedElement = getFocusedTextElement(),
           insertTextAtAndVerifyChange(element: focusedElement, text: text)
        {
            if hadFocusedTextField {
                try? await Task.sleep(for: .milliseconds(50))
                simulateReturn()
            }
            return .pasted
        }

        let pasteboard = pasteboardProvider()
        let savedItems = preserveClipboard ? saveClipboard(from: pasteboard) : []

        // Set transcribed text on clipboard and simulate Cmd+V.
        // Text stays on clipboard as fallback if no text field is focused.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulatePaste()

        if preserveClipboard {
            try? await Task.sleep(for: .milliseconds(200))
            restoreClipboard(savedItems, to: pasteboard)
        }

        if hadFocusedTextField {
            try? await Task.sleep(for: .milliseconds(50))
            simulateReturn()
        }

        return .pasted
    }

    func insertTextReliably(
        _ text: String,
        preserveClipboard: Bool = false,
        autoEnter: Bool = false
    ) async throws -> InsertionResult {
        guard isAccessibilityGranted else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let resolvedContext = captureSurroundingCursorContext()
        let capitalized = applyContextAwareCapitalization(to: text, context: resolvedContext)
        let processedText = applyAutoSpacing(to: capitalized)

        // When AX is unavailable, skip directly to a single clipboard paste — no AX steps, no retries.
        guard accessibilityAvailable else {
            let pasteboard = pasteboardProvider()
            pasteboard.clearContents()
            pasteboard.setString(processedText, forType: .string)
            simulatePaste()
            return .pasted
        }

        let hadFocusedTextField = autoEnter && hasFocusedTextField()

        // Step 1: Verified AX insertion
        if let focusedElement = getFocusedTextElement(),
           insertTextAtAndVerifyChange(element: focusedElement, text: processedText)
        {
            if hadFocusedTextField {
                try? await Task.sleep(for: .milliseconds(50))
                simulateReturn()
            }
            return .pasted
        }

        // Step 2: Clipboard paste with verification
        let pasteboard = pasteboardProvider()
        let savedItems = preserveClipboard ? saveClipboard(from: pasteboard) : []

        let preState = capturePasteVerificationState()

        pasteboard.clearContents()
        pasteboard.setString(processedText, forType: .string)
        simulatePaste()

        try? await Task.sleep(for: .milliseconds(75))

        if canRestoreClipboard(afterPasteUsing: preState) {
            if preserveClipboard {
                restoreClipboard(savedItems, to: pasteboard)
            }
            if hadFocusedTextField {
                try? await Task.sleep(for: .milliseconds(50))
                simulateReturn()
            }
            return .pasted
        }

        // Step 3: Retry paste once (only if AX is still available for verification)
        guard accessibilityAvailable else {
            if preserveClipboard { restoreClipboard(savedItems, to: pasteboard) }
            if hadFocusedTextField {
                try? await Task.sleep(for: .milliseconds(50))
                simulateReturn()
            }
            return .pasted
        }

        try? await Task.sleep(for: .milliseconds(75))

        let preRetryState = capturePasteVerificationState()
        simulatePaste()

        try? await Task.sleep(for: .milliseconds(75))

        if preserveClipboard {
            restoreClipboard(savedItems, to: pasteboard)
        }

        _ = canRestoreClipboard(afterPasteUsing: preRetryState)

        if hadFocusedTextField {
            try? await Task.sleep(for: .milliseconds(50))
            simulateReturn()
        }

        return .pasted
    }

    func focusedElementPosition() -> CGPoint? {
        guard accessibilityAvailable else { return nil }
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else {
            return nil
        }

        let axElement = element as! AXUIElement

        // Try to get the caret position from selected text range
        if let rect = caretRect(from: axElement) {
            return CGPoint(x: rect.origin.x + rect.width, y: rect.origin.y + rect.height)
        }

        // Fallback: get position of focused element
        return elementPosition(from: axElement)
    }

    /// Checks if the currently focused UI element is a text input field.
    func hasFocusedTextField() -> Bool {
        if let focusedTextFieldOverride {
            return focusedTextFieldOverride()
        }
        guard isAccessibilityGranted else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else { return false }

        let axElement = element as! AXUIElement
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        guard roleResult == .success, let role = roleValue as? String else { return false }

        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        return textRoles.contains(role)
    }

    private func caretRect(from element: AXUIElement) -> CGRect? {
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeValue
        )
        guard rangeResult == .success, let rangeValue = selectedRangeValue else { return nil }

        var bounds: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &bounds
        )
        guard boundsResult == .success, let boundsValue = bounds else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func elementPosition(from element: AXUIElement) -> CGPoint? {
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionValue
        )
        guard posResult == .success, let posValue = positionValue else { return nil }

        var point = CGPoint.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    func simulateReturn() {
        if let returnSimulatorOverride {
            returnSimulatorOverride()
            return
        }
        let returnKeyCode: CGKeyCode = 0x24
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: true)
        keyDown?.flags = []
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: false)
        keyUp?.flags = []
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func simulatePaste() {
        if let pasteSimulatorOverride {
            pasteSimulatorOverride()
            return
        }
        let vKeyCode = virtualKeyCode(for: "v") ?? 0x09 // Fallback to QWERTY
        // Use nil source + .cgSessionEventTap for App Sandbox compatibility
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func simulateCopy() {
        let cKeyCode = virtualKeyCode(for: "c") ?? 0x08 // Fallback to QWERTY
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: cKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// Resolves the virtual key code for a character in the current keyboard layout.
    /// Uses Carbon HIToolbox APIs to scan all key codes and match against the layout.
    private func virtualKeyCode(for character: String) -> CGKeyCode? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        for keyCode: UInt16 in 0 ... 127 {
            deadKeyState = 0
            let status = UCKeyTranslate(
                keyLayoutPtr,
                keyCode,
                UInt16(kUCKeyActionDown),
                0, // no modifiers
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            if status == noErr, length > 0 {
                let s = String(utf16CodeUnits: chars, count: length)
                if s == character {
                    return CGKeyCode(keyCode)
                }
            }
        }
        return nil
    }

    /// Attempts to get selected text by simulating Cmd+C. Saves and restores the clipboard.
    func getTextSelectionViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents (all types)
        let savedItems = saveClipboard(from: pasteboard)

        // Clear and simulate Cmd+C
        pasteboard.clearContents()
        simulateCopy()

        // Wait for the copy to land on the clipboard
        try? await Task.sleep(for: .milliseconds(100))

        // Read copied text
        let copiedText = pasteboard.string(forType: .string)

        // Restore original clipboard
        restoreClipboard(savedItems, to: pasteboard)

        guard let text = copiedText, !text.isEmpty else { return nil }
        return text
    }

    /// Public wrapper for simulatePaste(), for use by PromptPaletteHandler.
    func pasteFromClipboard() {
        simulatePaste()
    }

    static func clipboardSnapshot(from items: [NSPasteboardItem]) -> ClipboardSnapshot {
        items.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
    }

    static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    static func focusedTextDidChange(
        from initialState: (value: String?, selectedText: String?, selectedRange: NSRange?),
        to currentState: (value: String?, selectedText: String?, selectedRange: NSRange?)
    ) -> Bool {
        initialState.value != currentState.value ||
            initialState.selectedText != currentState.selectedText ||
            initialState.selectedRange != currentState.selectedRange
    }

    private func captureFocusedTextState() -> FocusedTextState? {
        guard let element = getFocusedTextElement() else { return nil }
        return captureFocusedTextState(for: element)
    }

    private func captureFocusedTextState(for element: AXUIElement) -> FocusedTextState? {
        if let focusedTextStateOverride {
            guard let snapshot = focusedTextStateOverride(element) else { return nil }
            return FocusedTextState(
                element: element,
                value: snapshot.value,
                selectedText: snapshot.selectedText,
                selectedRange: snapshot.selectedRange
            )
        }

        return FocusedTextState(
            element: element,
            value: stringAttribute(kAXValueAttribute as CFString, from: element),
            selectedText: stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
            selectedRange: selectedRangeAttribute(from: element)
        )
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func selectedRangeAttribute(from element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let rangeValue = value
        else {
            return nil
        }

        var range = CFRange()
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    // MARK: - Surrounding Cursor Context

    func captureSurroundingCursorContext() -> CursorContext? {
        if let surroundingContextOverride { return surroundingContextOverride() }

        guard isAccessibilityGranted else {
            logger.info("[CURSOR] Skipped: accessibility not granted")
            return nil
        }
        guard let element = getFocusedTextElement() else {
            logger.info("[CURSOR] Skipped: no focused text element")
            return nil
        }

        let fullText = (stringAttribute(kAXValueAttribute as CFString, from: element) ?? "") as NSString

        guard let range = selectedRangeAttribute(from: element) else {
            logger.info("[CURSOR] Skipped: no selected range from AX")
            return nil
        }

        let cursorLocation = range.location
        let selectionEnd = range.location + range.length

        let leftContext: String?
        if cursorLocation > 0, cursorLocation <= fullText.length {
            let raw = fullText.substring(to: cursorLocation)
            // Bounded to last 500 chars (nearest to cursor)
            leftContext = raw.isEmpty ? nil : String(raw.suffix(500))
        } else {
            leftContext = nil
        }

        let rightContext: String?
        if selectionEnd < fullText.length {
            let raw = fullText.substring(from: selectionEnd)
            // Bounded to first 500 chars (nearest to cursor)
            rightContext = raw.isEmpty ? nil : String(raw.prefix(500))
        } else {
            rightContext = nil
        }

        guard leftContext != nil || rightContext != nil else {
            logger.info("[CURSOR] Skipped: both left and right contexts empty")
            return nil
        }

        return CursorContext(leftContext: leftContext, rightContext: rightContext)
    }

    // MARK: - Auto Spacing

    func applyAutoSpacing(to text: String) -> String {
        guard !text.isEmpty else { return text }
        guard isAccessibilityGranted else {
            logger.info("[SPACING] Skipped: accessibility not granted")
            return text
        }
        guard let element = getFocusedTextElement() else {
            logger.info("[SPACING] Skipped: no focused text element")
            return text
        }

        let snapshot: FocusedTextSnapshot
        if let override = focusedTextStateOverride {
            guard let s = override(element) else {
                logger.info("[SPACING] Skipped: focusedTextStateOverride returned nil")
                return text
            }
            snapshot = s
        } else {
            snapshot = (
                value: stringAttribute(kAXValueAttribute as CFString, from: element),
                selectedText: stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
                selectedRange: selectedRangeAttribute(from: element)
            )
        }

        guard let fullString = snapshot.value else {
            logger.info("[SPACING] Skipped: AX value attribute is nil (app may not expose text via Accessibility)")
            return text
        }
        guard let range = snapshot.selectedRange else {
            logger.info("[SPACING] Skipped: AX selected range is nil (app may not expose cursor position via Accessibility)")
            return text
        }

        let nsText = fullString as NSString
        let cursorLocation = range.location
        let selectionEnd = range.location + range.length

        var result = text

        // Right side: checked first (index-independent from left side)
        if selectionEnd < nsText.length {
            let ch = nsText.character(at: selectionEnd)
            if !(result.last?.isWhitespace ?? false) && shouldAddRightSpace(for: ch) {
                result += " "
            }
        }

        // Left side
        if cursorLocation > 0, cursorLocation <= nsText.length {
            let ch = nsText.character(at: cursorLocation - 1)
            if !(result.first?.isWhitespace ?? false) && shouldAddLeftSpace(for: ch) {
                result = " " + result
            }
        }

        return result
    }

    func applyContextAwareCapitalization(to text: String, context: CursorContext?) -> String {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.adjustCapitalizationBasedOnContext) else {
            return text
        }

        guard let firstCharIndex = text.firstIndex(where: { !$0.isWhitespace }) else {
            return text
        }

        let firstWord = String(text[firstCharIndex...].prefix(while: { !$0.isWhitespace }))

        // Standalone "i" is always a pronoun — capitalize unconditionally
        if firstWord.lowercased() == "i" {
            var result = text
            result.replaceSubrange(firstCharIndex ... firstCharIndex, with: "I")
            return result
        }

        // ALL CAPS preservation: first word fully uppercase and longer than one character
        if firstWord.count > 1 && firstWord == firstWord.uppercased() {
            return text
        }

        // No left context means start of document — preserve capitalization
        guard let leftChar = context?.leftContext?.last(where: { !$0.isWhitespace }) else {
            return text
        }

        // Sentence boundary — preserve capitalization
        if ".!?".contains(leftChar) {
            return text
        }

        // Mid-sentence continuation — lowercase only the first character
        var result = text
        result.replaceSubrange(firstCharIndex ... firstCharIndex, with: String(text[firstCharIndex]).lowercased())
        return result
    }

    /// Returns true if a space should be prepended before inserted text when this character is to the left of the cursor.
    private func shouldAddLeftSpace(for unichar: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unichar) else { return false }
        let ch = Character(scalar)
        // Do NOT add space after: opening brackets, slashes, newline, whitespace
        if ch.isWhitespace || ch == "\n" || ch == "\r" { return false }
        if "([{/\\".contains(ch) { return false }
        return true
    }

    /// Returns true if a space should be appended after inserted text when this character is to the right of the cursor.
    private func shouldAddRightSpace(for unichar: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unichar) else { return false }
        let ch = Character(scalar)
        // Do NOT add space before: closing punctuation, sentence-ending punctuation, whitespace, newline
        if ch.isWhitespace || ch == "\n" || ch == "\r" { return false }
        if ",.:;!?)]}\\'\"".contains(ch) { return false }
        return true
    }
}
