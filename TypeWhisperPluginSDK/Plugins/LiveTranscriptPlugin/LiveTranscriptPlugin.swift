import AppKit
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - PluginHotkey

struct PluginHotkey: Codable, Equatable {
    let keyCode: UInt16
    let modifierFlags: UInt
}

// MARK: - Appearance

private enum LiveTranscriptAppearance {
    static let defaultFontSize = 14.0
    static let defaultWindowWidth = 420.0
    static let defaultWindowHeight = 320.0
    static let defaultBackgroundOpacity = 0.92

    static let fontSizeRange = 10.0...24.0
    static let windowWidthRange = 300.0...900.0
    static let windowHeightRange = 180.0...650.0
    static let backgroundOpacityRange = 0.20...0.95

    static let minimumWindowSize = NSSize(width: 250, height: 150)

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Plugin Entry Point

@objc(LiveTranscriptPlugin)
final class LiveTranscriptPlugin: NSObject, TypeWhisperPlugin, ObservableObject, @unchecked Sendable {
    static let pluginId = "com.typewhisper.livetranscript"
    static let pluginName = "Live Transcript"

    fileprivate var host: HostServices?
    private var subscriptionId: UUID?
    private var panel: LiveTranscriptPanel?
    private var viewModel: LiveTranscriptViewModel?
    private var autoCloseTask: Task<Void, Never>?

    fileprivate var _autoOpen: Bool = false
    fileprivate var _fontSize: Double = LiveTranscriptAppearance.defaultFontSize
    @Published fileprivate var _windowWidth: Double = LiveTranscriptAppearance.defaultWindowWidth
    @Published fileprivate var _windowHeight: Double = LiveTranscriptAppearance.defaultWindowHeight
    fileprivate var _backgroundOpacity: Double = LiveTranscriptAppearance.defaultBackgroundOpacity
    private let autoCloseDelay: Double = 4.0

    fileprivate var toggleHotkey: PluginHotkey?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotkeyIsDown: Bool = false
    private var streamingDisplayActive = false
    private var hasCompletedTranscript = false

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _autoOpen = host.userDefault(forKey: "autoOpen") as? Bool ?? false
        _fontSize = Self.clampedUserDefault(
            host,
            key: "fontSize",
            defaultValue: LiveTranscriptAppearance.defaultFontSize,
            range: LiveTranscriptAppearance.fontSizeRange
        )
        _windowWidth = Self.clampedUserDefault(
            host,
            key: "windowWidth",
            defaultValue: LiveTranscriptAppearance.defaultWindowWidth,
            range: LiveTranscriptAppearance.windowWidthRange
        )
        _windowHeight = Self.clampedUserDefault(
            host,
            key: "windowHeight",
            defaultValue: LiveTranscriptAppearance.defaultWindowHeight,
            range: LiveTranscriptAppearance.windowHeightRange
        )
        _backgroundOpacity = Self.clampedUserDefault(
            host,
            key: "backgroundOpacity",
            defaultValue: LiveTranscriptAppearance.defaultBackgroundOpacity,
            range: LiveTranscriptAppearance.backgroundOpacityRange
        )

        if let data = host.userDefault(forKey: "toggleHotkey") as? Data {
            toggleHotkey = try? JSONDecoder().decode(PluginHotkey.self, from: data)
        }
        setupHotkeyMonitor()

        subscriptionId = host.eventBus.subscribe { [weak self] event in
            await self?.handleEvent(event)
        }

        setStreamingDisplayActiveIfNeeded(_autoOpen)
    }

    func deactivate() {
        if let id = subscriptionId {
            host?.eventBus.unsubscribe(id: id)
            subscriptionId = nil
        }
        setStreamingDisplayActiveIfNeeded(false)
        tearDownHotkeyMonitor()
        autoCloseTask?.cancel()
        Task { @MainActor [weak self] in
            self?.panel?.close()
            self?.panel = nil
            self?.viewModel = nil
        }
        host = nil
    }

    var settingsView: AnyView? {
        AnyView(LiveTranscriptSettingsView(plugin: self))
    }

