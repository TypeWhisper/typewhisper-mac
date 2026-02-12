import SwiftUI
import Combine

@main
struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var serviceContainer = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra("TypeWhisper", systemImage: "waveform") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = DictationOverlayPanel()
        panel.startObserving()
        overlayPanel = panel
    }
}
