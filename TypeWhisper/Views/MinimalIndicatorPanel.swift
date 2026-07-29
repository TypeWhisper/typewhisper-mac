import AppKit
import SwiftUI
import Combine

private class MinimalFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating panel for the compact minimal indicator mode.
class MinimalIndicatorPanel: NSPanel {
    private let screenResolver: IndicatorScreenResolver
    private let displayModeProvider: () -> NotchIndicatorDisplay
    private let overlayPositionProvider: () -> OverlayPosition
    private let indicatorVisibleInScreenCapturesProvider: () -> Bool
    private var cancellables = Set<AnyCancellable>()
    private var cachedScreen: NSScreen?
    private var isFeedbackInteractive = false

    convenience init(screenResolver: IndicatorScreenResolver) {
        self.init(
            screenResolver: screenResolver,
            displayModeProvider: { DictationViewModel.shared.notchIndicatorDisplay },
            overlayPositionProvider: { DictationViewModel.shared.overlayPosition },
            indicatorVisibleInScreenCapturesProvider: {
                DictationViewModel.shared.indicatorVisibleInScreenCaptures
            },
            content: { MinimalIndicatorView() }
        )
    }

    init<Content: View>(
        screenResolver: IndicatorScreenResolver,
        displayModeProvider: @escaping () -> NotchIndicatorDisplay,
        overlayPositionProvider: @escaping () -> OverlayPosition,
        indicatorVisibleInScreenCapturesProvider: @escaping () -> Bool = { true },
        @ViewBuilder content: () -> Content
    ) {
        self.screenResolver = screenResolver
        self.displayModeProvider = displayModeProvider
        self.overlayPositionProvider = overlayPositionProvider
        self.indicatorVisibleInScreenCapturesProvider = indicatorVisibleInScreenCapturesProvider
        let initialSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .minimal,
            isFeedbackInteractive: false
        )
        super.init(
            contentRect: NSRect(origin: .zero, size: initialSize),
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
            displayMode: displayModeProvider(),
            windowLevel: FloatingPanelSpacePolicy.floatingIndicatorWindowLevel,
            isVisibleInScreenCaptures: indicatorVisibleInScreenCapturesProvider()
        )

        let hostingView = MinimalFirstMouseHostingView(rootView: content())
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

        vm.$indicatorVisibleInScreenCaptures
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisibleInScreenCaptures in
                guard let self else { return }
                FloatingPanelSpacePolicy.applyIndicatorCapturePolicy(
                    to: self,
                    isVisibleInScreenCaptures: isVisibleInScreenCaptures
                )
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(vm.$state, vm.$actionFeedbackMessage)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, message in
                self?.updateFeedbackInteraction(
                    isInteractive: IndicatorFeedbackPanelLayout.isInteractive(
                        state: state,
                        message: message
                    )
                )
            }
            .store(in: &cancellables)
    }

    func updateVisibility(
        vm: DictationViewModel = DictationViewModel.shared,
        recorder: AudioRecorderViewModel = AudioRecorderViewModel.shared
    ) {
        guard vm.indicatorStyle == .minimal else {
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

        let overlayPosition = overlayPositionProvider()
        let placement: IndicatorPlacement = overlayPosition == .top ? .notchStrip : .nonNotchArea
        if IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(on: screen, placement: placement) {
            suppressForForeignFullscreen()
            return
        }

        let screenFrame = screen.visibleFrame
        let panelSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .minimal,
            isFeedbackInteractive: isFeedbackInteractive
        )
        let panelFrame = IndicatorFeedbackPanelLayout.panelFrame(
            for: .minimal,
            size: panelSize,
            in: screenFrame,
            overlayPosition: overlayPosition
        )

        setFrame(panelFrame, display: true)
        ignoresMouseEvents = !isFeedbackInteractive
        FloatingPanelSpacePolicy.orderIndicatorFront(
            self,
            displayMode: displayModeProvider(),
            windowLevel: FloatingPanelSpacePolicy.floatingIndicatorWindowLevel,
            isVisibleInScreenCaptures: indicatorVisibleInScreenCapturesProvider()
        )
    }

    private func suppressForForeignFullscreen() {
        cachedScreen = nil
        orderOut(nil)
    }

    private func resolveScreen() -> NSScreen {
        screenResolver.resolveScreen(for: displayModeProvider())
    }

    func refreshPlacementForActiveContextChange() {
        guard isVisible else { return }
        if displayModeProvider() == .activeScreen {
            cachedScreen = nil
        }
        show()
    }

    func updateFeedbackInteraction(isInteractive: Bool) {
        if !isInteractive {
            ignoresMouseEvents = true
        }
        guard isFeedbackInteractive != isInteractive else { return }
        isFeedbackInteractive = isInteractive
        if isVisible {
            show()
        }
    }

    func dismiss() {
        ignoresMouseEvents = true
        cachedScreen = nil
        orderOut(nil)
    }
}
