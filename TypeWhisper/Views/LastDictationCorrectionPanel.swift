import AppKit
import SwiftUI

/// Shows Correct Last Dictation in floating panels in the style of the recent transcriptions
/// palette. The editor takes the keyboard without activating TypeWhisper, so the app the user
/// came from stays frontmost. The result then appears in a panel that does not take the
/// keyboard, so the corrected text can be pasted right away.
@MainActor
final class LastDictationCorrectionPanelController: LastDictationCorrectionPresenting {
    private var editorPanel: LastDictationCorrectionPanel?
    private var editorModel: LastDictationCorrectionEditorModel?
    private var resultPanel: LastDictationCorrectionPanel?
    private var resultDismissTask: Task<Void, Never>?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private let resultDisplayDuration: Duration

    init(resultDisplayDuration: Duration = .seconds(5)) {
        self.resultDisplayDuration = resultDisplayDuration
    }

    var isEditorVisible: Bool { editorPanel != nil }

    func showEditor(
        for target: LastDictationCorrectionTarget,
        learningAvailability: CorrectionLearningAvailability,
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        hide()

        let model = LastDictationCorrectionEditorModel(
            target: target,
            learningAvailability: learningAvailability,
            onConfirm: onConfirm,
            onCancel: onCancel
        )
        let panel = LastDictationCorrectionPanel(allowsKey: true)
        // Borderless panels have no visible title; VoiceOver still names the window by it.
        panel.title = String(localized: "Correct Last Dictation")
        panel.onSubmit = { [weak model] in model?.confirm() }
        panel.onCancel = { [weak model] in model?.cancel() }
        install(LastDictationCorrectionEditorView(model: model), in: panel)
        panel.positionOnActiveScreen()

        editorPanel = panel
        editorModel = model
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors(onOutsideClick: { [weak model] in model?.cancel() })
    }

    func showConfirmation(_ confirmation: LastDictationCorrectionConfirmation) {
        showResult(.confirmation(confirmation))
    }

    func showNotice(_ message: String) {
        showResult(.notice(message))
    }

    func hide() {
        removeClickMonitors()
        closeEditorPanel()
        closeResultPanel()
    }

    private func showResult(_ content: LastDictationCorrectionResultContent) {
        removeClickMonitors()
        closeResultPanel()

        let panel = LastDictationCorrectionPanel(allowsKey: false)
        panel.title = String(localized: "Correct Last Dictation")
        let size = install(
            LastDictationCorrectionResultView(content: content) { [weak self] in
                self?.dismissResult()
            },
            in: panel
        )
        if let editorFrame = editorPanel?.frame {
            // Takes the editor's place, aligned to its top edge.
            panel.setFrameOrigin(NSPoint(
                x: editorFrame.midX - size.width / 2,
                y: editorFrame.maxY - size.height
            ))
        } else {
            panel.positionOnActiveScreen()
        }

        // Shown before the editor closes, so the result replaces it without a gap. Closing the
        // editor returns the keyboard to the app the user came from.
        panel.orderFrontRegardless()
        resultPanel = panel
        closeEditorPanel()
        installClickMonitors(onOutsideClick: { [weak self] in self?.dismissResult() })

        let duration = resultDisplayDuration
        resultDismissTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, let panel, self.resultPanel === panel else { return }
            self.dismissResult()
        }
    }

    private func dismissResult() {
        removeClickMonitors()
        closeResultPanel()
    }

    /// Shows `view` at its ideal size and returns that size. The panel keeps it; SwiftUI does
    /// not resize the window afterwards.
    @discardableResult
    private func install<Content: View>(_ view: Content, in panel: LastDictationCorrectionPanel) -> NSSize {
        let hosting = NSHostingView(rootView: view)
        // Measured while SwiftUI still reports its sizes, which `sizingOptions = []` turns off.
        let size = hosting.fittingSize
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        return size
    }

    private func closeEditorPanel() {
        editorPanel?.onSubmit = nil
        editorPanel?.onCancel = nil
        editorPanel?.orderOut(nil)
        editorPanel = nil
        editorModel = nil
    }

    private func closeResultPanel() {
        resultDismissTask?.cancel()
        resultDismissTask = nil
        resultPanel?.orderOut(nil)
        resultPanel = nil
    }

    /// A click elsewhere closes the panels, like the palettes.
    private func installClickMonitors(onOutsideClick: @escaping @MainActor () -> Void) {
        removeClickMonitors()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let location = NSEvent.mouseLocation
            let isInsidePanel = [self.editorPanel, self.resultPanel].contains { panel in
                panel?.frame.contains(location) == true
            }
            if !isInsidePanel {
                onOutsideClick()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            onOutsideClick()
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }
}

