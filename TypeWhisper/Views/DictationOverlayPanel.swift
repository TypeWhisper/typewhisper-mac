import AppKit
import SwiftUI
import Combine

/// Floating non-activating panel that shows dictation status.
/// Uses a fixed frame size — all layout changes happen inside SwiftUI.
class DictationOverlayPanel: NSPanel {
    private static let panelWidth: CGFloat = 340
    private static let panelHeight: CGFloat = 160

    private var stateObservation: AnyCancellable?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isMovableByWindowBackground = false

        let hostingView = NSHostingView(rootView: DictationOverlayView())
        contentView = hostingView
    }

    func startObserving() {
        let vm = DictationViewModel.shared

        stateObservation = vm.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .recording, .processing, .inserting, .copiedToClipboard, .error:
                    self?.show()
                case .idle:
                    self?.dismiss()
                }
            }
    }

    func show() {
        guard !isVisible else { return }

        let vm = DictationViewModel.shared

        // Find the screen where the mouse currently is
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        let x = screenFrame.midX - Self.panelWidth / 2

        let y: CGFloat
        switch vm.overlayPosition {
        case .top:
            y = screenFrame.maxY - Self.panelHeight - 8
        case .bottom:
            y = screenFrame.minY + 8
        }

        setFrameOrigin(CGPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }
}
