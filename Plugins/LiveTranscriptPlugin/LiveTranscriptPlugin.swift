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

    // Settings (cached from UserDefaults)
    fileprivate var _autoOpen: Bool = true
    fileprivate var _autoCloseDelay: Double = 4.0
    fileprivate var _pauseThreshold: Double = 2.0
    fileprivate var _fontSize: Double = 14.0

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        loadSettings()

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

    // MARK: - Settings Persistence

    fileprivate func loadSettings() {
        _autoOpen = host?.userDefault(forKey: "autoOpen") as? Bool ?? true
        _autoCloseDelay = host?.userDefault(forKey: "autoCloseDelay") as? Double ?? 4.0
        _pauseThreshold = host?.userDefault(forKey: "pauseThreshold") as? Double ?? 2.0
        _fontSize = host?.userDefault(forKey: "fontSize") as? Double ?? 14.0
    }

    fileprivate func saveSetting(_ value: Any, forKey key: String) {
        host?.setUserDefault(value, forKey: key)
    }

    // MARK: - Event Handling

    @MainActor
    private func handleEvent(_ event: TypeWhisperEvent) {
        switch event {
        case .recordingStarted:
            autoCloseTask?.cancel()
            if _autoOpen {
                showPanel()
            }
            viewModel?.reset()

        case .partialTranscriptionUpdate(let payload):
            viewModel?.updateText(payload.text, elapsedSeconds: payload.elapsedSeconds, pauseThreshold: _pauseThreshold)
            if payload.isFinal {
                scheduleAutoClose()
            }

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
            let p = LiveTranscriptPanel(viewModel: vm, fontSize: _fontSize)
            panel = p

            // Restore saved frame
            if let x = host?.userDefault(forKey: "windowX") as? Double,
               let y = host?.userDefault(forKey: "windowY") as? Double,
               let w = host?.userDefault(forKey: "windowWidth") as? Double,
               let h = host?.userDefault(forKey: "windowHeight") as? Double {
                p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
            }

            p.onFrameChange = { [weak self] frame in
                self?.saveSetting(Double(frame.origin.x), forKey: "windowX")
                self?.saveSetting(Double(frame.origin.y), forKey: "windowY")
                self?.saveSetting(Double(frame.size.width), forKey: "windowWidth")
                self?.saveSetting(Double(frame.size.height), forKey: "windowHeight")
            }
        }
        panel?.orderFront(nil)
    }

    @MainActor
    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        let delay = _autoCloseDelay
        autoCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.panel?.close()
            self?.panel = nil
            self?.viewModel = nil
        }
    }
}

// MARK: - Transcript Data Model

struct TranscriptParagraph: Identifiable {
    let id = UUID()
    var text: String
    let startTime: Date
}

// MARK: - ViewModel

@MainActor
final class LiveTranscriptViewModel: ObservableObject {
    @Published var paragraphs: [TranscriptParagraph] = []
    @Published var isAutoScrollEnabled: Bool = true
    @Published var searchQuery: String = ""
    @Published var isSearchVisible: Bool = false
    @Published var currentMatchIndex: Int = 0

    private var previousFullText: String = ""
    private var lastTextChangeTimestamp: Date = Date()

    func reset() {
        paragraphs = []
        previousFullText = ""
        lastTextChangeTimestamp = Date()
        isAutoScrollEnabled = true
        searchQuery = ""
        isSearchVisible = false
        currentMatchIndex = 0
    }