    @MainActor
    var displayedTextForTesting: String {
        viewModel?.paragraphs.map(\.text).joined(separator: " ") ?? ""
    }

    var appearanceForTesting: (fontSize: Double, windowWidth: Double, windowHeight: Double, backgroundOpacity: Double) {
        (_fontSize, _windowWidth, _windowHeight, _backgroundOpacity)
    }

    @MainActor
    func updateAutoOpenPreference(_ enabled: Bool) {
        _autoOpen = enabled
        host?.setUserDefault(enabled, forKey: "autoOpen")
        refreshStreamingDisplayActive()
    }

    @MainActor
    func updateFontSizePreference(_ value: Double) {
        _fontSize = LiveTranscriptAppearance.clamped(value, to: LiveTranscriptAppearance.fontSizeRange)
        host?.setUserDefault(_fontSize, forKey: "fontSize")
        applyAppearanceToVisiblePanel()
    }

    @MainActor
    func updateWindowWidthPreference(_ value: Double) {
        _windowWidth = LiveTranscriptAppearance.clamped(value, to: LiveTranscriptAppearance.windowWidthRange)
        host?.setUserDefault(_windowWidth, forKey: "windowWidth")
        applyAppearanceToVisiblePanel(applyWindowSize: true)
    }

    @MainActor
    func updateWindowHeightPreference(_ value: Double) {
        _windowHeight = LiveTranscriptAppearance.clamped(value, to: LiveTranscriptAppearance.windowHeightRange)
        host?.setUserDefault(_windowHeight, forKey: "windowHeight")
        applyAppearanceToVisiblePanel(applyWindowSize: true)
    }

    @MainActor
    private func updateWindowSizeFromPanel(_ size: NSSize) {
        let width = LiveTranscriptAppearance.clamped(Double(size.width), to: LiveTranscriptAppearance.windowWidthRange)
        let height = LiveTranscriptAppearance.clamped(Double(size.height), to: LiveTranscriptAppearance.windowHeightRange)
        guard width != _windowWidth || height != _windowHeight else { return }

        _windowWidth = width
        _windowHeight = height
        host?.setUserDefault(width, forKey: "windowWidth")
        host?.setUserDefault(height, forKey: "windowHeight")
    }

    @MainActor
    func updateBackgroundOpacityPreference(_ value: Double) {
        _backgroundOpacity = LiveTranscriptAppearance.clamped(value, to: LiveTranscriptAppearance.backgroundOpacityRange)
        host?.setUserDefault(_backgroundOpacity, forKey: "backgroundOpacity")
        applyAppearanceToVisiblePanel()
    }

    private func setStreamingDisplayActiveIfNeeded(_ active: Bool) {
        guard streamingDisplayActive != active else { return }
        streamingDisplayActive = active
        host?.setStreamingDisplayActive(active)
    }

    @MainActor
    private func refreshStreamingDisplayActive() {
        setStreamingDisplayActiveIfNeeded(_autoOpen || panel?.isVisible == true)
    }

    private static func clampedUserDefault(
        _ host: HostServices,
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let rawValue: Double?
        if let value = host.userDefault(forKey: key) as? Double {
            rawValue = value
        } else if let value = host.userDefault(forKey: key) as? Int {
            rawValue = Double(value)
        } else {
            rawValue = nil
        }

        return LiveTranscriptAppearance.clamped(rawValue ?? defaultValue, to: range)
    }

    // MARK: - Event Handling

    @MainActor
    private func handleEvent(_ event: TypeWhisperEvent) {
        switch event {
        case .recordingStarted:
            autoCloseTask?.cancel()
            hasCompletedTranscript = false
            if _autoOpen { showPanel() }
            viewModel?.reset()

        case .partialTranscriptionUpdate(let payload):
            guard !hasCompletedTranscript else { return }
            viewModel?.updateText(payload.text, isFinal: payload.isFinal)
            if payload.isFinal { scheduleAutoClose() }

        case .transcriptionCompleted(let payload):
            hasCompletedTranscript = true
            viewModel?.updateText(payload.finalText, isFinal: true)
            scheduleAutoClose()

        case .recordingStopped:
            scheduleAutoClose()

        default:
            break
        }
    }

