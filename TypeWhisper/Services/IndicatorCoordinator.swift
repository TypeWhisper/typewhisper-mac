import Foundation
import AppKit
import Combine
import ApplicationServices

struct IndicatorPresentationState: Equatable {
    enum Source: Equatable {
        case dictation
        case recorder
    }

    let source: Source
    let state: DictationViewModel.State

    var isActiveDuringActivity: Bool {
        switch state {
        case .recording, .processing, .inserting, .error:
            return true
        case .idle, .promptSelection, .promptProcessing:
            return false
        }
    }

    static func resolve(
        dictationState: DictationViewModel.State,
        recorderState: AudioRecorderViewModel.RecorderState
    ) -> IndicatorPresentationState {
        switch dictationState {
        case .recording, .processing, .inserting, .error:
            return IndicatorPresentationState(source: .dictation, state: dictationState)
        case .idle, .promptSelection, .promptProcessing:
            if recorderState == .recording {
                return IndicatorPresentationState(source: .recorder, state: .recording)
            }
            return IndicatorPresentationState(source: .dictation, state: dictationState)
        }
    }

    static func shouldShow(
        visibility: NotchIndicatorVisibility,
        presentation: IndicatorPresentationState
    ) -> Bool {
        switch visibility {
        case .always:
            return true
        case .duringActivity:
            return presentation.isActiveDuringActivity
        case .never:
            return false
        }
    }
}

struct IndicatorPresentationData {
    let source: IndicatorPresentationState.Source
    let state: DictationViewModel.State
    let recordingDuration: TimeInterval
    let audioLevel: Float
    let partialText: String
    let activeRuleName: String?
    let activeAppIcon: NSImage?
    let isRecordingInputReady: Bool
    let recordingCancelWarningMessage: String?
    let processingPhase: String?
    let actionFeedbackMessage: String?
    let actionFeedbackIcon: String?
    let actionFeedbackIsError: Bool
    let externalStreamingDisplayCount: Int

    var isRecorder: Bool {
        source == .recorder
    }

    @MainActor
    static func make(
        dictation: DictationViewModel,
        recorder: AudioRecorderViewModel
    ) -> IndicatorPresentationData {
        let presentation = IndicatorPresentationState.resolve(
            dictationState: dictation.state,
            recorderState: recorder.state
        )

        switch presentation.source {
        case .dictation:
            return IndicatorPresentationData(
                source: .dictation,
                state: presentation.state,
                recordingDuration: dictation.recordingDuration,
                audioLevel: dictation.audioLevel,
                partialText: dictation.partialText,
                activeRuleName: dictation.activeRuleName,
                activeAppIcon: dictation.activeAppIcon,
                isRecordingInputReady: dictation.isRecordingInputReady,
                recordingCancelWarningMessage: dictation.recordingCancelWarningMessage,
                processingPhase: dictation.processingPhase,
                actionFeedbackMessage: dictation.actionFeedbackMessage,
                actionFeedbackIcon: dictation.actionFeedbackIcon,
                actionFeedbackIsError: dictation.actionFeedbackIsError,
                externalStreamingDisplayCount: dictation.externalStreamingDisplayCount
            )
        case .recorder:
            return IndicatorPresentationData(
                source: .recorder,
                state: presentation.state,
                recordingDuration: recorder.duration,
                audioLevel: max(recorder.micLevel, recorder.systemLevel),
                partialText: recorder.partialText,
                activeRuleName: nil,
                activeAppIcon: nil,
                isRecordingInputReady: true,
                recordingCancelWarningMessage: nil,
                processingPhase: nil,
                actionFeedbackMessage: nil,
                actionFeedbackIcon: nil,
                actionFeedbackIsError: false,
                externalStreamingDisplayCount: dictation.externalStreamingDisplayCount
            )
        }
    }
}

