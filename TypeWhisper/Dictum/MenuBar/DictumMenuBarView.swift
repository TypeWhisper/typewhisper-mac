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
        if let progress = glyph.status.downloadProgress {
            MenuBarProgressRing(progress: progress)
        } else {
            Image(nsImage: glyph.currentImage)
                .resizable().frame(width: 18, height: 18)
        }
    }
}

@MainActor
enum MenuBarGlyphImages {
    /// 润色脉冲的一个明或暗半周期；明暗各一次为 1 秒。
    static let pulseInterval: TimeInterval = 0.5
    static let dimmedOpacity: CGFloat = 0.35

    static func image(appearance: MenuBarGlyphModel.Appearance, pulseOn: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            NSImage(named: "MenuBarGlyph")?.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: pulseOn ? dimmedOpacity : 1
            )
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

    /// 润色脉冲通过整图预渲染的明暗两态交替呈现，避免在状态项上逐帧重绘。
    static func cachedImage(for appearance: MenuBarGlyphModel.Appearance, isPulseOn: Bool = false) -> NSImage {
        switch appearance {
        case .idle: idleImage
        case .recording: recordingImage
        case .polishing: isPulseOn ? polishingDimmedImage : polishingImage
        case .attention: attentionImage
        case .downloading: idleImage
        }
    }

    private static let idleImage = image(appearance: .idle)
    private static let recordingImage = image(appearance: .recording)
    private static let polishingImage = image(appearance: .polishing, pulseOn: false)
    private static let polishingDimmedImage = image(appearance: .polishing, pulseOn: true)
    private static let attentionImage = image(appearance: .attention)
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
    let progress: Double

    var body: some View {
        Circle().trim(from: 0, to: progress).stroke(lineWidth: 2)
            .rotationEffect(.degrees(-90))
            .frame(width: 16, height: 16)
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
    /// 润色期间明暗交替；每半个周期只发布这一个布尔值。
    @Published private(set) var pulseOn = false
    private var cancellable: AnyCancellable?
    private var pulse: AnyCancellable?
    private let pulseInterval: TimeInterval

    init(
        dictation: DictationViewModel = .shared,
        models: ModelManagerService = ServiceContainer.shared.modelManagerService,
        recorder: AudioRecorderViewModel = .shared,
        downloadProgressProvider: @escaping () -> Double? = { nil },
        accessibilityChecker: @escaping () -> Bool = { AXIsProcessTrusted() },
        isModelReady: (() -> Bool)? = nil,
        pulseInterval: TimeInterval = MenuBarGlyphImages.pulseInterval,
        accessibilityRefreshInterval: TimeInterval = 5
    ) {
        let isModelReady = isModelReady ?? { models.isModelReady }
        self.pulseInterval = pulseInterval
        status = Self.resolve(
            dictationState: dictation.state,
            isModelReady: isModelReady(),
            accessibility: accessibilityChecker(),
            downloadProgress: downloadProgressProvider()
        )
        // 辅助功能授权没有变化通知，慢速定时器重新读取一次。
        let accessibilityTick = Timer.publish(every: accessibilityRefreshInterval, on: .main, in: .common)
            .autoconnect().map { _ in }
        let trigger = models.objectWillChange.map { _ in }.merge(with: accessibilityTick).prepend(())
        cancellable = Publishers.CombineLatest3(dictation.$state, recorder.$state, trigger)
            // objectWillChange 在属性变化之前触发，先延后到下一轮主线程再读取模型状态。
            .receive(on: DispatchQueue.main)
            .map { [downloadProgressProvider] state, recorderState, _ in
                Self.resolve(
                    dictationState: state == .recording || recorderState == .recording ? .recording : state,
                    isModelReady: isModelReady(),
                    accessibility: accessibilityChecker(),
                    downloadProgress: downloadProgressProvider()
                )
            }
            .removeDuplicates()
            .sink { [weak self] resolved in
                self?.apply(resolved)
            }
        updatePulse()
    }

    var appearance: Appearance { status.appearance }

    var currentImage: NSImage {
        MenuBarGlyphImages.cachedImage(for: status.appearance, isPulseOn: pulseOn)
    }

    private func apply(_ resolved: Status) {
        status = resolved
        updatePulse()
    }

    private func updatePulse() {
        if status.appearance == .polishing {
            guard pulse == nil else { return }
            pulse = Timer.publish(every: pulseInterval, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.pulseOn.toggle() }
        } else {
            pulse = nil
            if pulseOn { pulseOn = false }
        }
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
