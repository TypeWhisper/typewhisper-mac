import AppKit
import SwiftUI
import Translation

/// Dedicated off-screen window hosting the `.translationTask` modifier.
///
/// The overlay panel uses `orderOut(nil)` which can pause SwiftUI updates,
/// preventing `.translationTask` from firing. This host window is kept
/// ordered-in off-screen and is moved on-screen only when Translation.framework
/// requires user interaction (e.g. language-pack approval/download).
@MainActor
final class TranslationHostWindow: NSWindow {
    private let offscreenRect = NSRect(x: -9999, y: -9999, width: 1, height: 1)
    private var isInteractiveMode = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(translationService: TranslationService) {
        super.init(
            contentRect: offscreenRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        alphaValue = 0.0
        level = .init(rawValue: Int(CGWindowLevelForKey(.minimumWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        contentView = NSHostingView(
            rootView: TranslationHostView(translationService: translationService)
        )

        orderFrontRegardless()
    }

    /// Temporarily move host on-screen and make it key so Translation.framework
    /// can present user-action/download UI for not-installed language packs.
    func setInteractiveMode(_ enabled: Bool) {
        guard isInteractiveMode != enabled else { return }
        isInteractiveMode = enabled
        DispatchQueue.main.async { [weak self] in
            self?.applyInteractiveMode(enabled)
        }
    }

    private func applyInteractiveMode(_ enabled: Bool) {
        if enabled {
            let targetFrame = interactiveRect()
            ignoresMouseEvents = true
            alphaValue = 0.001
            level = .floating
            if !frame.equalTo(targetFrame) {
                setFrame(targetFrame, display: false)
            }
            makeKeyAndOrderFront(nil)
        } else {
            let targetFrame = offscreenRect
            ignoresMouseEvents = true
            alphaValue = 0.0
            level = .init(rawValue: Int(CGWindowLevelForKey(.minimumWindow)) - 1)
            if !frame.equalTo(targetFrame) {
                setFrame(targetFrame, display: false)
            }
            orderFrontRegardless()
        }
    }

    private func interactiveRect() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 40, y: 40, width: 1, height: 1)
        }
        let frame = screen.visibleFrame
        return NSRect(
            x: frame.midX,
            y: frame.midY,
            width: 1,
            height: 1
        )
    }
}

/// Minimal SwiftUI view that observes TranslationService and hosts `.translationTask`.
/// Using `@ObservedObject` ensures the view re-renders when `configuration` changes,
/// which is required for `.translationTask` to fire.
private struct TranslationHostView: View {
    @ObservedObject var translationService: TranslationService

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(translationService.configuration) { session in
                await translationService.handleSession(session)
            }
            .id(translationService.viewId)
    }
}