    // MARK: - Panel Management

    @MainActor
    private func showPanel() {
        if panel == nil {
            let vm = viewModel ?? LiveTranscriptViewModel(
                fontSize: _fontSize,
                backgroundOpacity: _backgroundOpacity
            )
            viewModel = vm
            panel = LiveTranscriptPanel(
                viewModel: vm,
                windowSize: configuredWindowSize,
                onContentSizeChanged: { [weak self] size in
                    self?.updateWindowSizeFromPanel(size)
                }
            )
        }
        applyAppearanceToVisiblePanel()
        panel?.orderFront(nil)
        refreshStreamingDisplayActive()
    }

    private var configuredWindowSize: NSSize {
        NSSize(width: _windowWidth, height: _windowHeight)
    }

    @MainActor
    private func applyAppearanceToVisiblePanel(applyWindowSize: Bool = false) {
        viewModel?.updateAppearance(fontSize: _fontSize, backgroundOpacity: _backgroundOpacity)
        if applyWindowSize {
            panel?.applyWindowSize(configuredWindowSize)
        }
    }

    @MainActor
    private func togglePanel() {
        autoCloseTask?.cancel()
        if let panel, panel.isVisible {
            panel.close()
            self.panel = nil
            refreshStreamingDisplayActive()
        } else {
            showPanel()
        }
    }

    @MainActor
    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor [weak self, autoCloseDelay] in
            try? await Task.sleep(for: .seconds(autoCloseDelay))
            guard !Task.isCancelled else { return }
            self?.panel?.close()
            self?.panel = nil
            self?.refreshStreamingDisplayActive()
        }
    }

    // MARK: - Hotkey Monitoring

    fileprivate func setupHotkeyMonitor() {
        tearDownHotkeyMonitor()
        guard toggleHotkey != nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleHotkeyEvent(event)
            return event
        }
    }

    fileprivate func tearDownHotkeyMonitor() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        hotkeyIsDown = false
    }

    private func handleHotkeyEvent(_ event: NSEvent) {
        guard let hotkey = toggleHotkey else { return }
        guard event.keyCode == hotkey.keyCode else { return }

        let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let eventMods = event.modifierFlags.intersection(relevantFlags).rawValue
        guard eventMods == hotkey.modifierFlags else { return }

        if event.type == .keyDown {
            guard !hotkeyIsDown else { return }
            hotkeyIsDown = true
            Task { @MainActor [weak self] in
                self?.togglePanel()
            }
        } else if event.type == .keyUp {
            hotkeyIsDown = false
        }
    }

    fileprivate func updateHotkey(_ hotkey: PluginHotkey?) {
        toggleHotkey = hotkey
        if let hotkey, let data = try? JSONEncoder().encode(hotkey) {
            host?.setUserDefault(data, forKey: "toggleHotkey")
        } else {
            host?.setUserDefault(nil, forKey: "toggleHotkey")
        }
        setupHotkeyMonitor()
    }

    // MARK: - Display Name

    static func displayName(for hotkey: PluginHotkey) -> String {
        var parts: [String] = []

        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        parts.append(keyName(for: hotkey.keyCode))
        return parts.joined()
    }

    static func keyName(for keyCode: UInt16) -> String {
        let knownKeys: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
            0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2",
            0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I",
            0x23: "P", 0x24: "⏎", 0x25: "L", 0x26: "J", 0x27: "'",
            0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/",
            0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥", 0x31: "␣",
            0x32: "`", 0x33: "⌫", 0x35: "⎋", 0x7A: "F1", 0x78: "F2",
            0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
            0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x69: "F13", 0x6B: "F14", 0x71: "F15",
            0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→",
        ]
        return knownKeys[keyCode] ?? "Key \(keyCode)"
    }
}

// MARK: - ViewModel