    func updateText(_ fullText: String, elapsedSeconds: Double, pauseThreshold: Double) {
        let now = Date()
        let timeSinceLastChange = now.timeIntervalSince(lastTextChangeTimestamp)

        guard fullText != previousFullText else { return }

        if fullText.hasPrefix(previousFullText) {
            // New content appended
            let newContent = String(fullText.dropFirst(previousFullText.count))
            guard !newContent.trimmingCharacters(in: .whitespaces).isEmpty else {
                previousFullText = fullText
                return
            }

            if timeSinceLastChange >= pauseThreshold && !paragraphs.isEmpty {
                // Speech pause detected - start new paragraph
                paragraphs.append(TranscriptParagraph(
                    text: newContent.trimmingCharacters(in: .whitespaces),
                    startTime: now
                ))
            } else if !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1].text += newContent
            } else {
                paragraphs.append(TranscriptParagraph(
                    text: newContent.trimmingCharacters(in: .whitespaces),
                    startTime: now
                ))
            }
        } else {
            // Text was corrected/restabilized - rebuild last paragraph
            if paragraphs.isEmpty {
                paragraphs.append(TranscriptParagraph(
                    text: fullText.trimmingCharacters(in: .whitespaces),
                    startTime: now
                ))
            } else {
                // Compute the stable prefix across all previous paragraphs except the last
                let stableText = paragraphs.dropLast().map(\.text).joined(separator: " ")
                if fullText.hasPrefix(stableText) {
                    let remainder = String(fullText.dropFirst(stableText.count))
                        .trimmingCharacters(in: .whitespaces)
                    paragraphs[paragraphs.count - 1].text = remainder
                } else {
                    // Full restabilization - reset to single paragraph
                    paragraphs = [TranscriptParagraph(
                        text: fullText.trimmingCharacters(in: .whitespaces),
                        startTime: now
                    )]
                }
            }
        }

        lastTextChangeTimestamp = now
        previousFullText = fullText
    }

    // MARK: - Search

    struct SearchMatch: Equatable {
        let paragraphIndex: Int
        let range: Range<String.Index>
    }

    var allMatches: [SearchMatch] {
        guard !searchQuery.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        let query = searchQuery.lowercased()
        for (i, paragraph) in paragraphs.enumerated() {
            let lower = paragraph.text.lowercased()
            var searchStart = lower.startIndex
            while let range = lower.range(of: query, range: searchStart..<lower.endIndex) {
                let originalRange = paragraph.text.index(range.lowerBound, offsetBy: 0)..<paragraph.text.index(range.upperBound, offsetBy: 0)
                matches.append(SearchMatch(paragraphIndex: i, range: originalRange))
                searchStart = range.upperBound
            }
        }
        return matches
    }

    func nextMatch() {
        let matches = allMatches
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
    }

    func previousMatch() {
        let matches = allMatches
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
    }
}

// MARK: - Panel

final class LiveTranscriptPanel: NSPanel {
    var onFrameChange: ((NSRect) -> Void)?

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

        let hostingView = NSHostingView(rootView: LiveTranscriptView(viewModel: viewModel, fontSize: fontSize))
        hostingView.sizingOptions = []
        contentView = hostingView

        center()

        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSWindow.didResizeNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange),
            name: NSWindow.didMoveNotification, object: self
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func frameDidChange() {
        onFrameChange?(frame)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Main View

struct LiveTranscriptView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    let fontSize: Double
    @State private var scrolledToBottom = true
    private let bundle = Bundle(for: LiveTranscriptPlugin.self)

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Live Transcript", bundle: bundle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                Spacer()

                // Search toggle
                Button {
                    viewModel.isSearchVisible.toggle()
                    if !viewModel.isSearchVisible {
                        viewModel.searchQuery = ""
                        viewModel.currentMatchIndex = 0
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(viewModel.isSearchVisible ? .white : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28) // Space for invisible titlebar
            .padding(.bottom, 8)

            // Search bar
            if viewModel.isSearchVisible {
                SearchBarView(viewModel: viewModel)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // Transcript content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(viewModel.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                            ParagraphView(
                                paragraph: paragraph,
                                paragraphIndex: index,
                                viewModel: viewModel,
                                fontSize: fontSize
                            )
                            .id(paragraph.id)
                        }

                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
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
                .onChange(of: viewModel.currentMatchIndex) {
                    let matches = viewModel.allMatches
                    guard !matches.isEmpty else { return }
                    let match = matches[viewModel.currentMatchIndex]
                    if match.paragraphIndex < viewModel.paragraphs.count {
                        withAnimation {
                            proxy.scrollTo(viewModel.paragraphs[match.paragraphIndex].id, anchor: .center)
                        }
                    }
                }
            }

            // Scroll-to-bottom button
            if !viewModel.isAutoScrollEnabled {
                Button {
                    viewModel.isAutoScrollEnabled = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10))
                        Text("Scroll to bottom", bundle: bundle)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.92))
        )
    }
}

// MARK: - Search Bar

