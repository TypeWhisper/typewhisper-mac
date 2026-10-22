import AppKit
import SwiftUI
import Combine

private class OverlayFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Floating panel for the Overlay Indicator mode.
class OverlayIndicatorPanel: NSPanel {
    private let screenResolver: IndicatorScreenResolver
    private let displayModeProvider: () -> NotchIndicatorDisplay
    private let overlayPositionProvider: () -> OverlayPosition
    private let indicatorVisibleInScreenCapturesProvider: () -> Bool
    private let countdownModel: CalendarMeetingCountdownModel
    private let pointerRegion: IndicatorPointerRegion
    private let pointerTracker: IndicatorPointerTracker
    private var cancellables = Set<AnyCancellable>()
    private var cachedScreen: NSScreen?
    private var isActionFeedbackInteractive = false
    private var actionFeedbackMessage: String?
    private var actionFeedbackActionTitle: String?
    private var meetingCountdownKind: CalendarMeetingCountdownKind? {
        countdownModel.presentation?.kind
    }

    private var isMeetingCountdownPresented: Bool {
        meetingCountdownKind != nil
    }

    private var isFeedbackInteractive: Bool {
        isActionFeedbackInteractive || isMeetingCountdownPresented
    }

    convenience init(
        screenResolver: IndicatorScreenResolver,
        countdownModel: CalendarMeetingCountdownModel
    ) {
        self.init(
            screenResolver: screenResolver,
            displayModeProvider: { DictationViewModel.shared.notchIndicatorDisplay },
            overlayPositionProvider: { DictationViewModel.shared.overlayPosition },
            indicatorVisibleInScreenCapturesProvider: {
                DictationViewModel.shared.indicatorVisibleInScreenCaptures
            },
            countdownModel: countdownModel,
            content: {
                OverlayIndicatorView(countdownModel: countdownModel)
            }
        )
    }

    init<Content: View>(
        screenResolver: IndicatorScreenResolver,
        displayModeProvider: @escaping () -> NotchIndicatorDisplay,
        overlayPositionProvider: @escaping () -> OverlayPosition,
        indicatorVisibleInScreenCapturesProvider: @escaping () -> Bool = { true },
        countdownModel: CalendarMeetingCountdownModel = .init(),
        pointerLocationProvider: @escaping () -> NSPoint = { NSEvent.mouseLocation },
        @ViewBuilder content: () -> Content
    ) {
        self.screenResolver = screenResolver
        self.displayModeProvider = displayModeProvider
        self.overlayPositionProvider = overlayPositionProvider
        self.indicatorVisibleInScreenCapturesProvider = indicatorVisibleInScreenCapturesProvider
        self.countdownModel = countdownModel
        let pointerRegion = IndicatorPointerRegion()
        self.pointerRegion = pointerRegion
        pointerTracker = IndicatorPointerTracker(
            region: pointerRegion,
            pointerLocationProvider: pointerLocationProvider
        )
        let initialSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .overlay,
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

        let hostingView = OverlayFirstMouseHostingView(
            rootView: IndicatorPointerHost(region: pointerRegion, content: content())
        )
        hostingView.sizingOptions = []
        // The overlay content lays itself out from its own metrics and never
        // consumes the safe area.
        hostingView.safeAreaRegions = []

        // Same guard as NotchIndicatorPanel: the hosting view keeps one size
        // inside a plain container and only the window follows the feedback.
        // A root view that resizes with the window lets NSHostingView resize
        // the window from windowDidLayout, and AppKit raises
        // NSInternalInconsistencyException from
        // _postWindowNeedsUpdateConstraints (#1441).
        contentView = IndicatorHostingContainerView(
            hostingView: hostingView,
            size: initialSize,
            hostingSize: IndicatorFeedbackPanelLayout.hostingSize(for: .overlay),
            verticalAnchor: Self.hostingAnchor(for: overlayPositionProvider())
        )
        pointerTracker.hostingView = hostingView
        pointerTracker.onChange = { [weak self] in
            self?.updateMouseEventHandling()
        }
    }

    private static func hostingAnchor(for position: OverlayPosition) -> IndicatorHostingContainerView.VerticalAnchor {
        position == .top ? .top : .bottom
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

        // A meeting recording can be hidden from the indicator (#1079).
        Publishers.Merge(
            recorder.$state.map { _ in () },
            recorder.$isIndicatorHidden.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateVisibility(vm: vm, recorder: recorder)
        }
        .store(in: &cancellables)

        // A side that shows the Model content takes the pointer (#1351).
        Publishers.Merge(
            vm.$notchIndicatorLeftContent.map { _ in () },
            vm.$notchIndicatorRightContent.map { _ in () }
        )
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

        vm.$indicatorTheme
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.appearance = theme.panelAppearance
            }
            .store(in: &cancellables)

