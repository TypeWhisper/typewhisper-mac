import SwiftUI

struct DictumWindowMenuItems: View {
    var body: some View {
        Button { DictumNavigation.shared.open() } label: {
            Label(String(localized: "Open dictum", table: "DictumShell"), systemImage: "macwindow")
        }.keyboardShortcut("o")
        if #available(macOS 15, *) {
            settingsButton.modifierKeyAlternate(.option) { advancedSettingsButton }
        } else if NSEvent.modifierFlags.contains(.option) {
            advancedSettingsButton
        } else {
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button { DictumNavigation.shared.open(.general) } label: {
            Label(String(localized: "Settings…", table: "DictumShell"), systemImage: "gear")
        }.keyboardShortcut(",")
    }

    private var advancedSettingsButton: some View {
        Button { ManagedAppWindowOpener.shared.open(id: "settings") } label: {
            Text("Advanced settings", tableName: "DictumShell")
        }.keyboardShortcut(",")
    }
}