private struct SearchBarView: View {
    @ObservedObject var viewModel: LiveTranscriptViewModel
    @FocusState private var isFocused: Bool
    private let bundle = Bundle(for: LiveTranscriptPlugin.self)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))

            TextField(String(localized: "Search...", bundle: bundle), text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onSubmit {
                    viewModel.nextMatch()
                }

            if !viewModel.searchQuery.isEmpty {
                let matches = viewModel.allMatches
                if !matches.isEmpty {
                    Text("\(viewModel.currentMatchIndex + 1)/\(matches.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .monospacedDigit()

                    Button { viewModel.previousMatch() } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Button { viewModel.nextMatch() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(String(localized: "No results", bundle: bundle))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }

                Button {
                    viewModel.searchQuery = ""
                    viewModel.currentMatchIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.08))
        )
        .onAppear {
            isFocused = true
        }
    }
}

// MARK: - Paragraph View

private struct ParagraphView: View {
    let paragraph: TranscriptParagraph
    let paragraphIndex: Int
    @ObservedObject var viewModel: LiveTranscriptViewModel
    let fontSize: Double

    var body: some View {
        let matches = viewModel.allMatches
        let query = viewModel.searchQuery
        let hasQuery = !query.isEmpty
        let paragraphMatches = matches.filter { $0.paragraphIndex == paragraphIndex }
        let hasParagraphMatch = !paragraphMatches.isEmpty
        let dimmed = hasQuery && !hasParagraphMatch

        if hasQuery && hasParagraphMatch {
            highlightedText(paragraph.text, matches: paragraphMatches, query: query)
                .font(.system(size: CGFloat(fontSize)))
                .opacity(1.0)
        } else {
            Text(paragraph.text)
                .font(.system(size: CGFloat(fontSize)))
                .foregroundStyle(.white.opacity(0.85))
                .opacity(dimmed ? 0.3 : 1.0)
        }
    }

    @ViewBuilder
    private func highlightedText(_ text: String, matches: [LiveTranscriptViewModel.SearchMatch], query: String) -> some View {
        let allMatches = viewModel.allMatches
        let currentMatch = allMatches.isEmpty ? nil : allMatches[viewModel.currentMatchIndex]

        let attributed = buildHighlightedString(
            text: text,
            matches: matches,
            currentMatch: currentMatch,
            paragraphIndex: paragraphIndex
        )
        Text(attributed)
    }

    private func buildHighlightedString(
        text: String,
        matches: [LiveTranscriptViewModel.SearchMatch],
        currentMatch: LiveTranscriptViewModel.SearchMatch?,
        paragraphIndex: Int
    ) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = .white.opacity(0.85)

        for match in matches.reversed() {
            guard let attrRange = Range(match.range, in: attributed) else { continue }
            let isCurrent = currentMatch.map { $0.paragraphIndex == paragraphIndex && $0.range == match.range } ?? false
            attributed[attrRange].backgroundColor = isCurrent ? .yellow : .yellow.opacity(0.4)
            attributed[attrRange].foregroundColor = .black
        }
        return attributed
    }
}

// MARK: - Settings View

private struct LiveTranscriptSettingsView: View {
    let plugin: LiveTranscriptPlugin
    @State private var autoOpen: Bool = true
    @State private var autoCloseDelay: Double = 4.0
    @State private var pauseThreshold: Double = 2.0
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
                plugin.saveSetting(newValue, forKey: "autoOpen")
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-close delay", bundle: bundle)
                    .font(.headline)
                Text("How long the window stays open after recording stops.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(value: $autoCloseDelay, in: 1...10, step: 0.5)
                        .onChange(of: autoCloseDelay) { _, newValue in
                            plugin._autoCloseDelay = newValue
                            plugin.saveSetting(newValue, forKey: "autoCloseDelay")
                        }
                    Text("\(autoCloseDelay, specifier: "%.1f")s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Pause threshold", bundle: bundle)
                    .font(.headline)
                Text("Minimum silence duration to start a new paragraph.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(value: $pauseThreshold, in: 0.5...5.0, step: 0.5)
                        .onChange(of: pauseThreshold) { _, newValue in
                            plugin._pauseThreshold = newValue
                            plugin.saveSetting(newValue, forKey: "pauseThreshold")
                        }
                    Text("\(pauseThreshold, specifier: "%.1f")s")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Font size", bundle: bundle)
                    .font(.headline)
                HStack {
                    Slider(value: $fontSize, in: 10...24, step: 1)
                        .onChange(of: fontSize) { _, newValue in
                            plugin._fontSize = newValue
                            plugin.saveSetting(newValue, forKey: "fontSize")
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
            autoCloseDelay = plugin._autoCloseDelay
            pauseThreshold = plugin._pauseThreshold
            fontSize = plugin._fontSize
        }
    }
}
