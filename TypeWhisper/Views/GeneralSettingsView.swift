import SwiftUI
import ServiceManagement
import TypeWhisperPluginSDK

private func completeApplicationRelaunch(_ application: NSRunningApplication?, _ error: Error?) {
    guard application != nil, error == nil else {
        RelaunchSettingsPage.clear()
        return
    }
    Task { @MainActor in
        NSApplication.shared.terminate(nil)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var launchAtLogin = ServiceContainer.shared.launchAtLoginController
    @State private var appLanguage: String = {
        if let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) {
            return lang
        }
        let preferredLanguage = Locale.preferredLanguages.first
        if preferredLanguage?.hasPrefix("ja") == true {
            return "ja"
        }
        if preferredLanguage?.hasPrefix("zh") == true {
            return "zh-Hans"
        }
        if preferredLanguage?.hasPrefix("es") == true {
            return "es"
        }
        return preferredLanguage?.hasPrefix("de") == true ? "de" : "en"
    }()
    @State private var showRestartAlert = false
    @ObservedObject private var settings = SettingsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "General"))
            Divider()

            Form {
                // The spoken language lives on the Dictation page next to the engine
                // it applies to; this page keeps the app language.
                #if canImport(Translation)
                if #available(macOS 15, *) {
                    Section(String(localized: "Translation")) {
                    Toggle(String(localized: "Enable translation"), isOn: $settings.translationEnabled)

                    if settings.translationEnabled {
                        Picker(String(localized: "Target language"), selection: $settings.translationTargetLanguage) {
                            ForEach(TranslationService.availableTargetLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                    }

                    Text(String(localized: "Uses Apple Translate (on-device)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #endif

                Section(String(localized: "Language")) {
                Picker(String(localized: "App Language"), selection: $appLanguage) {
                    Text(String(localized: "English")).tag("en")
                    Text(String(localized: "Deutsch")).tag("de")
                    Text(String(localized: "日本語")).tag("ja")
                    Text(String(localized: "简体中文")).tag("zh-Hans")
                    Text(String(localized: "Español")).tag("es")
                }
                .onChange(of: appLanguage) {
                    UserDefaults.standard.set(appLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
                    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }

                Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at Login"), isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setUserChoice($0) }
                ))
                .disabled(launchAtLogin.isLocked)
                .managedLockAccessibilityHint(isLocked: launchAtLogin.isLocked, reason: nil)

                Text(String(localized: "TypeWhisper will start automatically when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if launchAtLogin.isLocked {
                    ManagedByOrganizationLabel()
                }

                if launchAtLogin.requiresApproval {
                    HStack {
                        Text(String(localized: "macOS needs your approval in Login Items before TypeWhisper can start at login."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Open Login Items")) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
            }

            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        // System Settings can change the login item while TypeWhisper runs, including after
        // "Open Login Items" while this page stays open.
        .onAppear { launchAtLogin.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refreshStatus()
        }
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                ApplicationRelauncher.relaunch(reopening: .general)
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting TypeWhisper."))
        }
    }

}

/// The Settings page a relaunch opens again, so a restart started from Settings
/// does not leave the user without the window they were working in.
/// Stored in the defaults because the sandbox drops launch arguments.
enum RelaunchSettingsPage: String, CaseIterable {
    case general
    case integrations

    /// A launch long after the restart, for example after a crash, opens no window.
    static let maximumAge: TimeInterval = 60

    var tab: SettingsTab {
        switch self {
        case .general: .general
        case .integrations: .integrations
        }
    }

    func store(in defaults: UserDefaults = .standard, now: Date = Date()) {
        defaults.set(["page": rawValue, "date": now], forKey: UserDefaultsKeys.relaunchSettingsPage)
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: UserDefaultsKeys.relaunchSettingsPage)
    }

    /// Returns the page the restart asked for and forgets it, so only the next launch opens it.
    static func consume(from defaults: UserDefaults = .standard, now: Date = Date()) -> RelaunchSettingsPage? {
        guard let entry = defaults.dictionary(forKey: UserDefaultsKeys.relaunchSettingsPage) else { return nil }
        clear(in: defaults)
        guard let rawValue = entry["page"] as? String,
              let date = entry["date"] as? Date,
              abs(now.timeIntervalSince(date)) <= maximumAge else { return nil }
        return RelaunchSettingsPage(rawValue: rawValue)
    }
}

@MainActor
enum ApplicationRelauncher {
    #if APPSTORE
    private static var pendingTermination: DispatchWorkItem?
    #endif

    static func relaunch(reopening settingsPage: RelaunchSettingsPage? = nil) {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        if let settingsPage {
            settingsPage.store()
        } else {
            RelaunchSettingsPage.clear()
        }
        #if APPSTORE
        // The new instance waits for this one to quit before it checks in, so
        // waiting for the launch completion here would stall both until the
        // single-instance timeout. Quit right after handing the launch over.
        AppStoreSingleInstance.markRelaunch()
        let terminate = DispatchWorkItem { NSApplication.shared.terminate(nil) }
        pendingTermination = terminate
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            guard error != nil else { return }
            // Keep running if the new instance could not be launched.
            Task { @MainActor in
                ApplicationRelauncher.pendingTermination?.cancel()
                ApplicationRelauncher.pendingTermination = nil
                AppStoreSingleInstance.clearRelaunchMark()
                RelaunchSettingsPage.clear()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: terminate)
        #else
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: config,
            completionHandler: completeApplicationRelaunch
        )
        #endif
    }
}
