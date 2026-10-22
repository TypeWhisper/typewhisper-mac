import SwiftUI
import AVFoundation
import Combine
import Foundation
import TypeWhisperPluginSDK

extension UserDefaults {
    @objc dynamic var showMenuBarIcon: Bool {
        bool(forKey: UserDefaultsKeys.showMenuBarIcon)
    }

    @objc dynamic var dockIconBehaviorWhenMenuBarHidden: String {
        string(forKey: UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden)
            ?? DockIconBehavior.keepVisible.rawValue
    }
}

extension Notification.Name {
    static let openManagedAppWindow = Notification.Name("openManagedAppWindow")
    static let resetSetupWizardWindow = Notification.Name("resetSetupWizardWindow")
    static let iOSCompanionPromoRequested = Notification.Name("iOSCompanionPromoRequested")
    static let whatsNewRequested = Notification.Name("whatsNewRequested")
    static let startupActivityDidBecomeIdle = Notification.Name("startupActivityDidBecomeIdle")
}

enum DockIconBehavior: String, CaseIterable {
    case keepVisible
    case onlyWhileWindowOpen
}

enum DockIconVisibility {
    static func shouldShowDockIcon(
        showMenuBarIcon: Bool,
        dockIconBehavior: DockIconBehavior,
        hasVisibleManagedWindow: Bool,
        hasInteractiveForegroundContent: Bool = false
    ) -> Bool {
        if hasVisibleManagedWindow || hasInteractiveForegroundContent {
            return true
        }

        guard !showMenuBarIcon else { return false }
        return dockIconBehavior == .keepVisible
    }
}

final class ManagedAppReopenSuppression: @unchecked Sendable {
    static let shared = ManagedAppReopenSuppression()

    private let lock = NSLock()
    private let duration: TimeInterval
    private var deadline: Date?

    init(duration: TimeInterval = 1.5) {
        self.duration = duration
    }

    func markBackgroundInteraction(at now: Date = Date()) {
        lock.withLock {
            deadline = now.addingTimeInterval(duration)
        }
    }

    func consumeIfActive(at now: Date = Date()) -> Bool {
        lock.withLock {
            guard let deadline, deadline >= now else {
                self.deadline = nil
                return false
            }
            self.deadline = nil
            return true
        }
    }
}

@MainActor
enum ManagedAppWindowRestoration {
    static func disable(for window: NSWindow) {
        window.isRestorable = false
    }
}

private final class ManagedAppWindowRestorationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        ManagedAppWindowRestoration.disable(for: window)
    }
}

private struct ManagedAppWindowRestorationAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> ManagedAppWindowRestorationView {
        ManagedAppWindowRestorationView()
    }

    func updateNSView(_ nsView: ManagedAppWindowRestorationView, context: Context) {
        guard let window = nsView.window else { return }
        ManagedAppWindowRestoration.disable(for: window)
    }
}

private extension View {
    func disablesManagedAppWindowRestoration() -> some View {
        background(ManagedAppWindowRestorationAccessor().frame(width: 0, height: 0))
    }
}

struct SettingsManagedAppWindowScene: Scene {
    let content: AnyView

    var body: some Scene {
        Window(String(localized: "Settings"), id: "settings") {
            content
                .disablesManagedAppWindowRestoration()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1050, height: 600)
    }
}

struct SetupManagedAppWindowScene: Scene {
    let content: AnyView

    var body: some Scene {
        Window(String(localized: "dictum Setup"), id: "setup") {
            content
                .disablesManagedAppWindowRestoration()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 560)
    }
}

struct HistoryManagedAppWindowScene: Scene {
    let content: AnyView

    var body: some Scene {
        Window(String(localized: "History"), id: "history") {
            content
                .disablesManagedAppWindowRestoration()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
    }
}

struct ErrorLogManagedAppWindowScene: Scene {
    let content: AnyView

    var body: some Scene {
        Window(String(localized: "Error Log"), id: "errors") {
            content
                .disablesManagedAppWindowRestoration()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 500, height: 400)
    }
}

@MainActor
protocol ManagedAppWindowSceneConfiguration {
    associatedtype SettingsScene: Scene
    associatedtype SetupScene: Scene
    associatedtype HistoryScene: Scene
    associatedtype ErrorLogScene: Scene

