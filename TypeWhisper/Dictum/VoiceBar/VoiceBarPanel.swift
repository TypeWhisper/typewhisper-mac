import AppKit
import Combine
import SwiftUI
import os

#if DEBUG
private let voiceBarTimingLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "VoiceBarTiming")
#endif

@MainActor
final class VoiceBarPresentation: ObservableObject {
    @Published var state: VoiceBarState = .idle
    @Published var isPresented = false
    @Published var targetMenuOpen = false
    private(set) var isActive = false
    @Published var text = ""
    @Published var duration: TimeInterval = 0
    @Published var levels = Array(repeating: Float.zero, count: 26)
    private var copiedText: String?
    private var lastActivity: DictationViewModel.State = .idle
    private var feedback: (state: VoiceBarState, deadline: Date)?
    private var feedbackCaptured = false
    static var enabled: Bool { UserDefaults.standard.object(forKey: "dictumVoiceBarEnabled") as? Bool ?? true }

#if DEBUG
    static let debugCondition: String? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--dictum-voicebar-condition"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }()
#endif

    var contentSize: NSSize {
#if DEBUG
        let started = ContinuousClock.now
        defer {
            let elapsed = started.duration(to: .now)
            if elapsed > .milliseconds(100) {
                voiceBarTimingLogger.warning("Layout took \(elapsed.description, privacy: .public)")
            }
        }
#endif
        guard state.showsTranscript, !text.isEmpty else { return NSSize(width: state.collapsedWidth, height: 44) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 22
        paragraph.maximumLineHeight = 22
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 424, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph]
        )
        return NSSize(width: 460, height: 60 + min(3, max(1, ceil(bounds.height / 22))) * 22)
    }

    static func replacesLegacyIndicator(_ vm: DictationViewModel) -> Bool {
        guard enabled else { return false }
        switch vm.state {
        case .recording, .processing, .error: return true
        case .inserting:
            return vm.cancelledRecordingDeadline != nil || vm.voiceBarInsertedText != nil
                || vm.voiceBarUndeliveredText != nil
                || ["mic.slash", "waveform.badge.exclamationmark", "exclamationmark.triangle.fill", "doc.on.clipboard", "doc.on.doc"].contains(vm.actionFeedbackIcon ?? "")
        default: return false
        }
    }

    func refresh(_ vm: DictationViewModel) {
#if DEBUG
        let started = ContinuousClock.now
        defer {
            let elapsed = started.duration(to: .now)
            if elapsed > .milliseconds(100) {
                voiceBarTimingLogger.warning("Refresh took \(elapsed.description, privacy: .public)")
            }
        }
#endif
        if lastActivity == .recording && vm.state == .processing && vm.cancelledRecordingDeadline == nil {
            ServiceContainer.shared.soundService.play(.recordingStopped, enabled: vm.soundFeedbackEnabled)
        }
        if lastActivity != vm.state {
            if vm.state == .recording || vm.state == .processing {
                copiedText = nil
                feedback = nil
                feedbackCaptured = false
            }
            if vm.state == .inserting { feedbackCaptured = false }
            lastActivity = vm.state
        }
        var input = VoiceBarState.Input()
        input.confirmedText = vm.partialText
        input.duration = vm.recordingDuration
        input.cancellationRemaining = vm.state == .inserting ? vm.cancelledRecordingDeadline?.timeIntervalSinceNow : nil
        input.translation = SettingsViewModel.shared.translationEnabled
        input.targetMenuOpen = targetMenuOpen
        switch vm.state {
        case .recording: input.activity = vm.isRecordingInputReady && !vm.isModelLoading ? .recording : .preparing
        case .processing: input.activity = .processing
        case .error(let message): input.outcome = .blockingError(message)
        case .inserting:
            if let undelivered = vm.voiceBarUndeliveredText {
                if copiedText != undelivered {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(undelivered, forType: .string)
                    copiedText = undelivered
                }
                input.outcome = .copied
                break
            }
            switch vm.actionFeedbackIcon {
            case "mic.slash", "waveform.badge.exclamationmark": input.outcome = vm.actionFeedbackIsError ? .blockingError(vm.actionFeedbackMessage ?? "") : .noSpeech
            case "exclamationmark.triangle.fill": input.outcome = .recoveredError
            case "doc.on.clipboard", "doc.on.doc": input.outcome = .copied
            default:
                if vm.actionFeedbackIsError {
                    input.outcome = .blockingError(vm.actionFeedbackMessage ?? "")
                } else if vm.cancelledRecordingDeadline == nil, let inserted = vm.voiceBarInsertedText {
                    let processing = ServiceContainer.shared.promptProcessingService
                    input.outcome = processing.fallbackPriorityList.contains(where: { processing.isProviderReady($0.providerId) })
                        ? .inserted(countWords(inserted)) : .noAI
                }
            }
        default: break
        }
#if DEBUG
        if let condition = Self.debugCondition {
            let parts = condition.split(separator: ":", maxSplits: 1)
            switch parts.first {
            case "downloading": input.model = .downloading(parts.count > 1 ? Double(parts[1]) : nil)
            case "loading": input.model = .loading
            case "failed": input.model = .failed(parts.count > 1 ? String(parts[1]) : "")
            case "recovered-error": input.outcome = .recoveredError
            case "blocking-error": input.outcome = .blockingError(parts.count > 1 ? String(parts[1]) : "")
            case "no-ai": input.outcome = .noAI
            case "no-speech": input.outcome = .noSpeech
            default: break
            }
        }
#endif
        var nextState = VoiceBarState.derive(input)
#if DEBUG
        if Self.debugCondition != nil {
            isActive = nextState != .idle
            if isActive { state = nextState }
            duration = vm.recordingDuration
            levels.removeFirst()
            levels.append(vm.audioLevel)
            return
        }
#endif
        if let lifetime = nextState.feedbackLifetime, !feedbackCaptured {
            feedback = (nextState, Date().addingTimeInterval(lifetime))
            feedbackCaptured = true
        }
        if let feedback, vm.state != .recording && vm.state != .processing && input.cancellationRemaining == nil {
            nextState = Date() < feedback.deadline ? feedback.state : .idle
        } else if feedbackCaptured && feedback == nil && nextState.feedbackLifetime != nil {
            nextState = .idle
        }
        isActive = nextState != .idle
        if isActive { state = nextState }
        if !vm.partialText.isEmpty || !state.showsTranscript { text = vm.partialText }
        duration = vm.recordingDuration
        levels.removeFirst()
        levels.append(vm.audioLevel)
    }

    func dismissFeedback() { feedback = nil; feedbackCaptured = true; isActive = false }

    private func countWords(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { substring, _, _, _ in
            guard let substring else { return }
            if substring.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains(Int($0.value)) }) { count += substring.count }
            else { count += 1 }
        }
        return count
    }
}