        IndicatorPreviewSession.shared.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
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

        Publishers.CombineLatest3(vm.$state, vm.$actionFeedbackMessage, vm.$actionFeedbackActionTitle)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, message, actionTitle in
                self?.updateFeedbackInteraction(
                    isInteractive: IndicatorFeedbackPanelLayout.isInteractive(
                        state: state,
                        message: message
                    ),
                    message: message,
                    actionTitle: actionTitle
                )
            }
            .store(in: &cancellables)

        countdownModel.$presentation
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibility(vm: vm, recorder: recorder)
            }
            .store(in: &cancellables)
    }

    func updateVisibility(
        vm: DictationViewModel = DictationViewModel.shared,
        recorder: AudioRecorderViewModel = AudioRecorderViewModel.shared
    ) {
        guard CalendarMeetingCountdownIndicatorPolicy.activeStyle(
            preferredStyle: vm.indicatorStyle,
            countdownPresented: isMeetingCountdownPresented
        ) == .overlay else {
            dismiss()
            return
        }

        let presentation = IndicatorPresentationState.resolve(
            dictationState: vm.state,
            recorderState: recorder.indicatorState,
            previewActive: IndicatorPreviewSession.shared.isActive,
            isErrorFeedback: vm.actionFeedbackIsError && vm.actionFeedbackMessage != nil
        )
        let normallyVisible = IndicatorPresentationState.shouldShow(
            visibility: vm.notchIndicatorVisibility,
            presentation: presentation
        )
        if CalendarMeetingCountdownIndicatorPolicy.shouldShow(
            normalVisibilityAllowsPresentation: normallyVisible,
            countdownPresented: isMeetingCountdownPresented
        ) {
            show()
            pointerTracker.setActive(presentation.tracksPointer(
                showsModelContent: NotchIndicatorContent.showsModel(
                    style: .overlay,
                    left: vm.notchIndicatorLeftContent,
                    right: vm.notchIndicatorRightContent
                )
            ))
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

        let overlayPosition = CalendarMeetingCountdownIndicatorPolicy.overlayPosition(
            preferredPosition: overlayPositionProvider(),
            countdownPresented: isMeetingCountdownPresented
        )
        let placement: IndicatorPlacement = overlayPosition == .top ? .notchStrip : .nonNotchArea
        if CalendarMeetingCountdownIndicatorPolicy.shouldSuppressForFullscreen(
            normallySuppressed: IndicatorFullscreenSuppressionPolicy.shouldSuppressIndicator(
                on: screen,
                placement: placement
            ),
            countdownPresented: isMeetingCountdownPresented
        ) {
            suppressForForeignFullscreen()
            return
        }

        let screenFrame = screen.visibleFrame
        let panelSize = IndicatorFeedbackPanelLayout.panelSize(
            for: .overlay,
            isFeedbackInteractive: isFeedbackInteractive,
            countdownKind: meetingCountdownKind,
            feedbackMessage: actionFeedbackMessage,
            feedbackActionTitle: actionFeedbackActionTitle
        )
        let panelFrame = IndicatorFeedbackPanelLayout.panelFrame(
            for: .overlay,
            size: panelSize,
            in: screenFrame,
            overlayPosition: overlayPosition
        )

        (contentView as? IndicatorHostingContainerView)?.verticalAnchor = Self.hostingAnchor(for: overlayPosition)
        setFrame(panelFrame, display: true)
        updateMouseEventHandling()
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

    func updateFeedbackInteraction(
        isInteractive: Bool,
        message: String? = nil,
        actionTitle: String? = nil
    ) {
        if !isInteractive && !isMeetingCountdownPresented && !pointerRegion.isPointerInside {
            ignoresMouseEvents = true
        }
        // The message decides how tall the feedback surface is, so a changed
        // message needs a new frame even when interactivity stays the same.
        let feedbackMessage = isInteractive ? message : nil
        let feedbackActionTitle = isInteractive ? actionTitle : nil
        guard isActionFeedbackInteractive != isInteractive
            || actionFeedbackMessage != feedbackMessage
            || actionFeedbackActionTitle != feedbackActionTitle else { return }
        isActionFeedbackInteractive = isInteractive
        actionFeedbackMessage = feedbackMessage
        actionFeedbackActionTitle = feedbackActionTitle
        if isVisible {
            show()
        }
    }

    /// Takes the mouse only for feedback, the countdown, or while the pointer
    /// is on a recording indicator; otherwise clicks pass through to other apps.
    private func updateMouseEventHandling() {
        ignoresMouseEvents = !(isFeedbackInteractive || pointerRegion.isPointerInside)
    }

    func dismiss() {
        pointerTracker.setActive(false)
        ignoresMouseEvents = true
        cachedScreen = nil
        orderOut(nil)
    }
}
