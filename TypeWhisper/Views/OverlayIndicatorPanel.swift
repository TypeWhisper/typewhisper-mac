import AppKit
import SwiftUI
import Combine

/// Floating panel for the Overlay Indicator mode.
class OverlayIndicatorPanel: NSPanel {
    private static let panelWidth: CGFloat = 500
    private static let panelHeight: CGFloat = 300

    private let screenResolver: IndicatorScreenResolver
    private var cancellables = Set<AnyCancellable>()
    private var cachedScreen: NSScreen?

    init(screenResolver: IndicatorScreenResolver) {
        self.screenResolver = screenResolver
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
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        FloatingPanelSpacePolicy.applyIndicatorPolicy(
            to: self,
            displayMode: DictationViewModel.shared.notchIndicatorDisplay
        )

        let hostingView = NSHostingView(rootView: OverlayIndicatorView())
        hostingView.sizingOptions = []
        contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func startObserving() {
        let vm = DictationViewModel.shared
        let recorder = AudioRecorderViewModel.shared

        vm.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        recorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        vm.$notchIndicatorVisibility
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        vm.$notchIndicatorDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cachedScreen = nil
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)

        vm.$overlayPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.show()
            }
            .store(in: &cancellables)
    }

    func updateVisibility(
        vm: DictationViewModel = DictationViewModel.shared,
        recorder: AudioRecorderViewModel = AudioRecorderViewModel.shared
    ) {
        guard vm.indicatorStyle == .overlay else {
            dismiss()
            return
        }

        let presentation = IndicatorPresentationState.resolve(
            dictationState: vm.state,
            recorderState: recorder.state
        )
        if IndicatorPresentationState.shouldShow(
            visibility: vm.notchIndicatorVisibility,
            presentation: presentation
        ) {
            show()
        } else {
            dismiss()
        }
    }

    func show() {
        let screen: NSScreen
        if let cached = cachedScreen, isVisible {
            screen = cached
        } else {
            screen = resolveScreen()
            cachedScreen = screen
        }

        let overlayPosition = DictationViewModel.shared.overlayPosition
        let placement: IndicatorPlacement = overlayPosition == .top ? .notchStrip : .nonNotchArea
        if IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(on: screen, placement: placement) {
            suppressForForeignFullscreen()
            return
        }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - Self.panelWidth / 2

        let y: CGFloat
        switch overlayPosition {
        case .bottom:
            y = screenFrame.origin.y + 20
        case .top:
            // Position below menu bar area, like a taskbar
            y = screenFrame.origin.y + screenFrame.height - Self.panelHeight - 20
        }

        setFrame(NSRect(x: x, y: y, width: Self.panelWidth, height: Self.panelHeight), display: true)
        FloatingPanelSpacePolicy.orderIndicatorFront(
            self,
            displayMode: DictationViewModel.shared.notchIndicatorDisplay
        )
    }

    private func suppressForForeignFullscreen() {
        cachedScreen = nil
        orderOut(nil)
    }

    private func resolveScreen() -> NSScreen {
        screenResolver.resolveScreen(for: DictationViewModel.shared.notchIndicatorDisplay)
    }

    func refreshPlacementForActiveContextChange() {
        guard isVisible else { return }
        if DictationViewModel.shared.notchIndicatorDisplay == .activeScreen {
            cachedScreen = nil
        }
        show()
    }

    func dismiss() {
        cachedScreen = nil
        orderOut(nil)
    }
}