private final class VoiceBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class VoiceBarPanel: NSPanel {
    private let presentation = VoiceBarPresentation()
    private let resolver = IndicatorScreenResolver()
    private var timer: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        let hosting = VoiceBarHostingView(rootView: VoiceBarView(model: presentation))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func startObserving() {
        timer = Timer.publish(every: 0.055, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            self.presentation.refresh(.shared)
            guard VoiceBarPresentation.enabled, self.presentation.isActive else {
                if self.presentation.isPresented {
                    self.presentation.isPresented = false
                    self.hideTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        guard let self, !self.presentation.isPresented else { return }
                        self.orderOut(nil)
                    }
                }
                return
            }
            self.hideTask?.cancel()
            let size = NSSize(width: 460, height: 126)
#if DEBUG
            let started = ContinuousClock.now
#endif
            let screen = self.resolver.resolveScreen(for: .activeScreen)
#if DEBUG
            let elapsed = started.duration(to: .now)
            if elapsed > .milliseconds(100) {
                voiceBarTimingLogger.warning("Screen lookup took \(elapsed.description, privacy: .public)")
            }
#endif
            let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 72, width: size.width, height: size.height)
            if self.frame != frame { self.setFrame(frame, display: true) }
            if !self.isVisible { self.orderFrontRegardless() }
            self.presentation.isPresented = true
        }
    }
}

private extension VoiceBarState {
    var feedbackLifetime: TimeInterval? {
        switch self {
        case .inserted: 1.2
        case .copied, .downloading: 3
        case .recoveredError, .noAI: 4
        case .noSpeech: 2
        case .blockingError: .infinity
        default: nil
        }
    }
    var collapsedWidth: CGFloat {
        switch self {
        case .inserted, .cancelled, .noSpeech: 220
        case .listening: 284
        case .translating, .targetMenu: 460
        default: 390
        }
    }
    var showsTranscript: Bool {
        switch self {
        case .listeningWithText, .translating, .targetMenu, .polishing, .countdown: true
        default: false
        }
    }
}

