import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "TextInsertionService")

@MainActor
final class TargetAppAccessibilityObservationLease {
    private var endAction: (() -> Void)?

    init(endAction: @escaping () -> Void) {
        self.endAction = endAction
    }

    func end() {
        let action = endAction
        endAction = nil
        action?()
    }
}

@MainActor
final class ChromiumAccessibilityObservationController {
    struct RunningApplicationTarget: Equatable {
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let bundleURL: URL
    }

    typealias ResolveApplication = (String, pid_t?) -> RunningApplicationTarget?
    typealias IsElectronApplication = (URL) -> Bool
    typealias ReadManualAccessibility = (pid_t) -> (error: AXError, enabled: Bool?)
    typealias SetManualAccessibility = (pid_t, Bool) -> AXError
    typealias ValidateApplication = (RunningApplicationTarget) -> Bool

    private static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let chromiumBrowserBundleIdentifiers = SupportedMeetingBrowser
        .automaticURLBundleIdentifiers
        .subtracting([SupportedMeetingBrowser.safari])

    private let resolveApplication: ResolveApplication
    private let isElectronApplicationAtURL: IsElectronApplication
    private let readManualAccessibility: ReadManualAccessibility
    private let setManualAccessibility: SetManualAccessibility
    private let validateApplication: ValidateApplication

    init(
        resolveApplication: ResolveApplication? = nil,
        isElectronApplication: IsElectronApplication? = nil,
        readManualAccessibility: ReadManualAccessibility? = nil,
        setManualAccessibility: SetManualAccessibility? = nil,
        validateApplication: ValidateApplication? = nil
    ) {
        self.resolveApplication = resolveApplication ?? Self.resolveRunningApplication
        self.isElectronApplicationAtURL = isElectronApplication ?? Self.containsElectronFramework
        self.readManualAccessibility = readManualAccessibility ?? Self.readManualAccessibilityValue
        self.setManualAccessibility = setManualAccessibility ?? Self.setManualAccessibilityValue
        self.validateApplication = validateApplication ?? Self.isSameRunningApplication
    }

    func beginObservation(
        bundleIdentifier: String?,
        processIdentifier: pid_t? = nil
    ) -> TargetAppAccessibilityObservationLease? {
        guard let bundleIdentifier,
              let target = resolveApplication(bundleIdentifier, processIdentifier),
              Self.chromiumBrowserBundleIdentifiers.contains(target.bundleIdentifier)
                || isElectronApplicationAtURL(target.bundleURL) else {
            return nil
        }

        let currentState = readManualAccessibility(target.processIdentifier)
        guard currentState.error == .success,
              currentState.enabled == false,
              setManualAccessibility(target.processIdentifier, true) == .success else {
            return nil
        }

        return TargetAppAccessibilityObservationLease {
            guard self.validateApplication(target) else { return }
            _ = self.setManualAccessibility(target.processIdentifier, false)
        }
    }

    func isElectronApplication(bundleIdentifier: String) -> Bool {
        guard let target = resolveApplication(bundleIdentifier, nil) else { return false }
        return isElectronApplicationAtURL(target.bundleURL)
    }

    private static func resolveRunningApplication(
        bundleIdentifier: String,
        processIdentifier: pid_t?
    ) -> RunningApplicationTarget? {
        let application: NSRunningApplication?
        if let processIdentifier {
            let exactApplication = NSRunningApplication(processIdentifier: processIdentifier)
            application = exactApplication?.bundleIdentifier == bundleIdentifier
                ? exactApplication
                : nil
        } else {
            let runningApplication = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            application = runningApplication
                ?? (frontmostApplication?.bundleIdentifier == bundleIdentifier
                    ? frontmostApplication
                    : nil)
        }
        guard let application,
              !application.isTerminated,
              let resolvedBundleIdentifier = application.bundleIdentifier,
              let bundleURL = application.bundleURL else {
            return nil
        }

        return RunningApplicationTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: resolvedBundleIdentifier,
            bundleURL: bundleURL
        )
    }

    private static func containsElectronFramework(bundleURL: URL) -> Bool {
        let electronFrameworkURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("Electron Framework.framework", isDirectory: true)
        return FileManager.default.fileExists(atPath: electronFrameworkURL.path)
    }

    private static func readManualAccessibilityValue(
        processIdentifier: pid_t
    ) -> (error: AXError, enabled: Bool?) {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            application,
            manualAccessibilityAttribute,
            &value
        )
        return (error, (value as? NSNumber)?.boolValue)
    }

    private static func setManualAccessibilityValue(
        processIdentifier: pid_t,
        enabled: Bool
    ) -> AXError {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(processIdentifier),
            manualAccessibilityAttribute,
            NSNumber(value: enabled)
        )
    }

    private static func isSameRunningApplication(_ target: RunningApplicationTarget) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated else {
            return false
        }
        return application.bundleIdentifier == target.bundleIdentifier
            && application.bundleURL == target.bundleURL
    }
}

/// Inserts transcribed text into the active application via clipboard + simulated Cmd+V.
@MainActor
final class TextInsertionService {
    private static let liveFieldMessagingTimeout: Float = 0.05