@MainActor
final class LiveTranscriptViewModel: ObservableObject {
    @Published var paragraphs: [TranscriptParagraph] = []
    @Published var isAutoScrollEnabled: Bool = true
    @Published var fontSize: Double
    @Published var backgroundOpacity: Double

    private var currentText: String?

    struct TranscriptParagraph: Identifiable {
        let id: UUID
        var text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    init(
        fontSize: Double = LiveTranscriptAppearance.defaultFontSize,
        backgroundOpacity: Double = LiveTranscriptAppearance.defaultBackgroundOpacity
    ) {
        self.fontSize = fontSize
        self.backgroundOpacity = backgroundOpacity
    }

    func updateAppearance(fontSize: Double, backgroundOpacity: Double) {
        self.fontSize = fontSize
        self.backgroundOpacity = backgroundOpacity
    }

    func reset() {
        paragraphs = []
        currentText = nil
        isAutoScrollEnabled = true
    }

    func scrollToBottom() {
        isAutoScrollEnabled = true
    }

    func updateText(_ fullText: String, isFinal: Bool) {
        let text = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard isFinal else { return }
            currentText = ""
            paragraphs = []
            return
        }
        guard text != currentText || isFinal else { return }

        currentText = text
        paragraphs = [TranscriptParagraph(id: paragraphs.first?.id ?? UUID(), text: text)]
    }
}

// MARK: - Panel

enum LiveTranscriptPanelFrameStore {
    static func defaultsKey(for autosaveName: String) -> String {
        "LiveTranscriptPanelFrame.\(autosaveName)"
    }

    static func storedString(for frame: NSRect) -> String {
        NSStringFromRect(frame)
    }

    static func restorableFrame(
        from storedString: String?,
        screenVisibleFrames: [NSRect],
        minimumSize: NSSize
    ) -> NSRect? {
        guard let storedString, !storedString.isEmpty else { return nil }

        let storedFrame = NSRectFromString(storedString)
        guard isFinite(storedFrame) else { return nil }
        guard storedFrame.width > 0, storedFrame.height > 0 else { return nil }

        let frame = NSRect(
            x: storedFrame.minX,
            y: storedFrame.minY,
            width: max(storedFrame.width, minimumSize.width),
            height: max(storedFrame.height, minimumSize.height)
        )
        guard isVisibleEnough(frame, in: screenVisibleFrames) else { return nil }

        return frame
    }

    static func restore(
        autosaveName: String,
        defaults: UserDefaults = .standard,
        screenVisibleFrames: [NSRect] = NSScreen.screens.map(\.visibleFrame),
        minimumSize: NSSize
    ) -> NSRect? {
        restorableFrame(
            from: defaults.string(forKey: defaultsKey(for: autosaveName)),
            screenVisibleFrames: screenVisibleFrames,
            minimumSize: minimumSize
        )
    }

    static func save(frame: NSRect, autosaveName: String, defaults: UserDefaults = .standard) {
        defaults.set(storedString(for: frame), forKey: defaultsKey(for: autosaveName))
    }

    private static func isFinite(_ frame: NSRect) -> Bool {
        frame.minX.isFinite &&
            frame.minY.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite
    }

    private static func isVisibleEnough(_ frame: NSRect, in screenVisibleFrames: [NSRect]) -> Bool {
        guard !screenVisibleFrames.isEmpty else { return true }

        let minimumVisibleWidth = min(80.0, max(1.0, frame.width))
        let minimumVisibleHeight = min(80.0, max(1.0, frame.height))

        return screenVisibleFrames.contains { screenFrame in
            let intersection = frame.intersection(screenFrame)
            return !intersection.isNull &&
                !intersection.isEmpty &&
                intersection.width >= minimumVisibleWidth &&
                intersection.height >= minimumVisibleHeight
        }
    }
}

final class LiveTranscriptPanel: NSPanel, NSWindowDelegate {
    private let transcriptFrameAutosaveName: String
    private let onContentSizeChanged: ((NSSize) -> Void)?
    private var shouldPersistFrameChanges = false
    private var lastNotifiedContentSize: NSSize?

