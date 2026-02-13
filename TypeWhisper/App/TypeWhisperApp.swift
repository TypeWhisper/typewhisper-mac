import SwiftUI
import Combine
@preconcurrency import Sparkle

@main
struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceContainer = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra("TypeWhisper", systemImage: "waveform") {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
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
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var updateChecker: UpdateChecker {
        .sparkle(updaterController.updater)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared = updateChecker
        let panel = DictationOverlayPanel()
        panel.startObserving()
        overlayPanel = panel

        // Keep settings window always on top
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @MainActor @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.level = .floating
        window.orderFrontRegardless()
    }
}
