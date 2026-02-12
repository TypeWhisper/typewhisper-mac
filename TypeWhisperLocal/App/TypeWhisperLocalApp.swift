import SwiftUI

@main
struct TypeWhisperLocalApp: App {
    @StateObject private var serviceContainer = ServiceContainer.shared

    var body: some Scene {
        MenuBarExtra("TypeWhisper Local", systemImage: "waveform") {
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