    static func settings(content: AnyView) -> SettingsScene
    static func setup(content: AnyView) -> SetupScene
    static func history(content: AnyView) -> HistoryScene
    static func errorLog(content: AnyView) -> ErrorLogScene
}

enum LegacyManagedAppWindowSceneConfiguration: ManagedAppWindowSceneConfiguration {
    static func settings(content: AnyView) -> some Scene {
        SettingsManagedAppWindowScene(content: content)
    }

    static func setup(content: AnyView) -> some Scene {
        SetupManagedAppWindowScene(content: content)
    }

    static func history(content: AnyView) -> some Scene {
        HistoryManagedAppWindowScene(content: content)
    }

    static func errorLog(content: AnyView) -> some Scene {
        ErrorLogManagedAppWindowScene(content: content)
    }
}

@available(macOS 15.0, *)
struct SuppressedManagedAppWindowScene<Content: Scene>: Scene {
    let content: Content

    var body: some Scene {
        content
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

@available(macOS 15.0, *)
enum SuppressedManagedAppWindowSceneConfiguration: ManagedAppWindowSceneConfiguration {
    static func settings(content: AnyView) -> some Scene {
        SuppressedManagedAppWindowScene(content: SettingsManagedAppWindowScene(content: content))
    }

    static func setup(content: AnyView) -> some Scene {
        SuppressedManagedAppWindowScene(content: SetupManagedAppWindowScene(content: content))
    }

    static func history(content: AnyView) -> some Scene {
        SuppressedManagedAppWindowScene(content: HistoryManagedAppWindowScene(content: content))
    }

    static func errorLog(content: AnyView) -> some Scene {
        SuppressedManagedAppWindowScene(content: ErrorLogManagedAppWindowScene(content: content))
    }
}

enum MenuBarIconState {
    static func isRecordingActive(
        dictationState: DictationViewModel.State,
        recorderState: AudioRecorderViewModel.RecorderState
    ) -> Bool {
        dictationState == .recording || recorderState == .recording
    }
}

@MainActor
final class FinderTranscriptionService: NSObject {
    typealias EnqueueFiles = @MainActor ([URL]) -> Void
    typealias PresentFileTranscription = @MainActor () -> Void

    private let enqueueFiles: EnqueueFiles
    private let presentFileTranscription: PresentFileTranscription

    init(
        enqueueFiles: @escaping EnqueueFiles = { FileTranscriptionViewModel.shared.addFiles($0) },
        presentFileTranscription: @escaping PresentFileTranscription = {
            SettingsNavigationCoordinator.shared.navigate(to: .fileTranscription)
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    ) {
        self.enqueueFiles = enqueueFiles
        self.presentFileTranscription = presentFileTranscription
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL]
        return FileTranscriptionViewModel.supportedFileURLs(objects?.map { $0 as URL } ?? [])
    }

    @discardableResult
    func handle(_ pasteboard: NSPasteboard) -> String? {
        WhatsNewCoordinator.shared?.suppressForCurrentLaunch()
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            return "No supported audio or video files were selected."
        }

        enqueueFiles(urls)
        presentFileTranscription()
        return nil
    }

    @objc(transcribeFiles:userData:error:)
    func transcribeFiles(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        if let errorMessage = handle(pasteboard) {
            errorPointer?.pointee = errorMessage as NSString
        }
    }
}

/// Only the recording flag reaches the status item. Observing the dictation view model
/// directly re-rendered the icon for every audio level sample during a dictation.
@MainActor
private final class MenuBarIconModel: ObservableObject {
    @Published private(set) var isRecordingActive: Bool
    private var cancellable: AnyCancellable?

    init(
        dictation: DictationViewModel = .shared,
        recorder: AudioRecorderViewModel = .shared
    ) {
        isRecordingActive = MenuBarIconState.isRecordingActive(
            dictationState: dictation.state,
            recorderState: recorder.state
        )
        cancellable = Publishers.CombineLatest(dictation.$state, recorder.$state)
            .map { MenuBarIconState.isRecordingActive(dictationState: $0, recorderState: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isRecordingActive = active
            }
    }
}

private struct MenuBarExtraLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @StateObject private var icon = MenuBarIconModel()

    private var title: String {
        AppConstants.isDevelopment ? "dictum Dev" : "dictum"
    }

    private var isRecordingActive: Bool {
        icon.isRecordingActive
    }

