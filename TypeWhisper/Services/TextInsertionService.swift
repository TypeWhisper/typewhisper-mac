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
        case copiedToClipboard
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
        let url = bundleId.flatMap { getBrowserURL(bundleId: $0) }
        return (app?.localizedName, bundleId, url)
    }

    // MARK: - Browser URL Detection

    private enum BrowserType: String {
        case safari, arc, chromiumBased, firefox, notABrowser
    }

    private func identifyBrowser(_ bundleId: String) -> BrowserType {
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

    private func getBrowserURL(bundleId: String) -> String? {
        let browserType = identifyBrowser(bundleId)
        guard browserType != .notABrowser else { return nil }

        // Firefox doesn't support AppleScript for URL access
        guard browserType != .firefox else { return nil }

        let script: String
        switch browserType {
        case .safari:
            script = """
            tell application id "\(bundleId)"
                if (count of windows) > 0 then
                    return URL of current tab of front window
                end if
            end tell
            return ""
            """
        case .arc:
            script = """
            tell application id "\(bundleId)"
                if (count of windows) > 0 then
                    return URL of active tab of front window
                end if
            end tell
            return ""
            """
        case .chromiumBased:
            script = """
            tell application id "\(bundleId)"
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

    private func executeAppleScript(_ source: String, timeout: TimeInterval) -> String? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            logger.warning("osascript process start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if process.isRunning {
            process.terminate()
            logger.warning("osascript timed out after \(timeout, privacy: .public)s")
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let result, !result.isEmpty, isValidURL(result) else { return nil }
        return result
    }

    private func isValidURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, trimmed.count < 2048 else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("file://")
    }

    func insertText(_ text: String) async throws -> InsertionResult {
        guard isAccessibilityGranted else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general
        let isTextInput = isFocusedElementTextInput()

        // Save current clipboard contents
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if isTextInput {
            // Simulate Cmd+V
            simulatePaste()

            // Wait for paste to complete, then restore clipboard
            try await Task.sleep(for: .milliseconds(200))

            pasteboard.clearContents()
            for (typeRaw, data) in savedItems {
                let type = NSPasteboard.PasteboardType(typeRaw)
                pasteboard.setData(data, forType: type)
            }
            return .pasted
        } else {
            // No text field focused — leave text in clipboard for manual paste
            return .copiedToClipboard
        }
    }

    private func isFocusedElementTextInput() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        // Check role
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        if roleResult == .success, let role = roleValue as? String {
            let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
            if textInputRoles.contains(role) {
                return true
            }
        }

        // Fallback: check if element supports text selection (indicates text input)
        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        return rangeResult == .success
    }

    func focusedElementPosition() -> CGPoint? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else {
            return nil
        }

        // Try to get the caret position from selected text range
        var selectedRangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )

        if rangeResult == .success, let rangeValue = selectedRangeValue {
            var bounds: CFTypeRef?
            let boundsResult = AXUIElementCopyParameterizedAttributeValue(
                element as! AXUIElement,
                kAXBoundsForRangeParameterizedAttribute as CFString,
                rangeValue,
                &bounds
            )

            if boundsResult == .success, let boundsValue = bounds {
                var rect = CGRect.zero
                if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) {
                    return CGPoint(x: rect.origin.x + rect.width, y: rect.origin.y + rect.height)
                }
            }
        }

        // Fallback: get position of focused element
        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXPositionAttribute as CFString,
            &positionValue
        )

        if posResult == .success, let posValue = positionValue {
            var point = CGPoint.zero
            if AXValueGetValue(posValue as! AXValue, .cgPoint, &point) {
                return point
            }
        }

        return nil
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 0x09 = V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