/// Coordinates the display of different indicator styles (Notch vs Overlay).
@MainActor
final class IndicatorCoordinator {
    private let screenResolver = IndicatorScreenResolver()
    private let notchPanel: NotchIndicatorPanel
    private let overlayPanel: OverlayIndicatorPanel
    private let minimalPanel: MinimalIndicatorPanel
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var deferredRefreshTask: Task<Void, Never>?
    private var isObserving = false

    init() {
        notchPanel = NotchIndicatorPanel(screenResolver: screenResolver)
        overlayPanel = OverlayIndicatorPanel(screenResolver: screenResolver)
        minimalPanel = MinimalIndicatorPanel(screenResolver: screenResolver)
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        let vm = DictationViewModel.shared

        // When style changes, dismiss the inactive panel and show the active one
        vm.$indicatorStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] style in
                self?.switchStyle(style, vm: vm)
            }
            .store(in: &cancellables)

        // Both panels observe state; the coordinator and panels gate which one is active
        notchPanel.startObserving()
        overlayPanel.startObserving()
        minimalPanel.startObserving()
        startObservingActiveScreenContextChanges()
    }

    private func switchStyle(_ style: IndicatorStyle, vm: DictationViewModel) {
        switch style {
        case .notch:
            overlayPanel.dismiss()
            minimalPanel.dismiss()
            notchPanel.updateVisibility(vm: vm)
        case .overlay:
            notchPanel.dismiss()
            minimalPanel.dismiss()
            overlayPanel.updateVisibility(vm: vm)
        case .minimal:
            notchPanel.dismiss()
            overlayPanel.dismiss()
            minimalPanel.updateVisibility(vm: vm)
        }
    }

    private func startObservingActiveScreenContextChanges() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleActiveScreenRefreshes()
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleActiveScreenRefreshes()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleActiveScreenRefreshes()
            }
            .store(in: &cancellables)

        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.scheduleActiveScreenRefreshes()
                }
            }
        }
    }

    private func refreshVisibleIndicatorPanels() {
        notchPanel.refreshPlacementForActiveContextChange()
        overlayPanel.refreshPlacementForActiveContextChange()
        minimalPanel.refreshPlacementForActiveContextChange()
    }

    private func scheduleActiveScreenRefreshes() {
        refreshVisibleIndicatorPanels()

        deferredRefreshTask?.cancel()
        deferredRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refreshVisibleIndicatorPanels()

            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshVisibleIndicatorPanels()
        }
    }
}

enum IndicatorWindowFrameLookup {
    nonisolated static func frontmostWindowFrame(for processIdentifier: pid_t) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        var fallbackFrame: CGRect?

        for windowInfo in windowList {
            guard let rawBounds = windowInfo[kCGWindowBounds as String] else {
                continue
            }

            let boundsDictionary = rawBounds as! CFDictionary

            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processIdentifier,
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsDictionary
                  ),
                  !bounds.isEmpty else {
                continue
            }

            let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { continue }

            let layer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            if layer == 0 {
                return bounds
            }

            if fallbackFrame == nil {
                fallbackFrame = bounds
            }
        }

        return fallbackFrame
    }

    nonisolated static func focusedWindowFrame() -> CGRect? {
        guard let focusedWindow = focusedWindowElement() else {
            return nil
        }
        let windowElement = focusedWindow as! AXUIElement

        var positionValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            windowElement,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
              let positionValue else {
            return nil
        }
        let axPosition = positionValue as! AXValue

        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            windowElement,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
              let sizeValue else {
            return nil
        }
        let axSize = sizeValue as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(axPosition, .cgPoint, &position),
              AXValueGetValue(axSize, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    nonisolated static func focusedWindowIsFullscreen() -> Bool? {
        guard let focusedWindow = focusedWindowElement() else {
            return nil
        }
        let windowElement = focusedWindow as! AXUIElement

        var fullScreenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            windowElement,
            "AXFullScreen" as CFString,
            &fullScreenValue
        ) == .success,
              let fullScreenValue else {
            return nil
        }

        if let isFullscreen = fullScreenValue as? Bool {
            return isFullscreen
        }

        return (fullScreenValue as? NSNumber)?.boolValue
    }

    private nonisolated static func focusedWindowElement() -> AnyObject? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApplication: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplication
        ) == .success,
              let focusedApplication else {
            return nil
        }
        let applicationElement = focusedApplication as! AXUIElement

        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        ) == .success,
              let focusedWindow else {
            return nil
        }
        return focusedWindow
    }
}

