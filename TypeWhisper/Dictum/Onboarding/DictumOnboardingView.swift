import SwiftUI
import AVFoundation
import ApplicationServices
import TypeWhisperPluginSDK

struct DictumOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var recorder = ServiceContainer.shared.audioRecordingService
    @ObservedObject private var models = ServiceContainer.shared.modelManagerService
    @ObservedObject private var devices = ServiceContainer.shared.audioDeviceService
    @State private var step = Self.initialStep
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var accessibility = AXIsProcessTrusted()
    @State private var fnAction = Self.fnUsage
    @State private var heardSeconds = 0.0
    @State private var meterStarted: Date?
    @State private var meterOwned = false
    @State private var meterTask: Task<Void, Never>?
    @State private var meterCleanup: Task<Void, Never>?
    @State private var progress: Double?
    @State private var modelSize = ""
    @State private var downloadDetail = ""
    @State private var failure: String?
    @State private var practiceText = ""
    @State private var completedPractice = false
    @ObservedObject private var languages = TranslationLanguageStore.shared
    @FocusState private var practiceFocused: Bool

    private static var initialStep: Int {
#if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--dictum-onboarding-step"),
           CommandLine.arguments.indices.contains(index + 1),
           let step = Int(CommandLine.arguments[index + 1]), (0...6).contains(step) { return step }
#endif
        return UserDefaults.standard.bool(forKey: "dictumPracticeRequested") ? 4 : 0
    }

    static var fnUsage: Int {
        (UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? NSNumber)?.intValue ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<7) { index in Capsule().fill(index == step ? DictumTheme.accent : DictumTheme.textTertiary.opacity(0.4)).frame(width: index == step ? 18 : 6, height: 6) }
            }.frame(height: 40)
            VStack(spacing: 16) { content }
                .padding(.horizontal, 64).padding(.top, 20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .id(step).transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 14)))
            HStack {
                if (1..<6).contains(step) { Button { step -= 1 } label: { text("Back") }.buttonStyle(.plain) }
                Spacer()
                if step == 4 || step == 5 { Button { step += 1 } label: { text("Skip") }.buttonStyle(.plain) }
                Button {
                    if step == 6 {
                        HomeViewModel.shared.completeSetupWizard()
                        dismiss()
                        DictumNavigation.shared.open(.home)
                    } else { step += 1 }
                } label: { text(step == 0 ? "Get Started" : step == 6 ? "Start Using dictum" : "Continue") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canContinue)
            }.padding(.horizontal, 24).frame(height: 72)
        }.frame(width: 640, height: 540).background(DictumTheme.windowBackground)
            .background(OnboardingWindowPolicy(finished: step == 6))
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.35), value: step)
            .task { if step == 0 || step == 3 { await prepareModel() } }
            .task(id: "\(step)-\(devices.selectedDeviceUID ?? "")") {
                if step == 2 { startMeter() }
            }
            .onChange(of: step) { old, new in
                if old == 2 { stopMeter() }
                if new == 4 || new == 5 {
                    practiceText = ""
                    completedPractice = false
                }
            }
            .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
                microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                accessibility = AXIsProcessTrusted()
                fnAction = Self.fnUsage
                if step == 2 && recorder.rawAudioLevel > 0.01 { heardSeconds += 0.1 }
                if (step == 4 || step == 5), dictation.state == .inserting,
                   dictation.sessionMode == (step == 5 ? .translation : .dictation),
                   !practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completedPractice = true }
            }
            .onAppear {
                if UserDefaults.standard.bool(forKey: "dictumPracticeRequested") {
                    UserDefaults.standard.removeObject(forKey: "dictumPracticeRequested")
                }
                if !SetupWizardDefaultHotkey.triggerSlots.contains(where: { !dictation.hotkeys(for: $0).isEmpty }) {
                    dictation.setHotkey(SetupWizardDefaultHotkey.recommendedHybridHotkey, for: .hybrid)
                }
            }
            .onDisappear { stopMeter() }
    }

    private var canContinue: Bool {
        switch step {
        case 1: microphone && accessibility && fnAction == 0
        case 2: heardSeconds >= 1.2
        case 3: models.isModelReady
        case 4, 5: completedPractice
        default: true
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 96, height: 96).padding(.top, 34)
            title("Talk, and it's typed")
            text("Press fn in any text field, talk, then press fn again. dictum cleans up filler words, organizes paragraphs, and puts the text at your cursor.").font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            shortcuts
        case 1:
            title("Turn on access")
            text("Audio and text are only processed when you press the shortcut.").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                permission("Microphone", subtitle: "To hear you", actionTitle: "Allow", icon: "mic", granted: microphone) { Task { microphone = await AVCaptureDevice.requestAccess(for: .audio) } }
                Divider()
                permission("Accessibility", subtitle: "To type into other apps and detect the fn key", actionTitle: "Open System Settings", icon: "hand.raised", granted: accessibility) { openPreferences("com.apple.preference.security?Privacy_Accessibility") }
                if fnAction != 0 {
                    Divider()
                    permission("fn key", subtitle: "Change the system fn action to Do Nothing.", actionTitle: "Open Keyboard Settings", icon: "keyboard", granted: false) { openPreferences("com.apple.Keyboard-Settings.extension") }
                }
            }.background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 10)).padding(.top, 10)
        case 2:
            title("Say something")
            text("For example: Nice weather today.").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(0..<32) { _ in Capsule().fill(DictumTheme.accent).frame(width: 7, height: CGFloat(6 + recorder.audioLevel * 80)) }
            }.frame(height: 90).padding(.top, 24)
            text(heardSeconds >= 1.2 ? "Sounds great" : meterStarted.map { Date().timeIntervalSince($0) > 8 } == true ? "No sound yet. Try another microphone." : "Listening for sound…")
                .foregroundStyle(heardSeconds >= 1.2 ? DictumTheme.success : DictumTheme.textSecondary)
            Picker(selection: $devices.selectedDeviceUID) {
                ForEach(devices.inputDevices) { device in Text(verbatim: device.name).tag(Optional(device.uid)) }
            } label: { text("Microphone") }.frame(maxWidth: 280)
            if let failure { Text(verbatim: failure).foregroundStyle(DictumTheme.danger) }
        case 3:
            title("Getting the speech model ready")
            text("Qwen3-ASR recognizes Chinese and English on this Mac, no internet needed.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                Label("Qwen3-ASR 1.7B", systemImage: "waveform")
                if !modelSize.isEmpty { Text(verbatim: modelSize).font(.caption).foregroundStyle(.secondary) }
                if models.isModelReady { text("Ready").foregroundStyle(DictumTheme.success) }
                else { ProgressView(value: progress); if let progress { Text(progress, format: .percent.precision(.fractionLength(0))) } }
                if !models.isModelReady, !downloadDetail.isEmpty { Text(verbatim: downloadDetail).font(.caption).foregroundStyle(.secondary) }
                if let failure {
                    Text(verbatim: failure).foregroundStyle(DictumTheme.danger)
                    Button { Task { await prepareModel() } } label: { text("Retry") }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12)).padding(.top, 14)
            Button { DictumNavigation.shared.open(.speech) } label: { text("Use cloud recognition instead") }.buttonStyle(.plain).foregroundStyle(DictumTheme.accent)
        case 4, 5:
            title(step == 4 ? "Practice dictation" : "Practice translation")
            if step == 4 {
                text("Press fn, read the text below, then press fn again.").foregroundStyle(.secondary)
                text("Um, let's meet Friday, no, Thursday afternoon, to discuss the budget, hiring, and next quarter's plans.")
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DictumTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            } else {
                translationPractice
            }
            TextEditor(text: $practiceText).font(.system(size: 14)).frame(height: 118).overlay(RoundedRectangle(cornerRadius: 10).stroke(DictumTheme.separator))
                .focused($practiceFocused).onAppear { practiceFocused = true }
                .accessibilityLabel(step == 4 ? text("Your text appears here") : Text("The translation appears here", tableName: "DictumTranslation"))
            if completedPractice {
                Label {
                    if step == 4 { text("Fillers and corrections handled") }
                    else { Text("Click the language on the voice bar to switch targets", tableName: "DictumTranslation") }
                } icon: { Image(systemName: "checkmark.circle.fill") }.foregroundStyle(DictumTheme.success)
            }
        default:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 72)).foregroundStyle(DictumTheme.success).padding(.top, 34)
            title("You're all set")
            shortcuts
        }
    }

    @ViewBuilder private var translationPractice: some View {
        let settings = languages.settings
        let practice = TranslationPractice.sentence(for: settings.isAutomatic ? nil : settings.spokenLanguage)
        if let pair = settings.pair {
            let spokenName = pair.spoken.map { TranslationLanguageNames.shortName(for: $0) }
            if let spokenName {
                Text("Press fn + Left ⇧, say this in \(spokenName), then press fn.", tableName: "DictumTranslation").foregroundStyle(.secondary)
            } else {
                Text("Press fn + Left ⇧, say this, then press fn.", tableName: "DictumTranslation").foregroundStyle(.secondary)
            }
            if practice.isFallback, let spokenName {
                Text("There is no sample sentence in \(spokenName) yet. Read this one, or say anything in \(spokenName).", tableName: "DictumTranslation")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "\(spokenName ?? String(localized: "Auto", table: "DictumTranslation")) → \(TranslationLanguageNames.name(for: pair.target))")
                    .font(.system(size: 11)).foregroundStyle(DictumTheme.translate)
                Text(verbatim: practice.text)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DictumTheme.translateSoft, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 16) {
            VStack(spacing: 8) { keycap("fn"); text("Dictate").font(.system(size: 12)).foregroundStyle(.secondary) }
            VStack(spacing: 8) {
                HStack(spacing: 4) { keycap("fn"); keycap("⇧") }
                text("Translate").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) { keycap("esc"); text("Cancel").font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(.top, 18)
    }
    private func keycap(_ key: String) -> some View {
        Text(verbatim: key).font(.system(size: 15)).frame(width: 44, height: 42)
            .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DictumTheme.separator, lineWidth: 0.5))
    }
    private func text(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "DictumHome") }
    private func title(_ key: LocalizedStringKey) -> some View { text(key).font(.system(size: 24, weight: .bold)).padding(.top, 18) }
    private func permission(_ key: LocalizedStringKey, subtitle: LocalizedStringKey, actionTitle: LocalizedStringKey, icon: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 32, height: 32).background(DictumTheme.inset, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                text(key)
                text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if granted { Label { text("On") } icon: { Image(systemName: "checkmark") }.foregroundStyle(DictumTheme.success) }
            else { Button(action: action) { text(actionTitle) } }
        }.padding(14).frame(minHeight: 60)
    }
    private func openPreferences(_ pane: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!) }
    private func stopMeter() {
        guard meterTask != nil || meterOwned else { return }
        let pendingStart = meterTask
        pendingStart?.cancel()
        recorder.cancelPendingRecordingStart()
        meterTask = nil
        let previousCleanup = meterCleanup
        meterCleanup = Task {
            await previousCleanup?.value
            await pendingStart?.value
            if meterOwned {
                meterOwned = false
                _ = await recorder.stopRecording(policy: .immediate)
                recorder.discardActiveRecoveryRecording()
            }
        }
    }

    private func startMeter() {
        stopMeter()
        let cleanup = meterCleanup
        meterTask = Task {
            await cleanup?.value
            guard !Task.isCancelled, step == 2 else { return }
            do {
                try await recorder.startRecordingAsync()
                meterOwned = true
                meterStarted = Date()
                heardSeconds = 0
                failure = nil
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
    }
    private func prepareModel() async {
        failure = nil
        guard let plugins = PluginManager.shared else { return }
        if let loaded = plugins.loadedPlugins.first(where: { $0.manifest.id == SetupWizardQwen3Recommendation.manifestId }), !loaded.isEnabled {
            plugins.setPluginEnabled(SetupWizardQwen3Recommendation.manifestId, enabled: true)
        }
        guard let engine = plugins.transcriptionEngine(for: SetupWizardQwen3Recommendation.providerId) else { return }
        let modelID = engine.selectedModelId ?? SetupWizardQwen3Recommendation.preferredModelId(from: engine.modelCatalog)
        modelSize = engine.modelCatalog.first(where: { $0.id == modelID })?.sizeDescription ?? ""
        models.selectProvider(engine.providerId)
        do {
            try await SetupWizardQwen3Recommendation.activate(engine) {
                progress = $0
                downloadDetail = (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity?.message ?? ""
            }
        }
        catch { failure = error.localizedDescription }
    }
}

private struct OnboardingWindowPolicy: NSViewRepresentable {
    let finished: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.finished = finished
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.delegate !== context.coordinator {
                context.coordinator.previousDelegate = window.delegate
                window.delegate = context.coordinator
            }
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = finished
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.setContentSize(NSSize(width: 640, height: 540))
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var finished = false
        weak var previousDelegate: (any NSWindowDelegate)?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !finished else { return previousDelegate?.windowShouldClose?(sender) ?? true }
            let alert = NSAlert()
            alert.messageText = String(localized: "Set up later?", table: "DictumHome")
            alert.addButton(withTitle: String(localized: "Continue", table: "DictumHome"))
            alert.addButton(withTitle: String(localized: "Later", table: "DictumHome"))
            alert.beginSheetModal(for: sender) { response in
                guard response == .alertSecondButtonReturn else { return }
                HomeViewModel.shared.deferSetupWizard()
                sender.close()
            }
            return false
        }
        func windowWillClose(_ notification: Notification) { previousDelegate?.windowWillClose?(notification) }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            previousDelegate?.responds(to: selector) == true ? previousDelegate : super.forwardingTarget(for: selector)
        }
    }
}
