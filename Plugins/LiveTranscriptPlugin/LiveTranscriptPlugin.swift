import AppKit
import SwiftUI
import TypeWhisperPluginSDK

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

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _autoOpen = host.userDefault(forKey: "autoOpen") as? Bool ?? true
        _fontSize = host.userDefault(forKey: "fontSize") as? Double ?? 14.0

        subscriptionId = host.eventBus.subscribe { [weak self] event in
            await self?.handleEvent(event)
        }
    }

    func deactivate() {
        if let id = subscriptionId {
            host?.eventBus.unsubscribe(id: id)
            subscriptionId = nil
        }
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
            let vm = LiveTranscriptViewModel()
            viewModel = vm
            panel = LiveTranscriptPanel(viewModel: vm, fontSize: _fontSize)
        }
        panel?.orderFront(nil)
    }

    @MainActor
    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { @MainActor [weak self, autoCloseDelay] in
            try? await Task.sleep(for: .seconds(autoCloseDelay))
            guard !Task.isCancelled else { return }
            self?.panel?.close()
            self?.panel = nil
            self?.viewModel = nil
        }
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
        }
        .padding()
        .onAppear {
            autoOpen = plugin._autoOpen
            fontSize = plugin._fontSize
        }
    }
}