    private let browserURLResolver: BrowserURLResolver
    private let chromiumAccessibilityObservationController: ChromiumAccessibilityObservationController
    private let syntheticPastePreferredBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "dev.warp.WarpPreview",
        "com.mitchellh.ghostty"
    ]
    // Gecko editors can report successful AX writes while applying text at
    // the wrong position or more than once. Prefer one synthetic paste.
    private let accessibilityInsertionExcludedBundleIdentifiers =
        SupportedMeetingBrowser.reminderOnlyBundleIdentifiers.union([
            "org.mozilla.thunderbird"
        ])
    private let generatedPasteboardMarkerTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
        .init("com.typewhisper.SpeechTranscription")
    ]

    typealias FocusedTextSnapshot = (value: String?, selectedText: String?, selectedRange: NSRange?)

    var accessibilityGrantedOverride: Bool?
    var pasteboardProvider: () -> NSPasteboard = { .general }
    var focusedTextElementOverride: (() -> AXUIElement?)?
    var focusedTextStateOverride: ((AXUIElement) -> FocusedTextSnapshot?)?
    var focusedTextPlaceholderOverride: ((AXUIElement) -> String?)?
    var liveFieldTargetEligibilityOverride: ((AXUIElement) -> Bool)?
    var liveFieldApplicationEligibilityOverride: ((String) -> Bool)?
    var liveFieldElectronApplicationOverride: ((String) -> Bool)?
    var secureTextElementOverride: ((AXUIElement) -> Bool)?
    var liveFieldElementProcessIdentifierOverride: ((AXUIElement) -> pid_t?)?
    var liveFieldApplicationMetadataOverride: ((pid_t) -> (name: String?, bundleId: String?, url: String?)?)?
    var liveFieldApplicationValidationOverride: ((pid_t, String) -> Bool)?
    var activatePinnedTargetApplicationOverride: ((pid_t) -> Bool)?
    var focusPinnedTargetElementOverride: ((AXUIElement) -> Bool)?
    var focusedApplicationProcessIdentifierOverride: (() -> pid_t?)?
    var chromiumAccessibilityObservationOverride: ((String?, pid_t?) -> TargetAppAccessibilityObservationLease?)?
    var setMessagingTimeoutOverride: ((AXUIElement, Float) -> Void)?
    var setSelectedRangeOverride: ((AXUIElement, NSRange) -> Bool)?
    var textSelectionOverride: (() -> TextSelection?)?
    var insertTextAtOverride: ((AXUIElement, String) -> Bool)?
    var pasteSimulatorOverride: (() -> Void)?
    var copySimulatorOverride: (() -> Void)?
    var returnSimulatorOverride: (() -> Void)?
    var captureActiveAppOverride: (() -> (name: String?, bundleId: String?, url: String?))?
    var selectedTextOverride: (() -> String?)?
    var textSelectionViaCopyOverride: (() -> String?)?
    var pasteVerificationAttempts = 10
    var pasteVerificationPollingDelay: Duration = .milliseconds(50)
    var defaultPasteFallbackRestoreDelay: Duration = .milliseconds(350)
    var richTextPasteFallbackRestoreDelay: Duration = .milliseconds(1500)
    var terminalPasteFallbackRestoreDelay: Duration = .milliseconds(900)
    var verifiedRestoreGraceDelay: Duration = .milliseconds(150)
    var autoEnterDelay: Duration = .milliseconds(50)
    var copySelectionRetryDelay: Duration = .milliseconds(120)
    var copySelectionReadSettleDelay: Duration = .milliseconds(20)

    /// A clipboard restore that runs after `insertText` has returned. Only one restore is
    /// pending at a time; the next clipboard write takes it over before saving the clipboard.
    private struct PendingClipboardRestore {
        let id: UUID
        let pasteboard: NSPasteboard
        let savedItems: ClipboardSnapshot
        /// Change count right after the generated payload was written. The snapshot is only
        /// restored while the clipboard still holds that payload.
        let ownedChangeCount: Int
        let task: Task<PasteVerification, Never>
    }

    private var pendingClipboardRestore: PendingClipboardRestore?

    init(
        browserURLResolver: BrowserURLResolver = BrowserURLResolver(),
        chromiumAccessibilityObservationController: ChromiumAccessibilityObservationController =
            ChromiumAccessibilityObservationController()
    ) {
        self.browserURLResolver = browserURLResolver
        self.chromiumAccessibilityObservationController = chromiumAccessibilityObservationController
    }

    enum InsertionResult: Equatable {
        case insertedViaAccessibility
        case pasted(verification: PasteVerification)
    }

    enum PasteVerification: Equatable {
        case verified
        case unverified(PasteVerificationFailure)
        /// Nothing needed the paste to land before `insertText` returned.
        case notAwaited
    }

    enum PasteVerificationFailure: String, Equatable {
        case focusedTextStateUnavailable = "focused-text-state-unavailable"
        case focusedTextUnchanged = "focused-text-unchanged"
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
        accessibilityGrantedOverride ?? AXIsProcessTrusted()
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

    func beginChromiumAccessibilityObservation(
        bundleIdentifier: String?,
        processIdentifier: pid_t? = nil
    ) -> TargetAppAccessibilityObservationLease? {
        if let chromiumAccessibilityObservationOverride {
            return chromiumAccessibilityObservationOverride(bundleIdentifier, processIdentifier)
        }
        return chromiumAccessibilityObservationController.beginObservation(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
    }

    func beginFocusedApplicationAccessibilityObservation() -> TargetAppAccessibilityObservationLease? {
        let workspaceApplication = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = captureActiveAppOverride?().bundleId
            ?? workspaceApplication?.bundleIdentifier
        let processIdentifier = focusedApplicationProcessIdentifierOverride?()
            ?? (captureActiveAppOverride == nil ? workspaceApplication?.processIdentifier : nil)
        return beginChromiumAccessibilityObservation(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
    }

    func resolveBrowserURL(bundleId: String) async -> String? {
        await browserURLResolver.activeURL(for: bundleId)?.absoluteString
    }

    func resolveBrowserInfo(bundleId: String) async -> (url: String?, title: String?) {
        let info = await browserURLResolver.activeBrowserInfo(for: bundleId)
        return (info.url?.absoluteString, info.title)
    }

    /// Captures the selected text and the AXUIElement it belongs to.
    struct TextSelection: @unchecked Sendable {
        let text: String
        let element: AXUIElement
    }

    struct InsertionContext: Equatable {
        let value: String
        let selectedRange: NSRange
        let selectedText: String?
        let previousCharacter: Character?
        let nextCharacter: Character?
    }

    typealias ClipboardItemSnapshot = [NSPasteboard.PasteboardType: Data]
    typealias ClipboardSnapshot = [ClipboardItemSnapshot]

    final class DeferredClipboardRestore: @unchecked Sendable {
        fileprivate var savedItems: ClipboardSnapshot?
        /// Change count after the selection copy. The snapshot is only restored while the
        /// clipboard still holds the copied selection.
        fileprivate let ownedChangeCount: Int

        fileprivate init(savedItems: ClipboardSnapshot, ownedChangeCount: Int) {
            self.savedItems = savedItems
            self.ownedChangeCount = ownedChangeCount
        }

        fileprivate func consumeSavedItems() -> ClipboardSnapshot? {
            let items = savedItems
            savedItems = nil
            return items
        }
    }

    struct CopiedTextSelection: @unchecked Sendable {
        let text: String
        let deferredClipboardRestore: DeferredClipboardRestore
    }

    struct PasteVerificationState {
        fileprivate let focusedTextState: FocusedTextState?
    }

    fileprivate struct FocusedTextState: Equatable {
        let element: AXUIElement
        let value: String?
        let selectedText: String?
        let selectedRange: NSRange?

        static func == (lhs: FocusedTextState, rhs: FocusedTextState) -> Bool {
            lhs.element == rhs.element &&
            lhs.value == rhs.value &&
            lhs.selectedText == rhs.selectedText &&
            lhs.selectedRange == rhs.selectedRange
        }
    }

    struct FocusedTextObservation: @unchecked Sendable {
        let element: AXUIElement
        let value: String
        let selectedText: String?
        let selectedRange: NSRange?
    }

    struct LiveFieldTarget: @unchecked Sendable {
        let applicationBundleIdentifier: String
        let applicationProcessIdentifier: pid_t
        fileprivate var element: AXUIElement
        let originalInsertionContext: InsertionContext
        fileprivate var expectedValue: String
        fileprivate var expectedCaret: NSRange
        fileprivate var ownedRange: NSRange
        fileprivate var provisionalText: String
        fileprivate(set) var hasAttemptedMutation = false

        var hasProvisionalText: Bool {
            !provisionalText.isEmpty
        }
    }

    struct PinnedInsertionTarget: @unchecked Sendable {
        let applicationBundleIdentifier: String
        let applicationProcessIdentifier: pid_t
        fileprivate let element: AXUIElement
        fileprivate let window: AXUIElement?
        let originalInsertionContext: InsertionContext?
    }

    struct LiveFieldRecordingRequestCapture: @unchecked Sendable {
        let activeApp: (name: String?, bundleId: String?, url: String?)
        let pinnedTarget: PinnedInsertionTarget
        let liveFieldTarget: LiveFieldTarget?
    }

    enum LiveFieldMutationResult {
        case applied(FocusedTextObservation)
        case detached
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

        let element: AXUIElement
        if let focusedTextElementOverride {
            guard let overrideElement = focusedTextElementOverride() else { return nil }
            element = overrideElement
        } else {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedElement: AnyObject?
            guard AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focusedElement
            ) == .success else {
                return nil
            }
            guard let focusedElement,
                  CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
                return nil
            }
            element = focusedElement as! AXUIElement
        }

        if let selection = selectionOwnedByElement(element) {
            return selection
        }
        return findSelectionInDescendants(of: element)
    }

    /// Returns the focused text element (even without selection), for later insertion.
    func getFocusedTextElement(messagingTimeout: Float? = nil) -> AXUIElement? {
        if let focusedTextElementOverride {
            guard let element = focusedTextElementOverride() else { return nil }
            applyMessagingTimeout(messagingTimeout, to: element)
            return element
        }
        guard isAccessibilityGranted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        applyMessagingTimeout(messagingTimeout, to: systemWide)
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        guard let element = axElement(from: focusedElement) else { return nil }
        applyMessagingTimeout(messagingTimeout, to: element)
        if isLiveFieldTextRole(element) {
            return element
        }
        return findEditableTextDescendant(of: element, messagingTimeout: messagingTimeout)
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
              let currentState = captureFocusedTextState(for: element) else {
            return false
        }
        guard let currentValue = currentState.value else {
            return false
        }
        return initialState.value != currentValue
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

    func restoreClipboardIfNeeded(_ deferredRestore: DeferredClipboardRestore?) {
        guard let deferredRestore,
              let savedItems = deferredRestore.consumeSavedItems() else { return }
        let pasteboard = pasteboardProvider()
        guard pasteboard.changeCount == deferredRestore.ownedChangeCount else {
            logger.info(
                "Skipping deferred clipboard restore because the clipboard changed after the selection copy: changeCount=\(pasteboard.changeCount, privacy: .public), owned=\(deferredRestore.ownedChangeCount, privacy: .public)"
            )
            return
        }
        restoreClipboard(savedItems, to: pasteboard)
    }

    /// Restores a pending clipboard snapshot now instead of after its delay, for example
    /// before the app terminates.
    func flushPendingClipboardRestore() {
        guard let pending = pendingClipboardRestore else { return }
        pendingClipboardRestore = nil
        pending.task.cancel()
        restoreClipboardIfOwned(pending)
    }

    /// Waits for the clipboard restore scheduled by the latest synthetic paste and returns
    /// the paste verification that selected its delay.
    @discardableResult
    func waitForPendingClipboardRestore() async -> PasteVerification? {
        guard let task = pendingClipboardRestore?.task else { return nil }
        return await task.value
    }

    var hasPendingClipboardRestore: Bool {
        pendingClipboardRestore != nil
    }

    /// Resolves a restore still waiting from an earlier insertion before the clipboard is
    /// written again. While the clipboard still holds that insertion's payload, the earlier
    /// snapshot is handed over so the user's original clipboard is what finally gets restored.
    private func takeOverPendingClipboardRestore(on pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        guard let pending = pendingClipboardRestore else { return nil }
        pendingClipboardRestore = nil
        pending.task.cancel()
        guard pending.pasteboard.name == pasteboard.name else {
            restoreClipboardIfOwned(pending)
            return nil
        }
        guard pasteboard.changeCount == pending.ownedChangeCount else {
            logger.info(
                "Dropping pending clipboard restore because the clipboard changed after insertion: changeCount=\(pasteboard.changeCount, privacy: .public), owned=\(pending.ownedChangeCount, privacy: .public)"
            )
            return nil
        }
        return pending.savedItems
    }

    /// Consumes a deferred selection-copy snapshot for a new insertion, but only while the
    /// clipboard still holds the copied selection.
    private func takeOverDeferredClipboardRestore(
        _ deferredRestore: DeferredClipboardRestore?,
        on pasteboard: NSPasteboard
    ) -> ClipboardSnapshot? {
        guard let deferredRestore,
              let savedItems = deferredRestore.consumeSavedItems() else { return nil }
        guard pasteboard.changeCount == deferredRestore.ownedChangeCount else {
            logger.info(
                "Ignoring deferred clipboard snapshot because the clipboard changed after the selection copy: changeCount=\(pasteboard.changeCount, privacy: .public), owned=\(deferredRestore.ownedChangeCount, privacy: .public)"
            )
            return nil
        }
        return savedItems
    }

    private func schedulePendingClipboardRestore(
        _ savedItems: ClipboardSnapshot,
        to pasteboard: NSPasteboard,
        ownedChangeCount: Int,
        verificationTask: Task<PasteVerification, Never>?,
        verificationState: PasteVerificationState,
        isTerminalApp: Bool,
        requiresPasteboardInsertion: Bool,
        bundleId: String?
    ) {
        let id = UUID()
        let task = Task { @MainActor [weak self] () -> PasteVerification in
            guard let self else { return .notAwaited }
            let verification: PasteVerification
            if let verificationTask {
                verification = await verificationTask.value
            } else {
                verification = await waitForPasteVerification(using: verificationState)
                logPasteVerification(verification, bundleId: bundleId)
            }
            let restoreDelay = clipboardRestoreDelay(
                after: verification,
                isTerminalApp: isTerminalApp,
                requiresPasteboardInsertion: requiresPasteboardInsertion
            )
            if verification != .verified {
                logger.warning(
                    "insertText delaying clipboard restore after unverified paste: bundle=\(bundleId ?? "nil", privacy: .public), delay=\(String(describing: restoreDelay), privacy: .public)"
                )
            }
            try? await Task.sleep(for: restoreDelay)
            finishPendingClipboardRestore(id: id)
            return verification
        }
        pendingClipboardRestore = PendingClipboardRestore(
            id: id,
            pasteboard: pasteboard,
            savedItems: savedItems,
            ownedChangeCount: ownedChangeCount,
            task: task
        )
    }

    private func finishPendingClipboardRestore(id: UUID) {
        // A later clipboard write or a flush already resolved this restore.
        guard let pending = pendingClipboardRestore, pending.id == id else { return }
        pendingClipboardRestore = nil
        restoreClipboardIfOwned(pending)
    }

    private func restoreClipboardIfOwned(_ pending: PendingClipboardRestore) {
        guard pending.pasteboard.changeCount == pending.ownedChangeCount else {
            logger.info(
                "insertText skipped clipboard restore because the clipboard changed after insertion: changeCount=\(pending.pasteboard.changeCount, privacy: .public), owned=\(pending.ownedChangeCount, privacy: .public)"
            )
            return
        }
        restoreClipboard(pending.savedItems, to: pending.pasteboard)
        logger.info(
            "insertText restored clipboard: changeCountAfterRestore=\(pending.pasteboard.changeCount, privacy: .public)"
        )
    }

    private func clipboardRestoreDelay(
        after verification: PasteVerification,
        isTerminalApp: Bool,
        requiresPasteboardInsertion: Bool
    ) -> Duration {
        if isTerminalApp {
            return terminalPasteFallbackRestoreDelay
        }
        if verification == .verified {
            return verifiedRestoreGraceDelay
        }
        if requiresPasteboardInsertion {
            return richTextPasteFallbackRestoreDelay
        }
        return defaultPasteFallbackRestoreDelay
    }

    func capturePasteVerificationState() -> PasteVerificationState {
        PasteVerificationState(focusedTextState: captureFocusedTextState())
    }

    func captureInsertionContext() -> InsertionContext? {
        guard let state = captureFocusedTextState(),
              let value = state.value,
              let selectedRange = state.selectedRange,
              let stringRange = Range(selectedRange, in: value) else {
            return nil
        }

        let previousCharacter = stringRange.lowerBound > value.startIndex
            ? value[value.index(before: stringRange.lowerBound)]
            : nil
        let nextCharacter = stringRange.upperBound < value.endIndex
            ? value[stringRange.upperBound]
            : nil

        return InsertionContext(
            value: value,
            selectedRange: selectedRange,
            selectedText: state.selectedText,
            previousCharacter: previousCharacter,
            nextCharacter: nextCharacter
        )
    }

    func captureLiveFieldTarget(expectedBundleIdentifier: String?) -> LiveFieldTarget? {
        guard isAccessibilityGranted else {
            logger.debug("Live field target rejected: Accessibility is not granted")
            return nil
        }
        guard let expectedBundleIdentifier else {
            logger.debug("Live field target rejected: target app has no bundle identifier")
            return nil
        }
        guard captureActiveApp().bundleId == expectedBundleIdentifier else {
            logger.debug("Live field target rejected: active app changed before capture")
            return nil
        }
        guard applicationSupportsVerifiedLiveFieldUpdates(expectedBundleIdentifier) else {
            logger.debug("Live field target rejected: app requires normal final insertion")
            return nil
        }
        guard let state = captureFocusedTextState(
            messagingTimeout: Self.liveFieldMessagingTimeout
        ) else {
            logger.debug("Live field target rejected: no readable focused text element")
            return nil
        }
        return makeLiveFieldTarget(
            from: state,
            applicationBundleIdentifier: expectedBundleIdentifier
        )
    }

    /// Pins the focused AX element without running the slower active-app context
    /// lookup. The full app and URL context is still captured after audio starts.
    func captureLiveFieldTargetAtRecordingRequest() -> LiveFieldRecordingRequestCapture? {
        guard isAccessibilityGranted else {
            logger.debug("Live field target rejected: Accessibility is not granted")
            return nil
        }
        guard let state = captureFocusedTextState(
            messagingTimeout: Self.liveFieldMessagingTimeout
        ) else {
            logger.debug("Live field target rejected: no readable focused text element")
            return nil
        }
        guard let processIdentifier = liveFieldProcessIdentifier(for: state.element),
              let activeApp = liveFieldApplicationMetadata(for: processIdentifier),
              let bundleIdentifier = activeApp.bundleId else {
            logger.debug("Live field target rejected: focused element has no running application")
            return nil
        }
        guard !isSecureTextElement(state.element) else {
            logger.debug("Pinned insertion target rejected: focused element is secure")
            return nil
        }

        let pinnedTarget = PinnedInsertionTarget(
            applicationBundleIdentifier: bundleIdentifier,
            applicationProcessIdentifier: processIdentifier,
            element: state.element,
            window: axElementAttribute(kAXWindowAttribute as CFString, from: state.element),
            originalInsertionContext: pinnedInsertionContext(from: state)
        )
        let liveFieldTarget = applicationSupportsVerifiedLiveFieldUpdates(bundleIdentifier)
            ? makeLiveFieldTarget(
                from: state,
                applicationBundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier
            )
            : nil
        logger.info(
            "Pinned insertion target captured: bundle=\(bundleIdentifier, privacy: .public), liveUpdates=\(liveFieldTarget != nil, privacy: .public)"
        )
        return LiveFieldRecordingRequestCapture(
            activeApp: activeApp,
            pinnedTarget: pinnedTarget,
            liveFieldTarget: liveFieldTarget
        )
    }

    private func pinnedInsertionContext(from state: FocusedTextState) -> InsertionContext? {
        guard let value = state.value,
              let selectedRange = state.selectedRange,
              selectedRange.length == 0,
              state.selectedText?.isEmpty != false,
              Range(selectedRange, in: value) != nil else {
            return nil
        }
        return insertionContext(
            value: value,
            selectedText: state.selectedText,
            selectedRange: selectedRange
        )
    }

    private func makeLiveFieldTarget(
        from state: FocusedTextState,
        applicationBundleIdentifier: String,
        processIdentifier knownProcessIdentifier: pid_t? = nil
    ) -> LiveFieldTarget? {
        guard !isSecureTextElement(state.element) else {
            logger.debug("Live field target rejected: focused element is secure")
            return nil
        }
        guard let value = state.value else {
            logger.debug("Live field target rejected: focused element has no readable value")
            return nil
        }
        guard let selectedRange = state.selectedRange else {
            logger.debug("Live field target rejected: focused element has no selected-text range")
            return nil
        }
        guard selectedRange.length == 0,
              state.selectedText?.isEmpty != false else {
            logger.debug("Live field target rejected: selection is not empty")
            return nil
        }
        guard Range(selectedRange, in: value) != nil else {
            logger.debug("Live field target rejected: selection is outside the readable value")
            return nil
        }
        guard isEligibleLiveFieldTarget(state.element) else {
            logger.debug("Live field target rejected: focused element is not eligible")
            return nil
        }
        guard let processIdentifier = knownProcessIdentifier
            ?? liveFieldProcessIdentifier(for: state.element) else {
            logger.debug("Live field target rejected: focused element has no owning process")
            return nil
        }

        let insertionContext = insertionContext(
            value: value,
            selectedText: state.selectedText,
            selectedRange: selectedRange
        )
        return LiveFieldTarget(
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationProcessIdentifier: processIdentifier,
            element: state.element,
            originalInsertionContext: insertionContext,
            expectedValue: value,
            expectedCaret: selectedRange,
            ownedRange: selectedRange,
            provisionalText: ""
        )
    }

    func replaceLiveFieldText(
        _ text: String,
        in target: inout LiveFieldTarget,
        knownTargetIsFocused: Bool? = nil
    ) -> LiveFieldMutationResult {
        guard let currentState = verifiedLiveFieldState(for: &target) else {
            return .detached
        }

        if text == target.provisionalText {
            return .applied(observation(from: currentState))
        }

        let targetWasFocused = knownTargetIsFocused ?? liveFieldTargetIsFocused(target)

        let expectedValue = (target.expectedValue as NSString).replacingCharacters(
            in: target.ownedRange,
            with: text
        )
        let replacementLength = (text as NSString).length
        let expectedCaret = NSRange(
            location: target.ownedRange.location + replacementLength,
            length: 0
        )
        let expectedOwnedRange = NSRange(
            location: target.ownedRange.location,
            length: replacementLength
        )

        guard setSelectedRange(target.ownedRange, on: target.element) else {
            return .detached
        }
        guard insertTextAt(element: target.element, text: text) else {
            _ = setSelectedRange(target.expectedCaret, on: target.element)
            return .detached
        }

        if targetWasFocused,
           !liveFieldTarget(
                target.element,
                hasValue: expectedValue,
                caret: expectedCaret
           ) {
            rebindLiveFieldTargetIfNeeded(
                &target,
                expectedValue: expectedValue,
                expectedCaret: expectedCaret
            )
        }

        if var resultingState = captureFocusedTextState(
            for: target.element,
            messagingTimeout: Self.liveFieldMessagingTimeout
        ),
           resultingState.value == expectedValue,
           resultingState.selectedRange != expectedCaret {
            _ = setSelectedRange(expectedCaret, on: target.element)
            resultingState = captureFocusedTextState(
                for: target.element,
                messagingTimeout: Self.liveFieldMessagingTimeout
            ) ?? resultingState
        }

        guard liveFieldApplicationIsValid(for: target),
              let resultingState = captureFocusedTextState(
                for: target.element,
                messagingTimeout: Self.liveFieldMessagingTimeout
              ),
              resultingState.value == expectedValue,
              resultingState.selectedRange == expectedCaret,
              resultingState.selectedText?.isEmpty != false,
              resultingState.element == target.element else {
            _ = setSelectedRange(target.expectedCaret, on: target.element)
            if let unchangedState = captureFocusedTextState(
                for: target.element,
                messagingTimeout: Self.liveFieldMessagingTimeout
            ),
               unchangedState.element == target.element,
               unchangedState.value == target.expectedValue,
               unchangedState.selectedRange == target.expectedCaret,
               unchangedState.selectedText?.isEmpty != false {
                return .detached
            }

            // AX reported a successful write but the resulting state is not
            // provably unchanged. Text may be present, so paste is unsafe.
            target.hasAttemptedMutation = true
            return .detached
        }

        target.hasAttemptedMutation = true
        target.element = resultingState.element
        target.expectedValue = expectedValue
        target.expectedCaret = expectedCaret
        target.ownedRange = expectedOwnedRange
        target.provisionalText = text
        return .applied(observation(from: resultingState))
    }

    func captureFocusedTextObservation() -> FocusedTextObservation? {
        guard let state = captureFocusedTextState(),
              let value = state.value else {
            return nil
        }

        return FocusedTextObservation(
            element: state.element,
            value: value,
            selectedText: state.selectedText,
            selectedRange: state.selectedRange
        )
    }

    func recaptureFocusedTextObservation(
        matching observation: FocusedTextObservation
    ) -> FocusedTextObservation? {
        guard let state = captureFocusedTextState(),
              state.element == observation.element,
              let value = state.value else {
            return nil
        }

        return FocusedTextObservation(
            element: state.element,
            value: value,
            selectedText: state.selectedText,
            selectedRange: state.selectedRange
        )
    }

    enum FocusedTextElementMatch: Equatable {
        case same
        case different
        case unavailable
    }

    func focusedTextElementMatch(_ observation: FocusedTextObservation) -> FocusedTextElementMatch {
        guard let focusedElement = getFocusedTextElement() else { return .unavailable }
        return focusedElement == observation.element ? .same : .different
    }

    func canRestoreClipboard(afterPasteUsing state: PasteVerificationState) -> Bool {
        guard let initialState = state.focusedTextState,
              let currentState = captureFocusedTextState(for: initialState.element) else {
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

    /// Inserts text into the focused application.
    ///
    /// A synthetic paste only waits for paste verification when the caller needs the paste to
    /// land before this returns (`autoEnter`, `awaitPasteVerification`). With `preserveClipboard`,
    /// the clipboard restore runs afterwards and only while the clipboard still holds the
    /// generated payload.
    func insertText(
        _ text: String,
        preserveClipboard: Bool = false,
        autoEnter: Bool = false,
        outputFormat: String? = nil,
        deferredClipboardRestore: DeferredClipboardRestore? = nil,
        awaitPasteVerification: Bool = false
    ) async throws -> InsertionResult {
        guard isAccessibilityGranted else {
            throw TextInsertionError.accessibilityNotGranted
        }

        let formattedClipboardPayload = ClipboardContentFormatter.payload(for: text, outputFormat: outputFormat)
        let requiresPasteboardInsertion = ClipboardContentFormatter.requiresPasteboardInsertion(
            outputFormat: outputFormat
        )
        let activeApp = captureActiveApp()
        let appName = activeApp.name
        let bundleId = activeApp.bundleId
        let isTerminalApp = bundleId.map { syntheticPastePreferredBundleIdentifiers.contains($0) } ?? false
        let requiresSyntheticPaste = bundleId.map {
            accessibilityInsertionExcludedBundleIdentifiers.contains($0)
        } ?? false
        let prefersSyntheticPaste = isTerminalApp || requiresSyntheticPaste

        logger.info(
            "insertText requested: app=\(appName ?? "nil", privacy: .public), bundle=\(bundleId ?? "nil", privacy: .public), preserveClipboard=\(preserveClipboard, privacy: .public), outputFormat=\(outputFormat ?? "plain", privacy: .public), prefersSyntheticPaste=\(prefersSyntheticPaste, privacy: .public)"
        )

        if preserveClipboard, !requiresPasteboardInsertion, !prefersSyntheticPaste,
           let focusedElement = getFocusedTextElement(),
           insertTextAtAndVerifyChange(element: focusedElement, text: text) {
            if autoEnter {
                try? await Task.sleep(for: autoEnterDelay)
                simulateReturn()
            }
            logger.info(
                "insertText completed via verified AX insertion: bundle=\(bundleId ?? "nil", privacy: .public)"
            )
            restoreClipboardIfNeeded(deferredClipboardRestore)
            return .insertedViaAccessibility
        }

        let pasteboard = pasteboardProvider()
        // Resolve an earlier restore before touching the clipboard so this insertion never
        // saves a previous dictation's payload as the user's original clipboard.
        let pendingOriginalItems = takeOverPendingClipboardRestore(on: pasteboard)
        let savedItems: ClipboardSnapshot = preserveClipboard
            ? (takeOverDeferredClipboardRestore(deferredClipboardRestore, on: pasteboard)
                ?? pendingOriginalItems
                ?? saveClipboard(from: pasteboard))
            : []
        let verifiesBeforeReturning = autoEnter || awaitPasteVerification
        let pasteVerificationState = verifiesBeforeReturning || preserveClipboard
            ? capturePasteVerificationState()
            : nil
        let initialChangeCount = pasteboard.changeCount

        // Set transcribed text on clipboard and simulate Cmd+V.
        // Text stays on clipboard as fallback if no text field is focused.
        pasteboard.clearContents()
        let generatedPayload = formattedClipboardPayload ?? ClipboardContentPayload(plainText: text)
        generatedPayload.write(to: pasteboard, markerTypes: generatedPasteboardMarkerTypes)
        let ownedChangeCount = pasteboard.changeCount
        logger.info(
            "insertText using synthetic paste: bundle=\(bundleId ?? "nil", privacy: .public), preserveClipboard=\(preserveClipboard, privacy: .public), changeCountBefore=\(initialChangeCount, privacy: .public), changeCountAfterWrite=\(ownedChangeCount, privacy: .public)"
        )
        simulatePaste()

        // One verification serves both this call and the clipboard restore.
        var verificationTask: Task<PasteVerification, Never>?
        if verifiesBeforeReturning, let pasteVerificationState {
            verificationTask = Task { @MainActor [weak self] () -> PasteVerification in
                guard let self else { return .unverified(.focusedTextStateUnavailable) }
                let verification = await waitForPasteVerification(using: pasteVerificationState)
                logPasteVerification(verification, bundleId: bundleId)
                return verification
            }
        }

        // Register the restore before waiting for verification. An insertion or selection copy
        // that runs meanwhile then takes over the user's original clipboard instead of saving
        // this insertion's payload as the clipboard to restore.
        if preserveClipboard, let pasteVerificationState {
            schedulePendingClipboardRestore(
                savedItems,
                to: pasteboard,
                ownedChangeCount: ownedChangeCount,
                verificationTask: verificationTask,
                verificationState: pasteVerificationState,
                isTerminalApp: isTerminalApp,
                requiresPasteboardInsertion: requiresPasteboardInsertion,
                bundleId: bundleId
            )
        }

        // Cancelling the caller does not cancel the verification: the pending restore still
        // waits for the paste to land (bounded by the polling attempts) before restoring.
        let verification: PasteVerification
        if let verificationTask {
            verification = await verificationTask.value
        } else {
            verification = .notAwaited
        }

        if autoEnter {
            try? await Task.sleep(for: autoEnterDelay)
            simulateReturn()
        }

        return .pasted(verification: verification)
    }

    private func waitForPasteVerification(using state: PasteVerificationState) async -> PasteVerification {
        guard state.focusedTextState != nil else {
            return .unverified(.focusedTextStateUnavailable)
        }

        let attempts = max(0, pasteVerificationAttempts)
        for attempt in 0...attempts {
            if canRestoreClipboard(afterPasteUsing: state) {
                return .verified
            }
            guard attempt < attempts, !Task.isCancelled else { break }
            try? await Task.sleep(for: pasteVerificationPollingDelay)
        }

        return canRestoreClipboard(afterPasteUsing: state)
            ? .verified
            : .unverified(.focusedTextUnchanged)
    }

    private func logPasteVerification(_ verification: PasteVerification, bundleId: String?) {
        switch verification {
        case .verified:
            logger.info("insertText paste verified: bundle=\(bundleId ?? "nil", privacy: .public)")
        case .unverified(let reason):
            logger.info(
                "insertText paste unverified: bundle=\(bundleId ?? "nil", privacy: .public), reason=\(reason.rawValue, privacy: .public)"
            )
        case .notAwaited:
            break
        }
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

    nonisolated static let simulatedReturnEventMarker: Int64 = 0x545752455455524E

    func simulateReturn() {
        if let returnSimulatorOverride {
            returnSimulatorOverride()
            return
        }
        let returnKeyCode: CGKeyCode = 0x24
        let eventSource = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: returnKeyCode, keyDown: true)
        keyDown?.setIntegerValueField(.eventSourceUserData, value: Self.simulatedReturnEventMarker)
        keyDown?.flags = []
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: returnKeyCode, keyDown: false)
        keyUp?.setIntegerValueField(.eventSourceUserData, value: Self.simulatedReturnEventMarker)
        keyUp?.flags = []
        keyUp?.post(tap: .cghidEventTap)
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
        if let copySimulatorOverride {
            copySimulatorOverride()
            return
        }
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

        for keyCode: UInt16 in 0...127 {
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
            if status == noErr && length > 0 {
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
        guard let copiedSelection = await getTextSelectionViaCopy(deferClipboardRestore: false) else {
            return nil
        }
        return copiedSelection.text
    }

    /// Attempts Cmd+C while carrying the original clipboard snapshot into the later insertion step.
    func getTextSelectionViaCopyPreservingClipboardForInsertion() async -> CopiedTextSelection? {
        await getTextSelectionViaCopy(deferClipboardRestore: true)
    }

    private func getTextSelectionViaCopy(deferClipboardRestore: Bool) async -> CopiedTextSelection? {
        if let textSelectionViaCopyOverride {
            let pasteboard = pasteboardProvider()
            let savedItems = takeOverPendingClipboardRestore(on: pasteboard)
                ?? saveClipboard(from: pasteboard)
            guard let text = textSelectionViaCopyOverride(), !text.isEmpty else {
                restoreClipboard(savedItems, to: pasteboard)
                return nil
            }
            let deferredRestore = DeferredClipboardRestore(
                savedItems: savedItems,
                ownedChangeCount: pasteboard.changeCount
            )
            if !deferClipboardRestore {
                restoreClipboardIfNeeded(deferredRestore)
            }
            return CopiedTextSelection(text: text, deferredClipboardRestore: deferredRestore)
        }

        let pasteboard = pasteboardProvider()

        // Save current clipboard contents (all types). A restore still pending from an earlier
        // insertion holds the user's original clipboard, so continue from that snapshot.
        let savedItems = takeOverPendingClipboardRestore(on: pasteboard)
            ?? saveClipboard(from: pasteboard)

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let initialChangeCount = pasteboard.changeCount
            simulateCopy()

            guard await waitForPasteboardChange(on: pasteboard, after: initialChangeCount) else {
                if attempt < maxAttempts {
                    try? await Task.sleep(for: copySelectionRetryDelay)
                    continue
                }
                restoreClipboard(savedItems, to: pasteboard)
                return nil
            }

            try? await Task.sleep(for: copySelectionReadSettleDelay)

            // Read copied text
            let copiedText = pasteboard.string(forType: .string)

            guard let text = copiedText, !text.isEmpty else {
                restoreClipboard(savedItems, to: pasteboard)
                if attempt < maxAttempts {
                    try? await Task.sleep(for: copySelectionRetryDelay)
                    continue
                }
                return nil
            }

            let deferredRestore = DeferredClipboardRestore(
                savedItems: savedItems,
                ownedChangeCount: pasteboard.changeCount
            )
            if !deferClipboardRestore {
                restoreClipboardIfNeeded(deferredRestore)
            }

            return CopiedTextSelection(text: text, deferredClipboardRestore: deferredRestore)
        }
        restoreClipboard(savedItems, to: pasteboard)
        return nil
    }

    private func waitForPasteboardChange(on pasteboard: NSPasteboard, after changeCount: Int) async -> Bool {
        let attempts = 100
        for attempt in 0...attempts {
            if pasteboard.changeCount != changeCount {
                return true
            }
            guard attempt < attempts else { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
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

    private func selectionOwnedByElement(_ element: AXUIElement) -> TextSelection? {
        var selectedText: AnyObject?
        let selectedTextResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )
        if selectedTextResult == .success,
           let text = selectedText as? String,
           !text.isEmpty {
            return TextSelection(text: text, element: element)
        }

        guard let text = selectedTextFromFocusedState(for: element) else {
            return nil
        }
        return TextSelection(text: text, element: element)
    }

    private func findSelectionInDescendants(of root: AXUIElement) -> TextSelection? {
        findSelectionInDescendants(of: root, maxDepth: 6, maxNodes: 80)
    }

    private func findEditableTextDescendant(
        of root: AXUIElement,
        messagingTimeout: Float? = nil
    ) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = childElements(of: root).map { ($0, 1) }
        var visited = 0

        while !queue.isEmpty && visited < 80 {
            let current = queue.removeFirst()
            visited += 1
            applyMessagingTimeout(messagingTimeout, to: current.element)

            if isLiveFieldTextRole(current.element),
               selectedRangeAttribute(from: current.element) != nil {
                return current.element
            }

            if current.depth < 6 {
                queue.append(contentsOf: childElements(of: current.element).map {
                    ($0, current.depth + 1)
                })
            }
        }

        return nil
    }

    private func findSelectionInDescendants(
        of root: AXUIElement,
        maxDepth: Int,
        maxNodes: Int
    ) -> TextSelection? {
        var queue: [(element: AXUIElement, depth: Int)] = childElements(of: root).map { ($0, 1) }
        var visited = 0

        while !queue.isEmpty && visited < maxNodes {
            let current = queue.removeFirst()
            visited += 1

            if let selection = selectionOwnedByElement(current.element) {
                return selection
            }

            if current.depth < maxDepth {
                queue.append(contentsOf: childElements(of: current.element).map { ($0, current.depth + 1) })
            }
        }

        return nil
    }

    private func childElements(of element: AXUIElement) -> [AXUIElement] {
        var children: [AXUIElement] = []
        for attribute in [
            kAXChildrenAttribute as CFString,
            kAXContentsAttribute as CFString,
            "AXVisibleChildren" as CFString
        ] {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
                continue
            }

            if let child = axElement(from: value) {
                children.append(child)
            } else if let childArray = value as? [AXUIElement] {
                children.append(contentsOf: childArray)
            } else if let objectArray = value as? [AnyObject] {
                children.append(contentsOf: objectArray.compactMap { axElement(from: $0) })
            }
        }
        return children
    }

    private func axElement(from value: AnyObject?) -> AXUIElement? {
        guard let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func axElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return axElement(from: value)
    }

    private func selectedTextFromFocusedState(for element: AXUIElement) -> String? {
        if let selectedRangesText = selectedTextFromSelectedTextRangesAttribute(for: element) {
            return selectedRangesText
        }

        var selectedRangeValue: AnyObject?
        let selectedRangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        )
        if selectedRangeResult == .success,
           let selectedRangeValue,
           let selectedRangeText = selectedText(from: selectedRangeValue, for: element) {
            return selectedRangeText
        }

        guard let state = captureFocusedTextState(for: element),
              let selectedRange = state.selectedRange else {
            return nil
        }

        return selectedText(from: selectedRange, value: state.value)
    }

    private func selectedTextFromSelectedTextRangesAttribute(for element: AXUIElement) -> String? {
        var selectedRangesValue: AnyObject?
        let selectedRangesResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangesAttribute as CFString,
            &selectedRangesValue
        )
        let selectedRanges = selectedRangesValue as? [AnyObject]
        guard selectedRangesResult == .success,
              let selectedRanges,
              !selectedRanges.isEmpty else {
            return nil
        }

        let fragments = selectedRanges.compactMap { selectedText(from: $0, for: element) }
        guard !fragments.isEmpty else { return nil }
        return fragments.joined(separator: "\n")
    }

    private func selectedText(from rangeValue: AnyObject, for element: AXUIElement) -> String? {
        if let parameterizedText = stringForRange(rangeValue, from: element) {
            return parameterizedText
        }

        guard let range = nsRange(from: rangeValue),
              let value = stringAttribute(kAXValueAttribute as CFString, from: element) else {
            return nil
        }

        return selectedText(from: range, value: value)
    }

    private func stringForRange(_ rangeValue: AnyObject, from element: AXUIElement) -> String? {
        var textValue: AnyObject?
        let stringForRangeResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textValue
        )
        let text = textValue as? String
        guard stringForRangeResult == .success,
              let text,
              !text.isEmpty else {
            return nil
        }

        return text
    }

    private func selectedText(from range: NSRange, value: String?) -> String? {
        guard let value,
              range.length > 0,
              let stringRange = Range(range, in: value) else {
            return nil
        }

        let text = String(value[stringRange])
        return text.isEmpty ? nil : text
    }

    private func captureFocusedTextState(messagingTimeout: Float? = nil) -> FocusedTextState? {
        guard let element = getFocusedTextElement(messagingTimeout: messagingTimeout) else { return nil }
        return captureFocusedTextState(for: element, messagingTimeout: messagingTimeout)
    }

    private func captureFocusedTextState(
        for element: AXUIElement,
        messagingTimeout: Float? = nil
    ) -> FocusedTextState? {
        applyMessagingTimeout(messagingTimeout, to: element)
        if let focusedTextStateOverride {
            guard let snapshot = focusedTextStateOverride(element) else { return nil }
            return FocusedTextState(
                element: element,
                value: normalizedTextValue(
                    snapshot.value,
                    placeholder: focusedTextPlaceholderOverride?(element),
                    selectedRange: snapshot.selectedRange
                ),
                selectedText: snapshot.selectedText,
                selectedRange: snapshot.selectedRange
            )
        }

        let selectedRange = selectedRangeAttribute(from: element)
        return FocusedTextState(
            element: element,
            value: normalizedTextValue(
                stringAttribute(kAXValueAttribute as CFString, from: element),
                placeholder: stringAttribute(kAXPlaceholderValueAttribute as CFString, from: element),
                selectedRange: selectedRange
            ),
            selectedText: stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
            selectedRange: selectedRange
        )
    }

    private func normalizedTextValue(
        _ value: String?,
        placeholder: String?,
        selectedRange: NSRange?
    ) -> String? {
        guard let value,
              let placeholder,
              !placeholder.isEmpty,
              value == placeholder,
              selectedRange == NSRange(location: 0, length: 0) else {
            return value
        }

        // Chromium/Electron content-editable fields can expose their visible
        // placeholder through AXValue. It disappears on the first real write,
        // so treating it as document content would make verification detach.
        return ""
    }

    private func insertionContext(
        value: String,
        selectedText: String?,
        selectedRange: NSRange
    ) -> InsertionContext {
        let stringRange = Range(selectedRange, in: value)
        let previousCharacter = stringRange.flatMap { range in
            range.lowerBound > value.startIndex
                ? value[value.index(before: range.lowerBound)]
                : nil
        }
        let nextCharacter = stringRange.flatMap { range in
            range.upperBound < value.endIndex ? value[range.upperBound] : nil
        }

        return InsertionContext(
            value: value,
            selectedRange: selectedRange,
            selectedText: selectedText,
            previousCharacter: previousCharacter,
            nextCharacter: nextCharacter
        )
    }

    private func verifiedLiveFieldState(for target: inout LiveFieldTarget) -> FocusedTextState? {
        guard liveFieldApplicationIsValid(for: target) else {
            return nil
        }
        guard let state = captureFocusedTextState(
                for: target.element,
                messagingTimeout: Self.liveFieldMessagingTimeout
              ),
              state.value == target.expectedValue,
              state.selectedRange == target.expectedCaret,
              state.selectedText?.isEmpty != false else {
            return nil
        }
        return FocusedTextState(
            element: target.element,
            value: target.expectedValue,
            selectedText: nil,
            selectedRange: target.expectedCaret
        )
    }

    private func liveFieldTarget(
        _ element: AXUIElement,
        hasValue expectedValue: String,
        caret expectedCaret: NSRange
    ) -> Bool {
        guard let state = captureFocusedTextState(
            for: element,
            messagingTimeout: Self.liveFieldMessagingTimeout
        ) else {
            return false
        }
        return state.value == expectedValue
            && state.selectedRange == expectedCaret
            && state.selectedText?.isEmpty != false
    }

    private func rebindLiveFieldTargetIfNeeded(
        _ target: inout LiveFieldTarget,
        expectedValue: String,
        expectedCaret: NSRange
    ) {
        guard captureActiveApp().bundleId == target.applicationBundleIdentifier,
              let focusedElement = getFocusedTextElement(
                messagingTimeout: Self.liveFieldMessagingTimeout
              ),
              focusedElement != target.element,
              liveFieldProcessIdentifier(for: focusedElement)
                == target.applicationProcessIdentifier,
              isEligibleLiveFieldTarget(focusedElement),
              !isSecureTextElement(focusedElement),
              let focusedState = captureFocusedTextState(
                for: focusedElement,
                messagingTimeout: Self.liveFieldMessagingTimeout
              ),
              focusedState.value == expectedValue,
              focusedState.selectedRange == expectedCaret,
              focusedState.selectedText?.isEmpty != false else {
            return
        }
        target.element = focusedElement
    }

    func liveFieldTargetIsFocused(_ target: LiveFieldTarget) -> Bool {
        liveFieldTargetIsFocused(
            target,
            knownActiveBundleIdentifier: captureActiveApp().bundleId
        )
    }

    func liveFieldTargetIsFocused(
        _ target: LiveFieldTarget,
        knownActiveBundleIdentifier: String?
    ) -> Bool {
        guard liveFieldApplicationIsValid(for: target),
              knownActiveBundleIdentifier == target.applicationBundleIdentifier,
              let focusedElement = getFocusedTextElement(
                messagingTimeout: Self.liveFieldMessagingTimeout
              ),
              focusedElement == target.element else {
            return false
        }
        return true
    }

    func pinnedInsertionTargetIsFocused(_ target: PinnedInsertionTarget) -> Bool {
        pinnedInsertionTargetIsFocused(
            target,
            knownActiveBundleIdentifier: captureActiveApp().bundleId
        )
    }

    func pinnedInsertionTargetIsFocused(
        _ target: PinnedInsertionTarget,
        knownActiveBundleIdentifier: String?
    ) -> Bool {
        guard liveFieldApplicationIsValid(
            processIdentifier: target.applicationProcessIdentifier,
            bundleIdentifier: target.applicationBundleIdentifier
        ),
        knownActiveBundleIdentifier == target.applicationBundleIdentifier,
        let focusedElement = getFocusedTextElement(
            messagingTimeout: Self.liveFieldMessagingTimeout
        ) else {
            return false
        }
        return focusedElement == target.element
    }

    func focusPinnedInsertionTarget(_ target: PinnedInsertionTarget) async -> Bool {
        if pinnedInsertionTargetIsFocused(target) {
            return true
        }
        guard liveFieldApplicationIsValid(
            processIdentifier: target.applicationProcessIdentifier,
            bundleIdentifier: target.applicationBundleIdentifier
        ),
        activatePinnedTargetApplication(target.applicationProcessIdentifier) else {
            logger.info("Pinned insertion target activation failed")
            return false
        }

        for attempt in 0..<5 {
            if let window = target.window {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(
                    window,
                    kAXMainAttribute as CFString,
                    kCFBooleanTrue
                )
            }
            _ = focusPinnedTargetElement(target.element)

            if pinnedInsertionTargetIsFocused(target) {
                logger.info("Pinned insertion target restored on attempt \(attempt + 1, privacy: .public)")
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }

        logger.info("Pinned insertion target could not be restored safely")
        return false
    }

    private func activatePinnedTargetApplication(_ processIdentifier: pid_t) -> Bool {
        if let activatePinnedTargetApplicationOverride {
            return activatePinnedTargetApplicationOverride(processIdentifier)
        }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            return false
        }
        if let sourceApplication = NSWorkspace.shared.frontmostApplication,
           sourceApplication.processIdentifier != processIdentifier,
           application.activate(from: sourceApplication) {
            return true
        }
        return application.activate()
    }

    private func focusPinnedTargetElement(_ element: AXUIElement) -> Bool {
        if let focusPinnedTargetElementOverride {
            return focusPinnedTargetElementOverride(element)
        }
        return AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private func liveFieldProcessIdentifier(for element: AXUIElement) -> pid_t? {
        if let liveFieldElementProcessIdentifierOverride {
            return liveFieldElementProcessIdentifierOverride(element)
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0 else {
            return nil
        }
        return processIdentifier
    }

    private func liveFieldApplicationMetadata(
        for processIdentifier: pid_t
    ) -> (name: String?, bundleId: String?, url: String?)? {
        if let liveFieldApplicationMetadataOverride {
            return liveFieldApplicationMetadataOverride(processIdentifier)
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated else {
            return nil
        }
        return (
            name: application.localizedName,
            bundleId: application.bundleIdentifier,
            url: nil
        )
    }

    private func liveFieldApplicationIsValid(for target: LiveFieldTarget) -> Bool {
        liveFieldApplicationIsValid(
            processIdentifier: target.applicationProcessIdentifier,
            bundleIdentifier: target.applicationBundleIdentifier
        )
    }

    private func liveFieldApplicationIsValid(
        processIdentifier: pid_t,
        bundleIdentifier: String
    ) -> Bool {
        if let liveFieldApplicationValidationOverride {
            return liveFieldApplicationValidationOverride(
                processIdentifier,
                bundleIdentifier
            )
        }

        guard let application = NSRunningApplication(
            processIdentifier: processIdentifier
        ),
        !application.isTerminated else {
            return false
        }
        return application.bundleIdentifier == bundleIdentifier
    }

    private func applyMessagingTimeout(_ timeout: Float?, to element: AXUIElement) {
        guard let timeout, timeout > 0 else { return }
        if let setMessagingTimeoutOverride {
            setMessagingTimeoutOverride(element, timeout)
        } else {
            _ = AXUIElementSetMessagingTimeout(element, timeout)
        }
    }

    private func applicationSupportsVerifiedLiveFieldUpdates(
        _ bundleIdentifier: String
    ) -> Bool {
        if let liveFieldApplicationEligibilityOverride {
            return liveFieldApplicationEligibilityOverride(bundleIdentifier)
        }

        return !accessibilityInsertionExcludedBundleIdentifiers.contains(bundleIdentifier)
            && !isElectronApplication(bundleIdentifier)
    }

    private func isElectronApplication(_ bundleIdentifier: String) -> Bool {
        if let liveFieldElectronApplicationOverride {
            return liveFieldElectronApplicationOverride(bundleIdentifier)
        }

        return chromiumAccessibilityObservationController.isElectronApplication(
            bundleIdentifier: bundleIdentifier
        )
    }

    private func observation(from state: FocusedTextState) -> FocusedTextObservation {
        FocusedTextObservation(
            element: state.element,
            value: state.value ?? "",
            selectedText: state.selectedText,
            selectedRange: state.selectedRange
        )
    }

    private func isEligibleLiveFieldTarget(_ element: AXUIElement) -> Bool {
        if let liveFieldTargetEligibilityOverride {
            return liveFieldTargetEligibilityOverride(element)
        }

        guard isLiveFieldTextRole(element) else { return false }

        var selectedTextSettable = DarwinBoolean(false)
        var selectedRangeSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success,
        AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeSettable
        ) == .success else {
            return false
        }
        return selectedTextSettable.boolValue && selectedRangeSettable.boolValue
    }

    private func isLiveFieldTextRole(_ element: AXUIElement) -> Bool {
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String else {
            return false
        }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
            .contains(role)
    }

    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        if let secureTextElementOverride {
            return secureTextElementOverride(element)
        }

        var subroleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success else {
            return false
        }
        return (subroleValue as? String) == "AXSecureTextField"
    }

    private func setSelectedRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        if let setSelectedRangeOverride {
            return setSelectedRangeOverride(element, range)
        }

        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        if let string = value as? String {
            return string
        }
        return (value as? NSAttributedString)?.string
    }

    private func selectedRangeAttribute(from element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let rangeValue = value else {
            return nil
        }

        return nsRange(from: rangeValue)
    }

    private func nsRange(from rangeValue: AnyObject) -> NSRange? {
        var range = CFRange()
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

}

@MainActor
final class LiveFieldTranscriptSession {
    enum State: Equatable {
        case active
        case detached
        case finalized
        case cancelled
    }

    enum CompletionResult {
        case applied(TextInsertionService.FocusedTextObservation)
        case detached(hadAttemptedMutation: Bool, allowsFocusedFallback: Bool)
    }

    let sessionID: UUID
    private(set) var state: State = .active
    private(set) var target: TextInsertionService.LiveFieldTarget

    private let textInsertionService: TextInsertionService
    private let updateInterval: Duration
    private var pendingText: String?
    private var updateTask: Task<Void, Never>?

    init(
        sessionID: UUID,
        target: TextInsertionService.LiveFieldTarget,
        textInsertionService: TextInsertionService,
        updateInterval: Duration = .milliseconds(120)
    ) {
        self.sessionID = sessionID
        self.target = target
        self.textInsertionService = textInsertionService
        self.updateInterval = updateInterval
    }

    deinit {
        updateTask?.cancel()
    }

    var originalInsertionContext: TextInsertionService.InsertionContext {
        target.originalInsertionContext
    }

    var hasAttemptedMutation: Bool {
        target.hasAttemptedMutation
    }

    var hasProvisionalText: Bool {
        target.hasProvisionalText
    }

    var targetIsCurrentlyFocused: Bool {
        textInsertionService.liveFieldTargetIsFocused(target)
    }

    func receivePartial(_ text: String) {
        guard state == .active,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        pendingText = text
        schedulePendingUpdateIfNeeded()
    }

    func finalize(with text: String) -> CompletionResult {
        cancelPendingUpdate()
        guard state == .active else {
            return detachedCompletionResult()
        }

        switch textInsertionService.replaceLiveFieldText(text, in: &target) {
        case .applied(let observation):
            state = .finalized
            return .applied(observation)
        case .detached:
            state = .detached
            return detachedCompletionResult()
        }
    }

    func cancel() -> CompletionResult {
        cancelPendingUpdate()
        guard state == .active else {
            return detachedCompletionResult()
        }

        switch textInsertionService.replaceLiveFieldText("", in: &target) {
        case .applied(let observation):
            state = .cancelled
            return .applied(observation)
        case .detached:
            state = .detached
            return detachedCompletionResult()
        }
    }

    func keepProvisionalText() {
        cancelPendingUpdate()
        guard state == .active else { return }
        state = .finalized
    }

    private func schedulePendingUpdateIfNeeded() {
        guard updateTask == nil else { return }
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: updateInterval)
            guard !Task.isCancelled else { return }
            applyPendingUpdate()
        }
    }

    private func applyPendingUpdate() {
        updateTask = nil
        guard state == .active, let pendingText else { return }
        self.pendingText = nil
        let targetIsFocused = targetIsCurrentlyFocused
        guard targetIsFocused else {
            logger.debug("Pausing live-field partial updates while the pinned target is not focused")
            return
        }

        switch textInsertionService.replaceLiveFieldText(
            pendingText,
            in: &target,
            knownTargetIsFocused: targetIsFocused
        ) {
        case .applied:
            if self.pendingText != nil {
                schedulePendingUpdateIfNeeded()
            }
        case .detached:
            state = .detached
            self.pendingText = nil
        }
    }

    private func cancelPendingUpdate() {
        updateTask?.cancel()
        updateTask = nil
        pendingText = nil
    }

    private func detachedCompletionResult() -> CompletionResult {
        .detached(
            hadAttemptedMutation: target.hasAttemptedMutation,
            allowsFocusedFallback: textInsertionService.liveFieldTargetIsFocused(target)
        )
    }
}