    init(
        viewModel: LiveTranscriptViewModel,
        windowSize: NSSize,
        frameAutosaveName: String = "LiveTranscriptPanel",
        onContentSizeChanged: ((NSSize) -> Void)? = nil
    ) {
        self.transcriptFrameAutosaveName = frameAutosaveName
        self.onContentSizeChanged = onContentSizeChanged

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height),
            styleMask: [.resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = LiveTranscriptAppearance.minimumWindowSize
        animationBehavior = .utilityWindow
        delegate = self

        let hostingView = NSHostingView(rootView: LiveTranscriptView(viewModel: viewModel))
        hostingView.sizingOptions = []
        contentView = hostingView

        if let savedFrame = LiveTranscriptPanelFrameStore.restore(
            autosaveName: frameAutosaveName,
            minimumSize: LiveTranscriptAppearance.minimumWindowSize
        ) {
            setFrame(savedFrame, display: false)
        } else {
            center()
        }
        shouldPersistFrameChanges = true
        persistCurrentFrame()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func windowDidMove(_: Notification) {
        persistCurrentFrame()
    }

    func windowDidResize(_: Notification) {
        persistCurrentFrame()
    }

    override func close() {
        persistCurrentFrame()
        delegate = nil
        super.close()
    }

    func applyWindowSize(_ size: NSSize) {
        setContentSize(size)
        persistCurrentFrame()
    }

    private func persistCurrentFrame() {
        guard shouldPersistFrameChanges else { return }
        LiveTranscriptPanelFrameStore.save(frame: frame, autosaveName: transcriptFrameAutosaveName)
        notifyContentSizeIfNeeded()
    }

    private func notifyContentSizeIfNeeded() {
        let size = contentLayoutRect.size
        guard lastNotifiedContentSize?.width != size.width ||
            lastNotifiedContentSize?.height != size.height else { return }

        lastNotifiedContentSize = size
        onContentSizeChanged?(size)
    }
}

// MARK: - Main View

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    private let bundle = pluginModuleBundle

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.paragraphs) { paragraph in
                        Text(paragraph.text)
                            .font(.system(size: CGFloat(viewModel.fontSize)))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .id(paragraph.id)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 12)
                .background(
                    ScrollWheelDetector {
                        viewModel.isAutoScrollEnabled = false
                    }
                )
            }
            .onChange(of: viewModel.paragraphs.last?.text) {
                if viewModel.isAutoScrollEnabled {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.paragraphs.count) {
                if viewModel.isAutoScrollEnabled {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !viewModel.isAutoScrollEnabled {
                    Button {
                        viewModel.scrollToBottom()
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("New text", bundle: bundle)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(viewModel.backgroundOpacity))
        )
    }
}

private let pluginModuleBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: LiveTranscriptPlugin.self)
#endif
}()

// MARK: - Scroll Wheel Detector

private struct ScrollWheelDetector: NSViewRepresentable {
    let onScrollUp: () -> Void

    func makeNSView(context: Context) -> ScrollWheelDetectorView {
        ScrollWheelDetectorView(onScrollUp: onScrollUp)
    }

    func updateNSView(_ nsView: ScrollWheelDetectorView, context: Context) {
        nsView.onScrollUp = onScrollUp
    }

    final class ScrollWheelDetectorView: NSView {
        var onScrollUp: (() -> Void)?
        private var monitor: Any?

        init(onScrollUp: (() -> Void)?) {
            self.onScrollUp = onScrollUp
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil

            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.scrollingDeltaY > 0 {
                    self.onScrollUp?()
                }
                return event
            }
        }
    }
}

// MARK: - Settings View

