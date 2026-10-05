#if APPSTORE
import AppKit
import CoreGraphics

/// Keyboard and mouse access of the Mac App Store edition.
///
/// The App Sandbox has no access to the Accessibility API of other apps, Apple
/// Events or event-suppressing taps. Two TCC services remain available:
///
/// - PostEvent (`CGEvent.post`) pastes text with a synthetic Cmd+V and reads
///   selected text with Cmd+C. System Settings lists it under Accessibility.
/// - ListenEvent (listen-only event tap) observes modifier-only, Fn,
///   double-tap and mouse-button shortcuts. System Settings lists it under
///   Input Monitoring.
///
/// Carbon hotkeys need neither. Without PostEvent, text is copied to the
/// clipboard for a manual paste.
enum AppStoreInputAccess {
    /// Build-time switch for synthetic paste (`TYPEWHISPER_APPSTORE_AUTOPASTE`).
    /// A clipboard-only build never posts events, in case App Review rejects
    /// synthetic paste under guideline 2.4.5.
    static let isAutoPasteEnabled: Bool = {
        switch Bundle.main.object(forInfoDictionaryKey: "TypeWhisperAutoPasteEnabled") {
        case let value as Bool:
            return value
        case let value as String:
            return ["yes", "true", "1"].contains(value.lowercased())
        default:
            return false
        }
    }()

    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )

    /// Whether the app may post keyboard events to other apps.
    static var canPostEvents: Bool {
        isAutoPasteEnabled && CGPreflightPostEventAccess()
    }

    /// Whether the app may observe keyboard and mouse events of other apps.
    static var canListenToEvents: Bool {
        CGPreflightListenEventAccess()
    }

    /// Name of the System Settings list that holds PostEvent access. macOS 27
    /// renamed Privacy & Security > Accessibility to Device Control and Data Access.
    static var postEventSettingsName: String {
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)) {
            return localizedAppText(
                "Device Control and Data Access",
                de: "Gerätesteuerung und Datenzugriff",
                ja: "デバイスの制御とデータへのアクセス",
                zh: "设备控制和数据访问"
            )
        }
        return localizedAppText("Accessibility", de: "Bedienungshilfen", ja: "アクセシビリティ", zh: "辅助功能")
    }

    static var listenEventSettingsName: String {
        localizedAppText("Input Monitoring", de: "Eingabeüberwachung", ja: "入力監視", zh: "输入监控")
    }

    /// Feedback after text was copied instead of pasted.
    static var manualPasteMessage: String {
        if isAutoPasteEnabled {
            return localizedAppText(
                "Copied to clipboard. Press ⌘V to paste, or allow TypeWhisper under \u{201C}\(postEventSettingsName)\u{201D} to paste automatically.",
                de: "In die Zwischenablage kopiert. Füge den Text mit ⌘V ein oder erlaube TypeWhisper unter „\(postEventSettingsName)“, um automatisch einzufügen."
            )
        }
        return localizedAppText(
            "Copied to clipboard. Press ⌘V to paste.",
            de: "In die Zwischenablage kopiert. Füge den Text mit ⌘V ein."
        )
    }

    /// Set once access was requested in this session. macOS may apply a newly
    /// granted Accessibility or Input Monitoring permission only after the app
    /// restarts, so the UI then offers a restart instead of waiting forever.
    nonisolated(unsafe) private(set) static var hasRequestedPostEventAccess = false
    nonisolated(unsafe) private(set) static var hasRequestedListenEventAccess = false

    /// Whether requested PostEvent access is still not in effect.
    static var postEventAccessPending: Bool {
        hasRequestedPostEventAccess && isAutoPasteEnabled && !CGPreflightPostEventAccess()
    }

    /// Whether requested ListenEvent access is still not in effect.
    static var listenEventAccessPending: Bool {
        hasRequestedListenEventAccess && !CGPreflightListenEventAccess()
    }

    /// Asks for PostEvent access. macOS 27 neither prompts for it nor lists a
    /// sandboxed app, so System Settings opens with a guide to drag the app in.
    @MainActor
    static func requestPostEventAccess() {
        guard isAutoPasteEnabled else { return }
        hasRequestedPostEventAccess = true
        guard !CGRequestPostEventAccess() else { return }
        openSettings(accessibilitySettingsURL)
        offerRestartOnReturn { postEventAccessPending }
    }

    /// Asks for ListenEvent access, opening System Settings with the same guide
    /// while it is missing.
    @MainActor
    static func requestListenEventAccess() {
        hasRequestedListenEventAccess = true
        guard !CGRequestListenEventAccess() else { return }
        openSettings(inputMonitoringSettingsURL)
        offerRestartOnReturn { listenEventAccessPending }
    }

    nonisolated(unsafe) private static var returnObserver: NSObjectProtocol?

    /// The running process cannot notice the grant: CoreGraphics caches its
    /// answer, so only a relaunched TypeWhisper gets it. When the user comes
    /// back from System Settings, ask once whether to restart.
    @MainActor
    private static func offerRestartOnReturn(isPending: @escaping @MainActor () -> Bool) {
        if let returnObserver {
            NotificationCenter.default.removeObserver(returnObserver)
        }
        returnObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let returnObserver {
                    NotificationCenter.default.removeObserver(returnObserver)
                }
                returnObserver = nil
                guard isPending() else { return }

                let alert = NSAlert()
                alert.messageText = localizedAppText(
                    "Did you turn on TypeWhisper?",
                    de: "Hast du TypeWhisper eingeschaltet?"
                )
                alert.informativeText = localizedAppText(
                    "macOS applies the permission after TypeWhisper restarts.",
                    de: "macOS übernimmt die Berechtigung erst nach einem Neustart von TypeWhisper."
                )
                alert.addButton(withTitle: localizedAppText("Restart TypeWhisper", de: "TypeWhisper neu starten"))
                alert.addButton(withTitle: localizedAppText("Later", de: "Später"))
                if alert.runModal() == .alertFirstButtonReturn {
                    ApplicationRelauncher.relaunch()
                }
            }
        }
    }

    private static func openSettings(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
#endif
