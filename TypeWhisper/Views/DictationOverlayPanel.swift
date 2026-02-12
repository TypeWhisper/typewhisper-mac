import AppKit
import SwiftUI
import Combine

/// Floating non-activating panel that shows dictation status near the text cursor.
class DictationOverlayPanel: NSPanel {
    private var stateObservation: AnyCancellable?
    private var sizeObservation: AnyCancellable?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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
                case .recording, .processing, .inserting, .error:
                    self?.showNearCursor()
                case .idle:
                    self?.dismiss()
                }
            }

        // Resize panel when partial text appears/disappears
        sizeObservation = vm.$partialText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self, self.isVisible else { return }
                let hasText = !text.isEmpty && vm.state == .recording
                let newWidth: CGFloat = hasText ? 320 : 240
                let newHeight: CGFloat = hasText ? 140 : 52
                let origin = self.frame.origin
                self.setFrame(NSRect(x: origin.x, y: origin.y, width: newWidth, height: newHeight), display: true, animate: true)
            }
    }

    func showNearCursor() {
        guard !isVisible else { return }

        let position = cursorScreenPosition()
        let panelSize = frame.size

        // Position below and slightly right of cursor
        var origin = CGPoint(
            x: position.x + 8,
            y: position.y - panelSize.height - 8
        )

        // Ensure panel stays on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if origin.x + panelSize.width > screenFrame.maxX {
                origin.x = screenFrame.maxX - panelSize.width - 8
            }
            if origin.y < screenFrame.minY {
                origin.y = position.y + 24
            }
        }

        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
    }

    private func cursorScreenPosition() -> CGPoint {
        // Try AX-based cursor position first
        if let axPosition = ServiceContainer.shared.textInsertionService.focusedElementPosition() {
            // AX coordinates are top-left origin; convert to bottom-left for NSWindow
            if let screen = NSScreen.main {
                return CGPoint(x: axPosition.x, y: screen.frame.height - axPosition.y)
            }
            return axPosition
        }

        // Fallback to mouse position
        let mouseLocation = NSEvent.mouseLocation
        return mouseLocation
    }
}
