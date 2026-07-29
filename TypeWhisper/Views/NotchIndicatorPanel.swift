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
        notchHeight = NotchIndicatorLayout.closedHeight(
            hasNotch: hasNotch,
            safeAreaTopInset: screen.safeAreaInsets.top
        )
    }
}

/// Hosting view that accepts first mouse click without requiring a prior activation click.
private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Panel that visually extends the MacBook notch, centered over the hardware notch.
/// Only shown on displays with a hardware notch - hidden on non-notch displays regardless of settings.
class NotchIndicatorPanel: NSPanel {
    private static let presentationAnimationDuration: Duration = .milliseconds(220)

    private let screenResolver: IndicatorScreenResolver
    private let displayModeProvider: () -> NotchIndicatorDisplay
    private let indicatorVisibleInScreenCapturesProvider: () -> Bool
    private let notchGeometry = NotchGeometry()
    private var cancellables = Set<AnyCancellable>()
    private var cachedScreen: NSScreen?
    private var showTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var isFeedbackInteractive = false

    convenience init(screenResolver: IndicatorScreenResolver) {
        self.init(
            screenResolver: screenResolver,
            displayModeProvider: { DictationViewModel.shared.notchIndicatorDisplay },
            indicatorVisibleInScreenCapturesProvider: {
                DictationViewModel.shared.indicatorVisibleInScreenCaptures
            },
            content: { NotchIndicatorView(geometry: $0) }
        )
    }

    init<Content: View>(
        screenResolver: IndicatorScreenResolver,
        displayModeProvider: @escaping () -> NotchIndicatorDisplay,
        indicatorVisibleInScreenCapturesProvider: @escaping () -> Bool = { true },
        @ViewBuilder content: (NotchGeometry) -> Content
    ) {
        self.screenResolver = screenResolver
        self.displayModeProvider = displayModeProvider
        self.indicatorVisibleInScreenCapturesProvider = indicatorVisibleInScreenCapturesProvider
        let initialSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .notch,
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
            windowLevel: FloatingPanelSpacePolicy.notchIndicatorWindowLevel,
            isVisibleInScreenCaptures: indicatorVisibleInScreenCapturesProvider()
        )

        let hostingView = FirstMouseHostingView(rootView: content(notchGeometry))
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
        guard vm.indicatorStyle == .notch else {
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

    // MARK: - Notch geometry

    func show() {
        showTask?.cancel()
        dismissTask?.cancel()

        let wasVisible = isVisible
        placePanel()

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

    private func placePanel() {
        let screen: NSScreen
        if let cached = cachedScreen, isVisible {
            screen = cached
        } else {
            screen = resolveScreen()
            cachedScreen = screen
        }

        notchGeometry.update(for: screen)

        let screenFrame = screen.frame
        let closedWidth = NotchIndicatorLayout.closedWidth(
            hasNotch: notchGeometry.hasNotch,
            notchWidth: notchGeometry.notchWidth
        )
        let panelSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .notch,
            isFeedbackInteractive: isFeedbackInteractive,
            notchClosedWidth: closedWidth,
            notchClosedHeight: notchGeometry.notchHeight
        )
        let panelFrame = IndicatorFeedbackPanelLayout.panelFrame(
            for: .notch,
            size: panelSize,
            in: screenFrame
        )

        setFrame(panelFrame, display: true)
        ignoresMouseEvents = !isFeedbackInteractive
        FloatingPanelSpacePolicy.orderIndicatorFront(
            self,
            displayMode: displayModeProvider(),
            windowLevel: FloatingPanelSpacePolicy.notchIndicatorWindowLevel,
            isVisibleInScreenCaptures: indicatorVisibleInScreenCapturesProvider()
        )
    }

    private func resolveScreen() -> NSScreen {
        screenResolver.resolveScreen(for: displayModeProvider())
    }

    func refreshPlacementForActiveContextChange() {
        guard isVisible, notchGeometry.isPresented else { return }
        if displayModeProvider() == .activeScreen {
            cachedScreen = nil
        }
        placePanel()
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
