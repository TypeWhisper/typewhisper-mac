import AppKit
import Combine
import SwiftUI
import os

#if DEBUG
private let voiceBarTimingLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "VoiceBarTiming")
#endif

@MainActor
final class VoiceBarPresentation: ObservableObject {
    @Published var state: VoiceBarState = .idle {
        didSet {
#if DEBUG
            if state != oldValue { voiceBarTimingLogger.notice("VoiceBar state \(String(describing: self.state), privacy: .public)") }
#endif
        }
    }
    @Published var isPresented = false
    @Published var targetMenuOpen = false
    private(set) var isActive = false
    @Published var text = ""
    @Published var tentativeText = ""
    @Published var duration: TimeInterval = 0
    @Published var levels = Array(repeating: Float.zero, count: 26)
    private var lastActivity: DictationViewModel.State = .idle
    private var feedback: (state: VoiceBarState, deadline: Date)?
    private var feedbackCaptured = false
    private var lastModelNoticeAttempt = 0
    private var preparingDebounce = PreparingDebounce()
    static var enabled: Bool { UserDefaults.standard.object(forKey: "dictumVoiceBarEnabled") as? Bool ?? true }

#if DEBUG
    static let debugCondition: String? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--dictum-voicebar-condition"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }()
#endif

#if DEBUG
    nonisolated static let debugFeedbackLifetime: TimeInterval? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--dictum-voicebar-feedback-lifetime"),
              CommandLine.arguments.indices.contains(index + 1),
              let seconds = TimeInterval(CommandLine.arguments[index + 1]), seconds > 0 else { return nil }
        return seconds
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
        guard state.showsTranscript, hasTranscript else { return NSSize(width: state.collapsedWidth, height: 44) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 22
        paragraph.maximumLineHeight = 22
        let bounds = (transcript as NSString).boundingRect(
            with: NSSize(width: 424, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph]
        )
        return NSSize(width: 460, height: 60 + min(3, max(1, ceil(bounds.height / 22))) * 22)
    }

