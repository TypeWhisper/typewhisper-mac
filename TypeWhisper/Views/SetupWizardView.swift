import SwiftUI
import TypeWhisperPluginSDK

struct SetupWizardView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var promptActionsViewModel = PromptActionsViewModel.shared
    @ObservedObject private var dictionaryViewModel = DictionaryViewModel.shared
    @ObservedObject private var promptProcessingService: PromptProcessingService

    @State private var currentStep: Int
    @State private var selectedProvider: String?
    @State private var selectedHotkeyMode: HotkeySlotType
    @State private var selectedIndustryPreset: IndustryPreset
    @State private var trialSuccess = false
    @State private var trialText = ""
    @FocusState private var isTrialFieldFocused: Bool

    private let totalSteps = 6

    init() {
        let saved = UserDefaults.standard.integer(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        _currentStep = State(initialValue: min(saved, 5))
        _selectedIndustryPreset = State(initialValue: IndustryPreset.selected())
        _promptProcessingService = ObservedObject(wrappedValue: PromptActionsViewModel.shared.promptProcessingService)

        if !DictationSettingsHandler.loadHotkeys(for: .hybrid).isEmpty {
            _selectedHotkeyMode = State(initialValue: .hybrid)
        } else if !DictationSettingsHandler.loadHotkeys(for: .pushToTalk).isEmpty {
            _selectedHotkeyMode = State(initialValue: .pushToTalk)
        } else if !DictationSettingsHandler.loadHotkeys(for: .toggle).isEmpty {
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
        case 4: return String(localized: "Prompts & AI")
        case 5: return String(localized: "Try It Out")
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
            case 4: promptsAIStep
            case 5: tryItOutStep
            default: EmptyView()
            }
        }
        .padding()
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    welcomeContent(twoColumn: proxy.size.width >= 640)
                        .padding(.horizontal, proxy.size.width >= 520 ? 14 : 28)
                        .padding(.top, 24)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(spacing: 8) {
                Button(String(localized: "Get Started")) {
                    applyIndustrySelection()
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
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func welcomeContent(twoColumn: Bool) -> some View {
        if twoColumn {
            VStack(spacing: 16) {
                welcomeHeader

                HStack(alignment: .top, spacing: 24) {
                    welcomeFeatureColumn
                        .frame(width: 230, alignment: .leading)
                    industryPresetColumn
                        .frame(width: 360, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(spacing: 16) {
                welcomeHeader
                welcomeFeatureColumn
                industryPresetColumn
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var welcomeHeader: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Welcome to TypeWhisper"))
                    .font(.title.weight(.bold))
                    .lineLimit(1)

                Text(String(localized: "Voice-powered typing for your Mac"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var welcomeFeatureColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        .frame(maxWidth: 230, alignment: .leading)
    }

    private var industryPresetColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "What kind of writing do you do most?"))
                .font(.title3.weight(.semibold))

            ForEach(IndustryPreset.allCases) { preset in
                industryOption(preset)
            }

            Text(String(localized: "Industry term packs are prepared during setup and activated automatically when a commercial license is active."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func industryOption(_ preset: IndustryPreset) -> some View {
        let isSelected = selectedIndustryPreset == preset

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : preset.systemImage)
                .font(.callout)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(preset.displayName)
                    .font(.headline)
                Text(preset.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndustryPreset = preset
        }
    }

    private func applyIndustrySelection() {
        dictionaryViewModel.applyIndustryPreset(selectedIndustryPreset)
    }

    private func featureHighlight(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
                        Text(audioDevice.displayName(for: device)).tag(device.uid as String?)
                    }
                }

                if let message = audioDevice.selectedDeviceStatusMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

                if let error = audioDevice.previewError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
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
                        Task { await registryService.fetchRegistry(force: true) }
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
        let availability = SetupWizardRecommendationAvailability.resolve(
            manifestId: manifestId,
            isInstalled: isInstalled,
            isReady: isReady,
            registryPlugin: registryPlugin,
            installState: installState,
            fetchState: registryService.fetchState
        )
        let resolvedDescription = recommendationDescription(
            fallback: description,
            availability: availability
        )

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

                Text(resolvedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch availability {
            case .ready:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Ready"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            case .setupRequired:
                RecommendationSettingsButton(manifestId: manifestId)
            case .installState(let installState):
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
            case .installAvailable:
                Button(String(localized: "Install")) {
                    Task {
                        guard let registryPlugin else { return }
                        await registryService.downloadAndInstall(registryPlugin)
                        PluginManager.shared.setPluginEnabled(registryPlugin.id, enabled: true)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .unavailable(let reason):
                unavailableRecommendationView(reason)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }

    private func recommendationDescription(
        fallback: String,
        availability: SetupWizardRecommendationAvailability
    ) -> String {
        guard availability == .unavailable(.appleSiliconOnly) else {
            return fallback
        }

        return localizedAppText(
            "Parakeet runs locally and requires Apple Silicon. Intel Macs can use cloud Whisper through Groq or OpenAI.",
            de: "Parakeet läuft lokal und braucht Apple Silicon. Intel-Macs können Cloud-Whisper über Groq oder OpenAI nutzen."
        )
    }

    private func unavailableRecommendationView(_ reason: SetupWizardRecommendationUnavailableReason) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(reason.title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Text(reason.message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 190, alignment: .trailing)
        }
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

    // MARK: - Step 4: Prompts & AI

    private var promptsAIStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Process your dictated text with AI - translate, reformat, summarize, and more."))
                .font(.callout)
                .foregroundStyle(.secondary)

            if hasAnyLLMProvider {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "You have an LLM provider ready."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            Text(String(localized: "Recommended"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if #available(macOS 26, *) {
                appleIntelligenceCard
            }

            llmProviderCard(
                manifestId: "com.typewhisper.groq",
                title: "Groq",
                badge: groqAlreadyInstalled
                    ? String(localized: "Already Installed")
                    : String(localized: "Free API Key"),
                description: groqAlreadyInstalled
                    ? String(localized: "Groq is already installed and also works as an LLM provider.")
                    : String(localized: "Fast cloud AI. Also supports transcription. Requires a free API key."),
                systemImage: "bolt.fill"
            )

            let otherProviders = pluginManager.llmProviders
                .filter { $0.providerName.caseInsensitiveCompare("Groq") != .orderedSame }
            if !otherProviders.isEmpty {
                Text(String(localized: "Also Available"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(otherProviders, id: \.providerName) { provider in
                    HStack {
                        Text(provider.providerName)
                            .font(.body.weight(.medium))
                        Spacer()
                        if provider.isAvailable {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(String(localized: "Ready"))
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        } else {
                            Text(String(localized: "API key required"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                }
            }

            if case .error(let message) = registryService.fetchState {
                HStack {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button(String(localized: "Retry")) {
                        Task { await registryService.fetchRegistry(force: true) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            Text(String(localized: "Prompt Presets"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Built-in prompts for common tasks like translation, email drafting, and formatting."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if promptActionsViewModel.availablePresets.isEmpty && !promptActionsViewModel.promptActions.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "All imported"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } else {
                    Button(String(localized: "Import Presets")) {
                        promptActionsViewModel.loadPresets()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))

            Text(String(localized: "You can manage prompts and install more providers in the Prompts and Integrations tabs after setup."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            if registryService.fetchState == .idle {
                await registryService.fetchRegistry()
            }
        }
    }

    private var hasAnyLLMProvider: Bool {
        if #available(macOS 26, *) {
            if promptProcessingService.isAppleIntelligenceAvailable { return true }
        }
        return !pluginManager.llmProviders.isEmpty
    }

    private var groqAlreadyInstalled: Bool {
        pluginManager.loadedPlugins.contains { $0.manifest.id == "com.typewhisper.groq" }
    }

    @ViewBuilder
    private func llmProviderCard(
        manifestId: String,
        title: String,
        badge: String,
        description: String,
        systemImage: String
    ) -> some View {
        let loadedPlugin = pluginManager.loadedPlugins.first { $0.manifest.id == manifestId }
        let isInstalled = loadedPlugin != nil
        let llmProvider = loadedPlugin?.instance as? any LLMProviderPlugin
        let isReady = llmProvider?.isAvailable ?? false
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

    @available(macOS 26, *)
    private var appleIntelligenceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.blue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Apple Intelligence")
                        .font(.body.weight(.medium))

                    Text(String(localized: "Built-in"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }

                Text(String(localized: "On-device AI processing. No API key needed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if promptProcessingService.isAppleIntelligenceAvailable {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Ready"))
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } else {
                Text(String(localized: "Enable in System Settings"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
    }

    // MARK: - Step 5: Try It Out

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
            if currentStep == 5 && trialSuccess {
                Spacer()
            } else {
                Button(currentStep == 5
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

            if currentStep == 5 {
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

                nextButton
            }
        }
        .padding()
    }

    @ViewBuilder
    private var nextButton: some View {
        if canProceed {
            Button(String(localized: "Next")) {
                withAnimation { currentStep += 1 }
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 72)
        } else {
            Button(String(localized: "Next")) {}
                .buttonStyle(.bordered)
                .disabled(true)
                .frame(minWidth: 72)
        }
    }

    // MARK: - Helpers

    private var canProceed: Bool {
        switch currentStep {
        case 1: return !dictation.needsMicPermission
        case 2: return hasAnyEngineReady
        case 3: return true
        case 4: return true
        default: return true
        }
    }

    private var hasAnyEngineReady: Bool {
        _ = pluginManager.readinessRevision
        return pluginManager.transcriptionEngines.contains { $0.isConfigured }
    }

    private var hasAnyHotkeySet: Bool {
        !DictationSettingsHandler.loadHotkeys(for: .hybrid).isEmpty
            || !DictationSettingsHandler.loadHotkeys(for: .pushToTalk).isEmpty
            || !DictationSettingsHandler.loadHotkeys(for: .toggle).isEmpty
    }

    private func hotkeyLabel(for mode: HotkeySlotType) -> String {
        switch mode {
        case .hybrid: return dictation.hybridHotkeyLabel
        case .pushToTalk: return dictation.pttHotkeyLabel
        case .toggle: return dictation.toggleHotkeyLabel
        case .promptPalette: return dictation.promptPaletteHotkeyLabel
        case .recentTranscriptions: return dictation.recentTranscriptionsHotkeyLabel
        case .copyLastTranscription: return dictation.copyLastTranscriptionHotkeyLabel
        case .recorderToggle: return dictation.recorderToggleHotkeyLabel
        }
    }

    private func hotkeyModeTitle(for mode: HotkeySlotType) -> String {
        switch mode {
        case .hybrid: return String(localized: "Hybrid")
        case .pushToTalk: return String(localized: "Push-to-Talk")
        case .toggle: return String(localized: "Toggle")
        case .promptPalette: return localizedAppText("Workflow Palette", de: "Workflow-Palette")
        case .recentTranscriptions: return String(localized: "Recent Transcriptions")
        case .copyLastTranscription: return String(localized: "Copy Last Transcription")
        case .recorderToggle: return String(localized: "settings.tab.recorder")
        }
    }
}

// MARK: - Recommendation Availability

enum SetupWizardRecommendationUnavailableReason: Equatable {
    case appleSiliconOnly
    case marketplaceUnavailable

    var title: String {
        switch self {
        case .appleSiliconOnly:
            localizedAppText("Apple Silicon only", de: "Nur Apple Silicon")
        case .marketplaceUnavailable:
            localizedAppText("Unavailable", de: "Nicht verfügbar")
        }
    }

    var message: String {
        switch self {
        case .appleSiliconOnly:
            localizedAppText(
                "Use Groq or OpenAI with a cloud Whisper model on Intel.",
                de: "Nutze auf Intel Groq oder OpenAI mit einem Cloud-Whisper-Modell."
            )
        case .marketplaceUnavailable:
            localizedAppText(
                "No compatible download is available for this Mac.",
                de: "Für diesen Mac ist kein kompatibler Download verfügbar."
            )
        }
    }
}

enum SetupWizardRecommendationAvailability: Equatable {
    case ready
    case setupRequired
    case installState(PluginRegistryService.InstallState)
    case installAvailable
    case loading
    case unavailable(SetupWizardRecommendationUnavailableReason)

    static func resolve(
        manifestId: String,
        isInstalled: Bool,
        isReady: Bool,
        registryPlugin: RegistryPlugin?,
        installState: PluginRegistryService.InstallState?,
        fetchState: PluginRegistryService.FetchState,
        architecture: String = RuntimeArchitecture.current
    ) -> SetupWizardRecommendationAvailability {
        if isReady {
            return .ready
        }

        if isInstalled {
            return .setupRequired
        }

        if let installState {
            return .installState(installState)
        }

        if registryPlugin != nil {
            return .installAvailable
        }

        switch fetchState {
        case .idle, .loading:
            return .loading
        case .loaded, .error(_):
            if manifestId == "com.typewhisper.parakeet", architecture != "arm64" {
                return .unavailable(.appleSiliconOnly)
            }
            return .unavailable(.marketplaceUnavailable)
        }
    }
}

// MARK: - Recommendation Settings Button

private struct RecommendationSettingsButton: View {
    let manifestId: String

    var body: some View {
        Button {
            if let loaded = PluginManager.shared.loadedPlugins.first(where: { $0.manifest.id == manifestId }) {
                if !loaded.isEnabled {
                    PluginManager.shared.setPluginEnabled(manifestId, enabled: true)
                }
                if let activePlugin = PluginManager.shared.loadedPlugins.first(where: { $0.manifest.id == manifestId }),
                   activePlugin.supportsSettingsWindow {
                    PluginSettingsWindowManager.shared.present(activePlugin)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gear")
                Text(String(localized: "Setup"))
                    .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Engine Row

private struct SetupEngineRow: View {
    let engine: any TranscriptionEnginePlugin
    @ObservedObject private var pluginManager = PluginManager.shared

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
                    PluginSettingsWindowManager.shared.present(loaded)
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}
