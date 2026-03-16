import AppKit
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - PluginHotkey

struct PluginHotkey: Codable, Equatable {
    let keyCode: UInt16
    let modifierFlags: UInt
}

// MARK: - Plugin Entry Point

@objc(LiveTranscriptPlugin)
final class LiveTranscriptPlugin: NSObject, TypeWhisperPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.livetranscript"
    static let pluginName = "Live Transcript"

    fileprivate var host: HostServices?
    private var subscriptionId: UUID?
    private var panel: LiveTranscriptPanel?
    private var viewModel: LiveTranscriptViewModel?
    private var autoCloseTask: Task<Void, Never>?

    fileprivate var _autoOpen: Bool = true
    fileprivate var _fontSize: Double = 14.0
    private let pauseThreshold: Double = 2.0
    private let autoCloseDelay: Double = 4.0

    fileprivate var toggleHotkey: PluginHotkey?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotkeyIsDown: Bool = false

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _autoOpen = host.userDefault(forKey: "autoOpen") as? Bool ?? true
        _fontSize = host.userDefault(forKey: "fontSize") as? Double ?? 14.0

        if let data = host.userDefault(forKey: "toggleHotkey") as? Data {
            toggleHotkey = try? JSONDecoder().decode(PluginHotkey.self, from: data)
        }
        setupHotkeyMonitor()

        subscriptionId = host.eventBus.subscribe { [weak self] event in
            await self?.handleEvent(event)
        }
    }

    func deactivate() {
        if let id = subscriptionId {
            host?.eventBus.unsubscribe(id: id)
            subscriptionId = nil
        }
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

    // MARK: - Event Handling

    @MainActor
    private func handleEvent(_ event: TypeWhisperEvent) {
        switch event {
        case .recordingStarted:
            autoCloseTask?.cancel()
            if _autoOpen { showPanel() }
            viewModel?.reset()

        case .partialTranscriptionUpdate(let payload):
            viewModel?.updateText(payload.text, pauseThreshold: pauseThreshold)
            if payload.isFinal { scheduleAutoClose() }

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
            let vm = viewModel ?? LiveTranscriptViewModel()
            viewModel = vm
            panel = LiveTranscriptPanel(viewModel: vm, fontSize: _fontSize)
        }
        panel?.orderFront(nil)
    }

    @MainActor
    private func togglePanel() {
        autoCloseTask?.cancel()
        if let panel, panel.isVisible {
            panel.close()
            self.panel = nil
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

    private var previousFullText: String = ""
    private var lastTextChangeTimestamp: Date = Date()

    struct TranscriptParagraph: Identifiable {
        let id = UUID()
        var text: String
    }

    func reset() {
        paragraphs = []
        previousFullText = ""
        lastTextChangeTimestamp = Date()
    }

    func updateText(_ fullText: String, pauseThreshold: Double) {
        let now = Date()
        let timeSinceLastChange = now.timeIntervalSince(lastTextChangeTimestamp)

        guard fullText != previousFullText else { return }

        if fullText.hasPrefix(previousFullText) {
            let newContent = String(fullText.dropFirst(previousFullText.count))
                .trimmingCharacters(in: .whitespaces)
            guard !newContent.isEmpty else {
                previousFullText = fullText
                return
            }

            if timeSinceLastChange >= pauseThreshold && !paragraphs.isEmpty {
                paragraphs.append(TranscriptParagraph(text: newContent))
            } else if !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1].text += " " + newContent
            } else {
                paragraphs.append(TranscriptParagraph(text: newContent))
            }
        } else if paragraphs.isEmpty {
            paragraphs.append(TranscriptParagraph(text: fullText.trimmingCharacters(in: .whitespaces)))
        } else {
            let stableText = paragraphs.dropLast().map(\.text).joined(separator: " ")
            if fullText.hasPrefix(stableText) {
                paragraphs[paragraphs.count - 1].text = String(fullText.dropFirst(stableText.count))
                    .trimmingCharacters(in: .whitespaces)
            } else {
                paragraphs = [TranscriptParagraph(text: fullText.trimmingCharacters(in: .whitespaces))]
            }
        }

        lastTextChangeTimestamp = now
        previousFullText = fullText
    }
}

// MARK: - Panel

final class LiveTranscriptPanel: NSPanel {
    init(viewModel: LiveTranscriptViewModel, fontSize: Double) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
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
        minSize = NSSize(width: 250, height: 150)
        animationBehavior = .utilityWindow
        setFrameAutosaveName("LiveTranscriptPanel")

        let hostingView = NSHostingView(rootView: LiveTranscriptView(viewModel: viewModel, fontSize: fontSize))
        hostingView.sizingOptions = []
        contentView = hostingView

        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Main View

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    let fontSize: Double

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.paragraphs) { paragraph in
                        Text(paragraph.text)
                            .font(.system(size: CGFloat(fontSize)))
                            .foregroundStyle(.white.opacity(0.85))
                            .id(paragraph.id)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            .onChange(of: viewModel.paragraphs.last?.text) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.paragraphs.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.92))
        )
    }
}

// MARK: - Settings View

private struct LiveTranscriptSettingsView: View {
    let plugin: LiveTranscriptPlugin
    @State private var autoOpen: Bool = true
    @State private var fontSize: Double = 14.0
    @State private var currentHotkey: PluginHotkey?
    @State private var isRecording: Bool = false
    private let bundle = Bundle(for: LiveTranscriptPlugin.self)

    var body: some View {
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
                plugin._autoOpen = newValue
                plugin.host?.setUserDefault(newValue, forKey: "autoOpen")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Font size", bundle: bundle)
                    .font(.headline)
                HStack {
                    Slider(value: $fontSize, in: 10...24, step: 1)
                        .onChange(of: fontSize) { _, newValue in
                            plugin._fontSize = newValue
                            plugin.host?.setUserDefault(newValue, forKey: "fontSize")
                        }
                    Text("\(Int(fontSize))pt")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
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
        .onAppear {
            autoOpen = plugin._autoOpen
            fontSize = plugin._fontSize
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
