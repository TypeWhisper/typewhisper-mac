import SwiftUI
import AVFoundation
import Combine
import TypeWhisperPluginSDK
@preconcurrency import Sparkle

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

enum MenuBarIconState {
    static func isRecordingActive(
        dictationState: DictationViewModel.State,
        recorderState: AudioRecorderViewModel.RecorderState
    ) -> Bool {
        dictationState == .recording || recorderState == .recording
    }
}

private struct MenuBarExtraLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var recorder = AudioRecorderViewModel.shared

    private var title: String {
        AppConstants.isDevelopment ? "TypeWhisper Dev" : "TypeWhisper"
    }

    private var isRecordingActive: Bool {
        MenuBarIconState.isRecordingActive(
            dictationState: dictation.state,
            recorderState: recorder.state
        )
    }

    var body: some View {
        Image(nsImage: MenuBarLogoMarkImage.image(isRecordingActive: isRecordingActive))
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

    static func image(isRecordingActive: Bool) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        NSGraphicsContext.current?.shouldAntialias = true
        (isRecordingActive ? NSColor.systemRed : NSColor.black).setFill()

        for rect in barRects(in: CGRect(origin: .zero, size: size)) {
            NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width / 2,
                yRadius: rect.width / 2
            ).fill()
        }

        image.unlockFocus()
        image.isTemplate = !isRecordingActive
        return image
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

struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var startupSheet: StartupSheetRoute?
    @State private var lastPresentedStartupSheet: StartupSheetRoute?
    @State private var ignoreNextStartupSheetDismiss = false

    private var postUpdatePromptCoordinator: PostUpdatePromptCoordinator {
        PostUpdatePromptCoordinator.shared
    }

    private var settingsNavigation: SettingsNavigationCoordinator {
        SettingsNavigationCoordinator.shared
    }

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
        }

        settingsScene

        Window(String(localized: "TypeWhisper Setup"), id: "setup") {
            setupContent
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 820, height: 560)

        Window(String(localized: "History"), id: "history") {
            historyContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 500)

        Window(String(localized: "Error Log"), id: "errors") {
            errorLogContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 500, height: 400)
    }

    private var settingsScene: some Scene {
        Window(String(localized: "Settings"), id: "settings") {
            settingsContent
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1050, height: 600)
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
                .sheet(item: $startupSheet, onDismiss: handleStartupSheetDismissed) { route in
                    switch route {
                    case .welcome:
                        WelcomeSheet()
                    case .postUpdateLicensing:
                        PostUpdateLicensePromptView(
                            onPersonalOSS: handlePersonalOSSSelection,
                            onWorkUsage: handleWorkUsageSelection,
                            onExistingKey: handleExistingKeySelection,
                            onBecomeSupporter: handleSupporterSelection,
                            onNotNow: handlePromptDismissalAction
                        )
                    }
                }
                .task {
                    refreshStartupSheet()
                }
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

        // Trigger ServiceContainer initialization
        _ = ServiceContainer.shared
        SettingsNavigationCoordinator.shared = SettingsNavigationCoordinator()
        WorkflowsNavigationCoordinator.shared = WorkflowsNavigationCoordinator()
        PostUpdatePromptCoordinator.shared = PostUpdatePromptCoordinator()

        Task { @MainActor in
            await ServiceContainer.shared.initialize()
        }
    }

    private func refreshStartupSheet() {
        if HomeViewModel.shared.showSetupWizard {
            startupSheet = nil
            return
        }

        let nextRoute: StartupSheetRoute?
        if LicenseService.shared.needsWelcomeSheet {
            nextRoute = .welcome
        } else {
            nextRoute = postUpdatePromptCoordinator.activeSheetRoute
        }

        startupSheet = nextRoute
        if let nextRoute {
            lastPresentedStartupSheet = nextRoute
        }
    }

    private func handleStartupSheetDismissed() {
        let dismissedRoute = lastPresentedStartupSheet
        defer {
            lastPresentedStartupSheet = nil
        }

        if dismissedRoute == .postUpdateLicensing {
            if ignoreNextStartupSheetDismiss {
                ignoreNextStartupSheetDismiss = false
            } else {
                postUpdatePromptCoordinator.handleSheetDismissedWithoutExplicitAction()
            }
        }

        refreshStartupSheet()
    }

    private func dismissStartupPrompt(after action: () -> Void) {
        ignoreNextStartupSheetDismiss = true
        action()
        startupSheet = nil
    }

    private func handlePersonalOSSSelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handlePersonalOSSSelection()
        }
    }

    private func handleWorkUsageSelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleWorkUsageSelection()
            settingsNavigation.navigateToLicense(target: .top)
        }
    }

    private func handleExistingKeySelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleExistingKeySelection()
            settingsNavigation.navigateToLicense(target: .activationKey)
        }
    }

    private func handleSupporterSelection() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleSupporterSelection()
            settingsNavigation.navigateToLicense(target: .supporter)
        }
    }

    private func handlePromptDismissalAction() {
        dismissStartupPrompt {
            postUpdatePromptCoordinator.handleNotNowSelection()
        }
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
final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var indicatorCoordinator: IndicatorCoordinator?
    private var translationHostWindow: NSWindow?
    private var menuBarIconObserver: NSKeyValueObservation?
    private var dockIconBehaviorObserver: NSKeyValueObservation?
    private var appActivationObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var hasInteractiveForegroundContent = false
    private lazy var updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    var updateChecker: UpdateChecker {
        .sparkle(updaterController.updater)
    }

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
            UserDefaultsKeys.updateChannel: AppConstants.defaultReleaseChannel.rawValue,
            UserDefaultsKeys.appFormattingEnabled: true,
            UserDefaultsKeys.transcriptionNumberNormalizationEnabled: true,
            UserDefaultsKeys.targetAppCorrectionLearningEnabled: false
        ])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.registerDefaultUserDefaults()

        guard !AppConstants.isRunningTests else {
            return
        }

        UpdateChecker.shared = updateChecker
        applyActivationPolicy()

        let coordinator = IndicatorCoordinator()
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
        ServiceContainer.shared.hotkeyService.onRecorderToggle = {
            AudioRecorderViewModel.shared.toggleRecording()
        }

        // Auto-open the standalone setup assistant while first-run setup is incomplete.
        if HomeViewModel.shared.showSetupWizard {
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
            HomeViewModel.shared.showSetupWizard = true
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSetupWindow()
            }
        } else if PostUpdatePromptCoordinator.shared.shouldAutoOpenSettingsOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.openSettingsWindow()
            }
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
        }

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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleManagedWindow {
            if HomeViewModel.shared.showSetupWizard {
                openSetupWindow()
            } else {
                openSettingsWindow()
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func openSettingsWindow() {
        ManagedAppWindowOpener.shared.open(id: "settings")
    }

    private func openSetupWindow() {
        ManagedAppWindowOpener.shared.open(id: "setup")
    }

    private func handleIncomingURL(_ url: URL) {
        guard SupporterDiscordService.canHandleCallbackURL(url) else { return }

        openSettingsWindow()

        Task { @MainActor in
            await SupporterDiscordService.shared?.handleCallbackURL(url)
        }
    }

    private func isManagedWindow(_ window: NSWindow) -> Bool {
        if let identifier = window.identifier?.rawValue.lowercased() {
            if identifier.contains("settings")
                || identifier.contains("setup")
                || identifier.contains("history")
                || identifier.contains("errors") {
                return true
            }
        }

        let title = window.title
        return title == String(localized: "Settings")
            || title == String(localized: "TypeWhisper Setup")
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
            self.applyActivationPolicy(activate: true)
        }
    }

    @objc nonisolated private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isManagedWindow(window) else { return }
            self.applyActivationPolicy()
        }
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppConstants.effectiveUpdateChannel.sparkleChannels
    }
}
