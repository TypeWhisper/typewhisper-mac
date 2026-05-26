import SwiftUI
import TypeWhisperPluginSDK

struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var promptProcessingService: PromptProcessingService

    @State private var currentStep: Int
    @State private var selectedHotkeyMode: HotkeySlotType
    @State private var trialSuccess = false
    @State private var trialText = ""
    @State private var didAnnounceInitialStep = false
    @State private var isPreparingAppleSpeechFallback = false
    @State private var isActivatingParakeet = false
    @State private var manuallySelectedSetupProviderId: String?
    @FocusState private var isTrialFieldFocused: Bool

    private let accessibilityAnnouncementService = ServiceContainer.shared.accessibilityAnnouncementService

    init() {
        let saved = UserDefaults.standard.integer(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        let maxStep = SetupWizardStep.allCases.count - 1
        _currentStep = State(initialValue: min(max(saved, 0), maxStep))
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
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.05, blue: 0.07),
                    Color(red: 0.04, green: 0.09, blue: 0.12),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                footer
            }
        }
        .frame(minWidth: 760, idealWidth: 820, maxWidth: 860, minHeight: 520, idealHeight: 560)
        .preferredColorScheme(.dark)
        .onChange(of: currentStep) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.setupWizardCurrentStep)
            announceCurrentStep()
        }
        .task {
            if !didAnnounceInitialStep {
                didAnnounceInitialStep = true
                announceCurrentStep()
            }

            if registryService.fetchState == .idle {
                await registryService.fetchRegistry()
            }
        }
        .task(id: currentStep) {
            guard currentWizardStep == .engineAI || currentWizardStep == .finish else { return }
            await preparePreferredSetupEngineIfNeeded()
        }
        .onReceive(pluginManager.$loadedPlugins) { _ in
            guard currentWizardStep == .engineAI || currentWizardStep == .finish else { return }
            Task { await preparePreferredSetupEngineIfNeeded() }
        }
        .onChange(of: pluginManager.readinessRevision) { _, _ in
            guard currentWizardStep == .engineAI || currentWizardStep == .finish else { return }
            Task { await preparePreferredSetupEngineIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetSetupWizardWindow)) { _ in
            restartWizardFromBeginning()
        }
    }

    // MARK: - Shell

    private var currentWizardStep: SetupWizardStep {
        SetupWizardStep(rawValue: currentStep) ?? .welcome
    }

    private func announceCurrentStep() {
        accessibilityAnnouncementService.announce(String(localized: "\(currentWizardStep.title). Step \(currentStep + 1) of \(SetupWizardStep.allCases.count). \(currentWizardStep.subtitle)"))
    }

    private func restartWizardFromBeginning() {
        trialSuccess = false
        trialText = ""
        manuallySelectedSetupProviderId = nil
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        withAnimation(.easeInOut(duration: 0.18)) {
            currentStep = 0
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Text(String(localized: "TypeWhisper Setup"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                ForEach(SetupWizardStep.allCases) { step in
                    progressItem(for: step)

                    if step.rawValue < SetupWizardStep.allCases.count - 1 {
                        Rectangle()
                            .fill(step.rawValue < currentStep ? Color.blue : Color.white.opacity(0.14))
                            .frame(width: 46, height: 1)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 18)
        .padding(.horizontal, 34)
        .padding(.bottom, 10)
    }

    private func progressItem(for step: SetupWizardStep) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(progressFill(for: step))
                    .frame(width: 26, height: 26)

                if step.rawValue < currentStep {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(step.rawValue <= currentStep ? .white : .secondary)
                }
            }

            Text(step.progressTitle)
                .font(.caption2.weight(step == currentWizardStep ? .semibold : .regular))
                .foregroundStyle(step == currentWizardStep ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 82)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Step \(step.rawValue + 1) of \(SetupWizardStep.allCases.count), \(step.progressTitle)"))
        .accessibilityValue(progressAccessibilityStatus(for: step))
    }

    private func progressFill(for step: SetupWizardStep) -> Color {
        if step.rawValue <= currentStep {
            return .blue
        }
        return Color.white.opacity(0.16)
    }

    private func progressAccessibilityStatus(for step: SetupWizardStep) -> String {
        if step.rawValue < currentStep {
            return String(localized: "Completed")
        }
        if step == currentWizardStep {
            return String(localized: "Current")
        }
        return String(localized: "Upcoming")
    }

    private var stepContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 5) {
                    Text(currentWizardStep.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(currentWizardStep.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                switch currentWizardStep {
                case .welcome:
                    welcomeStep
                case .permissions:
                    permissionsStep
                case .hotkey:
                    hotkeyStep
                case .engineAI:
                    engineAIStep
                case .finish:
                    finishStep
                }
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 34)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.never)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                Button(String(localized: "Back")) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        currentStep -= 1
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            }

            Spacer()

            Button(String(localized: "Skip Setup")) {
                completeSetupAndOpenHome()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            Button(primaryActionTitle) {
                handlePrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(primaryKeyboardShortcut)
            .accessibilityHint(primaryActionAccessibilityHint)
            .disabled(!canProceed)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.18))
    }

    private var primaryActionTitle: String {
        if currentWizardStep == .permissions, dictation.needsMicPermission {
            return String(localized: "Grant Microphone Access")
        }

        return currentWizardStep == .finish
            ? String(localized: "Complete Setup")
            : String(localized: "Continue")
    }

    private var primaryKeyboardShortcut: KeyboardShortcut {
        currentWizardStep == .finish
            ? KeyboardShortcut(.return, modifiers: [.command])
            : .defaultAction
    }

    private var primaryActionAccessibilityHint: String {
        if currentWizardStep == .finish {
            return String(localized: "Press Command Return to complete setup.")
        }

        return String(localized: "Press Return to continue.")
    }

    private func handlePrimaryAction() {
        if currentWizardStep == .permissions, dictation.needsMicPermission {
            dictation.requestMicPermission()
            return
        }

        if currentWizardStep == .hotkey {
            applyRecommendedHotkeyIfNeeded()
        }

        if currentWizardStep == .finish {
            completeSetupAndOpenHome()
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            currentStep = min(currentStep + 1, SetupWizardStep.allCases.count - 1)
        }
    }

    private func completeSetupAndOpenHome() {
        HomeViewModel.shared.completeSetupWizard()
        SettingsNavigationCoordinator.shared?.navigate(to: .home)
        dismiss()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 74, height: 74)
                .shadow(color: .blue.opacity(0.35), radius: 16)

            VStack(alignment: .leading, spacing: 14) {
                setupFeatureRow(
                    icon: "mic.fill",
                    title: String(localized: "Speak naturally"),
                    description: String(localized: "Press a hotkey and talk in any app.")
                )
                setupFeatureRow(
                    icon: "text.cursor",
                    title: String(localized: "Type instantly"),
                    description: String(localized: "Your words appear as text right away.")
                )
                setupFeatureRow(
                    icon: "wand.and.stars",
                    title: String(localized: "Enhance with AI"),
                    description: String(localized: "Rewrite, translate, summarize, and more.")
                )
            }
            .frame(maxWidth: 390, alignment: .leading)
        }
        .padding(.top, 4)
    }

    private func setupFeatureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 30, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            permissionCard(
                title: String(localized: "Microphone Access"),
                description: String(localized: "Required to capture your voice."),
                systemImage: "mic.fill",
                isGranted: !dictation.needsMicPermission,
                isRequired: true,
                action: { dictation.requestMicPermission() }
            )

            permissionCard(
                title: String(localized: "Accessibility Access"),
                description: String(localized: "Required to type into other apps."),
                systemImage: "figure.stand",
                isGranted: !dictation.needsAccessibilityPermission,
                isRequired: false,
                action: { dictation.requestAccessibilityPermission() }
            )

            Label(
                String(localized: "You can change permissions anytime in System Settings."),
                systemImage: "lock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    private func permissionCard(
        title: String,
        description: String,
        systemImage: String,
        isGranted: Bool,
        isRequired: Bool,
        action: @escaping () -> Void
    ) -> some View {
        setupCard(isSelected: false) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(isGranted ? .green : .blue)
                    .frame(width: 38)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isGranted {
                    statusPill(
                        String(localized: "Granted"),
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                } else {
                    VStack(alignment: .trailing, spacing: 8) {
                        statusPill(
                            String(localized: "Needs Access"),
                            systemImage: isRequired ? "exclamationmark.circle.fill" : "circle",
                            color: isRequired ? .orange : .secondary
                        )

                        Button(String(localized: "Grant Access")) {
                            action()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isGranted ? [] : .isButton)
        .accessibilityLabel(permissionAccessibilityLabel(title: title, description: description, isGranted: isGranted))
        .accessibilityHint(isGranted ? "" : String(localized: "Use the grant access button to continue setup."))
        .accessibilityAction(named: Text(String(localized: "Grant Access"))) {
            guard !isGranted else { return }
            action()
        }
    }

    private func permissionAccessibilityLabel(title: String, description: String, isGranted: Bool) -> String {
        let status = isGranted
            ? String(localized: "Granted")
            : String(localized: "Needs access")
        return "\(title). \(description) \(status)."
    }

    // MARK: - Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 12) {
            recommendedHotkeyCard

            VStack(spacing: 8) {
                compactHotkeyModeCard(
                    mode: .pushToTalk,
                    title: String(localized: "Push-to-Talk"),
                    description: String(localized: "Hold to record, release to stop.")
                )

                compactHotkeyModeCard(
                    mode: .toggle,
                    title: String(localized: "Toggle"),
                    description: String(localized: "Press to start, press again to stop.")
                )
            }

            if let hotkeyMessage {
                Label(hotkeyMessage.text, systemImage: hotkeyMessage.systemImage)
                    .font(.caption)
                    .foregroundStyle(hotkeyMessage.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    private var recommendedHotkeyCard: some View {
        setupCard(isSelected: selectedHotkeyMode == .hybrid) {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: selectedHotkeyMode == .hybrid ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selectedHotkeyMode == .hybrid ? .blue : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(String(localized: "Hybrid"))
                                .font(.headline)

                            Text(String(localized: "Recommended"))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.18))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }

                        Text(String(localized: "Short press to toggle, hold to push-to-talk."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    hotkeyChip(label: displayedHotkeyLabel(for: .hybrid))
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedHotkeyMode = .hybrid }

                if selectedHotkeyMode == .hybrid, shouldShowRecorder(for: .hybrid) {
                    hotkeyRecorder(for: .hybrid)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(hotkeyModeAccessibilityLabel(
            title: String(localized: "Hybrid"),
            description: String(localized: "Short press to toggle, hold to push-to-talk."),
            label: displayedHotkeyLabel(for: .hybrid)
        ))
        .accessibilityValue(selectedHotkeyMode == .hybrid ? String(localized: "Selected") : "")
        .accessibilityHint(String(localized: "Recommended. Press Return to continue with this shortcut."))
        .accessibilityAction(named: Text(String(localized: "Select"))) {
            selectedHotkeyMode = .hybrid
        }
    }

    private func compactHotkeyModeCard(mode: HotkeySlotType, title: String, description: String) -> some View {
        setupCard(isSelected: selectedHotkeyMode == mode) {
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    Image(systemName: selectedHotkeyMode == mode ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selectedHotkeyMode == mode ? .blue : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !dictation.hotkeys(for: mode).isEmpty {
                        hotkeyChip(label: displayedHotkeyLabel(for: mode))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedHotkeyMode = mode }

                if selectedHotkeyMode == mode, shouldShowRecorder(for: mode) {
                    hotkeyRecorder(for: mode)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(hotkeyModeAccessibilityLabel(
            title: title,
            description: description,
            label: displayedHotkeyLabel(for: mode)
        ))
        .accessibilityValue(selectedHotkeyMode == mode ? String(localized: "Selected") : "")
        .accessibilityHint(String(localized: "Selects this hotkey mode."))
        .accessibilityAction(named: Text(String(localized: "Select"))) {
            selectedHotkeyMode = mode
        }
    }

    private func hotkeyModeAccessibilityLabel(title: String, description: String, label: String) -> String {
        "\(title). \(description) \(String(localized: "Shortcut")): \(label)."
    }

    private func shouldShowRecorder(for mode: HotkeySlotType) -> Bool {
        if mode != selectedHotkeyMode { return false }
        if !dictation.hotkeys(for: mode).isEmpty { return false }
        return mode != .hybrid || !recommendedHotkeyResolution.shouldApply
    }

    private func hotkeyRecorder(for mode: HotkeySlotType) -> some View {
        HStack(spacing: 10) {
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

            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
    }

    private var hotkeyMessage: (text: String, systemImage: String, color: Color)? {
        if hasAnyTriggerHotkey {
            return (
                String(localized: "Your existing shortcut will stay unchanged."),
                "checkmark.circle.fill",
                .green
            )
        }

        if selectedHotkeyMode == .hybrid, recommendedHotkeyResolution.shouldApply {
            return (
                String(localized: "Fn will be set automatically when you continue."),
                "keyboard",
                .secondary
            )
        }

        if selectedHotkeyMode == .hybrid,
           case .conflictingSlot(let slot) = recommendedHotkeyResolution.blockedReason {
            return (
                String(localized: "Fn is already used by \(hotkeyModeTitle(for: slot)). Record another shortcut to continue."),
                "exclamationmark.triangle.fill",
                .orange
            )
        }

        return (
            String(localized: "Record a shortcut to use this mode."),
            "keyboard",
            .secondary
        )
    }

    // MARK: - Engine & AI

    private var engineAIStep: some View {
        VStack(spacing: 10) {
            localReadinessCard

            recommendationCard(
                manifestId: SetupWizardParakeetRecommendation.manifestId,
                title: "Parakeet",
                badge: String(localized: "Recommended"),
                description: SetupWizardParakeetRecommendation.description,
                systemImage: "desktopcomputer",
                isProminent: true
            )

            appleSpeechCard

            appleIntelligenceCard

            cloudProvidersHint
        }
    }

    private var cloudProvidersHint: some View {
        Label(
            String(localized: "Cloud providers can be added later in Settings."),
            systemImage: "cloud"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var localReadinessCard: some View {
        let isReady = hasEngineReadyForSetupTest

        return HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isReady ? .green : .secondary)
            Text(localReadinessText)
            .font(.callout.weight(.medium))
            .foregroundStyle(isReady ? .green : .secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    private var localReadinessText: String {
        if isActivatingParakeet {
            return String(localized: "Activating Parakeet for local dictation")
        }
        if hasEngineReadyForSetupTest {
            if selectedTranscriptionEngineForSetup?.providerId == SetupWizardAppleSpeechFallback.providerId {
                return String(localized: "Apple Speech is ready for local dictation")
            }
            if selectedTranscriptionEngineForSetup?.providerId == SetupWizardParakeetRecommendation.providerId {
                return String(localized: "Parakeet is ready for local dictation")
            }
            return String(localized: "Ready to use locally")
        }
        if isPreparingAppleSpeechFallback {
            return String(localized: "Preparing Apple Speech for the first test")
        }
        if canUseAppleSpeechFallback {
            return String(localized: "Apple Speech can be used locally")
        }
        return String(localized: "Choose a local engine now or continue and finish later")
    }

    @ViewBuilder
    private func recommendationCard(
        manifestId: String,
        title: String,
        badge: String,
        description: String,
        systemImage: String,
        isProminent: Bool = false
    ) -> some View {
        let loadedPlugin = pluginManager.loadedPlugins.first { $0.manifest.id == manifestId }
        let isInstalled = loadedPlugin != nil
        let engine = loadedPlugin?.instance as? any TranscriptionEnginePlugin
        let isReady = engine?.isConfigured ?? false
        let isSelected = engine?.providerId == modelManager.selectedProviderId
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
        let isInteractive = recommendationCardIsInteractive(
            manifestId: manifestId,
            availability: availability,
            isSelected: isSelected
        )
        let card = setupCard(isSelected: isSelected) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.headline)
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(isProminent ? 0.22 : 0.18))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Text(recommendationDescription(fallback: description, availability: availability))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                recommendationStatus(
                    manifestId: manifestId,
                    availability: availability,
                    registryPlugin: registryPlugin,
                    isSelected: isSelected
                )
            }
        }

        if isInteractive {
            card
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await handleRecommendationCardAction(manifestId: manifestId, registryPlugin: registryPlugin) }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(recommendationCardAccessibilityHint(manifestId: manifestId, availability: availability))
        } else {
            card
        }
    }

    @ViewBuilder
    private func recommendationStatus(
        manifestId: String,
        availability: SetupWizardRecommendationAvailability,
        registryPlugin: RegistryPlugin?,
        isSelected: Bool
    ) -> some View {
        if manifestId == SetupWizardParakeetRecommendation.manifestId, isActivatingParakeet {
            ProgressView()
                .controlSize(.small)
        } else {
            switch availability {
            case .ready:
                if manifestId == SetupWizardParakeetRecommendation.manifestId, isSelected {
                    statusPill(String(localized: "Selected"), systemImage: "checkmark.circle.fill", color: .blue)
                } else if manifestId == SetupWizardParakeetRecommendation.manifestId {
                    statusPill(String(localized: "Select"), systemImage: "circle", color: .blue)
                } else {
                    statusPill(String(localized: "Ready"), systemImage: "checkmark.circle.fill", color: .green)
                }
            case .setupRequired:
                if manifestId == SetupWizardParakeetRecommendation.manifestId {
                    statusPill(String(localized: "Activate"), systemImage: "play.circle.fill", color: .blue)
                } else {
                    RecommendationSettingsButton(manifestId: manifestId)
                }
            case .installState(let installState):
                switch installState {
                case .downloading(let progress):
                    ProgressView(value: progress)
                        .frame(width: 70)
                case .extracting:
                    ProgressView()
                        .controlSize(.small)
                case .error:
                    statusPill(String(localized: "Retry later"), systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
            case .installAvailable:
                statusPill(String(localized: "Install"), systemImage: "arrow.down.circle.fill", color: .blue)
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .unavailable(let reason):
                statusPill(reason.title, systemImage: "exclamationmark.triangle.fill", color: .orange)
                    .help(reason.message)
            }
        }
    }

    private func recommendationCardIsInteractive(
        manifestId: String,
        availability: SetupWizardRecommendationAvailability,
        isSelected: Bool
    ) -> Bool {
        guard manifestId == SetupWizardParakeetRecommendation.manifestId, !isSelected else {
            return false
        }

        switch availability {
        case .ready, .setupRequired, .installAvailable:
            return true
        default:
            return false
        }
    }

    private func recommendationCardAccessibilityHint(
        manifestId: String,
        availability: SetupWizardRecommendationAvailability
    ) -> String {
        guard manifestId == SetupWizardParakeetRecommendation.manifestId else {
            return ""
        }

        switch availability {
        case .installAvailable:
            return String(localized: "Installs and selects Parakeet.")
        case .setupRequired:
            return String(localized: "Activates Parakeet.")
        default:
            return String(localized: "Selects Parakeet.")
        }
    }

    @MainActor
    private func handleRecommendationCardAction(manifestId: String, registryPlugin: RegistryPlugin?) async {
        guard manifestId == SetupWizardParakeetRecommendation.manifestId else { return }
        await activateParakeetForSetup(registryPlugin: registryPlugin)
    }

    @MainActor
    private func activateParakeetForSetup(registryPlugin: RegistryPlugin? = nil) async {
        guard !isActivatingParakeet else { return }

        manuallySelectedSetupProviderId = SetupWizardParakeetRecommendation.providerId
        isActivatingParakeet = true
        defer { isActivatingParakeet = false }

        if parakeetEngine == nil {
            if let registryPlugin,
               pluginManager.loadedPlugins.first(where: { $0.manifest.id == registryPlugin.id }) == nil {
                await registryService.downloadAndInstall(registryPlugin)
            }

            if let loaded = pluginManager.loadedPlugins.first(where: { $0.manifest.id == SetupWizardParakeetRecommendation.manifestId }),
               !loaded.isEnabled {
                pluginManager.setPluginEnabled(SetupWizardParakeetRecommendation.manifestId, enabled: true)
            }
        }

        guard let engine = await waitForParakeetEngine() else { return }

        modelManager.selectProvider(engine.providerId)

        if !engine.isConfigured {
            let modelId = engine.selectedModelId
                ?? SetupWizardParakeetRecommendation.preferredModelId(from: engine.modelCatalog)
            if let modelId {
                engine.selectModel(modelId)
            }
        }

        for _ in 0..<240 {
            if Task.isCancelled || engine.isConfigured { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    @MainActor
    private func waitForParakeetEngine() async -> TranscriptionEnginePlugin? {
        for _ in 0..<40 {
            if Task.isCancelled { return nil }
            if let parakeetEngine {
                return parakeetEngine
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return parakeetEngine
    }

    private func recommendationDescription(
        fallback: String,
        availability: SetupWizardRecommendationAvailability
    ) -> String {
        guard availability == .unavailable(.appleSiliconOnly) else {
            return fallback
        }

        return String(localized: "Best local quality, but requires Apple Silicon. Intel Macs can use Apple Speech for setup.")
    }

    @ViewBuilder
    private var appleSpeechCard: some View {
        let isSelected = modelManager.selectedProviderId == SetupWizardAppleSpeechFallback.providerId
        let card = setupCard(isSelected: isSelected) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.mic")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("Apple Speech")
                            .font(.headline)
                        Text(String(localized: "Built-in"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.18))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Text(appleSpeechDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                appleSpeechStatus
            }
        }

        if canSelectAppleSpeechForSetup {
            card
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await activateAppleSpeechForSetup() }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(String(localized: "Selects Apple Speech as the local dictation engine."))
        } else {
            card
        }
    }

    private var appleSpeechDescription: String {
        if isPreparingAppleSpeechFallback {
            return String(localized: "Preparing the built-in speech engine for the first dictation test.")
        }

        return String(localized: "Lightweight built-in option with no large local model. Parakeet gives better quality for daily dictation.")
    }

    @ViewBuilder
    private var appleSpeechStatus: some View {
        if #available(macOS 26, *) {
            if appleSpeechEngine?.isConfigured == true {
                if modelManager.selectedProviderId == SetupWizardAppleSpeechFallback.providerId {
                    statusPill(String(localized: "Selected"), systemImage: "checkmark.circle.fill", color: .blue)
                } else {
                    statusPill(String(localized: "Select"), systemImage: "circle", color: .blue)
                }
            } else if isPreparingAppleSpeechFallback {
                ProgressView()
                    .controlSize(.small)
            } else if modelManager.selectedProviderId == SetupWizardAppleSpeechFallback.providerId {
                statusPill(String(localized: "Active"), systemImage: "checkmark.circle.fill", color: .blue)
            } else if let appleSpeechEngine, modelManager.canUseForTranscription(appleSpeechEngine) {
                statusPill(String(localized: "Select"), systemImage: "circle", color: .blue)
            } else {
                statusPill(String(localized: "Unavailable"), systemImage: "circle", color: .secondary)
            }
        } else {
            statusPill(String(localized: "macOS 26"), systemImage: "circle", color: .secondary)
        }
    }

    @ViewBuilder
    private var appleIntelligenceCard: some View {
        setupCard(isSelected: false) {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text("Apple Intelligence")
                            .font(.headline)
                        Text(String(localized: "Built-in"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.18))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Text(String(localized: "On-device AI processing. No API key needed."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if #available(macOS 26, *) {
                    if promptProcessingService.isAppleIntelligenceAvailable {
                        statusPill(String(localized: "Ready"), systemImage: "checkmark.circle.fill", color: .green)
                    } else {
                        statusPill(String(localized: "Optional"), systemImage: "circle", color: .secondary)
                    }
                } else {
                    statusPill(String(localized: "macOS 26"), systemImage: "circle", color: .secondary)
                }
            }
        }
    }

    // MARK: - Finish

    private var finishStep: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.blue)
                hotkeyChip(label: primaryHotkeyLabel)
            }
            .font(.callout)

            TextEditor(text: $trialText)
                .font(.body)
                .frame(minHeight: 112)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .focused($isTrialFieldFocused)
                .accessibilityLabel(String(localized: "Try dictation text field"))
                .accessibilityHint(String(localized: "Press your hotkey and dictate. Inserted text appears here."))

            if trialSuccess {
                setupCard(isSelected: false) {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "You're all set!"))
                                .font(.headline)
                            Text(String(localized: "TypeWhisper is ready to help you work faster."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                setupCard(isSelected: false) {
                    HStack(spacing: 14) {
                        Image(systemName: readinessIcon)
                            .font(.title2)
                            .foregroundStyle(readinessColor)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(readinessTitle)
                                .font(.headline)
                            Text(readinessDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
            }
        }
        .onChange(of: dictation.state) { oldValue, newValue in
            if case .inserting = oldValue, case .idle = newValue {
                withAnimation(.spring(duration: 0.35)) {
                    trialSuccess = true
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isTrialFieldFocused = true
        }
    }

    private var readinessIcon: String {
        hasEngineReadyForSetupTest && hasAnyTriggerHotkey ? "sparkles" : "exclamationmark.triangle.fill"
    }

    private var readinessColor: Color {
        hasEngineReadyForSetupTest && hasAnyTriggerHotkey ? .blue : .orange
    }

    private var readinessTitle: String {
        hasEngineReadyForSetupTest && hasAnyTriggerHotkey
            ? String(localized: "Try it out")
            : String(localized: "Setup can be finished later")
    }

    private var readinessDescription: String {
        if isPreparingAppleSpeechFallback {
            return String(localized: "Apple Speech is being prepared for this test.")
        }
        if !hasEngineReadyForSetupTest {
            return String(localized: "Apple Speech or another engine still needs to be enabled before dictation can run.")
        }
        if !hasAnyTriggerHotkey {
            return String(localized: "A hotkey still needs to be set before dictation can start.")
        }
        return String(localized: "Press your hotkey and say something.")
    }

    // MARK: - Shared Helpers

    private var canProceed: Bool {
        switch currentWizardStep {
        case .permissions:
            return true
        case .hotkey:
            return canProceedFromHotkey
        default:
            return true
        }
    }

    private var canProceedFromHotkey: Bool {
        if hasAnyTriggerHotkey { return true }
        if !dictation.hotkeys(for: selectedHotkeyMode).isEmpty { return true }
        return selectedHotkeyMode == .hybrid && recommendedHotkeyResolution.shouldApply
    }

    private var hasEngineReadyForSetupTest: Bool {
        _ = pluginManager.readinessRevision
        guard let engine = selectedTranscriptionEngineForSetup else { return false }
        return canUseEngineForSetupTest(engine)
    }

    private var selectedTranscriptionEngineForSetup: TranscriptionEnginePlugin? {
        guard let providerId = modelManager.selectedProviderId else { return nil }
        return pluginManager.transcriptionEngine(for: providerId)
    }

    private var appleSpeechEngine: TranscriptionEnginePlugin? {
        pluginManager.transcriptionEngine(for: SetupWizardAppleSpeechFallback.providerId)
    }

    private var parakeetEngine: TranscriptionEnginePlugin? {
        pluginManager.transcriptionEngine(for: SetupWizardParakeetRecommendation.providerId)
    }

    private var isParakeetReadyForSetup: Bool {
        guard let parakeetEngine else { return false }
        return canUseEngineForSetupTest(parakeetEngine)
    }

    private var canUseAppleSpeechFallback: Bool {
        canUseAppleSpeechFallbackEngine(appleSpeechEngine)
    }

    private var canSelectAppleSpeechForSetup: Bool {
        canUseAppleSpeechFallback
    }

    private func canUseEngineForSetupTest(_ engine: TranscriptionEnginePlugin) -> Bool {
        guard modelManager.canUseForTranscription(engine) else { return false }
        if engine.isConfigured { return true }
        return engine.providerId != SetupWizardAppleSpeechFallback.providerId && engine.selectedModelId != nil
    }

    private func canUseAppleSpeechFallbackEngine(_ engine: TranscriptionEnginePlugin?) -> Bool {
        guard #available(macOS 26, *) else { return false }
        guard let engine, modelManager.canUseForTranscription(engine) else { return false }
        return engine.isConfigured || !engine.modelCatalog.isEmpty
    }

    @MainActor
    private func activateAppleSpeechForSetup() async {
        manuallySelectedSetupProviderId = SetupWizardAppleSpeechFallback.providerId
        ensureAppleSpeechPluginEnabledIfPossible()

        guard let appleSpeechEngine = await waitForAppleSpeechEngine(),
              modelManager.canUseForTranscription(appleSpeechEngine) else {
            return
        }

        modelManager.selectProvider(appleSpeechEngine.providerId)
        guard !appleSpeechEngine.isConfigured else { return }

        isPreparingAppleSpeechFallback = true
        defer { isPreparingAppleSpeechFallback = false }

        for _ in 0..<40 {
            if Task.isCancelled { return }
            if appleSpeechEngine.isConfigured { return }
            if let modelId = SetupWizardAppleSpeechFallback.preferredModelId(from: appleSpeechEngine.modelCatalog) {
                appleSpeechEngine.selectModel(modelId)
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        for _ in 0..<40 {
            if Task.isCancelled || appleSpeechEngine.isConfigured { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func preparePreferredSetupEngineIfNeeded() async {
        guard !isActivatingParakeet else { return }

        if let manuallySelectedSetupProviderId,
           let manuallySelectedEngine = pluginManager.transcriptionEngine(for: manuallySelectedSetupProviderId),
           canUseEngineForSetupTest(manuallySelectedEngine) {
            modelManager.selectProvider(manuallySelectedEngine.providerId)
            return
        }

        let selectedEngineReady = selectedTranscriptionEngineForSetup.map(canUseEngineForSetupTest) ?? false
        let preferredProviderId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: modelManager.selectedProviderId,
            selectedEngineReady: selectedEngineReady,
            parakeetReady: isParakeetReadyForSetup,
            appleSpeechAvailable: canUseAppleSpeechFallback
        )

        if preferredProviderId == SetupWizardParakeetRecommendation.providerId, let parakeetEngine {
            modelManager.selectProvider(parakeetEngine.providerId)
            return
        }

        if let selectedEngine = selectedTranscriptionEngineForSetup,
           selectedEngineReady,
           preferredProviderId == selectedEngine.providerId {
            modelManager.selectProvider(selectedEngine.providerId)
            return
        }

        guard !isPreparingAppleSpeechFallback else {
            return
        }

        ensureAppleSpeechPluginEnabledIfPossible()

        guard let appleSpeechEngine = await waitForAppleSpeechEngine(),
              modelManager.canUseForTranscription(appleSpeechEngine),
              SetupWizardEngineSelection.preferredProviderId(
                selectedProviderId: modelManager.selectedProviderId,
                selectedEngineReady: selectedEngineReady,
                parakeetReady: isParakeetReadyForSetup,
                appleSpeechAvailable: true
              ) == SetupWizardAppleSpeechFallback.providerId else {
            return
        }

        modelManager.selectProvider(appleSpeechEngine.providerId)
        guard !appleSpeechEngine.isConfigured else { return }

        isPreparingAppleSpeechFallback = true
        defer { isPreparingAppleSpeechFallback = false }

        for _ in 0..<40 {
            if Task.isCancelled { return }
            if appleSpeechEngine.isConfigured { return }
            if let modelId = SetupWizardAppleSpeechFallback.preferredModelId(from: appleSpeechEngine.modelCatalog) {
                appleSpeechEngine.selectModel(modelId)
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        for _ in 0..<40 {
            if Task.isCancelled || appleSpeechEngine.isConfigured { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func ensureAppleSpeechPluginEnabledIfPossible() {
        guard appleSpeechEngine == nil,
              let loaded = pluginManager.loadedPlugins.first(where: { $0.manifest.id == SetupWizardAppleSpeechFallback.manifestId }),
              !loaded.isEnabled else {
            return
        }

        pluginManager.setPluginEnabled(SetupWizardAppleSpeechFallback.manifestId, enabled: true)
    }

    @MainActor
    private func waitForAppleSpeechEngine() async -> TranscriptionEnginePlugin? {
        for _ in 0..<20 {
            if Task.isCancelled { return nil }
            if let appleSpeechEngine {
                return appleSpeechEngine
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return appleSpeechEngine
    }

    private var hasAnyTriggerHotkey: Bool {
        SetupWizardDefaultHotkey.triggerSlots.contains { !dictation.hotkeys(for: $0).isEmpty }
    }

    private var recommendedHotkeyResolution: SetupWizardDefaultHotkey.Resolution {
        SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: SetupWizardDefaultHotkey.triggerSlots.reduce(into: [:]) { result, slot in
                result[slot] = dictation.hotkeys(for: slot)
            },
            conflictingSlot: dictation.isHotkeyAssigned(SetupWizardDefaultHotkey.recommendedHybridHotkey, excluding: .hybrid)
        )
    }

    private func applyRecommendedHotkeyIfNeeded() {
        guard selectedHotkeyMode == .hybrid,
              recommendedHotkeyResolution.shouldApply else {
            return
        }

        dictation.setHotkey(SetupWizardDefaultHotkey.recommendedHybridHotkey, for: .hybrid)
    }

    private var primaryHotkeyLabel: String {
        for slot in SetupWizardDefaultHotkey.triggerSlots {
            let label = hotkeyLabel(for: slot)
            if !label.isEmpty { return label }
        }
        return String(localized: "No hotkey")
    }

    private func displayedHotkeyLabel(for mode: HotkeySlotType) -> String {
        let label = hotkeyLabel(for: mode)
        if !label.isEmpty { return label }
        if mode == .hybrid, recommendedHotkeyResolution.shouldApply {
            return HotkeyService.displayName(for: SetupWizardDefaultHotkey.recommendedHybridHotkey)
        }
        return String(localized: "Not set")
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
        case .promptPalette: return String(localized: "Workflow Palette")
        case .recentTranscriptions: return String(localized: "Recent Transcriptions")
        case .copyLastTranscription: return String(localized: "Copy Last Transcription")
        case .recorderToggle: return String(localized: "settings.tab.recorder")
        }
    }

    private func setupCard<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.12) : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.65) : Color.white.opacity(0.11), lineWidth: 1)
            )
    }

    private func statusPill(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .lineLimit(1)
    }

    private func hotkeyChip(label: String) -> some View {
        Text(label)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .lineLimit(1)
    }
}

private enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case hotkey
    case engineAI
    case finish

    var id: Int { rawValue }

    var progressTitle: String {
        switch self {
        case .welcome:
            String(localized: "Welcome")
        case .permissions:
            String(localized: "Permissions")
        case .hotkey:
            String(localized: "Hotkey")
        case .engineAI:
            String(localized: "AI & Engine")
        case .finish:
            String(localized: "Finish")
        }
    }

    var title: String {
        switch self {
        case .welcome:
            String(localized: "Welcome to TypeWhisper")
        case .permissions:
            String(localized: "Permissions")
        case .hotkey:
            String(localized: "Choose Your Hotkey")
        case .engineAI:
            String(localized: "AI & Engine")
        case .finish:
            String(localized: "Try It Out")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            String(localized: "Set up voice typing in a few simple steps.")
        case .permissions:
            String(localized: "TypeWhisper needs access to work on your Mac.")
        case .hotkey:
            String(localized: "Start and stop dictation without leaving your app.")
        case .engineAI:
            String(localized: "Local defaults are ready first; cloud providers can wait.")
        case .finish:
            String(localized: "Press your hotkey and say something.")
        }
    }
}

enum SetupWizardDefaultHotkey {
    enum BlockedReason: Equatable {
        case existingTriggerHotkey
        case conflictingSlot(HotkeySlotType)
    }

    struct Resolution: Equatable {
        let shouldApply: Bool
        let blockedReason: BlockedReason?
    }

    static let triggerSlots: [HotkeySlotType] = [.hybrid, .pushToTalk, .toggle]
    static let recommendedHybridHotkey = UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true)

    static func resolve(
        existingTriggerHotkeys: [HotkeySlotType: [UnifiedHotkey]],
        conflictingSlot: HotkeySlotType?
    ) -> Resolution {
        if triggerSlots.contains(where: { !(existingTriggerHotkeys[$0] ?? []).isEmpty }) {
            return Resolution(shouldApply: false, blockedReason: .existingTriggerHotkey)
        }

        if let conflictingSlot {
            return Resolution(shouldApply: false, blockedReason: .conflictingSlot(conflictingSlot))
        }

        return Resolution(shouldApply: true, blockedReason: nil)
    }
}

enum SetupWizardParakeetRecommendation {
    static let providerId = "parakeet"
    static let manifestId = "com.typewhisper.parakeet"

    static var description: String {
        String(localized: "Best local quality for daily dictation. Runs offline with no API key.")
    }

    static func preferredModelId(from models: [PluginModelInfo]) -> String? {
        models.first { $0.id == "parakeet-tdt-0.6b-v3" }?.id
            ?? models.first { $0.id.localizedCaseInsensitiveContains("v3") }?.id
            ?? models.first?.id
    }
}

enum SetupWizardEngineSelection {
    static func preferredProviderId(
        selectedProviderId: String?,
        selectedEngineReady: Bool,
        parakeetReady: Bool,
        appleSpeechAvailable: Bool
    ) -> String? {
        if parakeetReady, selectedProviderId == SetupWizardAppleSpeechFallback.providerId {
            return SetupWizardParakeetRecommendation.providerId
        }

        if selectedEngineReady {
            return selectedProviderId
        }

        if parakeetReady {
            return SetupWizardParakeetRecommendation.providerId
        }

        if appleSpeechAvailable {
            return SetupWizardAppleSpeechFallback.providerId
        }

        return nil
    }
}

enum SetupWizardAppleSpeechFallback {
    static let providerId = "speechAnalyzer"
    static let manifestId = "com.typewhisper.speechanalyzer"

    static func preferredModelId(
        from models: [PluginModelInfo],
        localeIdentifier: String = Locale.current.identifier,
        languageCode: String? = Locale.current.language.languageCode?.identifier
    ) -> String? {
        guard !models.isEmpty else { return nil }

        for modelId in localeModelIds(for: localeIdentifier) {
            if models.contains(where: { $0.id == modelId }) {
                return modelId
            }
        }

        if let languageCode {
            let languageModelId = "speechanalyzer-\(languageCode)"
            if models.contains(where: { $0.id == languageModelId }) {
                return languageModelId
            }

            if let match = models.first(where: { modelLanguageCode(for: $0.id) == languageCode }) {
                return match.id
            }
        }

        return models.first?.id
    }

    private static func localeModelIds(for localeIdentifier: String) -> [String] {
        uniqueModelIds([
            localeIdentifier,
            localeIdentifier.replacingOccurrences(of: "-", with: "_"),
            localeIdentifier.replacingOccurrences(of: "_", with: "-")
        ])
        .map { "speechanalyzer-\($0)" }
    }

    private static func modelLanguageCode(for modelId: String) -> String? {
        let prefix = "speechanalyzer-"
        guard modelId.hasPrefix(prefix) else { return nil }
        let localeIdentifier = String(modelId.dropFirst(prefix.count))
        return Locale(identifier: localeIdentifier).language.languageCode?.identifier
    }

    private static func uniqueModelIds(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            guard !value.isEmpty, !result.contains(value) else { return }
            result.append(value)
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
            String(localized: "Apple Silicon only")
        case .marketplaceUnavailable:
            String(localized: "Unavailable")
        }
    }

    var message: String {
        switch self {
        case .appleSiliconOnly:
            String(localized: "Use Groq or OpenAI with a cloud Whisper model on Intel.")
        case .marketplaceUnavailable:
            String(localized: "No compatible download is available for this Mac.")
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
        if manifestId == SetupWizardParakeetRecommendation.manifestId, architecture != "arm64" {
            return .unavailable(.appleSiliconOnly)
        }

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
            Label(String(localized: "Setup"), systemImage: "gear")
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
