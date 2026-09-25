import AppKit
import Combine
import SwiftUI

@MainActor
final class VoiceTransformWindowController: NSObject, NSWindowDelegate {
    private let coordinator: VoiceTransformCoordinator
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    private var layoutSize: NSSize?
    private let defaults: UserDefaults
    private var preferenceSubscriptions = Set<AnyCancellable>()
    private var displayedState: VoiceTransformCoordinator.State = .idle

    init(coordinator: VoiceTransformCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
        super.init()
        // @Published emits in willSet. AppKit resizing can synchronously render
        // the hosting view (and pump its animation loop), so doing it in that
        // callback makes SwiftUI read the previous state and miss the final one.
        subscription = coordinator.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            // A cancellation or a new session may supersede a queued layout.
            guard let self, state == coordinator.state else { return }
            displayedState = state
            if state == .idle { panel?.orderOut(nil) }
            else {
                if state == .starting { layoutSize = nil }
                resize(for: state)
            }
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, panel?.isVisible == true else { return }
                resize(for: displayedState)
            }
            .store(in: &preferenceSubscriptions)
        NotificationCenter.default.publisher(for: VoiceTransformWindowPreferences.resetNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                layoutSize = nil
                resize(for: displayedState)
            }
            .store(in: &preferenceSubscriptions)
    }

    func show() {
        if panel == nil {
            let window = VoiceTransformPanel(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 420, height: 180)),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            window.title = "Voice Transform"
            window.level = .floating
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 380, height: 160)
            window.contentView = NSHostingView(rootView: VoiceTransformView(coordinator: coordinator))
            window.delegate = self
            window.center()
            panel = window
        }
        resize(for: coordinator.state)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func resize(for state: VoiceTransformCoordinator.State) {
        guard let panel else { return }
        let size = VoiceTransformWindowPreferences.size(for: state, defaults: defaults)
        guard layoutSize != size else { return }
        layoutSize = size
        panel.contentMinSize = NSSize(width: 380, height: size.height == 180 ? 160 : 280)
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: panel.frame.midX - frame.width / 2, y: panel.frame.maxY - frame.height)
        if let screen = panel.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.size.height = min(frame.height, screen.height)
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
            frame.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
        }
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard displayedState == .preview, let panel,
              VoiceTransformWindowPreferences.remembersSize(defaults) else { return }
        let size = panel.contentRect(forFrameRect: panel.frame).size
        layoutSize = size
        VoiceTransformWindowPreferences.saveReviewSize(size, to: defaults)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard coordinator.state != .applying else { return false }
        coordinator.cancel()
        return true
    }
}

private final class VoiceTransformPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct VoiceTransformView: View {
    @ObservedObject var coordinator: VoiceTransformCoordinator
    @State private var showsDetails = false

    private var isReviewing: Bool {
        coordinator.state == .preview || coordinator.state == .applying || coordinator.state == .failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(status).font(.headline)
                Spacer()
                if coordinator.isBusy { ProgressView().controlSize(.small) }
            }
            if let error = coordinator.errorMessage {
                ScrollView {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: coordinator.state == .failed ? 100 : 44)
            }
            if isReviewing && !coordinator.original.isEmpty {
                DisclosureGroup("Instruction and original", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Instruction").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $coordinator.instruction)
                            .frame(height: 60)
                            .disabled(coordinator.isBusy)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        if !coordinator.matchedTriggers.isEmpty {
                            Text("Applied: " + coordinator.matchedTriggers.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            Text(coordinator.original).font(.callout).foregroundStyle(.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 70)
                    }.padding(.top, 4)
                }
                if !coordinator.result.isEmpty && coordinator.instruction != coordinator.generatedInstruction {
                    Text("Instruction changed. Retry to update the result before replacing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !coordinator.result.isEmpty {
                    textPane("Result", text: coordinator.result)
                }
                if !coordinator.diff.isEmpty {
                    DisclosureGroup("Changes") {
                        ScrollView { diffText.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 120)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(coordinator.state == .applying || coordinator.state == .cancelling)
                Spacer()
                if coordinator.state == .recording {
                    Button("Stop and preview") { coordinator.finishRecording() }
                        .keyboardShortcut(.defaultAction)
                } else if isReviewing && !coordinator.original.isEmpty {
                    Button("Retry") { coordinator.retry() }
                        .disabled(coordinator.isBusy || coordinator.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coordinator.result, forType: .string)
                    }.disabled(coordinator.result.isEmpty || coordinator.isBusy)
                    Button("Replace") { coordinator.apply() }
                        .disabled(!coordinator.canApply)
                }
            }
        }
        .padding(16)
        .onChange(of: coordinator.state) { _, state in
            if state == .starting { showsDetails = false }
            if state == .failed && !coordinator.instruction.isEmpty { showsDetails = true }
        }
    }

    private func textPane(_ title: String, text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ScrollView {
                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var diffText: Text {
        coordinator.diff.reduce(Text("")) { result, segment in
            switch segment {
            case .unchanged(let text): result + Text(text + " ")
            case .removed(let text): result + Text(text + " ").foregroundColor(.red).strikethrough()
            case .added(let text): result + Text(text + " ").foregroundColor(.green).underline()
            }
        }
    }

    private var status: String {
        switch coordinator.state {
        case .idle: "Voice Transform"
        case .starting: "Starting microphone…"
        case .recording: "Describe your change…"
        case .transcribing: "Transcribing instruction…"
        case .generating: "Rewriting with your LLM…"
        case .preview: "Review your rewrite"
        case .applying: "Checking and replacing selection…"
        case .cancelling: "Cancelling…"
        case .failed: "Transform needs attention"
        }
    }
}
