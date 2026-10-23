import SwiftUI
import ApplicationServices
import Combine

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
                else { Text(SidebarStatus.current().titleKey, tableName: "DictumShell") + Text(verbatim: " · \(models.activeModelName ?? "")") }
            } icon: { Image(systemName: "circle.fill") }.disabled(true)
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
                Picker(selection: $polishLevel) {
                    Text("Light", tableName: "DictumHome").tag("light")
                    Text("Standard", tableName: "DictumHome").tag("standard")
                    Text("Rewrite", tableName: "DictumHome").tag("rewrite")
                } label: { text("Polish Strength") }
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
    private func start(translation: Bool) {
        MenuBarActionDispatcher.performAfterMenuDismissal {
            MenuBarDictationSession.shared.start(translation: translation)
        }
    }
}

struct DictumMenuBarGlyph: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var models = ServiceContainer.shared.modelManagerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: dictation.state != .processing || reduceMotion)) { timeline in
            ZStack(alignment: .topTrailing) {
                if case .downloading(let progress) = SidebarStatus.current() {
                    if let progress { Circle().trim(from: 0, to: progress).stroke(lineWidth: 2).rotationEffect(.degrees(-90)).frame(width: 16, height: 16) }
                    else { ProgressView().controlSize(.mini) }
                } else {
                    Image("MenuBarGlyph").renderingMode(.template).resizable().frame(width: 18, height: 18)
                        .opacity(dictation.state == .processing && !reduceMotion ? 0.675 + 0.325 * cos(timeline.date.timeIntervalSinceReferenceDate * 2 * .pi) : 1)
                    if dictation.state == .recording { Circle().fill(DictumTheme.live).frame(width: 6, height: 6) }
                    else if !AXIsProcessTrusted() || !models.isModelReady { Circle().fill(DictumTheme.warning).frame(width: 6, height: 6) }
                }
            }.frame(width: 18, height: 18)
        }
    }
}
