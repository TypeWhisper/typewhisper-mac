import Foundation
import AppKit
import ApplicationServices
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "TextInsertionService")

/// Inserts transcribed text into the active application via clipboard + simulated Cmd+V.
@MainActor
final class TextInsertionService {

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
            case .pasteFailed(let detail):
                "Failed to paste text: \(detail)"
            }
        }
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
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
        let app = NSWorkspace.shared.frontmostApplication
        let bundleId = app?.bundleIdentifier
        return (app?.localizedName, bundleId, nil)
    }

    func resolveBrowserURL(bundleId: String) async -> String? {
        #if APPSTORE
        // Apple Events to other apps are blocked in the App Sandbox
        return nil
        #else
        await Task.detached(priority: .utility) {
            Self.getBrowserURL(bundleId: bundleId)
        }.value
        #endif
    }

    func resolveBrowserInfo(bundleId: String) async -> (url: String?, title: String?) {
        #if APPSTORE
        return (nil, nil)
        #else
        await Task.detached(priority: .utility) {
            Self.getBrowserURLAndTitle(bundleId: bundleId)
        }.value
        #endif
    }

    // MARK: - Browser URL Detection

    private enum BrowserType: String {
        case safari, arc, chromiumBased, firefox, notABrowser
    }

    nonisolated private static func identifyBrowser(_ bundleId: String) -> BrowserType {
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

    nonisolated private static func getBrowserURL(bundleId: String) -> String? {
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

    nonisolated private static func getBrowserURLAndTitle(bundleId: String) -> (url: String?, title: String?) {
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

    nonisolated private static func executeAppleScript(_ source: String, timeout: TimeInterval, validateURL: Bool = true) -> String? {
        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            let descriptor = script?.executeAndReturnError(&error)
            if let errorDict = error {
                logger.warning("NSAppleScript error: \(errorDict)")
            }
            if let stringValue = descriptor?.stringValue {
                result = stringValue
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            logger.warning("NSAppleScript timed out after \(timeout)s")
            return nil
        }

        guard let result, !result.isEmpty else { return nil }
        if validateURL {
            guard isValidURL(result) else { return nil }
        }
        return result
    }

    nonisolated private static func isValidURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, trimmed.count < 2048 else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://")
    }

    /// Captures the selected text and the AXUIElement it belongs to.
    struct TextSelection: @unchecked Sendable {
        let text: String
        let element: AXUIElement
    }

    struct SurroundingTextContext: @unchecked Sendable {
        let textBefore: String
        let selectedText: String?
        let textAfter: String
    }

    func getSelectedText() -> String? {
        getTextSelection()?.text
    }

    func getSurroundingText(limit: Int = 500) -> SurroundingTextContext? {
        guard isAccessibilityGranted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        let element = focusedElement as! AXUIElement

        // Get full text value
        var textValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue) == .success,
              let fullText = textValue as? String, !fullText.isEmpty else {
            return nil
        }

        // Get selected text range (cursor position)
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success else {
            return nil
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) else {
            return nil
        }

        let cursorLocation = cfRange.location
        let selectionLength = cfRange.length

        // Extract text before cursor (max limit chars)
        let beforeStart = max(0, cursorLocation - limit)
        let beforeRange = fullText.index(fullText.startIndex, offsetBy: min(beforeStart, fullText.count))
            ..< fullText.index(fullText.startIndex, offsetBy: min(cursorLocation, fullText.count))
        let textBefore = String(fullText[beforeRange])

        // Extract selected text (if any)
        let selectedText: String?
        if selectionLength > 0 {
            let selEnd = min(cursorLocation + selectionLength, fullText.count)
            let selRange = fullText.index(fullText.startIndex, offsetBy: min(cursorLocation, fullText.count))
                ..< fullText.index(fullText.startIndex, offsetBy: selEnd)
            selectedText = String(fullText[selRange])
        } else {
            selectedText = nil
        }

        // Extract text after cursor/selection (max limit chars)
        let afterStart = cursorLocation + selectionLength
        let afterEnd = min(afterStart + limit, fullText.count)
        let afterRange = fullText.index(fullText.startIndex, offsetBy: min(afterStart, fullText.count))
            ..< fullText.index(fullText.startIndex, offsetBy: afterEnd)
        let textAfter = String(fullText[afterRange])

        return SurroundingTextContext(textBefore: textBefore, selectedText: selectedText, textAfter: textAfter)
    }

    /// Returns the selected text and the AXUIElement, so the selection can be replaced later.
    func getTextSelection() -> TextSelection? {
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
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return result == .success
    }

    func insertText(_ text: String, autoSubmit: Bool = false) async throws -> InsertionResult {
        guard isAccessibilityGranted else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general
        // Set transcribed text on clipboard and simulate Cmd+V.
        // Text stays on clipboard as fallback if no text field is focused.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulatePaste()

        if autoSubmit {
            try? await Task.sleep(for: .milliseconds(50))
            simulateEnter()
        }

        return .pasted
    }

    func focusedElementPosition() -> CGPoint? {
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

    private func simulatePaste() {
        // Key code 0x09 = V
        // Use nil source + .cgSessionEventTap for App Sandbox compatibility
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func simulateEnter() {
        // Key code 0x24 = Return/Enter
        let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true)
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