private struct LiveTranscriptSettingsView: View {
    @ObservedObject var plugin: LiveTranscriptPlugin
    @State private var autoOpen: Bool = false
    @State private var fontSize: Double = LiveTranscriptAppearance.defaultFontSize
    @State private var backgroundOpacity: Double = LiveTranscriptAppearance.defaultBackgroundOpacity
    @State private var currentHotkey: PluginHotkey?
    @State private var isRecording: Bool = false
    private let bundle = Bundle(for: LiveTranscriptPlugin.self)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $autoOpen) {
                    VStack(alignment: .leading) {
                        Text("Auto-open on recording", bundle: bundle)
                            .font(.headline)
                        Text("Show the transcript window automatically when recording starts.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: autoOpen) { _, newValue in
                    plugin.updateAutoOpenPreference(newValue)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Font size", bundle: bundle)
                        .font(.headline)
                    HStack {
                        Slider(value: $fontSize, in: LiveTranscriptAppearance.fontSizeRange, step: 1)
                            .onChange(of: fontSize) { _, newValue in
                                plugin.updateFontSizePreference(newValue)
                            }
                        Text("\(Int(fontSize))pt")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Window size", bundle: bundle)
                        .font(.headline)
                    HStack {
                        Text("Width", bundle: bundle)
                            .frame(width: 48, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { plugin._windowWidth },
                                set: { newValue in
                                    plugin.updateWindowWidthPreference(newValue)
                                }
                            ),
                            in: LiveTranscriptAppearance.windowWidthRange,
                            step: 20
                        )
                        Text("\(Int(plugin._windowWidth))")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    HStack {
                        Text("Height", bundle: bundle)
                            .frame(width: 48, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { plugin._windowHeight },
                                set: { newValue in
                                    plugin.updateWindowHeightPreference(newValue)
                                }
                            ),
                            in: LiveTranscriptAppearance.windowHeightRange,
                            step: 20
                        )
                        Text("\(Int(plugin._windowHeight))")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Background opacity", bundle: bundle)
                        .font(.headline)
                    HStack {
                        Slider(value: $backgroundOpacity, in: LiveTranscriptAppearance.backgroundOpacityRange, step: 0.05)
                            .onChange(of: backgroundOpacity) { _, newValue in
                                plugin.updateBackgroundOpacityPreference(newValue)
                            }
                        Text("\(Int(backgroundOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("Lower values keep more of the app behind the transcript visible.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Toggle Shortcut", bundle: bundle)
                        .font(.headline)
                    Text("Show or hide the transcript window with a keyboard shortcut.", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        HotkeyRecorderButton(
                            hotkey: $currentHotkey,
                            isRecording: $isRecording,
                            plugin: plugin
                        )

                        if currentHotkey != nil {
                            Button {
                                currentHotkey = nil
                                plugin.updateHotkey(nil)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            autoOpen = plugin._autoOpen
            fontSize = plugin._fontSize
            backgroundOpacity = plugin._backgroundOpacity
            currentHotkey = plugin.toggleHotkey
        }
    }
}

// MARK: - Hotkey Recorder Button

private struct HotkeyRecorderButton: View {
    @Binding var hotkey: PluginHotkey?
    @Binding var isRecording: Bool
    let plugin: LiveTranscriptPlugin
    @State private var recordingMonitor: Any?
    private let bundle = Bundle(for: LiveTranscriptPlugin.self)

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            Text(buttonLabel)
                .frame(minWidth: 120)
        }
        .onDisappear {
            if isRecording { stopRecording() }
        }
    }

    private var buttonLabel: String {
        if isRecording {
            return String(localized: "Press a key combination...", bundle: bundle)
        }
        if let hotkey {
            return LiveTranscriptPlugin.displayName(for: hotkey)
        }
        return String(localized: "Record Shortcut", bundle: bundle)
    }

    private func startRecording() {
        plugin.tearDownHotkeyMonitor()
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 0x35 { // Escape - cancel
                stopRecording()
                return nil
            }
            let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
            let mods = event.modifierFlags.intersection(relevantFlags).rawValue
            let newHotkey = PluginHotkey(keyCode: event.keyCode, modifierFlags: mods)
            hotkey = newHotkey
            plugin.updateHotkey(newHotkey)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        recordingMonitor = nil
        isRecording = false
        plugin.setupHotkeyMonitor()
    }
}