    var body: some View {
        Image(nsImage: MenuBarLogoMarkImage.cachedImage(
            isRecordingActive: isRecordingActive,
            increaseContrast: colorSchemeContrast == .increased
        ))
            .resizable()
            .renderingMode(isRecordingActive ? .original : .template)
            .frame(width: 18, height: 18)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(
                isRecordingActive
                    ? Text(String(localized: "Recording..."))
                    : Text(String(localized: "Idle"))
            )
            .onAppear {
                ManagedAppWindowOpener.shared.openWindow = openWindow
            }
            .onReceive(NotificationCenter.default.publisher(for: .openManagedAppWindow)) { notification in
                guard let id = notification.userInfo?["id"] as? String else { return }
                ManagedAppWindowOpener.shared.openWindow = openWindow
                openWindow(id: id)
            }
    }
}

private struct ManagedWindowOpenerRegistrar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmptyView()
            .onAppear {
                ManagedAppWindowOpener.shared.openWindow = openWindow
            }
    }
}

enum MenuBarLogoMarkImage {
    static let size = CGSize(width: 18, height: 18)
    private static let relativeBarHeights: [CGFloat] = [0.5, 0.75, 1.0, 0.75, 0.5]
    private static let recordingBadgeInset: CGFloat = 0.5
    private static let recordingBadgeCornerRadius: CGFloat = 4
    /// Space between the badge edge and the square that holds the bars.
    private static let recordingBarInset: CGFloat = 2

    @MainActor private static let idleImage = image(isRecordingActive: false)
    @MainActor private static let recordingImage = image(isRecordingActive: true)
    @MainActor private static let increasedContrastRecordingImage = image(
        isRecordingActive: true,
        increaseContrast: true
    )

    /// Each state is drawn once; the status item swaps between them.
    @MainActor static func cachedImage(isRecordingActive: Bool, increaseContrast: Bool = false) -> NSImage {
        guard isRecordingActive else { return idleImage }
        return increaseContrast ? increasedContrastRecordingImage : recordingImage
    }

    /// Idle: the five logo bars as a template image. Recording: a filled red badge
    /// with the bars in white, so the icon changes its shape and not only its color.
    static func image(isRecordingActive: Bool, increaseContrast: Bool = false) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.shouldAntialias = true
            if isRecordingActive {
                let badge = recordingBadgeRect(in: rect)
                recordingBadgeColor(increaseContrast: increaseContrast).setFill()
                NSBezierPath(
                    roundedRect: badge,
                    xRadius: recordingBadgeCornerRadius,
                    yRadius: recordingBadgeCornerRadius
                ).fill()
                NSColor.white.setFill()
                fillBars(recordingBarRects(in: rect))
            } else {
                NSColor.black.setFill()
                fillBars(barRects(in: rect))
            }
            return true
        }
        image.isTemplate = !isRecordingActive
        return image
    }

    static func recordingBadgeRect(in rect: CGRect) -> CGRect {
        rect.insetBy(dx: recordingBadgeInset, dy: recordingBadgeInset)
    }

    /// The logo bars in their usual proportions, scaled down to fit inside the badge.
    static func recordingBarRects(in rect: CGRect) -> [CGRect] {
        barRects(in: recordingBadgeRect(in: rect).insetBy(dx: recordingBarInset, dy: recordingBarInset))
    }

    /// System red. With Increase Contrast, a darker red raises the white bars from
    /// about 3.6:1 to 5.4:1. `systemRed` does not change with that setting.
    static func recordingBadgeColor(increaseContrast: Bool) -> NSColor {
        increaseContrast
            ? NSColor(srgbRed: 215 / 255, green: 0, blue: 21 / 255, alpha: 1)
            : .systemRed
    }

    private static func fillBars(_ rects: [CGRect]) {
        for rect in rects {
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width / 2,
                yRadius: rect.width / 2
            ).fill()
        }
    }

    static func barRects(in rect: CGRect) -> [CGRect] {
        let side = min(rect.width, rect.height) * 0.875
        let barWidth = side / 7
        let spacing = barWidth / 2
        let totalWidth = (barWidth * CGFloat(relativeBarHeights.count))
            + (spacing * CGFloat(relativeBarHeights.count - 1))
        var x = rect.midX - (totalWidth / 2)

        return relativeBarHeights.map { relativeHeight in
            let height = side * relativeHeight
            defer {
                x += barWidth + spacing
            }

            return CGRect(
                x: x,
                y: rect.midY - (height / 2),
                width: barWidth,
                height: height
            )
        }
    }
}