/// Where an indicator panel renders relative to the display's notch safe area.
///
/// The fullscreen-suppression policy exists to avoid drawing the indicator
/// underneath a foreign fullscreen window that has expanded into the notch
/// strip on notched MacBooks (see #373, #543). Indicators that render away
/// from the notch strip (e.g. a bottom-aligned overlay) cannot collide with
/// that area, so suppression should not apply to them (see #602).
enum IndicatorPlacement {
    /// Indicator renders inside or adjacent to the notch safe-area strip.
    case notchStrip
    /// Indicator renders entirely outside the notch safe-area strip
    /// (for example, a bottom-aligned overlay).
    case nonNotchArea
}

enum IndicatorFullscreenSuppressionPolicy {
    private static let minimumHorizontalCoverage: CGFloat = 0.5
    private static let minimumVerticalCoverage: CGFloat = 0.5
    private static let minimumFullscreenDimensionCoverage: CGFloat = 0.98
    @MainActor private static var lastSuppression: IndicatorFullscreenSuppressionDiagnostics?

    @MainActor
    static func lastSuppressionDiagnostics() -> IndicatorFullscreenSuppressionDiagnostics? {
        lastSuppression
    }

    @MainActor
    static func shouldSuppressIndicator(
        on screen: NSScreen,
        placement: IndicatorPlacement = .notchStrip,
        frontmostApplicationProvider: () -> NSRunningApplication? = {
            ActivationSourceTracker.shared.lastExternalApplication ?? NSWorkspace.shared.frontmostApplication
        },
        focusedWindowFrameProvider: () -> CGRect? = IndicatorWindowFrameLookup.focusedWindowFrame,
        focusedWindowFullscreenProvider: () -> Bool? = IndicatorWindowFrameLookup.focusedWindowIsFullscreen,
        windowFrameProvider: (pid_t) -> CGRect? = IndicatorWindowFrameLookup.frontmostWindowFrame(for:),
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard placement == .notchStrip else {
            return false
        }

        guard let application = frontmostApplicationProvider() else {
            return false
        }

        guard application.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return false
        }

        let windowFrame = focusedWindowFrameProvider()
            ?? windowFrameProvider(application.processIdentifier)
        let focusedWindowIsFullscreen = focusedWindowFullscreenProvider()

        let shouldSuppress = shouldSuppressIndicator(
            screenFrame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            windowFrame: windowFrame,
            focusedWindowIsFullscreen: focusedWindowIsFullscreen,
            frontmostBundleIdentifier: application.bundleIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            placement: placement
        )

        if shouldSuppress {
            recordSuppression(
                screenFrame: screen.frame,
                safeAreaTopInset: screen.safeAreaInsets.top,
                windowFrame: windowFrame,
                focusedWindowIsFullscreen: focusedWindowIsFullscreen,
                frontmostApplication: application
            )
        }

