import Foundation
import AppKit
import Combine
import ApplicationServices

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
            notchPanel.updateVisibility(state: vm.state, vm: vm)
        case .overlay:
            notchPanel.dismiss()
            minimalPanel.dismiss()
            overlayPanel.updateVisibility(state: vm.state, vm: vm)
        case .minimal:
            notchPanel.dismiss()
            overlayPanel.dismiss()
            minimalPanel.updateVisibility(state: vm.state, vm: vm)
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

    private func refreshActiveScreenPanels() {
        notchPanel.refreshPlacementForActiveContextChange()
        overlayPanel.refreshPlacementForActiveContextChange()
        minimalPanel.refreshPlacementForActiveContextChange()
    }

    private func scheduleActiveScreenRefreshes() {
        refreshActiveScreenPanels()

        deferredRefreshTask?.cancel()
        deferredRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.refreshActiveScreenPanels()

            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.refreshActiveScreenPanels()
        }
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
        focusedWindowFrameProvider: @escaping FocusedWindowFrameProvider = IndicatorScreenResolver.focusedWindowFrame,
        frontmostApplicationProvider: @escaping FrontmostApplicationProvider = {
            ActivationSourceTracker.shared.lastExternalApplication ?? NSWorkspace.shared.frontmostApplication
        },
        mouseLocationProvider: @escaping MouseLocationProvider = { NSEvent.mouseLocation },
        screensProvider: @escaping ScreensProvider = { NSScreen.screens },
        mainScreenProvider: @escaping MainScreenProvider = { NSScreen.main },
        windowFrameProvider: @escaping WindowFrameProvider = IndicatorScreenResolver.frontmostWindowFrame(for:)
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

    nonisolated private static func frontmostWindowFrame(for processIdentifier: pid_t) -> CGRect? {
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

    nonisolated private static func focusedWindowFrame() -> CGRect? {
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

}
