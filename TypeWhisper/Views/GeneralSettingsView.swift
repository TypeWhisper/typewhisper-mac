import SwiftUI
import ServiceManagement
import TypeWhisperPluginSDK

private func completeApplicationRelaunch(_ application: NSRunningApplication?, _ error: Error?) {
    guard application != nil, error == nil else { return }
    Task { @MainActor in
        NSApplication.shared.terminate(nil)
    }
}

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
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
        return preferredLanguage?.hasPrefix("de") == true ? "de" : "en"
    }()
    @State private var showRestartAlert = false
    @ObservedObject private var settings = SettingsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "General"))
            Divider()

            Form {
                Section(String(localized: "Spoken Language")) {
                LanguageSelectionEditor(
                    selection: $settings.languageSelection,
                    availableLanguages: settings.availableLanguages,
                    hintBehavior: LanguageSelectionHintBehavior(engine: settings.activeTranscriptionEngine)
                )

                Text(String(localized: "Controls push-to-talk dictation, workflows that inherit the global spoken language, and CLI/API defaults when they use app defaults. Recorder and Recovery have separate language settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                }
                .onChange(of: appLanguage) {
                    UserDefaults.standard.set(appLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
                    UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
                    showRestartAlert = true
                }
            }

                Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at Login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }

                Text(String(localized: "TypeWhisper will start automatically when you log in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                ApplicationRelauncher.relaunch()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting TypeWhisper."))
        }
    }

    private func toggleLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

@MainActor
enum ApplicationRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: config,
            completionHandler: completeApplicationRelaunch
        )
    }
}
