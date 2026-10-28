import SwiftUI
import TypeWhisperPluginSDK

struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var promptProcessingService: PromptProcessingService
    @ObservedObject private var settings = SettingsViewModel.shared
    @StateObject private var networkStatus = SetupWizardNetworkStatus()

    @State private var currentStep: Int
    @State private var selectedHotkeyMode: HotkeySlotType
    @AppStorage(UserDefaultsKeys.setupWizardTestedSelections) private var testedSelectionsData = Data()
    @State private var trialSignal = SetupWizardTrialSignal()
    @State private var trialText = ""
    @State private var trialAnnouncementTask: Task<Void, Never>?
    @State private var didAnnounceInitialStep = false
    @State private var isPreparingAppleSpeechFallback = false
    @State private var activatingEngine: SetupWizardLocalEngine?
    @State private var activationModelProgress: Double?
    @State private var manuallySelectedSetupProviderId: String?
    @State private var isLogoHovering = false
    @State private var isMovingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isTrialFieldFocused: Bool

    private let accessibilityAnnouncementService = ServiceContainer.shared.accessibilityAnnouncementService

    init() {
        let saved = UserDefaults.standard.integer(forKey: UserDefaultsKeys.setupWizardCurrentStep)
        let maxStep = SetupWizardStep.allCases.count - 1
        let managedStep = ManagedOnboardingPolicy.initialStep(
            ServiceContainer.shared.managedPolicyService.current,
            savedStep: saved,
            readiness: .current()
        )
        _currentStep = State(initialValue: min(max(managedStep ?? saved, 0), maxStep))
        _promptProcessingService = ObservedObject(wrappedValue: ServiceContainer.shared.promptProcessingService)

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
        .onReceive(pluginManager.$registryRevision) { _ in
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
        accessibilityAnnouncementService.announce(localizedAppText(
            "\(currentWizardStep.title). Step \(currentStep + 1) of \(SetupWizardStep.allCases.count). \(currentWizardStep.subtitle)",
            de: "\(currentWizardStep.title). Schritt \(currentStep + 1) von \(SetupWizardStep.allCases.count). \(currentWizardStep.subtitle)",
            ja: "\(currentWizardStep.title)。\(SetupWizardStep.allCases.count)ステップ中\(currentStep + 1)。\(currentWizardStep.subtitle)",
            zh: "\(currentWizardStep.title)。第 \(currentStep + 1) 步，共 \(SetupWizardStep.allCases.count) 步。\(currentWizardStep.subtitle)",
            zhHant: "\(currentWizardStep.title)。第 \(currentStep + 1) 步，共 \(SetupWizardStep.allCases.count) 步。\(currentWizardStep.subtitle)",
            es: "\(currentWizardStep.title). Paso \(currentStep + 1) de \(SetupWizardStep.allCases.count). \(currentWizardStep.subtitle)"
        ))
    }

    /// "Step 2 of 5" for the current step, exposed as the progress value.
    private var currentStepPositionText: String {
        let index = currentStep + 1
        let count = SetupWizardStep.allCases.count
        return localizedAppText(
            "Step \(index) of \(count)",
            de: "Schritt \(index) von \(count)",
            ja: "ステップ \(index)/\(count)",
            zh: "第 \(index) 步，共 \(count) 步",
            zhHant: "第 \(index) 步，共 \(count) 步",
            es: "Paso \(index) de \(count)"
        )
    }

    private func restartWizardFromBeginning() {
        trialSignal.reset()
        trialText = ""
        manuallySelectedSetupProviderId = nil
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        isMovingForward = false
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = 0
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Text(localizedAppText("TypeWhisper Setup", de: "TypeWhisper Setup"))
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel(localizedAppText(
                "Setup progress",
                de: "Setup-Fortschritt",
                ja: "セットアップの進行状況",
                zh: "设置进度",
                zhHant: "設定進度"
            ))
            .accessibilityValue(currentStepPositionText)
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
        .accessibilityLabel(localizedAppText(
            "Step \(step.rawValue + 1) of \(SetupWizardStep.allCases.count), \(step.progressTitle)",
            de: "Schritt \(step.rawValue + 1) von \(SetupWizardStep.allCases.count), \(step.progressTitle)",
            ja: "\(SetupWizardStep.allCases.count)ステップ中\(step.rawValue + 1)、\(step.progressTitle)",
            zh: "第 \(step.rawValue + 1) 步，共 \(SetupWizardStep.allCases.count) 步，\(step.progressTitle)",
            zhHant: "第 \(step.rawValue + 1) 步，共 \(SetupWizardStep.allCases.count) 步，\(step.progressTitle)",
            es: "Paso \(step.rawValue + 1) de \(SetupWizardStep.allCases.count), \(step.progressTitle)"
        ))
        .accessibilityValue(progressAccessibilityStatus(for: step))
        .accessibilityAddTraits(step == currentWizardStep ? .isSelected : [])
    }

    private func progressFill(for step: SetupWizardStep) -> Color {
        if step.rawValue <= currentStep {
            return .blue
        }
        return Color.white.opacity(0.16)
    }

    private func progressAccessibilityStatus(for step: SetupWizardStep) -> String {
        if step.rawValue < currentStep {
            return localizedAppText("Completed", de: "Abgeschlossen", ja: "完了", zh: "已完成", zhHant: "已完成")
        }
        if step == currentWizardStep {
            return localizedAppText("Current", de: "Aktuell", ja: "現在のステップ", zh: "当前", zhHant: "目前")
        }
        return localizedAppText("Upcoming", de: "Ausstehend", ja: "未完了", zh: "待完成", zhHant: "待完成")
    }

    private var stepContent: some View {
        ScrollView {
            VStack(spacing: 18) {
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
                // Slide each step in from the direction of travel (forward from
                // the trailing edge, back from the leading edge); fall back to a
                // plain fade under Reduce Motion.
                .id(currentWizardStep)
                .transition(stepTransition)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 34)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.never)
    }

    /// Directional slide+fade for step changes; plain fade under Reduce Motion.
    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertionEdge: Edge = isMovingForward ? .trailing : .leading
        let removalEdge: Edge = isMovingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertionEdge).combined(with: .opacity),
            removal: .move(edge: removalEdge).combined(with: .opacity)
        )
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if currentStep > 0 {
                Button(localizedAppText("Back", de: "Zurück")) {
                    isMovingForward = false
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep -= 1
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            }

            Spacer()

            Button(localizedAppText("Skip Setup", de: "Setup überspringen")) {
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
            return localizedAppText("Grant Microphone Access", de: "Mikrofonzugriff erlauben")
        }

        if currentWizardStep == .finish {
            return setupReadiness.canCompleteSetup
                ? localizedAppText("Complete Setup", de: "Setup abschließen")
                : String(localized: "Finish Later")
        }
        return localizedAppText("Continue", de: "Weiter")
    }

    private var primaryKeyboardShortcut: KeyboardShortcut {
        currentWizardStep == .finish
            ? KeyboardShortcut(.return, modifiers: [.command])
            : .defaultAction
    }

    private var primaryActionAccessibilityHint: String {
        if currentWizardStep == .finish {
            return setupReadiness.canCompleteSetup
                ? localizedAppText("Press Command Return to complete setup.", de: "Drücke Befehlstaste Return, um das Setup abzuschließen.")
                : String(localized: "Press Command Return to finish setup later.")
        }

        return localizedAppText("Press Return to continue.", de: "Drücke Return, um fortzufahren.")
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

        isMovingForward = true
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = min(currentStep + 1, SetupWizardStep.allCases.count - 1)
        }
    }

    private func completeSetupAndOpenHome() {
        // A past test never substitutes for the current engine and permissions.
        if setupReadiness.canCompleteSetup {
            HomeViewModel.shared.completeSetupWizard()
        } else {
            HomeViewModel.shared.deferSetupWizard()
        }
        SettingsNavigationCoordinator.shared?.navigate(to: .home)
        dismiss()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 22) {
            WaveformLogoView(isActive: isLogoHovering && !reduceMotion)
                .frame(width: 74, height: 74)
                .shadow(color: .blue.opacity(0.35), radius: 16)
                .scaleEffect(isLogoHovering && !reduceMotion ? 1.05 : 1.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isLogoHovering)
                .onHover { isLogoHovering = $0 }
                // Decorative: the step title already says "Welcome to TypeWhisper".
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 14) {
                setupFeatureRow(
                    icon: "mic.fill",
                    title: localizedAppText("Speak naturally", de: "Natürlich sprechen"),
                    description: localizedAppText("Press a hotkey and talk in any app.", de: "Drücke einen Hotkey und sprich in jeder App.")
                )
                setupFeatureRow(
                    icon: "text.cursor",
                    title: localizedAppText("Type instantly", de: "Sofort schreiben"),
                    description: localizedAppText("Your words appear as text right away.", de: "Deine Worte erscheinen direkt als Text.")
                )
                setupFeatureRow(
                    icon: "wand.and.stars",
                    title: localizedAppText("Enhance with AI", de: "Mit KI verbessern"),
                    description: localizedAppText("Rewrite, translate, summarize, and more.", de: "Umschreiben, übersetzen, zusammenfassen und mehr.")
                )
            }
            .frame(maxWidth: 390, alignment: .leading)

            SetupWizardImportLink()
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
        .accessibilityElement(children: .combine)
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            permissionCard(
                title: localizedAppText("Microphone Access", de: "Mikrofonzugriff"),
                description: localizedAppText("Required to capture your voice.", de: "Erforderlich, um deine Stimme aufzunehmen."),
                systemImage: "mic.fill",
                isGranted: !dictation.needsMicPermission,
                isRequired: true,
                action: { dictation.requestMicPermission() }
            )