        return shouldSuppress
    }

    static func shouldSuppressIndicator(
        screenFrame: CGRect,
        safeAreaTopInset: CGFloat,
        windowFrame: CGRect?,
        focusedWindowIsFullscreen: Bool? = nil,
        frontmostBundleIdentifier: String?,
        appBundleIdentifier: String?,
        placement: IndicatorPlacement = .notchStrip
    ) -> Bool {
        guard placement == .notchStrip else {
            return false
        }

        guard safeAreaTopInset > 0,
              let candidateWindowFrame = windowFrame,
              !screenFrame.isEmpty,
              !candidateWindowFrame.isEmpty,
              !isTypeWhisperBundleIdentifier(frontmostBundleIdentifier, appBundleIdentifier: appBundleIdentifier) else {
            return false
        }

        let screenFrame = screenFrame.standardized
        let windowFrame = candidateWindowFrame.standardized

        if let focusedWindowIsFullscreen {
            guard focusedWindowIsFullscreen else { return false }
        } else if !isFullscreenLikeWindow(screenFrame: screenFrame, windowFrame: windowFrame) {
            return false
        }

        let notchStripHeight = min(safeAreaTopInset, screenFrame.height)
        let notchStrip = CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - notchStripHeight,
            width: screenFrame.width,
            height: notchStripHeight
        )

        let intersection = windowFrame.intersection(notchStrip)
        guard !intersection.isNull, !intersection.isEmpty else {
            return false
        }

        let horizontalCoverage = intersection.width / notchStrip.width
        let verticalCoverage = intersection.height / notchStrip.height

        return horizontalCoverage >= minimumHorizontalCoverage
            && verticalCoverage >= minimumVerticalCoverage
    }

    private static func isFullscreenLikeWindow(screenFrame: CGRect, windowFrame: CGRect) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return false }

        let widthCoverage = min(windowFrame.width / screenFrame.width, 1)
        let heightCoverage = min(windowFrame.height / screenFrame.height, 1)

        return widthCoverage >= minimumFullscreenDimensionCoverage
            && heightCoverage >= minimumFullscreenDimensionCoverage
    }

    private static func isTypeWhisperBundleIdentifier(
        _ bundleIdentifier: String?,
        appBundleIdentifier: String?
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        if let appBundleIdentifier, bundleIdentifier == appBundleIdentifier {
            return true
        }

        return bundleIdentifier == "com.typewhisper.mac"
            || bundleIdentifier == "com.typewhisper.mac.dev"
    }

    @MainActor
    private static func recordSuppression(
        screenFrame: CGRect,
        safeAreaTopInset: CGFloat,
        windowFrame: CGRect?,
        focusedWindowIsFullscreen: Bool?,
        frontmostApplication: NSRunningApplication
    ) {
        guard let windowFrame else { return }

        let screenFrame = screenFrame.standardized
        let standardizedWindowFrame = windowFrame.standardized
        let notchStripHeight = min(safeAreaTopInset, screenFrame.height)
        let notchStrip = CGRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - notchStripHeight,
            width: screenFrame.width,
            height: notchStripHeight
        )
        let intersection = standardizedWindowFrame.intersection(notchStrip)
        let horizontalCoverage = intersection.isNull || intersection.isEmpty ? 0 : intersection.width / notchStrip.width
        let verticalCoverage = intersection.isNull || intersection.isEmpty ? 0 : intersection.height / notchStrip.height

        lastSuppression = IndicatorFullscreenSuppressionDiagnostics(
            timestamp: Date(),
            frontmostBundleIdentifier: frontmostApplication.bundleIdentifier,
            frontmostLocalizedName: frontmostApplication.localizedName,
            frontmostProcessIdentifier: frontmostApplication.processIdentifier,
            screenFrame: .init(screenFrame),
            safeAreaTopInset: Double(safeAreaTopInset),
            windowFrame: .init(standardizedWindowFrame),
            focusedWindowIsFullscreen: focusedWindowIsFullscreen,
            horizontalCoverage: Double(horizontalCoverage),
            verticalCoverage: Double(verticalCoverage)
        )
    }
}

struct IndicatorFullscreenSuppressionDiagnostics: Encodable, Equatable, Sendable {
    let timestamp: Date
    let frontmostBundleIdentifier: String?
    let frontmostLocalizedName: String?
    let frontmostProcessIdentifier: pid_t
    let screenFrame: IndicatorRectDiagnostics
    let safeAreaTopInset: Double
    let windowFrame: IndicatorRectDiagnostics
    let focusedWindowIsFullscreen: Bool?
    let horizontalCoverage: Double
    let verticalCoverage: Double
}

