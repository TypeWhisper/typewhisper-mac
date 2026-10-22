import SwiftUI

struct AppSection: View {
    @ObservedObject private var launchAtLogin = ServiceContainer.shared.launchAtLoginController
    @AppStorage(UserDefaultsKeys.dictumShowInDock) private var showInDock = false
    @State private var language = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) ?? "system"
    @State private var needsRestart = false

    private var languageLabel: String {
        ["zh-Hans": "简体中文", "en": "English", "de": "Deutsch", "ja": "日本語"][language]
            ?? String(localized: "System", table: "DictumShell")
    }

    var body: some View {
        GroupedFormSection(title: "App", tableName: "DictumShell") {
            GroupedFormToggle(title: "Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setUserChoice($0) }
                ), separated: false).disabled(launchAtLogin.isLocked)
                .managedLockAccessibilityHint(isLocked: launchAtLogin.isLocked, reason: nil)
            if let error = launchAtLogin.lastErrorDescription {
                Text(error).font(DictumTheme.Typography.secondary).foregroundStyle(DictumTheme.danger).padding(10)
            }
            GroupedFormToggle(title: "Show in Dock", isOn: $showInDock)
            GroupedFormRow(separated: true) {
                Text("Language", tableName: "DictumShell")
                Spacer()
                DictumPopup(title: "Language", selection: $language, value: Text(verbatim: languageLabel)) {
                    Text("System", tableName: "DictumShell").tag("system")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "Deutsch").tag("de")
                    Text(verbatim: "日本語").tag("ja")
                }
            }
            GroupedFormRow(separated: true) {
                Text("Advanced settings", tableName: "DictumShell")
                Spacer()
                Button { ManagedAppWindowOpener.shared.open(id: "settings") } label: {
                    HStack(spacing: 6) {
                        Text("Open", tableName: "DictumShell")
                        Image(systemName: "arrow.up.right").accessibilityHidden(true)
                    }
                }.buttonStyle(DictumControlStyle(kind: .smallButton))
            }
        }
        .onAppear { launchAtLogin.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
        .onChange(of: language) { _, value in
            if value == "system" {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.preferredAppLanguage)
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set(value, forKey: UserDefaultsKeys.preferredAppLanguage)
                UserDefaults.standard.set([value], forKey: "AppleLanguages")
            }
            needsRestart = true
        }
        .alert(Text("Restart required", tableName: "DictumShell"), isPresented: $needsRestart) {
            Button { ApplicationRelauncher.relaunch() } label: { Text("Restart now", tableName: "DictumShell") }
            Button(role: .cancel) {} label: { Text("Later", tableName: "DictumShell") }
        } message: {
            Text("The language change will take effect after restarting dictum.", tableName: "DictumShell")
        }
    }
}