@MainActor
final class LastDictationCorrectionEditorModel: ObservableObject {
    let target: LastDictationCorrectionTarget
    let learningAvailability: CorrectionLearningAvailability
    /// App and time of the dictation, such as "Mail • 2 min. ago".
    let subtitle: String
    @Published var text: String

    private let onConfirm: @MainActor (String) -> Void
    private let onCancel: @MainActor () -> Void

    init(
        target: LastDictationCorrectionTarget,
        learningAvailability: CorrectionLearningAvailability,
        now: Date = Date(),
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.target = target
        self.learningAvailability = learningAvailability
        self.subtitle = Self.subtitle(for: target, now: now)
        self.text = target.finalText
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    private static func subtitle(for target: LastDictationCorrectionTarget, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relativeTime = formatter.localizedString(for: target.timestamp, relativeTo: now)
        guard let appName = target.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appName.isEmpty else {
            return relativeTime
        }
        return "\(appName) • \(relativeTime)"
    }

    var canConfirm: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func confirm() {
        guard canConfirm else {
            NSSound.beep()
            return
        }
        onConfirm(text)
    }

    func cancel() {
        onCancel()
    }
}

private struct LastDictationCorrectionEditorView: View {
    @ObservedObject var model: LastDictationCorrectionEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            LastDictationCorrectionTextView(
                text: $model.text,
                accessibilityLabel: String(localized: "correctLastDictation.editor.label"),
                accessibilityHint: String(localized: "correctLastDictation.editor.hint"),
                onSubmit: { model.confirm() },
                onCancel: { model.cancel() }
            )
            .frame(height: 112)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )

            if let rawText = model.target.rawText {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "correctLastDictation.original"))
                        .font(.caption.weight(.semibold))
                    Text(rawText)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if let learningHint = LastDictationCorrectionCopy.learningHint(for: model.learningAvailability) {
                Label {
                    Text(learningHint)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: learningHintIcon)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(String(localized: "correctLastDictation.keyboardHint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    // Longer translations wrap instead of being cut off next to the buttons.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // The text view's hint already gives the keys to VoiceOver.
                    .accessibilityHidden(true)

                Spacer(minLength: 8)

                Button(String(localized: "Cancel")) {
                    model.cancel()
                }

                Button(String(localized: "correctLastDictation.confirm")) {
                    model.confirm()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canConfirm)
            }
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "pencil.line")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(String(localized: "Correct Last Dictation"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(model.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var learningHintIcon: String {
        switch model.learningAvailability {
        case .available, .turnedOff, .notOffered: "book.closed"
        case .requiresLicense: "lock"
        }
    }
}

enum LastDictationCorrectionResultContent: Equatable {
    case confirmation(LastDictationCorrectionConfirmation)
    case notice(String)
}

private struct LastDictationCorrectionResultView: View {
    let content: LastDictationCorrectionResultContent
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }

    private var title: String {
        switch content {
        case .confirmation(let confirmation):
            LastDictationCorrectionCopy.title(for: confirmation)
        case .notice(let message):
            message
        }
    }

    private var detail: String? {
        switch content {
        case .confirmation(let confirmation):
            LastDictationCorrectionCopy.learningDetail(for: confirmation.learning)
        case .notice:
            nil
        }
    }

    private var icon: String {
        switch content {
        case .confirmation(let confirmation):
            confirmation.learning == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .notice:
            "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch content {
        case .confirmation(let confirmation):
            confirmation.learning == .failed ? .orange : .green
        case .notice:
            .secondary
        }
    }
}

/// A plain-text editor for the dictation. Return confirms, Shift-Return or Option-Return adds a
/// line, and Escape cancels. Keys go through the text system first, so an input method can
/// still use Return and Escape to finish or cancel its composition.
private struct LastDictationCorrectionTextView: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let textView = LastDictationCorrectionNSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 7)
        // Dictated text is corrected by hand; nothing should change it unasked.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHint)
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LastDictationCorrectionTextView

        init(_ parent: LastDictationCorrectionTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab moves to the buttons instead of adding a tab to the dictation.
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }
    }
}

private final class LastDictationCorrectionNSTextView: NSTextView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Typing can start right away, with the caret after the dictation.
        if let window, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
    }
}

private final class LastDictationCorrectionPanel: NSPanel {
    private let allowsKey: Bool
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    init(allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Command-Return confirms wherever the keyboard focus is, like the other editors.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.type == .keyDown, isReturn, modifiers == .command, let onSubmit {
            onSubmit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Return and Escape while a button, not the text, has the keyboard focus.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, modifiers.isEmpty {
            onSubmit?()
        } else if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func positionOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY + 60
        ))
    }
}
