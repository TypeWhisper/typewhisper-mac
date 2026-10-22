import SwiftUI

struct DictumWindowMenuItems: View {
    var body: some View {
        Button { DictumNavigation.shared.open() } label: {
            Label(String(localized: "Open dictum", table: "DictumShell"), systemImage: "macwindow")
        }.keyboardShortcut("o")
        Button { DictumNavigation.shared.open(.general) } label: {
            Label(String(localized: "Settings…", table: "DictumShell"), systemImage: "gear")
        }.keyboardShortcut(",")
        Button { ManagedAppWindowOpener.shared.open(id: "settings") } label: {
            Text("Advanced settings", tableName: "DictumShell")
        }
    }
}
