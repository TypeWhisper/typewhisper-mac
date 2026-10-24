import ApplicationServices
import Combine
import SwiftUI
import TypeWhisperPluginSDK

@MainActor
enum MenuBarActionDispatcher {
    static func performAfterMenuDismissal(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.default]) { Task { @MainActor in action() } }
    }
}

@MainActor
private final class MenuBarDictationSession {
    static let shared = MenuBarDictationSession()
    private var observation: AnyCancellable?
    private var previousTranslation: Bool?

    func start(translation: Bool) {
        let dictation = DictationViewModel.shared
        guard dictation.canDictate, dictation.canStartAPIRecording else { return }
        let settings = SettingsViewModel.shared
        previousTranslation = settings.translationEnabled
        settings.translationEnabled = translation
        observation = dictation.$state.dropFirst().sink { [weak self] state in
            guard state == .idle, let self, let previous = self.previousTranslation else { return }
            settings.translationEnabled = previous
            self.previousTranslation = nil
            self.observation = nil
        }
        _ = dictation.apiStartRecording()
    }
}

struct DictumMenuBarView: View {
    @AppStorage("dictum.polishLevel") private var polishLevel = "standard"
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var models = ServiceContainer.shared.modelManagerService
    @ObservedObject private var history = ServiceContainer.shared.historyService
    @ObservedObject private var recent = ServiceContainer.shared.recentTranscriptionStore
    @ObservedObject private var settings = SettingsViewModel.shared

    var body: some View {
        Group {
            Label {
                if !AXIsProcessTrusted() { text("Accessibility access needed") }
                else if dictation.state == .recording { text("Dictating") + Text(verbatim: " · \(Int(dictation.recordingDuration) / 60):\(String(format: "%02d", Int(dictation.recordingDuration) % 60))") }
                else { Text(SidebarStatus.current().titleKey, tableName: "DictumShell") + Text(verbatim: statusDetail.isEmpty ? "" : " · \(statusDetail)") }
            } icon: { Image(systemName: "circle.fill").font(.system(size: 7)) }.disabled(true)
            if !AXIsProcessTrusted() {
                Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } label: { text("Open System Settings") }
                Divider()
            }
            if dictation.state == .recording {
                Button { _ = dictation.apiStopRecording() } label: { text("Finish Dictation") }
                Button { dictation.cancelFromVoiceBar() } label: { text("Cancel") }
            } else {
                Button { start(translation: false) } label: { text("Start Dictation") }.disabled(!dictation.canDictate || !dictation.canStartAPIRecording)
                Button { start(translation: true) } label: { text("Start Translation") }.disabled(!dictation.canDictate || !dictation.canStartAPIRecording)
            }
            Divider()
            Menu {
                ForEach(VoiceBarLanguages.options) { language in
                    Toggle(language.name, isOn: Binding(get: { settings.translationTargetLanguage == language.code }, set: { if $0 { settings.translationTargetLanguage = language.code } }))
                }
            } label: { text("Translate To") }
            Menu {
                Toggle(isOn: polishBinding("light")) { text("Light") }
                Toggle(isOn: polishBinding("standard")) { text("Standard") }
                Toggle(isOn: polishBinding("rewrite")) { text("Rewrite") }
            } label: { text("Polish Strength") }
            Divider()
            if let record = recent.latestEntry(historyRecords: history.recentRecords) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.finalText, forType: .string)
                } label: {
                    VStack(alignment: .leading) {
                        text("Copy Last Dictation") + Text(verbatim: " · \(record.timestamp.formatted(date: .omitted, time: .shortened))")
                        Text(verbatim: String(record.finalText.prefix(64))).lineLimit(1)
                    }
                }
                Divider()
            }
            Button { DictumNavigation.shared.open(.home) } label: { text("Open dictum") }.keyboardShortcut("o")
            Button {
                if NSEvent.modifierFlags.contains(.option) { ManagedAppWindowOpener.shared.open(id: "settings") }
                else { DictumNavigation.shared.open(.general) }
            } label: { text(NSEvent.modifierFlags.contains(.option) ? "Advanced Settings…" : "Settings…") }.keyboardShortcut(",")
            Divider()
            Button { NSApplication.shared.terminate(nil) } label: { text("Quit dictum") }.keyboardShortcut("q")
        }
        .onAppear { ManagedAppWindowOpener.shared.openWindow = openWindow }
    }

    private func text(_ key: LocalizedStringKey) -> Text { Text(key, tableName: "DictumHome") }
    private func polishBinding(_ level: String) -> Binding<Bool> {
        Binding(get: { polishLevel == level }, set: { if $0 { polishLevel = level } })
    }
    private var statusDetail: String {
        switch SidebarStatus.current() {
        case .downloading(let progress):
            return progress.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        default:
            return models.activeModelName ?? ""
        }
    }
    private func start(translation: Bool) {
        MenuBarActionDispatcher.performAfterMenuDismissal {
            MenuBarDictationSession.shared.start(translation: translation)
        }
    }
}

struct DictumMenuBarGlyph: View {
    @StateObject private var glyph = MenuBarGlyphModel(
        downloadProgressProvider: MenuBarGlyphModel.downloadProgress
    )

    var body: some View {
        if glyph.status.downloadProgress != nil {
            let progress = glyph.status.downloadProgress
            MenuBarProgressRing(progress: progress)
        } else {
            Image(nsImage: MenuBarGlyphImages.cachedImage(for: glyph.appearance))
                .resizable().frame(width: 18, height: 18)
        }
    }
}