private struct VoiceBarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct VoiceBarView: View {
    @ObservedObject var model: VoiceBarPresentation
    var retryPolish: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if model.state.showsTranscript && !model.text.isEmpty {
                transcript.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 2)
            }
            HStack(spacing: 10) { controls }.padding(.leading, 15).padding(.trailing, 7).frame(height: 44)
        }
        .frame(width: model.contentSize.width, height: model.contentSize.height, alignment: .bottom)
        .foregroundStyle(.white)
        .background { VoiceBarMaterial().overlay(.black.opacity(0.55)) }
        .clipShape(RoundedRectangle(cornerRadius: model.state.showsTranscript ? 20 : 22))
        .overlay { RoundedRectangle(cornerRadius: model.state.showsTranscript ? 20 : 22).strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
        .overlay(alignment: .bottomLeading) {
            if case .cancelled(let remaining) = model.state {
                Capsule().fill(.white.opacity(0.45)).frame(width: model.contentSize.width * remaining, height: 2).padding(.bottom, 1)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78), value: model.state)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78), value: model.contentSize)
        .opacity(model.isPresented ? 1 : 0)
        .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.92, anchor: .bottom)
        .offset(y: model.isPresented || reduceMotion ? 0 : 10)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : model.isPresented ? .spring(response: 0.34, dampingFraction: 0.78) : .easeIn(duration: 0.20), value: model.isPresented)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                TimelineView(.animation(minimumInterval: 0.055, paused: !isPolishing || reduceMotion)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    Text(verbatim: model.text).font(.system(size: 15)).lineSpacing(4)
                        .foregroundStyle(LinearGradient(
                            colors: isPolishing && !reduceMotion ? [.white.opacity(0.55), .white, .white.opacity(0.55)] : [.white, .white],
                            startPoint: UnitPoint(x: phase * 2 - 1, y: 0), endPoint: UnitPoint(x: phase * 2, y: 0)
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.id("transcript")
            }
            .scrollIndicators(.hidden).scrollDisabled(true)
            .frame(height: model.contentSize.height - 60)
            .mask(LinearGradient(stops: [.init(color: model.contentSize.height >= 126 ? .clear : .white, location: 0), .init(color: .white, location: 0.27), .init(color: .white, location: 1)], startPoint: .top, endPoint: .bottom))
            .onChange(of: model.text) { _, _ in proxy.scrollTo("transcript", anchor: .bottom) }
            .onAppear { proxy.scrollTo("transcript", anchor: .bottom) }
        }
    }

    private var isPolishing: Bool {
        if case .polishing = model.state { return true }
        return false
    }

    @ViewBuilder private var controls: some View {
        switch model.state {
        case .idle: EmptyView()
        case .preparing:
            ProgressView().controlSize(.small)
            label("Getting ready")
            waveform
            Text(verbatim: timerText).font(.system(size: 13, design: .rounded)).foregroundStyle(.white.opacity(0.58))
            cancel
        case .listening, .listeningWithText, .translating, .targetMenu, .countdown:
            if model.state == .translating || model.state == .targetMenu { VoiceBarLanguageMenu(isOpen: $model.targetMenuOpen) }
            else if case .countdown(let seconds) = model.state {
                Circle().trim(from: 0, to: Double(seconds) / 60).stroke(DictumTheme.warning, lineWidth: 2).rotationEffect(.degrees(-90)).frame(width: 18, height: 18)
            } else { liveDot }
            waveform
            Text(verbatim: timerText).font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(timerColor)
            cancel
            Button { _ = DictationViewModel.shared.apiStopRecording() } label: {
                Image(systemName: "checkmark").foregroundStyle(.black).frame(width: 30, height: 30).background(.white, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(Text("Done", tableName: "DictumHome")).help("fn")
        case .polishing(let translating):
            TimelineView(.animation(minimumInterval: 0.055, paused: reduceMotion)) { timeline in
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle().fill(.white).frame(width: 5, height: 5)
                            .offset(y: reduceMotion ? 0 : -4 * max(0, sin(timeline.date.timeIntervalSinceReferenceDate * 5.7 - Double(index) * 0.7)))
                    }
                }.frame(height: 20)
            }.fixedSize()
            label(translating ? "Translating" : "Polishing")
            Spacer()
            cancel
        case .inserted(let count):
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DictumTheme.success)
            Text(String(localized: "Inserted · \(count) words", table: "DictumHome"))
        case .copied:
            Image(systemName: "doc.on.doc")
            label("Copied. No text field found.")
            Text(verbatim: "⌘V").font(.system(size: 12, weight: .medium))
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 6)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        case .recoveredError:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DictumTheme.warning)
            label("Polishing failed. Original inserted.")
            action("Retry") { retryPolish?() }.disabled(retryPolish == nil)
        case .blockingError(let message):
            Image(systemName: "mic.slash.fill").foregroundStyle(DictumTheme.danger)
            if message.isEmpty { label("Microphone unavailable") } else { Text(verbatim: message).lineLimit(1) }
            action("Open Settings") { model.dismissFeedback(); DictumNavigation.shared.open(.general) }
            Button { model.dismissFeedback() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(Text("Close", tableName: "DictumHome"))
        case .noSpeech:
            Image(systemName: "mic.slash")
            label("Didn't hear anything")
        case .downloading(let progress):
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 2)
                Circle().trim(from: 0, to: progress ?? 0.25).stroke(.white, lineWidth: 2).rotationEffect(.degrees(-90))
            }.frame(width: 18, height: 18)
            label("Downloading speech model")
            if let progress { Text(progress, format: .percent.precision(.fractionLength(0))) }
            action("View") { DictumNavigation.shared.open(.speech) }
        case .noAI:
            Image(systemName: "cloud")
            label("No AI model connected. Original inserted.")
            action("Settings") { DictumNavigation.shared.open(.aiModels) }
        case .cancelled:
            label("Cancelled")
            Spacer()
            action("Undo") { DictationViewModel.shared.restoreCancelledRecording() }
        }
    }

    private var waveform: some View {
        HStack(spacing: 2.5) {
            ForEach(model.levels.indices, id: \.self) { index in
                Capsule().fill(model.state == .translating || model.state == .targetMenu ? Color(red: 0.89, green: 0.82, blue: 1) : .white.opacity(0.88)).frame(width: 2.5, height: reduceMotion ? 8 : CGFloat(3 + min(1, max(0, model.levels[index])) * 19))
            }
        }.frame(height: 22).mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.22), .init(color: .white, location: 1)], startPoint: .leading, endPoint: .trailing)).accessibilityHidden(true)
    }
    private var liveDot: some View {
        TimelineView(.animation(minimumInterval: 0.055, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Circle().fill(DictumTheme.live).frame(width: 8, height: 8)
                .overlay { if !reduceMotion { Circle().stroke(DictumTheme.live.opacity(0.45 * (1 - phase))).scaleEffect(0.6 + phase) } }
        }.frame(width: 8, height: 8).accessibilityHidden(true)
    }
    private var timerText: String {
        let seconds: Int
        if case .countdown(let remaining) = model.state { seconds = remaining } else { seconds = Int(model.duration) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    private var timerColor: Color {
        if case .countdown = model.state { return DictumTheme.warning }
        return .white.opacity(0.58)
    }
    private var cancel: some View {
        Button { DictationViewModel.shared.cancelFromVoiceBar() } label: {
            Image(systemName: "xmark").frame(width: 30, height: 30)
        }.buttonStyle(.plain).accessibilityLabel(Text("Cancel", tableName: "DictumHome")).help("esc")
    }
    private func label(_ key: LocalizedStringKey) -> some View { Text(key, tableName: "DictumHome").font(.system(size: 12.5)) }
    private func action(_ key: LocalizedStringKey, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { label(key).padding(.horizontal, 10).frame(height: 26).background(.white.opacity(0.14), in: Capsule()) }.buttonStyle(.plain)
    }
}

struct VoiceBarLanguageMenu: View {
    @ObservedObject private var settings = SettingsViewModel.shared
    @Binding var isOpen: Bool
    var body: some View {
        VoiceBarLanguagePicker(target: settings.translationTargetLanguage, isOpen: $isOpen)
            .frame(width: 150, height: 26)
    }
}