#if APPSTORE
            // Both are optional: without them, text is copied to the clipboard and only
            // shortcuts with a regular key work.
            if AppStoreInputAccess.isAutoPasteEnabled {
                permissionCard(
                    title: AppStoreInputAccess.postEventSettingsName,
                    description: localizedAppText(
                        "Pastes text into other apps. Without it, text is copied to the clipboard.",
                        de: "Fügt Text in andere Apps ein. Ohne diesen Zugriff wird der Text in die Zwischenablage kopiert."
                    ),
                    systemImage: "figure.stand",
                    isGranted: !dictation.needsAccessibilityPermission,
                    isRequired: false,
                    action: { dictation.requestAccessibilityPermission() }
                )

                AppStorePermissionRestartHint(dictation: dictation, kind: .accessibility)
                    .padding(.horizontal, 4)
            }

            permissionCard(
                title: AppStoreInputAccess.listenEventSettingsName,
                description: localizedAppText(
                    "Needed for Fn, modifier-only, double-tap and mouse-button shortcuts, and for Esc in other apps.",
                    de: "Nötig für Fn-, Modifier-, Doppeltipp- und Maustasten-Kurzbefehle sowie für Esc in anderen Apps."
                ),
                systemImage: "keyboard",
                isGranted: dictation.isInputMonitoringGranted,
                isRequired: false,
                action: { dictation.requestInputMonitoringPermission() }
            )

            AppStorePermissionRestartHint(dictation: dictation, kind: .inputMonitoring)
                .padding(.horizontal, 4)
#else
            permissionCard(
                title: AccessibilityPermissionPane.text(
                    legacy: localizedAppText("Accessibility Access", de: "Bedienungshilfen-Zugriff"),
                    deviceControl: AccessibilityPermissionPane.localizedName()
                ),
                description: localizedAppText("Required to type into other apps.", de: "Erforderlich, um in andere Apps zu schreiben."),
                systemImage: "figure.stand",
                isGranted: !dictation.needsAccessibilityPermission,
                isRequired: true,
                action: { dictation.requestAccessibilityPermission() }
            )
