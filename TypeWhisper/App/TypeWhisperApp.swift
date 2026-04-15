import SwiftUI
import AVFoundation
import Combine
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

struct TypeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(UserDefaultsKeys.showMenuBarIcon) private var showMenuBarIcon = true
    @State private var showWelcomeSheet = false

    var body: some Scene {
        MenuBarExtra(AppConstants.isDevelopment ? "TypeWhisper Dev" : "TypeWhisper", systemImage: "waveform", isInserted: $showMenuBarIcon) {
            menuBarContent
        }
        .menuBarExtraStyle(.menu)

        settingsScene

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
                .sheet(isPresented: $showWelcomeSheet) {
                    WelcomeSheet()
                }
                .task {
                    if LicenseService.shared.needsWelcomeSheet {
                        showWelcomeSheet = true
                    }
                }
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

        Task { @MainActor in
            await ServiceContainer.shared.initialize()
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
        application.activate()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            UserDefaultsKeys.showMenuBarIcon: true,
            UserDefaultsKeys.dockIconBehaviorWhenMenuBarHidden: DockIconBehavior.keepVisible.rawValue,
            UserDefaultsKeys.updateChannel: AppConstants.defaultReleaseChannel.rawValue
        ])

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

        // Prompt palette hotkey - opens standalone prompt palette panel
        ServiceContainer.shared.hotkeyService.onPromptPaletteToggle = {
            DictationViewModel.shared.triggerStandalonePromptSelection()
        }

        // Auto-open Settings with setup wizard when microphone permission is not yet granted
        if AVAudioApplication.shared.recordPermission != .granted {
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
            HomeViewModel.shared.showSetupWizard = true
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
            openSettingsWindow()
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

    private func handleIncomingURL(_ url: URL) {
        guard SupporterDiscordService.canHandleCallbackURL(url) else { return }

        openSettingsWindow()

        Task { @MainActor in
            await SupporterDiscordService.shared?.handleCallbackURL(url)
        }
    }

    private func isManagedWindow(_ window: NSWindow) -> Bool {
        if let identifier = window.identifier?.rawValue.lowercased() {
            if identifier.contains("settings") || identifier.contains("history") || identifier.contains("errors") {
                return true
            }
        }

        let title = window.title
        return title == String(localized: "Settings")
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
