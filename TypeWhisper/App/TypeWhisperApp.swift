import SwiftUI
import AVFoundation
import Combine
#if !APPSTORE
@preconcurrency import Sparkle
#endif

extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        bool(forKey: UserDefaultsKeys.showMenuBarIcon)
    }
}

extension Notification.Name {
    static let openSettingsFromDock = Notification.Name("openSettingsFromDock")
}

struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceContainer = ServiceContainer.shared
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(AppConstants.isDevelopment ? "TypeWhisper Dev" : "TypeWhisper", systemImage: "waveform", isInserted: $showMenuBarIcon) {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)

        settingsScene

        Window(String(localized: "History"), id: "history") {
            HistoryView()
                .background(WindowBridge(windowID: "history"))
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 500)
    }

    private var settingsScene: some Scene {
        Window(String(localized: "Settings"), id: "settings") {
            SettingsView()
                .background(WindowBridge(windowID: "settings"))
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1050, height: 600)
    }

    init() {
        // Trigger ServiceContainer initialization
        _ = ServiceContainer.shared

        Task { @MainActor in
            await ServiceContainer.shared.initialize()
        }
    }
}

// MARK: - Settings Window Bridge

/// Captures the `openWindow` action and tags the hosting NSWindow with a stable identifier.
private struct WindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let windowID: String

    var body: some View {
        WindowAccessor { window in
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier(windowID)
            if windowID == "settings" {
                SettingsWindowOpener.shared.openWindow = openWindow
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsFromDock)) { _ in
            guard windowID == "settings" else { return }
            openWindow(id: "settings")
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

/// Stores the `openWindow` action captured from SwiftUI scene context.
@MainActor
final class SettingsWindowOpener {
    static let shared = SettingsWindowOpener()
    var openWindow: OpenWindowAction?

    func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow?(id: "settings")
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var indicatorCoordinator: IndicatorCoordinator?
    private var translationHostWindow: NSWindow?
    private var menuBarIconObserver: NSKeyValueObservation?
    #if !APPSTORE
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var updateChecker: UpdateChecker {
        .sparkle(updaterController.updater)
    }
    #endif

    private var isMenuBarIconHidden: Bool {
        !UserDefaults.standard.bool(forKey: UserDefaultsKeys.showMenuBarIcon)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            UserDefaultsKeys.showMenuBarIcon: true
        ])
        #if !APPSTORE
        UpdateChecker.shared = updateChecker
        #endif

        // If menu bar icon is hidden, show dock icon immediately
        if isMenuBarIconHidden {
            NSApp.setActivationPolicy(.regular)
        }

        let coordinator = IndicatorCoordinator()
        coordinator.startObserving()
        indicatorCoordinator = coordinator

        #if canImport(Translation)
        if #available(macOS 15, *), let ts = ServiceContainer.shared.translationService as? TranslationService {
            translationHostWindow = TranslationHostWindow(translationService: ts)
            ts.setInteractiveHostMode = { [weak self] enabled in
                (self?.translationHostWindow as? TranslationHostWindow)?.setInteractiveMode(enabled)
                if enabled {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                } else if self?.shouldRevertToAccessory == true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
        #endif

        // Prompt palette hotkey - opens standalone prompt palette panel
        ServiceContainer.shared.hotkeyService.onPromptPaletteToggle = {
            DictationViewModel.shared.triggerStandalonePromptSelection()
        }

        // Auto-open Settings with setup wizard when microphone permission is not yet granted
        if AVAudioApplication.shared.recordPermission != .granted {
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
            HomeViewModel.shared.showSetupWizard = true
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettingsWindow()
            }
        }

        // Observe menu bar icon visibility changes
        menuBarIconObserver = UserDefaults.standard.observe(
            \.showMenuBarIcon, options: [.new]
        ) { [weak self] _, change in
            DispatchQueue.main.async {
                let hidden = change.newValue == false
                if hidden {
                    NSApp.setActivationPolicy(.regular)
                } else if self?.hasVisibleManagedWindow != true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        // Observe settings window lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleManagedWindow {
            openSettingsWindow()
        }
        return true
    }

    @MainActor private func openSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Try existing window first (SwiftUI keeps it after close)
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "settings"
        }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Fall back to stored openWindow action from SwiftUI scene
        if SettingsWindowOpener.shared.openWindow != nil {
            SettingsWindowOpener.shared.openSettings()
            return
        }

        // Last resort: post notification for bridge view
        NotificationCenter.default.post(name: .openSettingsFromDock, object: nil)
    }

    @MainActor private func isManagedWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id == "settings" || id == "history"
    }

    @MainActor private var hasVisibleManagedWindow: Bool {
        NSApp.windows.contains { isManagedWindow($0) && $0.isVisible }
    }

    @MainActor private var shouldRevertToAccessory: Bool {
        !isMenuBarIconHidden && !hasVisibleManagedWindow
    }

    @MainActor @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isManagedWindow(window),
              window.isVisible
        else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isManagedWindow(window)
        else { return }
        // Only go back to accessory if menu bar icon is visible and no other managed window is open
        DispatchQueue.main.async {
            if self.shouldRevertToAccessory {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
