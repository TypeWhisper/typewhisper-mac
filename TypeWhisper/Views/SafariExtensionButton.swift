import SafariServices
import SwiftUI

/// Opens the Safari extension that comes with TypeWhisper in Safari's settings, where it is
/// turned on. Shows whether it is on, which Safari reports for extensions of this app only.
struct SafariExtensionButton: View {
    @State private var isEnabled: Bool?

    static var extensionIdentifier: String? {
        Bundle.main.bundleIdentifier.map { $0 + SafariExtensionConnection.extensionBundleIdentifierSuffix }
    }

    var body: some View {
        Button(isEnabled == true
            ? localizedAppText("Safari Settings", de: "Safari-Einstellungen", ja: "Safari の設定", zh: "Safari 设置", es: "Ajustes de Safari")
            : localizedAppText("Turn On in Safari", de: "In Safari aktivieren", ja: "Safari で有効にする", zh: "在 Safari 中启用", es: "Activar en Safari")
        ) {
            guard let identifier = Self.extensionIdentifier else { return }
            SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { _ in }
        }
        .help(isEnabled == true
            ? localizedAppText("The Safari extension is on.", de: "Die Safari-Erweiterung ist aktiviert.", ja: "Safari 拡張機能はオンです。", zh: "Safari 扩展已启用。", es: "La extensión de Safari está activada.")
            : localizedAppText("Opens Safari's extension settings, where you turn on TypeWhisper.", de: "Öffnet die Erweiterungs-Einstellungen von Safari, wo du TypeWhisper aktivierst.", ja: "Safari の拡張機能設定を開き、TypeWhisper をオンにします。", zh: "打开 Safari 的扩展设置，在其中启用 TypeWhisper。", es: "Abre los ajustes de extensiones de Safari, donde activas TypeWhisper.")
        )
        .task { await refreshState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshState() }
        }
    }

    private func refreshState() async {
        guard let identifier = Self.extensionIdentifier else { return }
        let state = try? await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: identifier)
        isEnabled = state?.isEnabled
    }
}
