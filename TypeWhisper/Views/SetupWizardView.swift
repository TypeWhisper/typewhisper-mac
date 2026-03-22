import SwiftUI
import TypeWhisperPluginSDK

struct SetupWizardView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService

    @State private var currentStep: Int
    @State private var selectedProvider: String?
    @State private var selectedHotkeyMode: HotkeySlotType
    @State private var trialSuccess = false
    @State private var trialText = ""
    @FocusState private var isTrialFieldFocused: Bool

    private let totalSteps = 5

    init() {
        let saved = UserDefaults.standard.integer(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        _currentStep = State(initialValue: min(saved, 4))

        if UserDefaults.standard.data(forKey: UserDefaultsKeys.hybridHotkey) != nil {
            _selectedHotkeyMode = State(initialValue: .hybrid)
        } else if UserDefaults.standard.data(forKey: UserDefaultsKeys.pttHotkey) != nil {
            _selectedHotkeyMode = State(initialValue: .pushToTalk)
        } else if UserDefaults.standard.data(forKey: UserDefaultsKeys.toggleHotkey) != nil {
            _selectedHotkeyMode = State(initialValue: .toggle)
        } else {
            _selectedHotkeyMode = State(initialValue: .hybrid)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if currentStep == 0 {
                welcomeStep
            } else {
                header
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Divider()
                navigation
            }
        }
        .frame(minHeight: 350)
        .onChange(of: currentStep) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(stepTitle)
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            Text(String(localized: "Step \(currentStep) of \(totalSteps - 1)"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(1..<totalSteps, id: \.self) { index in
                    Circle()
                        .fill(index <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityHidden(true)
        }
        .padding()
    }

    private var stepTitle: String {
        switch currentStep {
        case 1: return String(localized: "Permissions")
        case 2: return String(localized: "Transcription Engine")
        case 3: return String(localized: "Hotkey")
        case 4: return String(localized: "Try It Out")
        default: return String(localized: "Setup")
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            switch currentStep {
            case 1: permissionsStep
            case 2: engineStep
            case 3: hotkeyStep
            case 4: tryItOutStep
            default: EmptyView()
            }
        }
        .padding()
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text(String(localized: "Welcome to TypeWhisper"))
                .font(.largeTitle.weight(.bold))

            Text(String(localized: "Voice-powered typing for your Mac"))
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                featureHighlight(
                    icon: "waveform",
                    title: String(localized: "Speak"),
                    description: String(localized: "Press a hotkey and talk naturally in any app.")
                )
                featureHighlight(
                    icon: "text.cursor",
                    title: String(localized: "Type"),
                    description: String(localized: "Your words appear as text instantly.")
                )
                featureHighlight(
                    icon: "wand.and.stars",
                    title: String(localized: "Enhance"),
                    description: String(localized: "AI prompts can rewrite, translate, or summarize.")
                )
            }
            .frame(maxWidth: 380)

            Spacer()

            VStack(spacing: 12) {
                Button(String(localized: "Get Started")) {
                    withAnimation { currentStep = 1 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(String(localized: "Skip Setup")) {
                    HomeViewModel.shared.completeSetupWizard()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureHighlight(icon: String, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionRow(
                label: String(localized: "Microphone"),
                iconGranted: "mic.fill",
                iconMissing: "mic.slash",
                isGranted: !dictation.needsMicPermission,
                isRequired: true
            ) {
                dictation.requestMicPermission()
            }

            if dictation.needsMicPermission {
                Text(String(localized: "Microphone access is required to continue."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            permissionRow(
                label: String(localized: "Accessibility"),
                iconGranted: "lock.shield.fill",
                iconMissing: "lock.shield",
                isGranted: !dictation.needsAccessibilityPermission,
                isRequired: false
            ) {
                dictation.requestAccessibilityPermission()
            }

            if dictation.needsAccessibilityPermission {
                Text(String(localized: "Recommended for pasting text into other apps. You can grant this later."))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !dictation.needsMicPermission {
                Divider()

                Text(String(localized: "Select your preferred microphone:"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker(String(localized: "Microphone"), selection: $audioDevice.selectedDeviceUID) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }

                if audioDevice.isPreviewActive {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.quaternary)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.green.gradient)
                                    .frame(width: max(0, geo.size.width * CGFloat(audioDevice.previewAudioLevel)))
                                    .animation(.easeOut(duration: 0.08), value: audioDevice.previewAudioLevel)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)
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
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func permissionRow(
        label: String,
        iconGranted: String,
        iconMissing: String,
        isGranted: Bool,
        isRequired: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Label(label, systemImage: isGranted ? iconGranted : iconMissing)
                .foregroundStyle(isGranted ? .green : (isRequired ? .red : .orange))

            if !isGranted {
                Text(isRequired ? String(localized: "Required") : String(localized: "Recommended"))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((isRequired ? Color.red : Color.orange).opacity(0.1))
                    .foregroundStyle(isRequired ? .red : .orange)
                    .clipShape(Capsule())
            }

            Spacer()

            if isGranted {
                Text(String(localized: "Granted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Grant Access")) {
                    action()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    // MARK: - Step 2: Engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if hasAnyEngineReady {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "You have a transcription engine ready."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                Text(String(localized: "Install a transcription engine to get started."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(String(localized: "Recommended"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            recommendationCard(
                manifestId: "com.typewhisper.parakeet",
                title: "Parakeet",
                badge: String(localized: "Works Offline"),
                description: String(localized: "Runs locally on your Mac. No API key needed."),
                systemImage: "desktopcomputer"
            )

            recommendationCard(
                manifestId: "com.typewhisper.groq",
                title: "Groq",
                badge: String(localized: "Fastest"),
                description: String(localized: "Cloud-based transcription. Requires a free API key."),
                systemImage: "bolt.fill"
            )

            let otherEngines = pluginManager.loadedPlugins
                .filter { !recommendedManifestIds.contains($0.manifest.id) }
                .compactMap { $0.instance as? any TranscriptionEnginePlugin }
            if !otherEngines.isEmpty {
                Text(String(localized: "Also Installed"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(otherEngines, id: \.providerId) { engine in
                    SetupEngineRow(engine: engine)
                }
            }

            if pluginManager.transcriptionEngines.count > 1 {
                Picker(String(localized: "Default Engine"), selection: $selectedProvider) {
                    ForEach(pluginManager.transcriptionEngines, id: \.providerId) { engine in
                        HStack {
                            Text(engine.providerDisplayName)
                            if !engine.isConfigured {
                                Text("(\(String(localized: "not ready")))")
                                    .foregroundStyle(.secondary)
                            }
                        }.tag(engine.providerId as String?)
                    }
                }
                .onChange(of: selectedProvider) { _, newValue in
                    if let newValue {
                        modelManager.selectProvider(newValue)
                    }
                }
            }

            if case .error(let message) = registryService.fetchState {
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button(String(localized: "Retry")) {
                        Task { await registryService.fetchRegistry() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Text(String(localized: "You can install more engines from the Integrations tab after setup."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            if registryService.fetchState == .idle {
                await registryService.fetchRegistry()
            }
        }
        .onAppear {
            selectedProvider = modelManager.selectedProviderId
        }
        .onChange(of: pluginManager.transcriptionEngines.map(\.providerId)) { _, engines in
            if selectedProvider == nil || !engines.contains(where: { $0 == selectedProvider }),
               let first = engines.first {
                selectedProvider = first
                modelManager.selectProvider(first)
            }
        }
    }

    private let recommendedManifestIds: Set<String> = ["com.typewhisper.parakeet", "com.typewhisper.groq"]

    @ViewBuilder
    private func recommendationCard(
        manifestId: String,
        title: String,
        badge: String,
        description: String,
        systemImage: String
    ) -> some View {
        let loadedPlugin = pluginManager.loadedPlugins.first { $0.manifest.id == manifestId }
        let isInstalled = loadedPlugin != nil
        let engine = loadedPlugin?.instance as? any TranscriptionEnginePlugin
        let isReady = engine?.isConfigured ?? false
        let registryPlugin = registryService.registry.first { $0.id == manifestId }
        let installState = registryService.installStates[manifestId]

        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.blue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))

                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isReady {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Ready"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else if isInstalled {
                RecommendationSettingsButton(manifestId: manifestId)
            } else if let installState {
                switch installState {
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 60)
                case .extracting:
                    ProgressView()
                        .controlSize(.small)
                case .error(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            } else if let registryPlugin {
                Button(String(localized: "Install")) {
                    Task {
                        await registryService.downloadAndInstall(registryPlugin)
                        PluginManager.shared.setPluginEnabled(registryPlugin.id, enabled: true)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }

    // MARK: - Step 3: Hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Choose how you want to trigger dictation, then record a shortcut."))
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                hotkeyModeOption(
                    mode: .hybrid,
                    title: String(localized: "Hybrid"),
                    description: String(localized: "Short press to toggle, hold to push-to-talk."),
                    recommended: true
                )

                hotkeyModeOption(
                    mode: .pushToTalk,
                    title: String(localized: "Push-to-Talk"),
                    description: String(localized: "Hold to record, release to stop.")
                )

                hotkeyModeOption(
                    mode: .toggle,
                    title: String(localized: "Toggle"),
                    description: String(localized: "Press to start, press again to stop.")
                )
            }

            if !hasAnyHotkeySet {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(String(localized: "No hotkey set. You won't be able to start dictation without one."))
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }
        }
    }

    private func hotkeyModeOption(
        mode: HotkeySlotType,
        title: String,
        description: String,
        recommended: Bool = false
    ) -> some View {
        let isSelected = selectedHotkeyMode == mode

        return VStack(spacing: 0) {
            HStack {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body.weight(.medium))
                        if recommended {
                            Text(String(localized: "Recommended"))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture { selectedHotkeyMode = mode }

            if isSelected {
                Divider()
                    .padding(.horizontal, 10)

                HStack(spacing: 8) {
                    Spacer()

                    Image(systemName: "keyboard")
                        .foregroundStyle(.blue)

                    HotkeyRecorderView(
                        label: hotkeyLabel(for: mode),
                        title: String(localized: "Shortcut"),
                        onRecord: { hotkey in
                            if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: mode) {
                                dictation.clearHotkey(for: conflict)
                            }
                            dictation.setHotkey(hotkey, for: mode)
                        },
                        onClear: { dictation.clearHotkey(for: mode) }
                    )
                    .fixedSize()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(.blue.opacity(0.06)))
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.08)) : AnyShapeStyle(.quaternary)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1))
    }

    // MARK: - Step 4: Try It Out

    private var tryItOutStep: some View {
        VStack(spacing: 20) {
            if !hasAnyEngineReady || !hasAnyHotkeySet {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)

                    if !hasAnyEngineReady {
                        Text(String(localized: "No transcription engine is ready. Go back to set one up."))
                            .foregroundStyle(.secondary)
                    }
                    if !hasAnyHotkeySet {
                        Text(String(localized: "No hotkey is configured. Go back to set one up."))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if trialSuccess {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text(String(localized: "You're all set!"))
                        .font(.title2.weight(.semibold))

                    Text(String(localized: "TypeWhisper is ready to use in any app."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                VStack(spacing: 12) {
                    Text(String(localized: "Click the text field below, then press your hotkey and say something!"))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.blue)
                        Text(hotkeyLabel(for: selectedHotkeyMode))
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.blue.opacity(0.1)))
                    }

                    TextEditor(text: $trialText)
                        .font(.body)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tertiary, lineWidth: 1))
                        .focused($isTrialFieldFocused)

                    if dictation.state == .recording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            Text(String(localized: "Recording..."))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    } else if dictation.state == .processing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Processing..."))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    } else if case .error(let message) = dictation.state {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(message)
                                .foregroundStyle(.red)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .onChange(of: dictation.state) { oldValue, newValue in
            if case .inserting = oldValue, case .idle = newValue {
                withAnimation(.spring(duration: 0.4)) {
                    trialSuccess = true
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isTrialFieldFocused = true
        }
    }

    // MARK: - Navigation

    private var navigation: some View {
        HStack {
            if currentStep == 4 && trialSuccess {
                Spacer()
            } else {
                Button(currentStep == 4
                    ? String(localized: "I'll try later")
                    : String(localized: "Skip Setup")
                ) {
                    HomeViewModel.shared.completeSetupWizard()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)

                Spacer()
            }

            if currentStep == 4 {
                if trialSuccess {
                    Button(String(localized: "Try Again")) {
                        trialSuccess = false
                        trialText = ""
                        Task {
                            try? await Task.sleep(for: .milliseconds(50))
                            isTrialFieldFocused = true
                        }
                    }
                    .buttonStyle(.bordered)

                    Button(String(localized: "Go to Dashboard")) {
                        HomeViewModel.shared.completeSetupWizard()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(String(localized: "Back")) {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                if currentStep > 1 {
                    Button(String(localized: "Back")) {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.bordered)
                }

                Button(String(localized: "Next")) {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private var canProceed: Bool {
        switch currentStep {
        case 1: return !dictation.needsMicPermission
        case 2: return hasAnyEngineReady
        case 3: return true
        default: return true
        }
    }

    private var hasAnyEngineReady: Bool {
        pluginManager.transcriptionEngines.contains { $0.isConfigured }
    }

    private var hasAnyHotkeySet: Bool {
        [UserDefaultsKeys.hybridHotkey, UserDefaultsKeys.pttHotkey, UserDefaultsKeys.toggleHotkey]
            .contains { UserDefaults.standard.data(forKey: $0) != nil }
    }

    private func hotkeyLabel(for mode: HotkeySlotType) -> String {
        switch mode {
        case .hybrid: return dictation.hybridHotkeyLabel
        case .pushToTalk: return dictation.pttHotkeyLabel
        case .toggle: return dictation.toggleHotkeyLabel
        case .promptPalette: return dictation.promptPaletteHotkeyLabel
        }
    }

    private func hotkeyModeTitle(for mode: HotkeySlotType) -> String {
        switch mode {
        case .hybrid: return String(localized: "Hybrid")
        case .pushToTalk: return String(localized: "Push-to-Talk")
        case .toggle: return String(localized: "Toggle")
        case .promptPalette: return String(localized: "Prompt Palette")
        }
    }
}

// MARK: - Recommendation Settings Button

private struct RecommendationSettingsButton: View {
    let manifestId: String
    @State private var showSettings = false

    var body: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gear")
                Text(String(localized: "Setup"))
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .sheet(isPresented: $showSettings) {
            if let loaded = PluginManager.shared.loadedPlugins.first(where: { $0.manifest.id == manifestId }),
               let view = loaded.instance.settingsView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(loaded.manifest.name)
                            .font(.headline)
                        Spacer()
                        Button {
                            showSettings = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()

                    Divider()

                    view
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 500, minHeight: 400)
            }
        }
    }
}

// MARK: - Engine Row

private struct SetupEngineRow: View {
    let engine: any TranscriptionEnginePlugin
    @ObservedObject private var pluginManager = PluginManager.shared
    @State private var showSettings = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.providerDisplayName)
                    .font(.body.weight(.medium))

                if engine.isConfigured, let modelId = engine.selectedModelId,
                   let model = engine.transcriptionModels.first(where: { $0.id == modelId }) {
                    Text(model.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if engine.isConfigured {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Ready"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                Text(String(localized: "Not configured"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let loaded = PluginManager.shared.loadedPlugins.first(where: {
                ($0.instance as? any TranscriptionEnginePlugin)?.providerId == engine.providerId
            }), loaded.instance.settingsView != nil {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .sheet(isPresented: $showSettings) {
            if let loaded = PluginManager.shared.loadedPlugins.first(where: {
                ($0.instance as? any TranscriptionEnginePlugin)?.providerId == engine.providerId
            }), let view = loaded.instance.settingsView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(loaded.manifest.name)
                            .font(.headline)
                        Spacer()
                        Button {
                            showSettings = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding()

                    Divider()

                    view
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 500, minHeight: 400)
            }
        }
    }
}
