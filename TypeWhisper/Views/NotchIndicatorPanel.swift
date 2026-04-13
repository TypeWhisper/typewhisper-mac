import AppKit
import SwiftUI
import Combine

/// Observable notch geometry passed from the panel to the SwiftUI view.
@MainActor
final class NotchGeometry: ObservableObject {
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = NotchIndicatorLayout.notchedClosedHeight
    @Published var hasNotch: Bool = false
    @Published var isPresented: Bool = false

    func update(for screen: NSScreen) {
        hasNotch = screen.safeAreaInsets.top > 0
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - left - right + 4
        } else {
            notchWidth = 0
        }
        notchHeight = NotchIndicatorLayout.closedHeight(hasNotch: hasNotch)
    }
}

/// Hosting view that accepts first mouse click without requiring a prior activation click.
private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panel that visually extends the MacBook notch, centered over the hardware notch.
/// Only shown on displays with a hardware notch - hidden on non-notch displays regardless of settings.
class NotchIndicatorPanel: NSPanel {
    /// Large enough to accommodate the expanded (open) state. SwiftUI clips the visible area.
    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 500
    private static let presentationAnimationDuration: Duration = .milliseconds(220)

    private let notchGeometry = NotchGeometry()
    private var cancellables = Set<AnyCancellable>()
    private var cachedScreen: NSScreen?
    private var showTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        let hostingView = FirstMouseHostingView(rootView: NotchIndicatorView(geometry: notchGeometry))
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func startObserving() {
        let vm = DictationViewModel.shared

        vm.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateVisibility(state: state, vm: vm)
            }
            .store(in: &cancellables)

        vm.$notchIndicatorVisibility
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(state: vm.state, vm: vm)
            }
            .store(in: &cancellables)

        vm.$notchIndicatorDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cachedScreen = nil
                self?.updateVisibility(state: vm.state, vm: vm)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.orderFrontRegardless()
            }
            .store(in: &cancellables)
    }

    func updateVisibility(state: DictationViewModel.State, vm: DictationViewModel) {
        guard vm.indicatorStyle == .notch else {
            dismiss()
            return
        }

        switch vm.notchIndicatorVisibility {
        case .always:
            show()
        case .duringActivity:
            switch state {
            case .recording, .processing, .inserting, .error:
                show()
            case .idle, .promptSelection, .promptProcessing:
                dismiss()
            }
        case .never:
            dismiss()
        }
    }

    // MARK: - Notch geometry

    func show() {
        showTask?.cancel()
        dismissTask?.cancel()

        let screen: NSScreen
        if let cached = cachedScreen, isVisible {
            screen = cached
        } else {
            screen = resolveScreen()
            cachedScreen = screen
        }
        notchGeometry.update(for: screen)

        let screenFrame = screen.frame
        let x = screenFrame.midX - Self.panelWidth / 2
        let y = screenFrame.origin.y + screenFrame.height - Self.panelHeight

        let wasVisible = isVisible
        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: true)
        orderFrontRegardless()

        guard !wasVisible else {
            if !notchGeometry.isPresented {
                withAnimation(.easeOut(duration: 0.22)) {
                    notchGeometry.isPresented = true
                }
            }
            return
        }

        notchGeometry.isPresented = false
        showTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                self.notchGeometry.isPresented = true
            }
            self.showTask = nil
        }
    }

    private func resolveScreen() -> NSScreen {
        let display = DictationViewModel.shared.notchIndicatorDisplay
        switch display {
        case .activeScreen:
            let mouseLocation = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        case .primaryScreen:
            return NSScreen.main ?? NSScreen.screens[0]
        case .builtInScreen:
            return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        }
    }

    func dismiss() {
        cachedScreen = nil
        showTask?.cancel()
        showTask = nil
        dismissTask?.cancel()

        guard isVisible else {
            notchGeometry.isPresented = false
            orderOut(nil)
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            notchGeometry.isPresented = false
        }

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.presentationAnimationDuration)
            guard !Task.isCancelled else { return }
            guard let self, !self.notchGeometry.isPresented else { return }
            self.orderOut(nil)
            self.dismissTask = nil
        }
    }
}