struct IndicatorRectDiagnostics: Encodable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

@MainActor
final class IndicatorScreenResolver {
    typealias FocusedElementPositionProvider = () -> CGPoint?
    typealias FocusedWindowFrameProvider = () -> CGRect?
    typealias FrontmostApplicationProvider = () -> NSRunningApplication?
    typealias MouseLocationProvider = () -> CGPoint
    typealias ScreensProvider = () -> [NSScreen]
    typealias MainScreenProvider = () -> NSScreen?
    typealias WindowFrameProvider = (pid_t) -> CGRect?

    private let focusedElementPositionProvider: FocusedElementPositionProvider
    private let focusedWindowFrameProvider: FocusedWindowFrameProvider
    private let frontmostApplicationProvider: FrontmostApplicationProvider
    private let mouseLocationProvider: MouseLocationProvider
    private let screensProvider: ScreensProvider
    private let mainScreenProvider: MainScreenProvider
    private let windowFrameProvider: WindowFrameProvider

    init(
        focusedElementPositionProvider: @escaping FocusedElementPositionProvider = {
            ServiceContainer.shared.textInsertionService.focusedElementPosition()
        },
        focusedWindowFrameProvider: @escaping FocusedWindowFrameProvider = IndicatorWindowFrameLookup.focusedWindowFrame,
        frontmostApplicationProvider: @escaping FrontmostApplicationProvider = {
            ActivationSourceTracker.shared.lastExternalApplication ?? NSWorkspace.shared.frontmostApplication
        },
        mouseLocationProvider: @escaping MouseLocationProvider = { NSEvent.mouseLocation },
        screensProvider: @escaping ScreensProvider = { NSScreen.screens },
        mainScreenProvider: @escaping MainScreenProvider = { NSScreen.main },
        windowFrameProvider: @escaping WindowFrameProvider = IndicatorWindowFrameLookup.frontmostWindowFrame(for:)
    ) {
        self.focusedElementPositionProvider = focusedElementPositionProvider
        self.focusedWindowFrameProvider = focusedWindowFrameProvider
        self.frontmostApplicationProvider = frontmostApplicationProvider
        self.mouseLocationProvider = mouseLocationProvider
        self.screensProvider = screensProvider
        self.mainScreenProvider = mainScreenProvider
        self.windowFrameProvider = windowFrameProvider
    }

    func resolveScreen(for displayMode: NotchIndicatorDisplay) -> NSScreen {
        let screens = screensProvider()
        precondition(!screens.isEmpty, "Expected at least one screen")

        switch displayMode {
        case .activeScreen:
            if let screen = screen(containing: focusedElementPositionProvider()) {
                return screen
            }

            if let focusedWindowFrame = focusedWindowFrameProvider(),
               let screen = screen(intersecting: focusedWindowFrame) {
                return screen
            }

            if let application = frontmostApplicationProvider(),
               let windowFrame = windowFrameProvider(application.processIdentifier),
               let screen = screen(intersecting: windowFrame) {
                return screen
            }

            if let screen = screen(containing: mouseLocationProvider()) {
                return screen
            }

            return mainScreenProvider() ?? screens[0]
        case .primaryScreen:
            return mainScreenProvider() ?? screens[0]
        case .builtInScreen:
            return screens.first { $0.safeAreaInsets.top > 0 } ?? mainScreenProvider() ?? screens[0]
        }
    }

    private func screen(containing point: CGPoint?) -> NSScreen? {
        guard let point else { return nil }
        return screensProvider().first { $0.frame.contains(point) }
    }

    private func screen(intersecting frame: CGRect) -> NSScreen? {
        let screens = screensProvider()
        let bestScreen = screens
            .map { screen in
                let intersection = frame.intersection(screen.frame)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen, area)
            }
            .max(by: { $0.1 < $1.1 })

        if let bestScreen, bestScreen.1 > 0 {
            return bestScreen.0
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return screen(containing: center)
    }

}