struct TypeWhisperApp<WindowConfiguration: ManagedAppWindowSceneConfiguration>: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            menuBarContent
        } label: {
            if AppConstants.isRunningTests {
                EmptyView()
            } else {
                MenuBarExtraLabel()
            }
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appInfo) {
                ManagedWindowOpenerRegistrar()
            }
            PluginAppCommands(pluginManager: ServiceContainer.shared.pluginManager)
        }

        WindowConfiguration.settings(content: AnyView(settingsContent))
        WindowConfiguration.setup(content: AnyView(setupContent))
        WindowConfiguration.history(content: AnyView(historyContent))
        WindowConfiguration.errorLog(content: AnyView(errorLogContent))
    }

    @ViewBuilder
    private var menuBarContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            MenuBarView()
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            SettingsView()
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            SetupWizardView()
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            HistoryView()
        }
    }

    @ViewBuilder
    private var errorLogContent: some View {
        if AppConstants.isRunningTests {
            EmptyView()
        } else {
            ErrorLogView()
        }
    }

    init() {
        guard !AppConstants.isRunningTests else { return }

        LaunchSignposts.beginLaunch()
        WhatsNewCoordinator.shared = WhatsNewCoordinator()

        // Trigger ServiceContainer initialization
        let serviceContainer = LaunchSignposts.signposter.withIntervalSignpost("Launch.serviceContainer") {
            ServiceContainer.shared
        }
        serviceContainer.hotkeyService.onHotkeyAction = {
            WhatsNewCoordinator.shared?.suppressForCurrentLaunch()
        }
        SettingsNavigationCoordinator.shared = SettingsNavigationCoordinator()
        WorkflowsNavigationCoordinator.shared = WorkflowsNavigationCoordinator()

        #if DEBUG
        if AppConstants.isScreenshotAutomation {
            serviceContainer.prepareScreenshotFixtures()
        } else {
            Task { @MainActor in
                await serviceContainer.initialize()
            }
        }
        #else
        Task { @MainActor in
            await serviceContainer.initialize()
        }
        #endif
    }

}

@MainActor
final class ActivationSourceTracker {
    static let shared = ActivationSourceTracker()

    private(set) var lastExternalApplication: NSRunningApplication?

    func recordActivation(_ application: NSRunningApplication?) {
        guard let application else { return }
        if application.processIdentifier == NSRunningApplication.current.processIdentifier {
            return
        }
        lastExternalApplication = application
    }
}

@MainActor
final class ManagedAppWindowOpener {
    static let shared = ManagedAppWindowOpener()

    var openWindow: OpenWindowAction?

    func open(id: String) {
        WhatsNewCoordinator.shared?.handleWindowRequest()
        open(id: id, remainingAttempts: 10)
    }

    private func open(id: String, remainingAttempts: Int) {
        let sourceApplication = sourceApplicationForActivation()
        NSApp.setActivationPolicy(.regular)

        if let existingWindow = managedWindow(id: id) {
            reopenExistingWindow(existingWindow, sourceApplication: sourceApplication)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.reopenExistingWindow(existingWindow, sourceApplication: sourceApplication)
            }
            return
        }

