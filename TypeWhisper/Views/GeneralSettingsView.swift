import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var appLanguage: String = {
        if let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) {
            return lang
        }
        return Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
    }()
    @State private var showRestartAlert = false
    @State private var showMenuBarIconHiddenAlert = false
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(UserDefaultsKeys.showRecorderTab) private var showRecorderTab = false
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var settings = SettingsViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "Spoken Language")) {
                Picker(String(localized: "Spoken language"), selection: $settings.selectedLanguage) {
                    Text(String(localized: "Auto-detect")).tag(nil as String?)
                    Divider()
                    ForEach(settings.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code as String?)
                    }
                }

                Text(String(localized: "The language being spoken. Setting this explicitly improves accuracy."))
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
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
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

            Section(String(localized: "Appearance")) {
                Toggle(String(localized: "Show menu bar icon"), isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, newValue in
                        if !newValue {
                            let alertShown = UserDefaults.standard.bool(forKey: UserDefaultsKeys.menuBarIconHiddenAlertShown)
                            if !alertShown {
                                showMenuBarIconHiddenAlert = true
                                UserDefaults.standard.set(true, forKey: UserDefaultsKeys.menuBarIconHiddenAlertShown)
                            }
                        }
                    }

                Text(String(localized: "When hidden, the app is accessible via the Dock icon."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(String(localized: "settings.showRecorderTab"), isOn: $showRecorderTab)

                Text(String(localized: "settings.showRecorderTab.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Indicator")) {
                IndicatorPreviewView()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                IndicatorStylePicker()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Picker(String(localized: "Visibility"), selection: $dictation.notchIndicatorVisibility) {
                    Text(String(localized: "Always visible")).tag(NotchIndicatorVisibility.always)
                    Text(String(localized: "Only during activity")).tag(NotchIndicatorVisibility.duringActivity)
                    Text(String(localized: "Never")).tag(NotchIndicatorVisibility.never)
                }

                Picker(String(localized: "Display"), selection: $dictation.notchIndicatorDisplay) {
                    Text(String(localized: "Active Screen")).tag(NotchIndicatorDisplay.activeScreen)
                    Text(String(localized: "Primary Screen")).tag(NotchIndicatorDisplay.primaryScreen)
                    Text(String(localized: "Built-in Display")).tag(NotchIndicatorDisplay.builtInScreen)
                }

                if dictation.indicatorStyle == .overlay {
                    Picker(String(localized: "Position"), selection: $dictation.overlayPosition) {
                        Text(String(localized: "Top")).tag(OverlayPosition.top)
                        Text(String(localized: "Bottom")).tag(OverlayPosition.bottom)
                    }
                }

                Picker(String(localized: "Left Side"), selection: $dictation.notchIndicatorLeftContent) {
                    notchContentPickerOptions
                }

                Picker(String(localized: "Right Side"), selection: $dictation.notchIndicatorRightContent) {
                    notchContentPickerOptions
                }

                if dictation.indicatorStyle == .notch {
                    Text(String(localized: "The notch indicator extends the MacBook notch area to show recording status."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "The overlay indicator appears as a floating pill on the screen."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .alert(String(localized: "Restart Required"), isPresented: $showRestartAlert) {
            Button(String(localized: "Restart Now")) {
                restartApp()
            }
            Button(String(localized: "Later"), role: .cancel) {}
        } message: {
            Text(String(localized: "The language change will take effect after restarting TypeWhisper."))
        }
        .alert(String(localized: "Menu bar icon hidden"), isPresented: $showMenuBarIconHiddenAlert) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "You can access TypeWhisper settings via the Dock icon."))
        }
    }

    private func restartApp() {
        let bundleURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    @ViewBuilder
    private var notchContentPickerOptions: some View {
        Text(String(localized: "Recording Indicator")).tag(NotchIndicatorContent.indicator)
        Text(String(localized: "Timer")).tag(NotchIndicatorContent.timer)
        Text(String(localized: "Waveform")).tag(NotchIndicatorContent.waveform)
        Text(String(localized: "Profile")).tag(NotchIndicatorContent.profile)
        Text(String(localized: "None")).tag(NotchIndicatorContent.none)
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
