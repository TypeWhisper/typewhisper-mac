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
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var modelManager = ModelManagerViewModel.shared
    @ObservedObject private var settings = SettingsViewModel.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var promptActions = PromptActionsViewModel.shared

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

            Section(String(localized: "Default Model")) {
                if modelManager.readyModels.isEmpty && modelManager.configuredPluginEngines.isEmpty {
                    Text(String(localized: "No models available. Download or configure a model in the Models tab."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: "Model"), selection: Binding(
                        get: { modelManager.selectedModelId },
                        set: { if let id = $0 { modelManager.selectDefaultModel(id) } }
                    )) {
                        ForEach(modelManager.readyModels) { model in
                            Text("\(model.displayName) (\(model.engineType.displayName))")
                                .tag(model.id as String?)
                        }

                        if !modelManager.configuredPluginEngines.isEmpty && !modelManager.readyModels.isEmpty {
                            Divider()
                        }

                        ForEach(modelManager.configuredPluginEngines, id: \.providerId) { engine in
                            ForEach(engine.transcriptionModels, id: \.id) { model in
                                Text("\(model.displayName) (\(engine.providerDisplayName))")
                                    .tag(CloudProvider.fullId(provider: engine.providerId, model: model.id) as String?)
                            }
                        }
                    }
                }

                Text(String(localized: "The model used for transcription unless overridden by a profile."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Default Prompt")) {
                Picker(String(localized: "Prompt"), selection: $settings.defaultPromptActionId) {
                    Text(String(localized: "None")).tag(nil as String?)
                    Divider()
                    ForEach(promptActions.promptActions.filter(\.isEnabled)) { action in
                        Label(action.name, systemImage: action.icon).tag(action.id.uuidString as String?)
                    }
                }

                Text(String(localized: "When set, all dictations will be processed by this prompt. Profile-specific prompts take priority. Replaces translation when active."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            Section(String(localized: "Notch Indicator")) {
                Picker(String(localized: "Visibility"), selection: $dictation.notchIndicatorVisibility) {
                    Text(String(localized: "Always visible")).tag(DictationViewModel.NotchIndicatorVisibility.always)
                    Text(String(localized: "Only during activity")).tag(DictationViewModel.NotchIndicatorVisibility.duringActivity)
                    Text(String(localized: "Never")).tag(DictationViewModel.NotchIndicatorVisibility.never)
                }

                Picker(String(localized: "Left Side"), selection: $dictation.notchIndicatorLeftContent) {
                    notchContentPickerOptions
                }

                Picker(String(localized: "Right Side"), selection: $dictation.notchIndicatorRightContent) {
                    notchContentPickerOptions
                }

                Text(String(localized: "The notch indicator extends the MacBook notch area to show recording status."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Microphone")) {
                Picker(String(localized: "Input Device"), selection: $audioDevice.selectedDeviceUID) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }

                if audioDevice.isPreviewActive {
                    // Level meter with silence threshold marker
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        GeometryReader { geo in
                            let maxRms: Float = 0.15
                            let levelWidth = max(0, geo.size.width * CGFloat(min(audioDevice.previewRawLevel, maxRms) / maxRms))
                            let thresholdX = geo.size.width * CGFloat(min(Float(dictation.silenceThreshold), maxRms) / maxRms)

                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.quaternary)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(audioDevice.previewRawLevel < Float(dictation.silenceThreshold)
                                        ? Color.orange.gradient : Color.green.gradient)
                                    .frame(width: levelWidth)
                                    .animation(.easeOut(duration: 0.08), value: audioDevice.previewRawLevel)

                                // Silence threshold marker
                                Rectangle()
                                    .fill(.red)
                                    .frame(width: 2)
                                    .offset(x: thresholdX - 1)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Silence threshold"))
                        Slider(value: $dictation.silenceThreshold, in: 0.01...0.12, step: 0.005)
                    }

                    Text(String(localized: "Adjust so the red line sits above the background noise level. Sound below the line counts as silence."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(audioDevice.isPreviewActive
                    ? String(localized: "Stop Preview")
                    : String(localized: "Test Microphone")
                ) {
                    if audioDevice.isPreviewActive {
                        audioDevice.stopPreview()
                    } else {
                        audioDevice.startPreview()
                    }
                }
                .disabled(!audioDevice.isPreviewActive && dictation.needsMicPermission)

                if let name = audioDevice.disconnectedDeviceName {
                    Label(
                        String(localized: "Microphone disconnected. Falling back to system default."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if audioDevice.disconnectedDeviceName == name {
                                audioDevice.disconnectedDeviceName = nil
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Silence Detection")) {
                Toggle(String(localized: "Pause on silence instead of stopping"), isOn: $dictation.silencePauseEnabled)

                HStack {
                    Text(String(localized: "Silence duration"))
                    Slider(value: $dictation.silenceAutoStopDuration, in: 2...10, step: 1)
                    Text(String(format: "%.0fs", dictation.silenceAutoStopDuration))
                        .font(.system(.body).monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }

                Text(String(localized: "When enabled, recording pauses during silence and resumes automatically when you speak again. Only applies to toggle hotkey mode."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Sound")) {
                Toggle(String(localized: "Play sound feedback"), isOn: $dictation.soundFeedbackEnabled)

                Text(String(localized: "Plays a sound when recording starts and when transcription completes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Audio Ducking")) {
                Toggle(String(localized: "Reduce system volume during recording"), isOn: $dictation.audioDuckingEnabled)

                if dictation.audioDuckingEnabled {
                    HStack {
                        Image(systemName: "speaker.slash")
                            .foregroundStyle(.secondary)
                        Slider(value: $dictation.audioDuckingLevel, in: 0...0.5, step: 0.05)
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Percentage of your current volume to use during recording. 0% mutes completely."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            #if !APPSTORE
            Section(String(localized: "Updates")) {
                HStack {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    Text("Version \(version) (\(build))")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(String(localized: "Check for Updates...")) {
                        UpdateChecker.shared?.checkForUpdates()
                    }
                    .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
                }
            }
            #endif
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
    }

    @ViewBuilder
    private var notchContentPickerOptions: some View {
        Text(String(localized: "Recording Indicator")).tag(DictationViewModel.NotchIndicatorContent.indicator)
        Text(String(localized: "Timer")).tag(DictationViewModel.NotchIndicatorContent.timer)
        Text(String(localized: "Waveform")).tag(DictationViewModel.NotchIndicatorContent.waveform)
        Text(String(localized: "Clock")).tag(DictationViewModel.NotchIndicatorContent.clock)
        Text(String(localized: "Battery")).tag(DictationViewModel.NotchIndicatorContent.battery)
        Text(String(localized: "Profile")).tag(DictationViewModel.NotchIndicatorContent.profile)
        Text(String(localized: "None")).tag(DictationViewModel.NotchIndicatorContent.none)
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
