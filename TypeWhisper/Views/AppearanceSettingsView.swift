import SwiftUI
import TypeWhisperPluginSDK

/// Menu bar and Dock presence plus the dictation indicator. While this page is
/// open the real indicator runs on screen as a live preview, so every change
/// is visible in the actual rendering.
struct AppearanceSettingsView: View {
    private enum AppVisibilityMode: String, CaseIterable {
        case menuBar
        case dock
        case dockWhileWindowOpen
    }

    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden) private var dockIconBehaviorRawValue = DockIconBehavior.keepVisible.rawValue
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var preview = IndicatorPreviewSession.shared

    private var supportsTranscriptPreview: Bool {
        dictation.indicatorStyle.supportsTranscriptPreview
    }

    private var supportsPositionSelection: Bool {
        dictation.indicatorStyle == .overlay || dictation.indicatorStyle == .minimal
    }

    private var previewEngineOptions: [TranscriptionEnginePlugin] {
        pluginManager.transcriptionEngines
    }

    private var dockIconBehavior: DockIconBehavior {
        get { DockIconBehavior(rawValue: dockIconBehaviorRawValue) ?? .keepVisible }
        nonmutating set { dockIconBehaviorRawValue = newValue.rawValue }
    }

    private var appVisibilityMode: AppVisibilityMode {
        get {
            if showMenuBarIcon {
                return .menuBar
            }

            return dockIconBehavior == .keepVisible ? .dock : .dockWhileWindowOpen
        }
        nonmutating set {
            switch newValue {
            case .menuBar:
                showMenuBarIcon = true
                dockIconBehavior = .keepVisible
            case .dock:
                showMenuBarIcon = false
                dockIconBehavior = .keepVisible
            case .dockWhileWindowOpen:
                showMenuBarIcon = false
                dockIconBehavior = .onlyWhileWindowOpen
            }
        }
    }

    private var appVisibilityDescription: LocalizedStringKey {
        switch appVisibilityMode {
        case .menuBar:
            "TypeWhisper stays in the menu bar and hides its Dock icon while no window is open."
        case .dock:
            "TypeWhisper stays accessible via the Dock icon."
        case .dockWhileWindowOpen:
            "TypeWhisper hides both icons until a window opens. To reopen Settings later, launch TypeWhisper from Spotlight or the Applications folder."
        }
    }

    private var indicatorTranscriptPreviewSliderValue: Binding<Double> {
        Binding(
            get: { Double(dictation.indicatorTranscriptPreviewFontSizeOffset) },
            set: { dictation.indicatorTranscriptPreviewFontSizeOffset = Int($0.rounded()) }
        )
    }

    private var indicatorTranscriptPreviewSizeLabel: String {
        "\(Int(dictation.indicatorTranscriptPreviewFontSize(for: dictation.indicatorStyle))) pt"
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Appearance"))
            Divider()

            Form {
                Section(String(localized: "Menu Bar & Dock")) {
                    Picker(String(localized: "App visibility"), selection: Binding(
                        get: { appVisibilityMode },
                        set: { appVisibilityMode = $0 }
                    )) {
                        Text(String(localized: "Menu bar icon")).tag(AppVisibilityMode.menuBar)
                        Text(String(localized: "Dock icon")).tag(AppVisibilityMode.dock)
                        Text(String(localized: "Dock icon only while a window is open")).tag(AppVisibilityMode.dockWhileWindowOpen)
                    }

                    Text(appVisibilityDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "Indicator")) {
                    Label {
                        Text(String(localized: "While this page is open, the indicator runs as a live preview on your screen."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "eye")
                            .foregroundStyle(.secondary)
                    }

                    IndicatorStylePicker()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    IndicatorThemePicker()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    if dictation.indicatorStyle == .notch, dictation.indicatorTheme != .classic {
                        Text(String(localized: "The notch itself stays black. The theme applies to the area that expands below it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if dictation.indicatorTheme == .glass {
                        Text(String(localized: "Glass follows your system appearance and uses Liquid Glass on macOS 26. Earlier versions show a translucent material."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if supportsTranscriptPreview {
                        Toggle(String(localized: "Show live transcript preview"), isOn: $dictation.indicatorTranscriptPreviewEnabled)

                        Picker(String(localized: "Live preview engine"), selection: $dictation.livePreviewEngineId) {
                            Text(String(localized: "Match dictation engine")).tag(nil as String?)
                            Divider()
                            ForEach(previewEngineOptions, id: \.providerId) { engine in
                                HStack {
                                    Text(engine.providerDisplayName)
                                    if !dictation.canUseEngineForPreview(engine) {
                                        Text("(\(String(localized: "not ready")))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tag(engine.providerId as String?)
                                .disabled(!dictation.canUseEngineForPreview(engine))
                            }
                        }
                        .disabled(!dictation.indicatorTranscriptPreviewEnabled)

                        if dictation.indicatorTranscriptPreviewEnabled, dictation.livePreviewEngineId != nil {
                            Text(String(localized: "The live preview runs on this engine while the final transcription still uses your dictation engine. A fast local engine avoids extra network requests while you speak."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        LabeledContent(String(localized: "Live transcript size")) {
                            HStack(spacing: 12) {
                                Slider(value: indicatorTranscriptPreviewSliderValue, in: 0...8, step: 1)
                                    .frame(width: 180)

                                Text(verbatim: indicatorTranscriptPreviewSizeLabel)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 54, alignment: .trailing)
                            }
                        }
                        .disabled(!dictation.indicatorTranscriptPreviewEnabled)

                        if !dictation.indicatorTranscriptPreviewEnabled {
                            Text(String(localized: "When disabled, TypeWhisper skips live transcript requests for the indicator and only runs the final transcription after you stop recording."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

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

                    if supportsPositionSelection {
                        Picker(String(localized: "Position"), selection: $dictation.overlayPosition) {
                            Text(String(localized: "Top")).tag(OverlayPosition.top)
                            Text(String(localized: "Bottom")).tag(OverlayPosition.bottom)
                        }
                    }

                    if dictation.indicatorStyle != .minimal {
                        Picker(String(localized: "Left Side"), selection: $dictation.notchIndicatorLeftContent) {
                            notchContentPickerOptions
                        }
                    }

                    Picker(String(localized: "Right Side"), selection: $dictation.notchIndicatorRightContent) {
                        notchContentPickerOptions
                    }

                    if dictation.indicatorStyle == .notch {
                        Text(String(localized: "The notch indicator extends the MacBook notch area to show recording status."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if dictation.indicatorStyle == .minimal {
                        Text(String(localized: "The indicator style is a compact power-user indicator that only shows status, errors, and action feedback."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "The overlay indicator appears as a floating pill on the screen."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        String(localized: "Show indicator in screen recordings and screen shares"),
                        isOn: $dictation.indicatorVisibleInScreenCaptures
                    )

                    Text(String(localized: "Turn this off to hide the indicator from supported capture apps while keeping it visible on your display."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            preview.start()
        }
        .onDisappear {
            preview.stop()
        }
    }

    @ViewBuilder
    private var notchContentPickerOptions: some View {
        Text(String(localized: "Recording Indicator")).tag(NotchIndicatorContent.indicator)
        Text(String(localized: "Timer")).tag(NotchIndicatorContent.timer)
        Text(String(localized: "Waveform")).tag(NotchIndicatorContent.waveform)
        Text(localizedAppText("Workflow", de: "Workflow")).tag(NotchIndicatorContent.profile)
        Text(String(localized: "None")).tag(NotchIndicatorContent.none)
    }
}
