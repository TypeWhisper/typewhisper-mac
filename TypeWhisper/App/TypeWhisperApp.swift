import SwiftUI
import Combine
@preconcurrency import Sparkle

struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceContainer = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra("TypeWhisper", systemImage: "waveform") {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)

        Window(String(localized: "Settings"), id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 750, height: 600)
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
    private var overlayPanel: DictationOverlayPanel?
    private var translationHostWindow: TranslationHostWindow?
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var updateChecker: UpdateChecker {
        .sparkle(updaterController.updater)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared = updateChecker
        let panel = DictationOverlayPanel()
        panel.startObserving()
        overlayPanel = panel

        translationHostWindow = TranslationHostWindow(
            translationService: ServiceContainer.shared.translationService
        )

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

    @MainActor private func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
    }

    @MainActor @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isSettingsWindow(window)
        else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.level = .floating
        window.orderFrontRegardless()
    }

    @MainActor @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isSettingsWindow(window)
        else { return }
        window.level = .normal
        NSApp.setActivationPolicy(.accessory)
    }
}