@MainActor
enum MenuBarGlyphImages {
    static let pulseInterval: TimeInterval = 0.25

    static func image(appearance: MenuBarGlyphModel.Appearance, pulseOn: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            NSImage(named: "MenuBarGlyph")?.draw(in: rect)
            if pulseOn {
                NSColor.white.withAlphaComponent(0.35).setFill()
                rect.fill(using: .sourceAtop)
            }
            var dotColor: NSColor?
            switch appearance {
            case .recording: dotColor = NSColor(DictumTheme.live)
            case .attention: dotColor = NSColor(DictumTheme.warning)
            case .idle, .polishing, .downloading: break
            }
            if let dotColor {
                dotColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 13, width: 6, height: 6)).fill()
            }
            return true
        }
        // 录音和警示态带彩色圆点，其余状态保持模板渲染跟随菜单栏配色。
        image.isTemplate = appearance != .recording && appearance != .attention
        return image
    }

    static func cachedImage(for appearance: MenuBarGlyphModel.Appearance) -> NSImage {
        switch appearance {
        case .idle: idleImage
        case .recording: recordingImage
        case .polishing: polishingOffImage
        case .attention: attentionImage
        case .downloading: idleImage
        }
    }

    private static let idleImage = image(appearance: .idle)
    private static let recordingImage = image(appearance: .recording)
    private static let polishingOffImage = image(appearance: .polishing, pulseOn: false)
    private static let polishingOnImage = image(appearance: .polishing, pulseOn: true)
    private static let attentionImage = image(appearance: .attention)

    /// 润色脉冲通过整图预渲染的明暗两态交替呈现，避免在状态项上逐帧重绘。
    static func polishingImage(isPulseOn: Bool) -> NSImage {
        isPulseOn ? polishingOnImage : polishingOffImage
    }
}

extension MenuBarGlyphModel {
    /// 下载进度只在下载状态变化时读取一次；插件活动不进入图标重绘路径。
    static var downloadProgress: () -> Double? {
        {
            guard let providerId = ServiceContainer.shared.modelManagerService.selectedProviderId,
                  let engine = PluginManager.shared?.transcriptionEngine(for: providerId),
                  let activity = (engine as? any PluginSettingsActivityReporting)?.currentSettingsActivity,
                  !activity.isError else { return nil }
            return activity.progress
        }
    }
}

private struct MenuBarProgressRing: View {
    let progress: Double?

    var body: some View {
        ZStack {
            if let progress {
                Circle().trim(from: 0, to: progress).stroke(lineWidth: 2)
                    .rotationEffect(.degrees(-90))
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .frame(width: 16, height: 16)
        // 下载进度只跟随窄模型的去重更新，不再按录音电平重绘。
        .accessibilityHidden(true)
    }
}

/// 只把去重后的状态变化送进菜单栏图标；录音电平和下载进度细节不进入图标重绘。
@MainActor
final class MenuBarGlyphModel: ObservableObject {
    enum Appearance: Equatable {
        case idle
        case recording
        case polishing
        case attention
        case downloading
    }

    struct Status: Equatable {
        var appearance: Appearance
        var downloadProgress: Double?
    }

    @Published private(set) var status: Status
    private var cancellable: AnyCancellable?
    private var pulseTimer: Timer?
    private var pulseOn = false
    private let accessibilityChecker: () -> Bool

    init(
        dictation: DictationViewModel = .shared,
        models: ModelManagerService = ServiceContainer.shared.modelManagerService,
        recorder: AudioRecorderViewModel = .shared,
        downloadProgressProvider: @escaping () -> Double? = { nil },
        accessibilityChecker: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.accessibilityChecker = accessibilityChecker
        status = Self.resolve(
            dictationState: dictation.state,
            isModelReady: models.isModelReady,
            accessibility: accessibilityChecker(),
            downloadProgress: downloadProgressProvider()
        )
        cancellable = Publishers.CombineLatest3(dictation.$state, recorder.$state, models.objectWillChange)
            .map { [accessibilityChecker, downloadProgressProvider, models] state, recorderState, _ in
                Self.resolve(
                    dictationState: state == .recording || recorderState == .recording ? .recording : state,
                    isModelReady: models.isModelReady,
                    accessibility: accessibilityChecker(),
                    downloadProgress: downloadProgressProvider()
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resolved in
                self?.apply(resolved)
            }
    }

    var appearance: Appearance { status.appearance }

    private func apply(_ resolved: Status) {
        let pulseChanged = resolved.appearance != status.appearance
        status = resolved
        if pulseChanged {
            if resolved.appearance == .polishing {
                startPulse()
            } else {
                stopPulse()
            }
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: MenuBarGlyphImages.pulseInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pulseOn.toggle()
                self.status = Status(appearance: .polishing, downloadProgress: self.status.downloadProgress)
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseOn = false
    }

    static func resolve(
        dictationState: DictationViewModel.State,
        isModelReady: Bool,
        accessibility: Bool,
        downloadProgress: Double?
    ) -> Status {
        if !accessibility || !isModelReady {
            return Status(appearance: .attention, downloadProgress: downloadProgress)
        }
        switch dictationState {
        case .recording: return Status(appearance: .recording, downloadProgress: nil)
        case .processing: return Status(appearance: .polishing, downloadProgress: nil)
        default: return Status(appearance: .idle, downloadProgress: downloadProgress)
        }
    }
}
