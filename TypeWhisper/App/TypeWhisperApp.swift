import SwiftUI
import Combine
#if !APPSTORE
@preconcurrency import Sparkle
#endif

struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceContainer = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra(AppConstants.isDevelopment ? "TypeWhisper Dev" : "TypeWhisper", systemImage: "waveform") {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)

        Window(String(localized: "Settings"), id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 750, height: 600)

        Window(String(localized: "History"), id: "history") {
            HistoryView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 700, height: 500)
    }

    init() {
        // Trigger ServiceContainer initialization
        _ = ServiceContainer.shared

        Task { @MainActor in
            await ServiceContainer.shared.initialize()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchIndicatorPanel: NotchIndicatorPanel?
    private var translationHostWindow: TranslationHostWindow?
    #if !APPSTORE
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var updateChecker: UpdateChecker {
        .sparkle(updaterController.updater)
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !APPSTORE
        UpdateChecker.shared = updateChecker
        #endif

        let notchPanel = NotchIndicatorPanel()
        notchPanel.startObserving()
        notchIndicatorPanel = notchPanel

        translationHostWindow = TranslationHostWindow(
            translationService: ServiceContainer.shared.translationService
        )
        ServiceContainer.shared.translationService.setInteractiveHostMode = { [weak self] enabled in
            self?.translationHostWindow?.setInteractiveMode(enabled)
            if enabled {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            } else if self?.hasVisibleManagedWindow != true {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        // Prompt palette hotkey - opens standalone prompt palette panel
        ServiceContainer.shared.hotkeyService.onPromptPaletteToggle = {
            DictationViewModel.shared.triggerStandalonePromptSelection()
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

    @MainActor private func isManagedWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id.localizedCaseInsensitiveContains("settings")
            || id.localizedCaseInsensitiveContains("history")
    }

    @MainActor private var hasVisibleManagedWindow: Bool {
        NSApp.windows.contains { isManagedWindow($0) && $0.isVisible }
    }

    @MainActor @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isManagedWindow(window)
        else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    @MainActor @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isManagedWindow(window)
        else { return }
        // Only go back to accessory if no other managed window is still visible
        DispatchQueue.main.async {
            if !self.hasVisibleManagedWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