    /// 确认前缀与待确认尾段连在一起显示；首个部分结果的前缀为空，只有尾段。
    var transcript: String { text + tentativeText }
    var hasTranscript: Bool { !transcript.isEmpty }

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
        if lastActivity != vm.state {
            if vm.state == .recording || vm.state == .processing {
                feedback = nil
                feedbackCaptured = false
            }
            if vm.state == .inserting { feedbackCaptured = false }
            if vm.state != .recording { preparingDebounce.reset() }
            lastActivity = vm.state
        }
        // 每次被拒绝的听写尝试都让模型提示重新出现，包括提示刚被关闭之后。
        if vm.modelNoticeAttempt != lastModelNoticeAttempt {
            feedback = nil
            feedbackCaptured = false
            lastModelNoticeAttempt = vm.modelNoticeAttempt
        }
        var input = VoiceBarState.Input()
        input.confirmedText = vm.partialText
        input.tentativeText = vm.streamingPreview.tentativeTail
        input.duration = vm.recordingDuration
        input.cancellationRemaining = vm.state == .inserting ? vm.cancelledRecordingDeadline?.timeIntervalSinceNow : nil
        input.translation = vm.sessionMode == .translation
        input.targetMenuOpen = targetMenuOpen
        if vm.state == .idle, let notice = vm.modelNotice {
            switch notice {
            case .downloading(let progress): input.model = .downloading(progress)
            case .notDownloaded: input.model = .notDownloaded
            case .failed(let message): input.model = .failed(message)
            }
        }
        switch vm.state {
        case .recording:
            let preparing = !(vm.isRecordingInputReady && !vm.isModelLoading)
            switch preparingDebounce.update(preparing: preparing, now: Date()) {
            case .some(true): input.activity = .preparing
            case .some(false): input.activity = .recording
            case nil: input.activity = .idle
            }
        case .processing: input.activity = .processing
        case .error(let message): input.outcome = .blockingError(message)
        case .inserting:
            if vm.voiceBarUndeliveredText != nil {
                input.outcome = .copied
                break
            }
            switch vm.actionFeedbackIcon {
            case "mic.slash", "waveform.badge.exclamationmark": input.outcome = vm.actionFeedbackIsError ? .blockingError(vm.actionFeedbackMessage ?? "") : .noSpeech
            case "exclamationmark.triangle.fill": input.outcome = vm.sessionMode == .translation ? .translationFailed : .recoveredError
            case "doc.on.clipboard", "doc.on.doc": input.outcome = .copied
            default:
                if vm.actionFeedbackIsError {
                    input.outcome = .blockingError(vm.actionFeedbackMessage ?? "")
                } else if vm.cancelledRecordingDeadline == nil, let inserted = vm.voiceBarInsertedText {
                    let processing = ServiceContainer.shared.promptProcessingService
                    input.outcome = processing.fallbackPriorityList.contains(where: { processing.isProviderReady($0.providerId) })
                        ? .inserted(DictumWordCount.count(inserted)) : .noAI
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
            case "not-downloaded": input.model = .notDownloaded
            case "failed": input.model = .failed(parts.count > 1 ? String(parts[1]) : "")
            case "recovered-error": input.outcome = .recoveredError
            case "translation-failed": input.outcome = .translationFailed
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
        updateTranscript(recording: vm.state == .recording, partialText: vm.partialText, preview: vm.streamingPreview)
        duration = vm.recordingDuration
        levels.removeFirst()
        levels.append(vm.audioLevel)
    }

    func dismissFeedback() { feedback = nil; feedbackCaptured = true; isActive = false }

#if DEBUG
    func setStateForTesting(_ newState: VoiceBarState) {
        state = newState
        isActive = true
    }
#endif

    func updateTranscript(recording: Bool, partialText: String, preview: StreamingHandler.Preview) {
        let parts = Self.transcriptParts(recording: recording, partialText: partialText, preview: preview)
        if !partialText.isEmpty || !state.showsTranscript { text = parts.confirmed }
        tentativeText = parts.tentative
    }

    /// partialText 已包含待确认尾段，录音中按预览拆成确认前缀与尾段，其余状态整段显示。
    static func transcriptParts(recording: Bool, partialText: String, preview: StreamingHandler.Preview) -> (confirmed: String, tentative: String) {
        recording ? (preview.confirmedPrefix, preview.tentativeTail) : (partialText, "")
    }
}

/// 准备中状态只在准备条件连续成立 0.15 秒后显示，离开同样需要连续 0.15 秒，
/// 引擎就绪与模型加载之间的瞬时切换不会让语音条在准备中与聆听之间闪烁。
/// 一次录音显示过聆听之后，后续的准备条件一律显示为聆听，直到 `reset()`。
struct PreparingDebounce {
    static let delay: TimeInterval = 0.15
    private var shown: Bool?
    private var changeSince: Date?

    mutating func reset() {
        shown = nil
        changeSince = nil
    }

    /// 返回 nil 表示准备条件刚出现、尚未持续足够久，语音条暂不显示。
    mutating func update(preparing: Bool, now: Date) -> Bool? {
        if shown == nil, !preparing { shown = false }
        if shown == false {
            changeSince = nil
            return false
        }
        if let current = shown, current == preparing {
            changeSince = nil
            return current
        }
        let since = changeSince ?? now
        changeSince = since
        guard now.timeIntervalSince(since) >= Self.delay else { return shown }
        shown = preparing
        changeSince = nil
        return preparing
    }
}

private final class VoiceBarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class VoiceBarPanel: NSPanel {
    let presentation = VoiceBarPresentation()
    private let dictation: DictationViewModel
    // 焦点元素与焦点窗口都要跨进程查询辅助功能接口，首次显示时会让主线程停顿约 200 毫秒；
    // 语音条只需要最前应用的窗口所在的屏幕。
    private let resolver = IndicatorScreenResolver(
        focusedElementPositionProvider: { nil },
        focusedWindowFrameProvider: { nil }
    )
    private var screenChangeObservers: [NSObjectProtocol] = []
    private var timer: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var cachedScreen: NSScreen?
    private var lastScreenResolve = Date.distantPast
    private var wakeObserver: AnyCancellable?

    init(dictation: DictationViewModel = .shared) {
        self.dictation = dictation
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        let hosting = VoiceBarHostingView(rootView: VoiceBarView(model: presentation, retryPolish: { DictationViewModel.shared.retryPolish() }))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        contentView = hosting
        let notificationCenter = NotificationCenter.default
        screenChangeObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.lastScreenResolve = .distantPast })
        screenChangeObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.lastScreenResolve = .distantPast })
        // 隐藏期间 55ms 定时刷新停止；objectWillChange 在属性变化之前触发，
        // 延后到下一轮主线程再刷新，才能读到变化后的值。
        wakeObserver = dictation.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.timer == nil else { return }
            self.tick()
        }
    }

    isolated deinit {
        for observer in screenChangeObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func startObserving() {
        startTimer()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.publish(every: 0.055, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer = nil
    }

    private func tick() {
        presentation.refresh(dictation)
        guard VoiceBarPresentation.enabled, presentation.isActive else {
            if presentation.isPresented {
                presentation.isPresented = false
                hideTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, !self.presentation.isPresented else { return }
                    self.orderOut(nil)
                }
            } else if VoiceBarPresentation.enabled, dictation.state == .recording {
                // 准备中状态要等条件持续 0.15 秒才显示，录音开始后没有新的发布，刷新要继续运行。
                startTimer()
            } else {
                stopTimer()
            }
            return
        }
        startTimer()
        hideTask?.cancel()
        let size = NSSize(width: 460, height: 126)
#if DEBUG
        let started = ContinuousClock.now
#endif
        // 解析活动屏幕会经辅助功能 API 查询焦点元素，单次可能阻塞主线程数十毫秒；
        // 屏幕只需跟随焦点变化，不必每 55ms 都解析。
        let screen: NSScreen
        if Date().timeIntervalSince(lastScreenResolve) < 2, let cachedScreen {
            screen = cachedScreen
        } else {
            screen = self.resolver.resolveScreen(for: .activeScreen)
            cachedScreen = screen
            lastScreenResolve = Date()
        }
#if DEBUG
        let elapsed = started.duration(to: .now)
        if elapsed > .milliseconds(100) {
            voiceBarTimingLogger.warning("Screen lookup took \(elapsed.description, privacy: .public)")
        }
#endif
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 72, width: size.width, height: size.height)
        if self.frame != frame { self.setFrame(frame, display: true) }
        if !self.isVisible {
            // 语音条重新显示时焦点可能已迁移到别的屏幕，强制重新解析一次。
            self.lastScreenResolve = .distantPast
            self.orderFrontRegardless()
        }
        presentation.isPresented = true
    }
}