        if let openWindow {
            openWindow(id: id)
        } else {
            NotificationCenter.default.post(
                name: .openManagedAppWindow,
                object: nil,
                userInfo: ["id": id]
            )
            if remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.open(id: id, remainingAttempts: remainingAttempts - 1)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = self.managedWindow(id: id) else { return }
            self.reopenExistingWindow(window, sourceApplication: sourceApplication)
        }
    }

    private func sourceApplicationForActivation() -> NSRunningApplication? {
        ActivationSourceTracker.shared.lastExternalApplication
            ?? NSWorkspace.shared.frontmostApplication
    }

    private func managedWindow(id: String) -> NSWindow? {
        NSApp.windows.first(where: {
            $0.identifier?.rawValue.localizedCaseInsensitiveContains(id) == true
        })
    }

    private func reopenExistingWindow(_ window: NSWindow, sourceApplication: NSRunningApplication?) {
        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        requestActivation(from: sourceApplication)
    }

    private func requestActivation(from sourceApplication: NSRunningApplication?) {
        let currentApplication = NSRunningApplication.current

        guard let sourceApplication,
              sourceApplication.processIdentifier != currentApplication.processIdentifier else {
            forceActivateCurrentApplication(currentApplication)
            return
        }

        let activated = currentApplication.activate(from: sourceApplication)
        if !activated {
            forceActivateCurrentApplication(currentApplication)
        }
    }

    private func forceActivateCurrentApplication(_ application: NSRunningApplication) {
        _ = application.activate()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var indicatorCoordinator: IndicatorCoordinator?
    private var translationHostWindow: NSWindow?
    private var menuBarIconObserver: NSKeyValueObservation?
    private var dockIconBehaviorObserver: NSKeyValueObservation?
    private var appActivationObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var workspaceSleepObserver: NSObjectProtocol?
    private var screenLockObservers: [NSObjectProtocol] = []
    private var hasInteractiveForegroundContent = false
    private var pluginScreenshotCaptureController: PluginSettingsScreenshotCaptureController?
    private var whatsNewWindowController: WhatsNewWindowController?
    private var startupActivitySubscriptions = Set<AnyCancellable>()
    private let finderTranscriptionService = FinderTranscriptionService()

    private var showMenuBarIconPreference: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true
    }

    private var dockIconBehaviorPreference: DockIconBehavior {
        DockIconBehavior(rawValue: UserDefaults.standard.dockIconBehaviorWhenMenuBarHidden) ?? .keepVisible
    }

    private var shouldShowDockIcon: Bool {
        DockIconVisibility.shouldShowDockIcon(
            showMenuBarIcon: showMenuBarIconPreference,
            dockIconBehavior: dockIconBehaviorPreference,
            hasVisibleManagedWindow: hasVisibleManagedWindow,
            hasInteractiveForegroundContent: hasInteractiveForegroundContent
        )
    }

    static func registerDefaultUserDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            UserDefaultsKeys.showMenuBarIcon: true,
            UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden: DockIconBehavior.keepVisible.rawValue,
            UserDefaultsKeys.appFormattingEnabled: true,
            UserDefaultsKeys.stripFinalPeriodFromStandaloneValuesEnabled: true,
            UserDefaultsKeys.transcriptionNumberNormalizationEnabled: true,
            UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue: TranscriptionNormalizationService.defaultNumberNormalizationMinimumValue,
            UserDefaultsKeys.targetAppCorrectionLearningEnabled: false,
            UserDefaultsKeys.calendarMeetingStartMode: CalendarMeetingStartMode.off.rawValue,
            UserDefaultsKeys.calendarMeetingAutoStopEnabled: false,
            UserDefaultsKeys.calendarMeetingDetectAdHoc: false,
            UserDefaultsKeys.calendarMeetingConfirmSoloEvents: false,
            UserDefaultsKeys.calendarMeetingSuppressedOccurrenceDigests: [String](),
            UserDefaultsKeys.calendarMeetingReminderRequestDigests: [String](),
            UserDefaultsKeys.calendarMeetingNotificationsConfigured: false,
            UserDefaultsKeys.dictationRecoveryRetentionDays: DictationRecoveryRetentionPolicy.defaultPolicy.rawValue
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.registerDefaultUserDefaults()

        guard !AppConstants.isRunningTests else {
            return
        }

        observeStartupActivity()
        NotificationCenter.default.publisher(for: .whatsNewRequested)
            .sink { [weak self] _ in self?.presentWhatsNewManually() }
            .store(in: &startupActivitySubscriptions)

        if AppConstants.isScreenshotAutomation {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                self.openScreenshotWindow()
            }
            return
        }

        let signposter = LaunchSignposts.signposter
        let didFinishLaunchingState = signposter.beginInterval("Launch.didFinishLaunching")
        defer { signposter.endInterval("Launch.didFinishLaunching", didFinishLaunchingState) }

        ServiceContainer.shared.calendarMeetingAutomationController
            .installNotificationRouterIfNeeded()

        NSApp.servicesProvider = finderTranscriptionService
        NSUpdateDynamicServices()

        applyActivationPolicy()

        let coordinator = IndicatorCoordinator(
            countdownModel: ServiceContainer.shared.calendarMeetingCountdownModel
        )
        coordinator.startObserving()
        indicatorCoordinator = coordinator

        #if canImport(Translation)
        if #available(macOS 15, *), let ts = ServiceContainer.shared.translationService as? TranslationService {
            translationHostWindow = TranslationHostWindow(translationService: ts)
            ts.setInteractiveHostMode = { [weak self] enabled in
                guard let self else { return }
                (self.translationHostWindow as? TranslationHostWindow)?.setInteractiveMode(enabled)
                self.hasInteractiveForegroundContent = enabled
                self.applyActivationPolicy(activate: enabled)
            }
        }
        #endif

        // Workflow palette hotkey - opens the standalone workflow palette panel
        ServiceContainer.shared.hotkeyService.onPromptPaletteToggle = {
            DictationViewModel.shared.triggerWorkflowPalette()
        }
        ServiceContainer.shared.hotkeyService.onRecentTranscriptionsToggle = {
            DictationViewModel.shared.triggerRecentTranscriptionsPalette()
        }
        ServiceContainer.shared.hotkeyService.onCopyLastTranscription = {
            DictationViewModel.shared.copyLastTranscriptionToClipboard()
        }
        ServiceContainer.shared.hotkeyService.onPasteLastTranscription = {
            DictationViewModel.shared.pasteLastTranscription()
        }
        ServiceContainer.shared.hotkeyService.onUndoLastDictation = {
            DictationViewModel.shared.undoLastDictation()
        }
        ServiceContainer.shared.hotkeyService.onRestoreRawTranscript = {
            DictationViewModel.shared.restoreRawTranscript()
        }
        ServiceContainer.shared.hotkeyService.onRecorderToggle = {
            AudioRecorderViewModel.shared.toggleRecording()
        }

        let isNormalLaunch = Self.isNormalLaunch(notification)
        if !isNormalLaunch {
            WhatsNewCoordinator.shared?.suppressForCurrentLaunch()
        }
        // Allow launch URLs and Services to arrive first; recheck all priorities
        // at presentation time, not when scheduling the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.presentInitialWindow(isNormalLaunch: isNormalLaunch)
        }

        // Observe appearance preference changes
        menuBarIconObserver = UserDefaults.standard.observe(\.showMenuBarIcon, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyActivationPolicy()
            }
        }
        dockIconBehaviorObserver = UserDefaults.standard.observe(\.dockIconBehaviorWhenMenuBarHidden, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.applyActivationPolicy()
            }
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                ActivationSourceTracker.shared.recordActivation(application)
            }
        }

        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            PluginHTTPClient.resetSharedSession(reason: "macOS wake")
            Task { @MainActor in
                ServiceContainer.shared.audioRecordingService.handleSystemWake()
                ServiceContainer.shared.calendarMeetingAutomationController.handleWake()
            }
        }

        // The optional microphone pre-roll keeps the input open, so release it while the
        // Mac sleeps or the screen is locked and re-arm afterwards.
        workspaceSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                ServiceContainer.shared.audioRecordingService.suspendMicrophonePreroll(reason: .sleep)
            }
        }
        screenLockObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    ServiceContainer.shared.audioRecordingService.suspendMicrophonePreroll(reason: .screenLock)
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    ServiceContainer.shared.audioRecordingService.resumeMicrophonePreroll()
                }
            },
        ]

        // Observe settings window lifecycle
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // The controller starts the launch sync itself; this only fills in if it has not run.
        Task { await ServiceContainer.shared.cloudFolderSyncController.syncIfNeeded() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !AppConstants.isRunningTests, !AppConstants.isScreenshotAutomation else { return }
        ServiceContainer.shared.calendarMeetingAutomationController.handleApplicationBecameActive()
        Task { await ServiceContainer.shared.cloudFolderSyncController.handleApplicationDidBecomeActive() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AppConstants.isScreenshotAutomation {
            try? FileManager.default.removeItem(at: AppConstants.appSupportDirectory)
            return
        }

        guard !AppConstants.isRunningTests else { return }
        WhatsNewCoordinator.shared?.acknowledgePresentation()
        DictationViewModel._shared?.flushPendingPostInsertionPersistence()
        ServiceContainer.shared.audioRecordingService.waitForPendingRecoveryPreservation()
        ServiceContainer.shared.textInsertionService.flushPendingClipboardRestore()
        ServiceContainer.shared.snippetService.saveDeferredUsageCounts()
        ServiceContainer.shared.dictionaryService.saveDeferredUsageCounts()
        ServiceContainer.shared.calendarMeetingAutomationController.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        WhatsNewCoordinator.shared?.handleWindowRequest()
        if ManagedAppReopenSuppression.shared.consumeIfActive() {
            return true
        }
        if !hasVisibleManagedWindow {
            if ManagedLaunchGate.isSetupWizardRequired {
                openSetupWindow()
            } else {
                openSettingsWindow()
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WhatsNewCoordinator.shared?.suppressForCurrentLaunch()
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func openSettingsWindow() {
        ManagedAppWindowOpener.shared.open(id: "settings")
    }

    static func isNormalLaunch(_ notification: Notification) -> Bool {
        notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true
            && notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] == nil
    }

    private func observeStartupActivity() {
        let container = ServiceContainer.shared
        guard let whatsNew = WhatsNewCoordinator.shared else { return }
        whatsNew.activityDidBecomeIdle = {
            NotificationCenter.default.post(name: .startupActivityDidBecomeIdle, object: nil)
        }
        let activities = [
            container.dictationViewModel.$state.map { $0 != .idle }.eraseToAnyPublisher(),
            container.audioRecorderViewModel.$state.map { $0 != .idle }.eraseToAnyPublisher(),
            container.audioRecorderViewModel.$retranscribingRecordingURL.map { $0 != nil }.eraseToAnyPublisher(),
            container.fileTranscriptionViewModel.$batchState.map { $0 == .processing }.eraseToAnyPublisher(),
            container.speakerTranscriptionViewModel.$batchState.map { $0 == .processing }.eraseToAnyPublisher(),
            container.dictionaryTrainingService.activityPublisher,
            HistoryRetranscriptionActivity.recordIDPublisher.map { $0 != nil }.eraseToAnyPublisher()
        ]
        whatsNew.observeActivity(activities)
    }

    var operationInProgress: Bool {
        let container = ServiceContainer.shared
        return container.dictationViewModel.state != .idle
            || container.hotkeyService.isDictationStartPending
            || container.audioRecorderViewModel.state != .idle
            || container.audioRecorderViewModel.retranscribingRecordingURL != nil
            || container.fileTranscriptionViewModel.batchState == .processing
            || container.speakerTranscriptionViewModel.batchState == .processing
            || container.dictionaryTrainingService.activeSampleID != nil
            || HistoryRetranscriptionActivity.recordID != nil
            || Self.hasBlockingModalPresentation
    }

    static var hasBlockingModalPresentation: Bool {
        NSApp.modalWindow != nil
            || NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil }
    }

    private func presentWhatsNewManually() {
        guard let whatsNew = WhatsNewCoordinator.shared,
              whatsNew.beginManualPresentation() else { return }
        // Use the same activity state as the About button. A sheet attached to
        // another window only blocks automatic presentation, not this explicit request.
        showWhatsNew(coordinator: whatsNew)
    }

    private func showWhatsNew(coordinator: WhatsNewCoordinator) {
        if whatsNewWindowController == nil {
            whatsNewWindowController = WhatsNewWindowController(coordinator: coordinator)
        }
        whatsNewWindowController?.showWindow(nil)
        // An unfocused overview still counts as an open window for Dock policy.
        applyActivationPolicy()
    }

    private func presentInitialWindow(isNormalLaunch: Bool) {
        guard let whatsNew = WhatsNewCoordinator.shared else { return }
        let suppressesOptionalPrompts = ManagedLaunchGate.suppressesOptionalPrompts
        if suppressesOptionalPrompts {
            // The highlights stay available from Settings > About.
            whatsNew.suppressForCurrentLaunch()
        }
        let presentation = whatsNew.presentationForLaunch(
            isNormalLaunch: isNormalLaunch,
            setupWizardRequired: ManagedLaunchGate.isSetupWizardRequired,
            operationInProgress: operationInProgress
        )

        LaunchSignposts.signposter.withIntervalSignpost("Launch.initialWindow") {
            switch presentation {
            case .setup:
                NSApp.setActivationPolicy(.regular)
                openSetupWindow()
            case .whatsNew:
                showWhatsNew(coordinator: whatsNew)
            case .none:
                break
            }
        }
    }

    private func openScreenshotWindow() {
        if let pluginId = AppConstants.screenshotPluginId {
            openScreenshotPluginWindow(pluginId: pluginId)
            return
        }

        if ["history", "history-speakers"].contains(AppConstants.screenshotState)
            || AppConstants.screenshotState?.hasPrefix("history-comparison") == true {
            ManagedAppWindowOpener.shared.open(id: "history")
            prepareScreenshotHistoryWindow()
            return
        }

        openSettingsWindow()
        prepareScreenshotSettingsWindow()
    }

    private func openScreenshotPluginWindow(pluginId: String) {
        guard let plugin = PluginManager.shared.loadedPlugins.first(where: { $0.id == pluginId }) else {
            fputs("Screenshot plugin was not loaded: \(pluginId)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        guard plugin.supportsSettingsWindow else {
            fputs("Screenshot plugin has no settings window: \(pluginId)\n", stderr)
            NSApp.terminate(nil)
            return
        }

        PluginSettingsWindowManager.shared.present(plugin)
        prepareScreenshotPluginWindow(pluginId: pluginId)
    }

    private func prepareScreenshotSettingsWindow(remainingAttempts: Int = 8) {
        guard AppConstants.isScreenshotAutomation else { return }

        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.lowercased().contains("settings") == true
        }) else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.prepareScreenshotSettingsWindow(remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        prepareScreenshotWindow(window, contentSize: NSSize(width: 1_150, height: 890))
    }

    private func prepareScreenshotHistoryWindow(remainingAttempts: Int = 8) {
        guard AppConstants.isScreenshotAutomation else { return }

        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.lowercased().contains("history") == true
                || $0.title == String(localized: "History")
        }) else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.prepareScreenshotHistoryWindow(remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        prepareScreenshotWindow(window, contentSize: NSSize(width: 1_150, height: 890))
    }

    private func prepareScreenshotPluginWindow(
        pluginId: String,
        remainingAttempts: Int = 8
    ) {
        guard AppConstants.isScreenshotAutomation else { return }

        guard let window = PluginSettingsWindowManager.shared.managedWindow(for: pluginId) else {
            guard remainingAttempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self.prepareScreenshotPluginWindow(
                    pluginId: pluginId,
                    remainingAttempts: remainingAttempts - 1
                )
            }
            return
        }

        var contentSize = AppConstants.screenshotPluginWindowSize
        if let requestedSize = contentSize,
           let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            let titlebarHeight = window.frame.height - window.contentLayoutRect.height
            let maximumHeight = max(400, visibleFrame.height - titlebarHeight - 80)
            contentSize = NSSize(width: requestedSize.width, height: min(requestedSize.height, maximumHeight))
        }

        guard let readyFileURL = AppConstants.screenshotReadyFileURL,
              let commandFileURL = AppConstants.screenshotScrollCommandFileURL else {
            prepareScreenshotWindow(window, contentSize: contentSize)
            return
        }

        prepareScreenshotWindow(window, contentSize: contentSize, writesReadyMarker: false)
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let window else { return }
            let controller = PluginSettingsScreenshotCaptureController(
                window: window,
                readyFileURL: readyFileURL,
                commandFileURL: commandFileURL
            )
            self.pluginScreenshotCaptureController = controller
            controller.start()
        }
    }

    private func prepareScreenshotWindow(
        _ window: NSWindow,
        contentSize: NSSize? = nil,
        writesReadyMarker: Bool = true
    ) {
        if let contentSize {
            window.setContentSize(contentSize)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        guard writesReadyMarker,
              let readyFileURL = AppConstants.screenshotReadyFileURL else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            do {
                try "\(window.windowNumber)\n".write(
                    to: readyFileURL,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                fputs("Could not write screenshot readiness marker: \(error)\n", stderr)
            }
        }
    }

    private func openSetupWindow() {
        ManagedAppWindowOpener.shared.open(id: "setup")
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "dictum" else { return }
        openSettingsWindow()
    }

    func isManagedWindow(_ window: NSWindow) -> Bool {
        if let identifier = window.identifier?.rawValue.lowercased() {
            if identifier.contains("settings")
                || identifier.contains("setup")
                || identifier.contains("history")
                || identifier.contains("errors")
                || identifier == "whats-new" {
                return true
            }
        }

        let title = window.title
        return title == String(localized: "Settings")
            || title == String(localized: "dictum Setup")
            || title == String(localized: "History")
            || title == String(localized: "Error Log")
    }

    private var hasVisibleManagedWindow: Bool {
        NSApp.windows.contains { isManagedWindow($0) && $0.isVisible }
    }

    private func applyActivationPolicy(activate: Bool = false) {
        let targetPolicy: NSApplication.ActivationPolicy = shouldShowDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }

        if activate {
            NSApp.activate()
        }
    }

    @objc nonisolated private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isManagedWindow(window), window.isVisible else { return }
            // The overview participates in Dock policy without activating the app
            // over the user's current work when it is shown automatically.
            self.applyActivationPolicy(activate: window.identifier?.rawValue != "whats-new")
        }
    }

    @objc nonisolated private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isManagedWindow(window) else { return }
            self.applyActivationPolicy()
        }
    }
}