#endif

            Label(
                localizedAppText("You can change permissions anytime in System Settings.", de: "Du kannst diese Berechtigungen jederzeit in den Systemeinstellungen ändern."),
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
                        localizedAppText("Granted", de: "Erlaubt"),
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                } else {
                    VStack(alignment: .trailing, spacing: 8) {
                        // Required and optional access differ in text, not only in icon
                        // and color. Only the App Store edition has optional permissions.
                        if isRequired {
                            statusPill(
                                localizedAppText("Needs Access", de: "Zugriff nötig"),
                                systemImage: "exclamationmark.circle.fill",
                                color: .orange
                            )
                        } else {
                            statusPill(
                                localizedAppText("Optional", de: "Optional", ja: "任意", zh: "可选", zhHant: "可選"),
                                systemImage: "circle",
                                color: .secondary
                            )
                        }

                        Button(localizedAppText("Grant Access", de: "Zugriff erlauben")) {
                            action()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        // One element per permission: name and purpose as the label, the
        // granted state as the value (the pill text, not just its color), and
        // pressing it requests access while access is still missing.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(permissionAccessibilityLabel(title: title, description: description, isRequired: isRequired))
        .accessibilityValue(isGranted
            ? localizedAppText("Granted", de: "Erlaubt")
            : localizedAppText("Needs access", de: "Zugriff nötig"))
        .setupWizardAccessibilityPress(
            isEnabled: !isGranted,
            hint: localizedAppText(
                "Requests access. macOS shows a permission prompt or opens System Settings.",
                de: "Fordert den Zugriff an. macOS zeigt eine Abfrage oder öffnet die Systemeinstellungen.",
                ja: "アクセスを要求します。macOS が確認ダイアログを表示するか、システム設定を開きます。",
                zh: "请求访问权限。macOS 会显示权限提示或打开系统设置。",
                zhHant: "請求存取權限。macOS 會顯示權限提示或開啟系統設定。"
            ),
            perform: action
        )
    }

    private func permissionAccessibilityLabel(title: String, description: String, isRequired: Bool) -> String {
        guard !isRequired else { return "\(title). \(description)" }
        let optional = localizedAppText("Optional", de: "Optional", ja: "任意", zh: "可选", zhHant: "可選")
        return "\(title), \(optional). \(description)"
    }

    // MARK: - Hotkey

    private var hotkeyStep: some View {
        VStack(spacing: 12) {
            recommendedHotkeyCard

            VStack(spacing: 8) {
                compactHotkeyModeCard(
                    mode: .pushToTalk,
                    title: localizedAppText("Push-to-Talk", de: "Push-to-Talk"),
                    description: localizedAppText("Hold to record, release to stop.", de: "Zum Aufnehmen halten, zum Stoppen loslassen.")
                )

                compactHotkeyModeCard(
                    mode: .toggle,
                    title: localizedAppText("Toggle", de: "Toggle"),
                    description: localizedAppText("Press to start, press again to stop.", de: "Zum Starten drücken, zum Stoppen erneut drücken.")
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
        let title = localizedAppText("Hybrid", de: "Hybrid")
        let badge = localizedAppText("Recommended", de: "Empfohlen")
        let description = localizedAppText("Short press to toggle, hold to push-to-talk.", de: "Kurz drücken zum Umschalten, halten für Push-to-Talk.")

        return setupCard(isSelected: selectedHotkeyMode == .hybrid) {
            VStack(spacing: 12) {
                // A real (plain) button so the mode can be chosen with Tab and
                // Space, not only by clicking. The recorder below stays a
                // separate control instead of being merged into this row.
                Button {
                    selectedHotkeyMode = .hybrid
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: selectedHotkeyMode == .hybrid ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedHotkeyMode == .hybrid ? .blue : .secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(title)
                                    .font(.headline)

                                Text(badge)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.18))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }

                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        hotkeyChip(label: displayedHotkeyLabel(for: .hybrid))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hotkeyModeAccessibility(
                    label: hotkeyModeAccessibilityLabel(
                        title: title,
                        badge: badge,
                        description: description,
                        label: displayedHotkeyLabel(for: .hybrid)
                    ),
                    isSelected: selectedHotkeyMode == .hybrid,
                    hint: localizedAppText("Recommended. Press Return to continue with this shortcut.", de: "Empfohlen. Drücke Return, um mit diesem Shortcut fortzufahren.")
                )

                if selectedHotkeyMode == .hybrid, shouldShowRecorder(for: .hybrid) {
                    hotkeyRecorder(for: .hybrid)
                }
            }
        }
    }

    private func compactHotkeyModeCard(mode: HotkeySlotType, title: String, description: String) -> some View {
        setupCard(isSelected: selectedHotkeyMode == mode) {
            VStack(spacing: 10) {
                Button {
                    selectedHotkeyMode = mode
                } label: {
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
                }
                .buttonStyle(.plain)
                .hotkeyModeAccessibility(
                    label: hotkeyModeAccessibilityLabel(
                        title: title,
                        badge: nil,
                        description: description,
                        label: displayedHotkeyLabel(for: mode)
                    ),
                    isSelected: selectedHotkeyMode == mode,
                    hint: localizedAppText("Selects this hotkey mode.", de: "Wählt diesen Hotkey-Modus aus.")
                )

                if selectedHotkeyMode == mode, shouldShowRecorder(for: mode) {
                    hotkeyRecorder(for: mode)
                }
            }
        }
    }

    private func hotkeyModeAccessibilityLabel(title: String, badge: String?, description: String, label: String) -> String {
        let name = badge.map { "\(title), \($0)" } ?? title
        return "\(name). \(description) \(localizedAppText("Shortcut", de: "Shortcut")): \(label)."
    }

    private func shouldShowRecorder(for mode: HotkeySlotType) -> Bool {
        if mode != selectedHotkeyMode { return false }
        #if APPSTORE
        // The selected mode always offers a recorder, so the recommended or an
        // existing shortcut can be replaced right here.
        return true
        #else
        if !dictation.hotkeys(for: mode).isEmpty { return false }
        return mode != .hybrid || !recommendedHotkeyResolution.shouldApply
        #endif
    }

    private func hotkeyRecorder(for mode: HotkeySlotType) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            HotkeyRecorderView(
                label: mode == .hybrid && recommendedHotkeyResolution.shouldApply
                    ? HotkeyService.displayName(for: SetupWizardDefaultHotkey.recommendedHybridHotkey)
                    : hotkeyLabel(for: mode),
                title: localizedAppText("Shortcut", de: "Shortcut"),
                onRecord: { hotkey in
                    if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: mode) {
                        dictation.clearHotkey(for: conflict)
                    }
                    dictation.setHotkey(hotkey, for: mode)
                },
                onClear: { dictation.clearHotkey(for: mode) },
                hotkey: dictation.hotkeys(for: mode).first,
                visualKeyboardExistingAssignment: { candidate in
                    guard let slot = dictation.isHotkeyAssigned(candidate, excluding: mode) else {
                        return nil
                    }
                    return HotkeyRecorderView.assignmentDescription(for: slot)
                }
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
                localizedAppText("Your existing shortcut will stay unchanged.", de: "Dein bestehender Shortcut bleibt unverändert."),
                "checkmark.circle.fill",
                .green
            )
        }

        let recommendedName = HotkeyService.displayName(for: SetupWizardDefaultHotkey.recommendedHybridHotkey)
        if selectedHotkeyMode == .hybrid, recommendedHotkeyResolution.shouldApply {
            #if APPSTORE
            let message = localizedAppText(
                "\(recommendedName) will be set when you continue. Click the shortcut to record another one.",
                de: "\(recommendedName) wird beim Fortfahren gesetzt. Klicke auf den Shortcut, um einen anderen aufzunehmen.",
                zhHant: "繼續後將設定為 \(recommendedName)。按一下快速鍵可錄製其他快速鍵。",
                es: "Se configurará \(recommendedName) al continuar. Haz clic en el atajo para grabar otro."
            )
            #else
            let message = localizedAppText("Fn will be set automatically when you continue.", de: "Fn wird beim Fortfahren automatisch gesetzt.")
            #endif
            return (
                message,
                "keyboard",
                .secondary
            )
        }

        if selectedHotkeyMode == .hybrid,
           case .conflictingSlot(let slot) = recommendedHotkeyResolution.blockedReason {
            return (
                localizedAppText(
                    "\(recommendedName) is already used by \(hotkeyModeTitle(for: slot)). Record another shortcut to continue.",
                    de: "\(recommendedName) wird bereits von \(hotkeyModeTitle(for: slot)) verwendet. Nimm einen anderen Shortcut auf, um fortzufahren.",
                    ja: "\(recommendedName)はすでに\(hotkeyModeTitle(for: slot))で使用されています。続行するには別のショートカットを録音してください。",
                    zhHant: "\(recommendedName) 已被「\(hotkeyModeTitle(for: slot))」使用。請錄製其他快速鍵以繼續。",
                    es: "\(hotkeyModeTitle(for: slot)) ya usa \(recommendedName). Graba otro atajo para continuar."
                ),
                "exclamationmark.triangle.fill",
                .orange
            )
        }

        return (
            localizedAppText("Record a shortcut to use this mode.", de: "Nimm einen Shortcut auf, um diesen Modus zu verwenden."),
            "keyboard",
            .secondary
        )
    }

    // MARK: - Engine & AI

    private var engineAIStep: some View {
        // Once per update: the cards below share it instead of rebuilding the input.
        let recommendation = SetupWizardEngineRecommendation.recommend(for: engineRecommendationInput)

        return VStack(spacing: 10) {
            spokenLanguageRow

            localReadinessCard

            switch recommendation {
            case .engine(let choice) where choice.engine != .appleSpeech:
                recommendationCard(for: choice)
            case .limitation(let limitation):
                limitationCard(limitation)
            case .engine, .pending:
                EmptyView()
            }

            appleSpeechCard(recommendation: recommendation)

            appleIntelligenceCard

            cloudProvidersHint
        }
    }

    private var cloudProvidersHint: some View {
        Label(
            localizedAppText(
                "Cloud providers can be added later in Settings.",
                de: "Cloud-Provider kannst du später in den Einstellungen hinzufügen."
            ),
            systemImage: "cloud"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: Spoken Language

    /// The recommendation follows the language the user dictates in. This is the
    /// spoken language setting of the Dictation page; the app language is not used.
    private var spokenLanguageRow: some View {
        let hint = String(localized: "Also used for dictation. You can change it later on the Dictation page.")
        let options = spokenLanguageOptions

        return HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(String(localized: "Spoken Language"))
                .font(.callout.weight(.medium))
                .accessibilityHidden(true)
            Spacer()
            Picker(String(localized: "Spoken Language"), selection: $settings.languageSelection) {
                Text(localizedAppLanguageName(for: "auto"))
                    .tag(LanguageSelection.auto)
                // A mixed selection from the Dictation page stays selectable as it is.
                if case .hints(let codes) = settings.languageSelection {
                    Text(Self.languageList(codes))
                        .tag(settings.languageSelection)
                }
                Divider()
                ForEach(options.featured, id: \.code) { option in
                    Text(option.name).tag(LanguageSelection.exact(option.code))
                }
                Divider()
                ForEach(options.other, id: \.code) { option in
                    Text(option.name).tag(LanguageSelection.exact(option.code))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(hint)
            .accessibilityHint(hint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }

    /// The languages of the local engines and of the Dictation page's picker, plus the
    /// current selection, with the featured languages first.
    private var spokenLanguageOptions: (featured: [LocalizedAppLanguageOption], other: [LocalizedAppLanguageOption]) {
        var codes = Set(settings.availableLanguages.map(\.code))
        for engine in SetupWizardLocalEngine.offered {
            codes.formUnion(engine.knownLanguages ?? [])
        }
        codes.formUnion(settings.languageSelection.selectedCodes)

        let options = localizedAppLanguageOptions(for: Array(codes))
        let featured = options
            .compactMap { option in featuredAppLanguageRank(for: option.code).map { (rank: $0, option: option) } }
            .sorted { $0.rank < $1.rank }
            .map(\.option)
        let featuredCodes = Set(featured.map(\.code))
        let other = options
            .filter { !featuredCodes.contains($0.code) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (featured, other)
    }

    /// "German and English" in the app language.
    private static func languageList(_ codes: [String]) -> String {
        let names = codes.map(localizedAppLanguageName(for:))
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: preferredAppLanguageCode())
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }

    private var spokenLanguages: SetupWizardSpokenLanguages {
        SetupWizardSpokenLanguages(settings.languageSelection)
    }

    // MARK: Recommendation

    /// Checks on disk which models each engine has downloaded, so the step builds it
    /// once per update and passes the recommendation on.
    private var engineRecommendationInput: SetupWizardEngineRecommendationInput {
        _ = pluginManager.readinessRevision
        var engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [:]
        for kind in SetupWizardLocalEngine.offered {
            let engine = pluginManager.transcriptionEngine(for: kind.providerId)
            let languages = engine?.supportedLanguages ?? []
            engines[kind] = SetupWizardEngineState(
                isInstalled: pluginManager.loadedPlugins.contains { $0.manifest.id == kind.manifestId },
                isReady: kind == .appleSpeech
                    ? canUseAppleSpeechFallback
                    : engine.map(canUseEngineForSetupTest) ?? false,
                // Apple Speech reports no languages until it has asked the system.
                reportedLanguages: languages.isEmpty ? nil : languages,
                modelIds: engine.map { $0.modelCatalog.map(\.id) },
                selectedModelId: engine?.selectedModelId,
                downloadedModelIds: engine.map(modelManager.downloadedModelIds(of:)) ?? []
            )
        }

        return SetupWizardEngineRecommendationInput(
            spokenLanguages: spokenLanguages,
            architecture: RuntimeArchitecture.current,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            engines: engines,
            catalog: catalogState,
            isOffline: networkStatus.isOffline
        )
    }

    private var catalogState: SetupWizardCatalogState {
        switch registryService.fetchState {
        case .idle, .loading:
            .loading
        case .loaded:
            .loaded(Set(registryService.registry.map(\.id)))
        case .error:
            .unavailable
        }
    }

    /// Spoken languages the selected engine reports it cannot transcribe. The engine
    /// stays selected; the readiness line says so instead.
    private var selectedEngineUnsupportedLanguages: [String] {
        guard let engine = selectedTranscriptionEngineForSetup else { return [] }
        return SetupWizardEngineRecommendation.unsupportedLanguages(
            spokenLanguages,
            reportedLanguages: engine.supportedLanguages
        )
    }

    private var localReadinessCard: some View {
        let isReady = hasEngineReadyForSetupTest
        // Matches localReadinessText, which shows the activation instead of the warning.
        let isUnsupported = activatingEngine == nil && isReady && !selectedEngineUnsupportedLanguages.isEmpty
        let color: Color = isUnsupported ? .orange : (isReady ? .green : .secondary)
        let icon = isUnsupported ? "exclamationmark.triangle.fill" : (isReady ? "checkmark.circle.fill" : "circle.dashed")

        return HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(localReadinessText)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private var localReadinessText: String {
        if let activatingEngine {
            return String(localized: "Activating \(activatingEngine.displayName) for local dictation")
        }
        if hasEngineReadyForSetupTest, let engine = selectedTranscriptionEngineForSetup {
            let unsupported = selectedEngineUnsupportedLanguages
            if !unsupported.isEmpty {
                return String(localized: "\(engine.providerDisplayName) does not support \(Self.languageList(unsupported)).")
            }
            if engine.providerId == SetupWizardAppleSpeechFallback.providerId {
                return localizedAppText("Apple Speech is ready for local dictation", de: "Apple Speech ist für lokales Diktieren bereit")
            }
            if let localEngine = SetupWizardLocalEngine.engine(forProviderId: engine.providerId) {
                return String(localized: "\(localEngine.displayName) is ready for local dictation")
            }
            return localizedAppText("Ready to use locally", de: "Lokal einsatzbereit")
        }
        if isPreparingAppleSpeechFallback {
            return localizedAppText("Preparing Apple Speech for the first test", de: "Apple Speech wird für den ersten Test vorbereitet")
        }
        if canUseAppleSpeechFallback {
            return localizedAppText("Apple Speech can be used locally", de: "Apple Speech kann lokal genutzt werden")
        }
        return localizedAppText("Choose a local engine now or continue and finish later", de: "Wähle jetzt eine lokale Engine oder fahre fort und schließe später ab")
    }

    @ViewBuilder
    private func recommendationCard(for choice: SetupWizardEngineChoice) -> some View {
        let recommended = choice.engine
        let manifestId = recommended.manifestId
        let engine = pluginManager.transcriptionEngine(for: recommended.providerId)
        let isSelected = engine.map { $0.providerId == modelManager.selectedProviderId } ?? false
        let registryPlugin = registryService.registry.first { $0.id == manifestId }
        let availability = SetupWizardRecommendationAvailability.resolve(
            manifestId: manifestId,
            isInstalled: pluginManager.loadedPlugins.contains { $0.manifest.id == manifestId },
            isReady: engine.map(canUseEngineForSetupTest) ?? false,
            registryPlugin: registryPlugin,
            installState: registryService.installStates[manifestId],
            fetchState: registryService.fetchState,
            modelIsDownloaded: choice.modelIsDownloaded,
            isOffline: networkStatus.isOffline
        )
        let card = setupCard(isSelected: isSelected) {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(recommended.displayName)
                            .font(.headline)
                        Text(localizedAppText("Recommended", de: "Empfohlen"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.22))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Text(recommendationDescription(for: choice))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                recommendationStatus(for: recommended, availability: availability, isSelected: isSelected)
            }
        }

        if recommendationCardIsInteractive(availability: availability, isSelected: isSelected) {
            // A plain button keeps the card's look but makes it reachable with
            // Tab and pressable with Space and VoiceOver.
            Button {
                Task { await activateRecommendedEngine(choice, registryPlugin: registryPlugin) }
            } label: {
                card
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(recommendationCardAccessibilityHint(for: recommended, availability: availability))
        } else {
            card
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func recommendationDescription(for choice: SetupWizardEngineChoice) -> String {
        let reason: String
        switch choice.reason {
        case .supportsLanguages(let codes):
            reason = String(localized: "Supports \(Self.languageList(codes)).")
        case .detectsLanguages(let count?) where choice.engine == .parakeet:
            reason = String(localized: "Recognizes \(count) European languages. For another language, choose it above.")
        case .detectsLanguages:
            reason = String(localized: "Detects the spoken language automatically.")
        }

        let availability = switch choice.availability {
        case .available:
            String(localized: "Runs offline with no API key.")
        case .needsConnection:
            String(localized: "Connect to the internet to download it.")
        case .notInCatalog, .catalogUnavailable:
            localizedAppText(
                "No compatible download is available for this Mac.",
                de: "Für diesen Mac ist kein kompatibler Download verfügbar."
            )
        }
        return "\(reason) \(availability)"
    }

    private func limitationCard(_ limitation: SetupWizardEngineLimitation) -> some View {
        let title: String
        let message: String
        switch limitation {
        case .noLocalEngine:
            title = String(localized: "No local engine for this Mac")
            message = String(localized: "Parakeet, WhisperKit and Qwen3 need Apple Silicon. Apple Speech needs macOS 26.")
        case .unsupportedLanguages(let codes):
            title = String(localized: "No local engine for \(Self.languageList(codes))")
            message = codes.count == 1
                ? String(localized: "The local engines that run on this Mac don't support this language.")
                : String(localized: "The local engines that run on this Mac don't support all of these languages.")
        }

        return setupCard(isSelected: false) {
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func recommendationStatus(
        for recommended: SetupWizardLocalEngine,
        availability: SetupWizardRecommendationAvailability,
        isSelected: Bool
    ) -> some View {
        if activatingEngine == recommended {
            if case .downloading(let progress) = registryService.installStates[recommended.manifestId] {
                setupProgressIndicator(progress)
            } else if let activationModelProgress {
                setupProgressIndicator(activationModelProgress)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText("Activating", de: "Wird aktiviert", ja: "有効化中", zh: "正在激活", zhHant: "正在啟用"))
            }
        } else {
            switch availability {
            case .ready:
                if isSelected {
                    statusPill(localizedAppText("Selected", de: "Ausgewählt"), systemImage: "checkmark.circle.fill", color: .blue)
                } else {
                    statusPill(localizedAppText("Select", de: "Auswählen"), systemImage: "circle", color: .blue)
                }
            case .setupRequired:
                statusPill(localizedAppText("Activate", de: "Aktivieren"), systemImage: "play.circle.fill", color: .blue)
            case .installState(let installState):
                switch installState {
                case .downloading(let progress):
                    setupProgressIndicator(progress)
                case .extracting:
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(localizedAppText("Installing", de: "Wird installiert", ja: "インストール中", zh: "正在安装", zhHant: "正在安裝"))
                case .restartRequired:
                    statusPill(localizedAppText("Restart", de: "Neustart"), systemImage: "arrow.clockwise.circle.fill", color: .orange)
                case .error:
                    statusPill(localizedAppText("Retry later", de: "Später erneut"), systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
            case .installAvailable:
                statusPill(localizedAppText("Install", de: "Installieren"), systemImage: "arrow.down.circle.fill", color: .blue)
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText("Loading", de: "Wird geladen", ja: "読み込み中", zh: "正在加载", zhHant: "正在載入"))
            case .unavailable(let reason):
                statusPill(reason.title, systemImage: "exclamationmark.triangle.fill", color: .orange)
                    .help(reason.message)
            }
        }
    }

    private func setupProgressIndicator(_ progress: Double) -> some View {
        let progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        let percent = Int(progress * 100)
        return HStack(spacing: 6) {
            ProgressView(value: progress)
                .frame(width: 70)
            Text("\(percent)%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizedAppText("Download progress", de: "Download-Fortschritt", ja: "ダウンロードの進行状況", zh: "下载进度", zhHant: "下載進度"))
        .accessibilityValue(localizedAppText("\(percent) percent", de: "\(percent) Prozent", ja: "\(percent)パーセント", zh: "百分之 \(percent)", zhHant: "百分之 \(percent)", es: "\(percent) por ciento"))
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
    }

    private func recommendationCardIsInteractive(
        availability: SetupWizardRecommendationAvailability,
        isSelected: Bool
    ) -> Bool {
        !isSelected && availability.allowsActivation
    }

    private func recommendationCardAccessibilityHint(
        for recommended: SetupWizardLocalEngine,
        availability: SetupWizardRecommendationAvailability
    ) -> String {
        let name = recommended.displayName
        switch availability {
        case .installAvailable:
            return String(localized: "Installs and selects \(name).")
        case .setupRequired:
            return String(localized: "Activates \(name).")
        default:
            return String(localized: "Selects \(name).")
        }
    }

    /// Installs the recommended engine if needed, selects it and loads its model,
    /// downloading the model when the engine has none yet.
    @MainActor
    private func activateRecommendedEngine(_ choice: SetupWizardEngineChoice, registryPlugin: RegistryPlugin?) async {
        guard activatingEngine == nil else { return }

        let recommended = choice.engine
        let providerId = recommended.providerId
        manuallySelectedSetupProviderId = providerId
        activatingEngine = recommended
        defer {
            activatingEngine = nil
            activationModelProgress = nil
        }

        if pluginManager.transcriptionEngine(for: providerId) == nil {
            if let registryPlugin,
               pluginManager.loadedPlugins.first(where: { $0.manifest.id == registryPlugin.id }) == nil {
                await registryService.downloadAndInstall(registryPlugin)
            }

            if let loaded = pluginManager.loadedPlugins.first(where: { $0.manifest.id == recommended.manifestId }),
               !loaded.isEnabled {
                pluginManager.setPluginEnabled(recommended.manifestId, enabled: true)
            }
        }

        // An engine chosen while the plugin was installing stays selected.
        guard let engine = await waitForTranscriptionEngine(providerId),
              manuallySelectedSetupProviderId == providerId else { return }

        modelManager.selectProvider(engine.providerId)

        // The model chosen in the engine stays unless it lacks the spoken language, which
        // the card promised; Parakeet's English-only models report only English.
        let selectedModelFits = SetupWizardEngineRecommendation.unsupportedLanguages(
            spokenLanguages,
            reportedLanguages: engine.supportedLanguages
        ).isEmpty
        if !engine.isConfigured || !selectedModelFits,
           let modelId = SetupWizardEngineRecommendation.activationModelId(
               selectedModelId: engine.selectedModelId,
               reportedLanguages: engine.supportedLanguages,
               recommendedModelId: Self.modelToLoad(for: choice, from: engine.modelCatalog),
               spokenLanguages: spokenLanguages
           ),
           !modelManager.startModelLoad(modelId, of: engine) {
            engine.selectModel(modelId)
        }

        // Idle polls time out after 2 minutes; an active model download may take up to 30 minutes.
        var idlePolls = 0
        for _ in 0..<3_600 {
            if Task.isCancelled || engine.isConfigured || idlePolls >= 240 { return }
            if manuallySelectedSetupProviderId != providerId { return }
            let activity = (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity
            if activity?.isError == true { return }
            activationModelProgress = activity?.progress
            if activity == nil { idlePolls += 1 }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The recommended model when the installed plugin offers it, otherwise the
    /// plugin's own best match.
    private static func modelToLoad(for choice: SetupWizardEngineChoice, from catalog: [PluginModelInfo]) -> String? {
        if let modelId = choice.modelId, catalog.isEmpty || catalog.contains(where: { $0.id == modelId }) {
            return modelId
        }
        if choice.engine == .parakeet {
            return SetupWizardParakeetRecommendation.preferredModelId(from: catalog)
        }
        return catalog.first?.id
    }

    @MainActor
    private func waitForTranscriptionEngine(_ providerId: String) async -> TranscriptionEnginePlugin? {
        for _ in 0..<40 {
            if Task.isCancelled { return nil }
            if let engine = pluginManager.transcriptionEngine(for: providerId) {
                return engine
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return pluginManager.transcriptionEngine(for: providerId)
    }

    @ViewBuilder
    private func appleSpeechCard(recommendation: SetupWizardEngineRecommendation) -> some View {
        let isSelected = modelManager.selectedProviderId == SetupWizardAppleSpeechFallback.providerId
        let isRecommended = recommendation.choice?.engine == .appleSpeech
        let card = setupCard(isSelected: isSelected) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.badge.mic")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 36)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(String(localized: "Apple Speech"))
                            .font(.headline)
                        Text(isRecommended
                            ? localizedAppText("Recommended", de: "Empfohlen")
                            : localizedAppText("Built-in", de: "Integriert"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(isRecommended ? 0.22 : 0.18))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Text(appleSpeechDescription(for: recommendation))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                appleSpeechStatus
            }
        }

        if canSelectAppleSpeechForSetup {
            Button {
                Task { await activateAppleSpeechForSetup() }
            } label: {
                card
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(localizedAppText("Selects Apple Speech as the local dictation engine.", de: "Wählt Apple Speech als lokale Diktier-Engine aus."))
        } else {
            card
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private func appleSpeechDescription(for recommendation: SetupWizardEngineRecommendation) -> String {
        if isPreparingAppleSpeechFallback {
            return localizedAppText(
                "Preparing the built-in speech engine for the first dictation test.",
                de: "Die integrierte Spracherkennung wird für den ersten Diktat-Test vorbereitet."
            )
        }

        let lightweight = String(localized: "Lightweight built-in option with no large local model.")
        if let appleSpeechEngine, case .specific(let codes) = spokenLanguages {
            let unsupported = SetupWizardEngineRecommendation.unsupportedLanguages(
                spokenLanguages,
                reportedLanguages: appleSpeechEngine.supportedLanguages
            )
            if !unsupported.isEmpty {
                return "\(lightweight) \(String(localized: "Does not support \(Self.languageList(unsupported)) on this Mac."))"
            }
            if recommendation.choice?.engine == .appleSpeech {
                return "\(String(localized: "Supports \(Self.languageList(codes)).")) \(lightweight)"
            }
        }

        // The comparison holds where it was measured (English, German, Russian) and is only
        // shown while Parakeet is the recommendation.
        guard recommendation.choice?.engine == .parakeet else { return lightweight }
        return localizedAppText(
            "Lightweight built-in option with no large local model. Parakeet gives better quality for daily dictation.",
            de: "Leichte integrierte Option ohne großes lokales Modell. Parakeet liefert bessere Qualität fürs tägliche Diktieren."
        )
    }

    @ViewBuilder
    private var appleSpeechStatus: some View {
        if #available(macOS 26, *) {
            if appleSpeechEngine?.isConfigured == true {
                if modelManager.selectedProviderId == SetupWizardAppleSpeechFallback.providerId {
                    statusPill(localizedAppText("Selected", de: "Ausgewählt"), systemImage: "checkmark.circle.fill", color: .blue)
                } else {
                    statusPill(localizedAppText("Select", de: "Auswählen"), systemImage: "circle", color: .blue)
                }
            } else if isPreparingAppleSpeechFallback {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText("Preparing", de: "Wird vorbereitet", ja: "準備中", zh: "正在准备", zhHant: "正在準備"))
            } else if modelManager.selectedProviderId == SetupWizardAppleSpeechFallback.providerId {
                statusPill(localizedAppText("Active", de: "Aktiv"), systemImage: "checkmark.circle.fill", color: .blue)
            } else if let appleSpeechEngine, modelManager.canUseForTranscription(appleSpeechEngine) {
                statusPill(localizedAppText("Select", de: "Auswählen"), systemImage: "circle", color: .blue)
            } else {
                statusPill(localizedAppText("Unavailable", de: "Nicht verfügbar"), systemImage: "circle", color: .secondary)
            }
        } else {
            statusPill(localizedAppText("macOS 26", de: "macOS 26"), systemImage: "circle", color: .secondary)
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
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(String(localized: "Apple Intelligence"))
                            .font(.headline)
                        Text(localizedAppText("Built-in", de: "Integriert"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.18))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }

                    Text(localizedAppText("On-device AI processing. No API key needed.", de: "KI-Verarbeitung auf dem Gerät. Kein API-Key nötig."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if #available(macOS 26, *) {
                    if promptProcessingService.isAppleIntelligenceAvailable {
                        statusPill(localizedAppText("Ready", de: "Bereit"), systemImage: "checkmark.circle.fill", color: .green)
                    } else {
                        statusPill(localizedAppText("Optional", de: "Optional"), systemImage: "circle", color: .secondary)
                    }
                } else {
                    statusPill(localizedAppText("macOS 26", de: "macOS 26"), systemImage: "circle", color: .secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Finish

    private var trialSuccessTitle: String {
        localizedAppText("You're all set!", de: "Alles bereit!")
    }

    private var trialSuccessMessage: String {
        localizedAppText("TypeWhisper is ready to help you work faster.", de: "TypeWhisper ist bereit, damit du schneller arbeiten kannst.")
    }

    private var finishStep: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                hotkeyChip(label: primaryHotkeyLabel)
            }
            .font(.callout)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(localizedAppText("Your hotkey", de: "Dein Hotkey", ja: "現在のショートカットキー", zh: "你的快捷键", zhHant: "你的快速鍵"))
            .accessibilityValue(primaryHotkeyLabel)
            .accessibilityAddTraits(.isStaticText)

            TextEditor(text: $trialText)
                .font(.body)
                .frame(minHeight: 112)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .focused($isTrialFieldFocused)
                .accessibilityLabel(localizedAppText("Try dictation text field", de: "Diktat-Testfeld"))
                .accessibilityHint(localizedAppText("Press your hotkey and dictate. Inserted text appears here.", de: "Drücke deinen Hotkey und diktiere. Eingefügter Text erscheint hier."))

            if trialSuccess {
                setupCard(isSelected: false) {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(trialSuccessTitle)
                                .font(.headline)
                            Text(trialSuccessMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
                .accessibilityElement(children: .combine)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                setupCard(isSelected: false) {
                    HStack(spacing: 14) {
                        Image(systemName: readinessIcon)
                            .font(.title2)
                            .foregroundStyle(readinessColor)
                            .accessibilityHidden(true)

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
                .accessibilityElement(children: .combine)
            }
        }
        .onChange(of: dictation.state) { oldValue, newValue in
            let testedSelection = trialSignal.observe(
                oldState: oldValue,
                newState: newValue,
                selection: selectedSetupModel,
                completedInsertion: dictation.lastSuccessfulDictationInsertion
            )
            if let testedSelection, setupReadiness.canCompleteSetup {
                let wasAlreadySuccessful = trialSuccess
                withAnimation(.spring(duration: 0.35)) {
                    markSetupWizardSelectionTested(testedSelection)
                }
                if !wasAlreadySuccessful {
                    announceTrialSuccess()
                }
            }
        }
        .onChange(of: selectedSetupModel) { _, _ in
            // Never attribute an in-flight test to a different provider/model.
            trialSignal.reset()
            trialAnnouncementTask?.cancel()
        }
        .onDisappear {
            trialSignal.reset()
            trialAnnouncementTask?.cancel()
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            isTrialFieldFocused = true
        }
    }

    /// The success card appears silently below the text field, so VoiceOver
    /// users get the same confirmation spoken. The short delay lets the
    /// dictation flow's own "transcription complete" announcement finish first.
    private func announceTrialSuccess() {
        let message = "\(trialSuccessTitle) \(trialSuccessMessage)"
        trialAnnouncementTask?.cancel()
        // Cancelled when the wizard goes away or the tested model changes meanwhile.
        trialAnnouncementTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            accessibilityAnnouncementService.announce(message)
        }
    }

    private var readinessIcon: String {
        setupReadiness.canCompleteSetup && hasAnyTriggerHotkey ? "sparkles" : "exclamationmark.triangle.fill"
    }

    private var readinessColor: Color {
        setupReadiness.canCompleteSetup && hasAnyTriggerHotkey ? .blue : .orange
    }

    private var readinessTitle: String {
        setupReadiness.canCompleteSetup && hasAnyTriggerHotkey
            ? localizedAppText("Try it out", de: "Probier es aus")
            : localizedAppText("Setup can be finished later", de: "Setup kann später abgeschlossen werden")
    }

    private var readinessDescription: String {
        if dictation.needsMicPermission {
            return String(localized: "Microphone access is required for dictation.")
        }
#if !APPSTORE
        if dictation.needsAccessibilityPermission {
            return AccessibilityPermissionPane.text(
                legacy: String(localized: "Accessibility access is required to paste text into other apps."),
                deviceControl: localizedAppText(
                    "Device Control and Data Access permission is required to paste text into other apps.",
                    de: "Die Berechtigung „Gerätesteuerung und Datenzugriff“ wird benötigt, um Text in andere Apps einzufügen.",
                    ja: "他のアプリへテキストを貼り付けるには、「デバイスの制御とデータへのアクセス」の権限が必要です。",
                    zh: "需要“设备控制和数据访问”权限才能将文本粘贴到其他应用。",
                    zhHant: "需要「裝置控制和資料存取」權限才能將文字貼上到其他應用。"
                )
            )
        }
#endif
        if isPreparingAppleSpeechFallback {
            return localizedAppText(
                "Apple Speech is being prepared for this test.",
                de: "Apple Speech wird gerade für diesen Test vorbereitet."
            )
        }
        if !hasEngineReadyForSetupTest {
            return localizedAppText(
                "Apple Speech or another engine still needs to be enabled before dictation can run.",
                de: "Apple Speech oder eine andere Engine muss noch aktiviert werden, bevor Diktieren funktioniert."
            )
        }
        if !hasAnyTriggerHotkey {
            return localizedAppText("A hotkey still needs to be set before dictation can start.", de: "Ein Hotkey muss noch gesetzt werden, bevor Diktieren starten kann.")
        }
        return localizedAppText("Press your hotkey and say something.", de: "Drücke deinen Hotkey und sag etwas.")
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

    /// A downloaded local engine, other than Apple Speech, that supports the spoken
    /// languages: the first in the recommendation order.
    private var readyLocalProviderId: String? {
        guard let engine = SetupWizardEngineRecommendation.readyEngine(for: engineRecommendationInput),
              engine != .appleSpeech else { return nil }
        return engine.providerId
    }

    /// Apple Speech reports the languages the system offers and loads the model of the
    /// requested one before each transcription. Before it has reported them, it supports
    /// no specific language yet.
    private func appleSpeechSupportsSpokenLanguages(_ engine: TranscriptionEnginePlugin?) -> Bool {
        guard case .specific = spokenLanguages else { return true }
        guard let engine, !engine.supportedLanguages.isEmpty else { return false }
        return SetupWizardEngineRecommendation.unsupportedLanguages(
            spokenLanguages,
            reportedLanguages: engine.supportedLanguages
        ).isEmpty
    }

    private func appleSpeechModelId(from models: [PluginModelInfo]) -> String? {
        SetupWizardAppleSpeechFallback.preferredModelId(from: models, spokenLanguage: spokenLanguages.codes.first)
    }

    private var canUseAppleSpeechFallback: Bool {
        canUseAppleSpeechFallbackEngine(appleSpeechEngine)
    }

    private var canSelectAppleSpeechForSetup: Bool {
        canUseAppleSpeechFallback
    }

    private func canUseEngineForSetupTest(_ engine: TranscriptionEnginePlugin) -> Bool {
        // Issue #1335: a selected or persisted model ID alone is not readiness.
        // canUseForTranscription only checks authentication, so gate the setup
        // test on the engine being configured (loaded) or restorable —
        // installed model assets persisted for lazy restoration, or a provider
        // preparation fallback such as Apple Speech's catalog. The test itself
        // runs the real recording/transcription/insertion path, which is the
        // actual proof of readiness.
        modelManager.canPrepareForTranscription(engine)
    }

#if APPSTORE
    private static let requiresAccessibilityForSetup = false
#else
    private static let requiresAccessibilityForSetup = true
#endif

    private var setupReadiness: SetupWizardReadiness {
        SetupWizardReadiness(
            canPrepareEngine: hasEngineReadyForSetupTest,
            microphoneGranted: !dictation.needsMicPermission,
            // The App Store edition falls back to the clipboard without PostEvent access.
            accessibilityGranted: Self.requiresAccessibilityForSetup ? !dictation.needsAccessibilityPermission : true
        )
    }

    private var selectedSetupModel: SetupWizardTestedSelection? {
        _ = pluginManager.readinessRevision
        guard let engine = selectedTranscriptionEngineForSetup else { return nil }
        return SetupWizardTestedSelection(providerId: engine.providerId, modelId: engine.selectedModelId)
    }

    private var trialSuccess: Bool {
        setupReadiness.hasSuccessfulTest(
            for: selectedSetupModel,
            testedSelections: SetupWizardTestedSelection.decode(testedSelectionsData)
        )
    }

    private func markSetupWizardSelectionTested(_ selection: SetupWizardTestedSelection) {
        var selections = SetupWizardTestedSelection.decode(testedSelectionsData)
        guard !selections.contains(selection) else { return }
        selections.append(selection)
        if let data = try? JSONEncoder().encode(selections) {
            testedSelectionsData = data
        }
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
            if let modelId = appleSpeechModelId(from: appleSpeechEngine.modelCatalog) {
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
        guard activatingEngine == nil else { return }

        if let manuallySelectedSetupProviderId,
           let manuallySelectedEngine = pluginManager.transcriptionEngine(for: manuallySelectedSetupProviderId),
           canUseEngineForSetupTest(manuallySelectedEngine) {
            modelManager.selectProvider(manuallySelectedEngine.providerId)
            return
        }

        let selectedEngineReady = selectedTranscriptionEngineForSetup.map(canUseEngineForSetupTest) ?? false
        let readyLocalProviderId = readyLocalProviderId
        let preferredProviderId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: modelManager.selectedProviderId,
            selectedEngineReady: selectedEngineReady,
            readyLocalProviderId: readyLocalProviderId,
            appleSpeechAvailable: canUseAppleSpeechFallback && appleSpeechSupportsSpokenLanguages(appleSpeechEngine)
        )

        if let readyLocalProviderId,
           preferredProviderId == readyLocalProviderId,
           let readyEngine = pluginManager.transcriptionEngine(for: readyLocalProviderId) {
            modelManager.selectProvider(readyEngine.providerId)
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

        // A spoken language Apple Speech does not support leaves the engine unselected:
        // the step explains it and recommends another engine instead.
        guard let appleSpeechEngine = await waitForAppleSpeechEngine(),
              modelManager.canUseForTranscription(appleSpeechEngine),
              SetupWizardEngineSelection.preferredProviderId(
                selectedProviderId: modelManager.selectedProviderId,
                selectedEngineReady: selectedEngineReady,
                readyLocalProviderId: readyLocalProviderId,
                appleSpeechAvailable: appleSpeechSupportsSpokenLanguages(appleSpeechEngine)
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
            if let modelId = appleSpeechModelId(from: appleSpeechEngine.modelCatalog) {
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
        return localizedAppText("No hotkey", de: "Kein Hotkey")
    }

    private func displayedHotkeyLabel(for mode: HotkeySlotType) -> String {
        let label = hotkeyLabel(for: mode)
        if !label.isEmpty { return label }
        if mode == .hybrid, recommendedHotkeyResolution.shouldApply {
            return HotkeyService.displayName(for: SetupWizardDefaultHotkey.recommendedHybridHotkey)
        }
        return localizedAppText("Not set", de: "Nicht gesetzt")
    }

    private func hotkeyLabel(for mode: HotkeySlotType) -> String {
        switch mode {
        case .hybrid: return dictation.hybridHotkeyLabel
        case .pushToTalk: return dictation.pttHotkeyLabel
        case .toggle: return dictation.toggleHotkeyLabel
        case .promptPalette: return dictation.promptPaletteHotkeyLabel
        case .recentTranscriptions: return dictation.recentTranscriptionsHotkeyLabel
        case .copyLastTranscription: return dictation.copyLastTranscriptionHotkeyLabel
        case .pasteLastTranscription: return dictation.pasteLastTranscriptionHotkeyLabel
        case .recorderToggle: return dictation.recorderToggleHotkeyLabel
        case .undoLastDictation: return dictation.undoLastDictationHotkeyLabel
        case .restoreRawTranscript: return dictation.restoreRawTranscriptHotkeyLabel
        case .correctLastDictation: return dictation.correctLastDictationHotkeyLabel
        }
    }

    private func hotkeyModeTitle(for mode: HotkeySlotType) -> String {
        switch mode {
        case .hybrid: return localizedAppText("Hybrid", de: "Hybrid")
        case .pushToTalk: return localizedAppText("Push-to-Talk", de: "Push-to-Talk")
        case .toggle: return localizedAppText("Toggle", de: "Toggle")
        case .promptPalette: return localizedAppText("Workflow Palette", de: "Workflow-Palette")
        case .recentTranscriptions: return String(localized: "Recent Transcriptions")
        case .copyLastTranscription: return String(localized: "Copy Last Transcription")
        case .pasteLastTranscription: return String(localized: "Paste Last Transcription")
        case .recorderToggle: return String(localized: "settings.tab.recorder")
        case .undoLastDictation: return localizedAppText("Undo Last Dictation", de: "Letztes Diktat rückgängig")
        case .restoreRawTranscript: return localizedAppText("Restore Raw Transcript", de: "Rohtext wiederherstellen")
        case .correctLastDictation: return String(localized: "Correct Last Dictation")
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

// MARK: - Accessibility Helpers

private extension View {
    /// Makes a combined card pressable for VoiceOver (button trait plus default
    /// action) only while `isEnabled`; otherwise it stays a plain element.
    @ViewBuilder
    func setupWizardAccessibilityPress(
        isEnabled: Bool,
        hint: String,
        perform action: @escaping () -> Void
    ) -> some View {
        if isEnabled {
            self
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(hint)
                .accessibilityAction { action() }
        } else {
            self
        }
    }

    /// One hotkey-mode choice: a single element with the selection state as
    /// both trait and spoken value.
    func hotkeyModeAccessibility(label: String, isSelected: Bool, hint: String) -> some View {
        self
            .accessibilityLabel(label)
            .accessibilityValue(isSelected ? localizedAppText("Selected", de: "Ausgewählt") : "")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(hint)
    }
}

// Raw values are persisted and mirrored by `ManagedOnboardingPolicy.Step`.
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
            localizedAppText("Welcome", de: "Willkommen")
        case .permissions:
            localizedAppText("Permissions", de: "Rechte")
        case .hotkey:
            localizedAppText("Hotkey", de: "Hotkey")
        case .engineAI:
            localizedAppText("AI & Engine", de: "KI & Engine")
        case .finish:
            localizedAppText("Finish", de: "Fertig")
        }
    }

    var title: String {
        switch self {
        case .welcome:
            localizedAppText("Welcome to TypeWhisper", de: "Willkommen bei TypeWhisper")
        case .permissions:
            localizedAppText("Permissions", de: "Berechtigungen")
        case .hotkey:
            localizedAppText("Choose Your Hotkey", de: "Wähle deinen Hotkey")
        case .engineAI:
            localizedAppText("AI & Engine", de: "KI & Engine")
        case .finish:
            localizedAppText("Try It Out", de: "Probier es aus")
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            localizedAppText("Set up voice typing in a few simple steps.", de: "Richte Voice Typing in wenigen Schritten ein.")
        case .permissions:
            localizedAppText("TypeWhisper needs access to work on your Mac.", de: "TypeWhisper braucht Zugriff, um auf deinem Mac zu funktionieren.")
        case .hotkey:
            localizedAppText("Start and stop dictation without leaving your app.", de: "Starte und stoppe Diktat, ohne deine App zu verlassen.")
        case .engineAI:
            localizedAppText("Local defaults are ready first; cloud providers can wait.", de: "Lokale Defaults zuerst; Cloud-Provider können warten.")
        case .finish:
            localizedAppText("Press your hotkey and say something.", de: "Drücke deinen Hotkey und sag etwas.")
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
    #if APPSTORE
    // Option-Space is a Carbon hotkey and needs no permission; Fn needs Input
    // Monitoring in the sandbox and cannot suppress the globe-key action.
    static let recommendedHybridHotkey = UnifiedHotkey(
        keyCode: 49,
        modifierFlags: NSEvent.ModifierFlags.option.rawValue,
        isFn: false
    )
    #else
    static let recommendedHybridHotkey = UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true)
    #endif

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

    static func preferredModelId(from models: [PluginModelInfo]) -> String? {
        models.first { $0.id == "parakeet-ultra" }?.id
            ?? models.first { $0.id == "parakeet-tdt-0.6b-v3" }?.id
            ?? models.first { $0.id.localizedCaseInsensitiveContains("v3") }?.id
            ?? models.first?.id
    }
}

enum SetupWizardEngineSelection {
    /// - Parameters:
    ///   - readyLocalProviderId: A downloaded local engine other than Apple Speech that
    ///     supports the spoken languages, as `SetupWizardEngineRecommendation.readyEngine` finds it.
    ///   - appleSpeechAvailable: Apple Speech can be prepared and supports the spoken languages.
    static func preferredProviderId(
        selectedProviderId: String?,
        selectedEngineReady: Bool,
        readyLocalProviderId: String?,
        appleSpeechAvailable: Bool
    ) -> String? {
        if let readyLocalProviderId, selectedProviderId == SetupWizardAppleSpeechFallback.providerId {
            return readyLocalProviderId
        }

        // Kept even when it does not support the spoken language; the step says so.
        if selectedEngineReady {
            return selectedProviderId
        }

        if let readyLocalProviderId {
            return readyLocalProviderId
        }

        if appleSpeechAvailable {
            return SetupWizardAppleSpeechFallback.providerId
        }

        return nil
    }
}

enum SetupWizardAppleSpeechFallback {
    static let providerId = AppleSpeechModelSelection.providerId
    static let manifestId = AppleSpeechModelSelection.manifestId

    /// The model for the spoken language when Apple Speech has one, otherwise the one for
    /// the Mac's locale. The Mac's own locale also wins when it is in the spoken language,
    /// so "de" loads de_CH on a Swiss Mac.
    static func preferredModelId(
        from models: [PluginModelInfo],
        spokenLanguage: String? = nil,
        localeIdentifier: String = Locale.current.identifier,
        languageCode: String? = Locale.current.language.languageCode?.identifier
    ) -> String? {
        if let spokenLanguage, spokenLanguage != languageCode,
           let modelId = AppleSpeechModelSelection.preferredModelId(
               from: models,
               localeIdentifier: spokenLanguage,
               languageCode: spokenLanguage,
               fallbackToFirst: false
           ) {
            return modelId
        }

        return AppleSpeechModelSelection.preferredModelId(
            from: models,
            localeIdentifier: localeIdentifier,
            languageCode: languageCode
        )
    }
}

// MARK: - Recommendation Availability

enum SetupWizardRecommendationUnavailableReason: Equatable {
    case appleSiliconOnly
    case marketplaceUnavailable
    case offline

    var title: String {
        switch self {
        case .appleSiliconOnly:
            localizedAppText("Apple Silicon only", de: "Nur Apple Silicon")
        case .marketplaceUnavailable:
            localizedAppText("Unavailable", de: "Nicht verfügbar")
        case .offline:
            String(localized: "Offline")
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
        case .offline:
            String(localized: "Connect to the internet to download it.")
        }
    }
}

struct SetupWizardTestedSelection: Codable, Equatable {
    let providerId: String
    let modelId: String?

    static func decode(_ data: Data) -> [Self] {
        (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
}

struct SetupWizardReadiness {
    let canPrepareEngine: Bool
    let microphoneGranted: Bool
    let accessibilityGranted: Bool

    var canCompleteSetup: Bool {
        canPrepareEngine && microphoneGranted && accessibilityGranted
    }

    func hasSuccessfulTest(
        for selection: SetupWizardTestedSelection?,
        testedSelections: [SetupWizardTestedSelection]
    ) -> Bool {
        guard canCompleteSetup, let selection else { return false }
        return testedSelections.contains(selection)
    }
}

/// Issue #1335: decides whether a dictation state transition counts as a
/// successful setup-wizard dictation test.
///
/// Indicator feedback, including processing cancellation, can use the same
/// state transitions as successful dictation. A completed cycle therefore also
/// requires a new explicit insertion result for the selection being tested.
struct SetupWizardTrialSignal {
    private var recordingSelection: SetupWizardTestedSelection?
    private var insertionIDAtRecordingStart: UUID?
    private var enteredInsertingFromProcessing = false

    mutating func reset() {
        recordingSelection = nil
        insertionIDAtRecordingStart = nil
        enteredInsertingFromProcessing = false
    }

    mutating func observe(
        oldState: DictationViewModel.State,
        newState: DictationViewModel.State,
        selection: SetupWizardTestedSelection?,
        completedInsertion: DictationInsertionCompletion? = nil
    ) -> SetupWizardTestedSelection? {
        if newState == .recording {
            reset()
            recordingSelection = selection
            insertionIDAtRecordingStart = completedInsertion?.id
        } else if selection != recordingSelection {
            reset()
        }
        let evaluation = Self.evaluate(
            oldState: oldState,
            newState: newState,
            enteredInsertingFromProcessing: enteredInsertingFromProcessing
        )
        enteredInsertingFromProcessing = evaluation.enteredInsertingFromProcessing
        let completedSelection: SetupWizardTestedSelection?
        if evaluation.granted,
           let recordingSelection,
           let completedInsertion,
           completedInsertion.id != insertionIDAtRecordingStart,
           completedInsertion.providerId == recordingSelection.providerId,
           completedInsertion.modelId == recordingSelection.modelId {
            completedSelection = recordingSelection
        } else {
            completedSelection = nil
        }
        switch newState {
        case .idle, .error:
            reset()
        default:
            break
        }
        return completedSelection
    }

    /// Identifies a potential completed cycle. `observe` must additionally
    /// verify an explicit insertion result before granting the tested state.
    static func evaluate(
        oldState: DictationViewModel.State,
        newState: DictationViewModel.State,
        enteredInsertingFromProcessing: Bool
    ) -> (granted: Bool, enteredInsertingFromProcessing: Bool) {
        if oldState == .inserting, newState == .inserting {
            // Re-entrant set inside the real insertion path (e.g. the
            // post-processing fallback toast): keep the flag, grant nothing yet.
            return (false, enteredInsertingFromProcessing)
        }
        if oldState == .processing, newState == .inserting {
            return (false, true)
        }
        guard oldState == .inserting else {
            return (false, enteredInsertingFromProcessing)
        }
        // Leaving .inserting: the flag has served its purpose — reset it, and
        // grant only when a transcription actually ran beforehand.
        return (newState == .idle && enteredInsertingFromProcessing, false)
    }
}

enum SetupWizardRecommendationAvailability: Equatable {
    case ready
    case setupRequired
    case installState(PluginRegistryService.InstallState)
    case installAvailable
    case loading
    case unavailable(SetupWizardRecommendationUnavailableReason)

    /// Pressing the card selects, activates or installs the engine.
    var allowsActivation: Bool {
        switch self {
        case .ready, .setupRequired, .installAvailable:
            true
        case .installState, .loading, .unavailable:
            false
        }
    }

    /// - Parameter modelIsDownloaded: The model that activating the installed engine
    ///   loads is on disk, so activating it needs no connection.
    static func resolve(
        manifestId: String,
        isInstalled: Bool,
        isReady: Bool,
        registryPlugin: RegistryPlugin?,
        installState: PluginRegistryService.InstallState?,
        fetchState: PluginRegistryService.FetchState,
        modelIsDownloaded: Bool = false,
        isOffline: Bool = false,
        architecture: String = RuntimeArchitecture.current
    ) -> SetupWizardRecommendationAvailability {
        if manifestId == SetupWizardParakeetRecommendation.manifestId, architecture != "arm64" {
            return .unavailable(.appleSiliconOnly)
        }

        if isReady {
            return .ready
        }

        // Everything below needs a download of the plugin or its model, except loading
        // a model that is already on disk into an installed engine.
        if isOffline, !(isInstalled && modelIsDownloaded) {
            return .unavailable(.offline)
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