private extension VoiceBarState {
    var feedbackLifetime: TimeInterval? {
        let lifetime: TimeInterval? = switch self {
        case .inserted: 1.2
        case .copied, .downloading, .notDownloaded: 3
        case .recoveredError, .translationFailed, .noAI: 4
        case .noSpeech: 2
        case .blockingError, .modelFailed: .infinity
        default: nil
        }
#if DEBUG
        if let debugLifetime = VoiceBarPresentation.debugFeedbackLifetime, let lifetime, lifetime.isFinite {
            return debugLifetime
        }
#endif
        return lifetime
    }
    var collapsedWidth: CGFloat {
        switch self {
        case .inserted, .cancelled, .noSpeech: 220
        case .listening: 300
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
            if model.state.showsTranscript && model.hasTranscript {
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
                    Text(transcriptText(phase: phase))
                        .font(.system(size: 15)).lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }.id("transcript")
            }
            .scrollIndicators(.hidden).scrollDisabled(true)
            .frame(height: model.contentSize.height - 60)
            .mask(LinearGradient(stops: [.init(color: model.contentSize.height >= 126 ? .clear : .white, location: 0), .init(color: .white, location: 0.27), .init(color: .white, location: 1)], startPoint: .top, endPoint: .bottom))
            .onChange(of: model.transcript) { _, _ in proxy.scrollTo("transcript", anchor: .bottom) }
            .onAppear { proxy.scrollTo("transcript", anchor: .bottom) }
        }
    }

    private var isPolishing: Bool {
        if case .polishing = model.state { return true }
        return false
    }

    private func transcriptText(phase: Double) -> AttributedString {
        var transcript = AttributedString(model.text)
        transcript.foregroundColor = shimmerColor(phase: phase)
        var tentative = AttributedString(model.tentativeText)
        tentative.foregroundColor = Color.white.opacity(0.34)
        transcript.append(tentative)
        return transcript
    }

    private func shimmerColor(phase: Double) -> Color {
        // 润色微光按 1.4 秒周期在 55% 与 100% 白之间往返。
        let wave = 0.5 - 0.5 * cos(2 * .pi * phase)
        if isPolishing && !reduceMotion {
            return Color.white.opacity(0.55 + 0.45 * wave)
        }
        return .white
    }

    @ViewBuilder private var controls: some View {
        switch model.state {
        case .idle: EmptyView()
        case .preparing:
            ProgressView().controlSize(.small)
            label("Getting ready")
            waveform
            Text(verbatim: timerText).font(.system(size: 13, design: .rounded)).lineLimit(1).fixedSize().foregroundStyle(.white.opacity(0.58))
            cancel
        case .listening, .listeningWithText, .translating, .targetMenu, .countdown:
            if model.state == .translating || model.state == .targetMenu { VoiceBarLanguageMenu(isOpen: $model.targetMenuOpen) }
            else if case .countdown(let seconds) = model.state {
                Circle().trim(from: 0, to: Double(seconds) / 60).stroke(DictumTheme.warning, lineWidth: 2).rotationEffect(.degrees(-90)).frame(width: 18, height: 18)
            } else { liveDot }
            waveform
            Text(verbatim: timerText).font(.system(size: 13, design: .rounded)).monospacedDigit().lineLimit(1).fixedSize().foregroundStyle(timerColor)
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
        case .translationFailed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DictumTheme.warning)
            Text("Translation failed. What you said was inserted.", tableName: "DictumTranslation").font(.system(size: 12.5))
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
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
            label("Speech model not downloaded")
            action("Open Settings") { model.dismissFeedback(); DictumNavigation.shared.open(.speech) }
        case .modelFailed(let message):
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(DictumTheme.danger)
            Text(verbatim: message).lineLimit(1)
            action("Open Settings") { model.dismissFeedback(); DictumNavigation.shared.open(.speech) }
            Button { model.dismissFeedback() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(Text("Close", tableName: "DictumHome"))
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
    @ObservedObject private var dictation = DictationViewModel.shared
    @Binding var isOpen: Bool
    var body: some View {
        if let pair = dictation.sessionPair {
            VoiceBarLanguagePicker(pair: pair, isOpen: $isOpen)
                .frame(width: max(150, Self.titleWidth(for: pair) + 28), height: 26)
        }
    }

    private static func titleWidth(for pair: TranslationPair) -> CGFloat {
        let spoken = pair.spoken.map { TranslationLanguageNames.shortName(for: $0) } ?? String(localized: "Auto", table: "DictumTranslation")
        let title = "\(spoken) → \(TranslationLanguageNames.name(for: pair.target)) ⌄"
        return (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width
    }
}
