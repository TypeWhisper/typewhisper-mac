import AppKit
import SwiftUI

enum PremiumSettingsDestination: String, CaseIterable, Hashable, Sendable {
    case access
    case calendarMeeting
    case correctionLearning
    case cloudSync
}

@MainActor
protocol PremiumSettingsWindowPresenting: AnyObject {
    func present(_ destination: PremiumSettingsDestination)
    func closeAll()
}

@MainActor
struct PremiumSettingsWindowDefinition {
    let title: String
    let preferredSize: CGSize
    let minimumSize: CGSize
    let accessibilityIdentifier: String
    let content: AnyView
}

@MainActor
struct PremiumSettingsWindowFactories {
    typealias Factory = @MainActor () -> PremiumSettingsWindowDefinition

    let access: Factory
    let calendarMeeting: Factory
    let correctionLearning: Factory
    let cloudSync: Factory

    func makeDefinition(
        for destination: PremiumSettingsDestination
    ) -> PremiumSettingsWindowDefinition {
        switch destination {
        case .access:
            access()
        case .calendarMeeting:
            calendarMeeting()
        case .correctionLearning:
            correctionLearning()
        case .cloudSync:
            cloudSync()
        }
    }

    static var live: Self {
        Self(
            access: {
                PremiumSettingsWindowDefinition(
                    title: String(localized: "premium.window.access.title"),
                    preferredSize: CGSize(width: 560, height: 500),
                    minimumSize: CGSize(width: 500, height: 420),
                    accessibilityIdentifier: "premium.window.access",
                    content: AnyView(
                        PremiumAccessSettingsView(
                            licenseService: .shared,
                            premiumAccount: ServiceContainer.shared.premiumAccountService,
                            settingsNavigation: .shared
                        )
                    )
                )
            },
            calendarMeeting: {
                PremiumSettingsWindowDefinition(
                    title: String(localized: "premium.window.calendar.title"),
                    preferredSize: CGSize(width: 640, height: 700),
                    minimumSize: CGSize(width: 560, height: 520),
                    accessibilityIdentifier: "premium.window.calendar",
                    content: AnyView(
                        PremiumCalendarMeetingSettingsWindow(
                            licenseService: .shared,
                            premiumAccount: ServiceContainer.shared.premiumAccountService,
                            controllerFactory: {
                                ServiceContainer.shared.calendarMeetingAutomationController
                            },
                            onManageAccess: {
                                PremiumSettingsWindowManager.shared.present(.access)
                            }
                        )
                    )
                )
            },
            correctionLearning: {
                PremiumSettingsWindowDefinition(
                    title: String(localized: "premium.window.learning.title"),
                    preferredSize: CGSize(width: 580, height: 560),
                    minimumSize: CGSize(width: 520, height: 460),
                    accessibilityIdentifier: "premium.window.learning",
                    content: AnyView(
                        PremiumCorrectionLearningSettingsView(
                            licenseService: .shared,
                            correctionLearningService: ServiceContainer.shared.targetAppCorrectionLearningService,
                            onManageAccess: {
                                PremiumSettingsWindowManager.shared.present(.access)
                            }
                        )
                    )
                )
            },
            cloudSync: {
                PremiumSettingsWindowDefinition(
                    title: String(localized: "premium.window.sync.title"),
                    preferredSize: CGSize(width: 640, height: 600),
                    minimumSize: CGSize(width: 560, height: 500),
                    accessibilityIdentifier: "premium.window.sync",
                    content: AnyView(
                        PremiumCloudSyncSettingsWindow(
                            licenseService: .shared,
                            premiumAccount: ServiceContainer.shared.premiumAccountService,
                            syncController: ServiceContainer.shared.cloudFolderSyncController,
                            onManageAccess: {
                                PremiumSettingsWindowManager.shared.present(.access)
                            }
                        )
                    )
                )
            }
        )
    }
}

@MainActor
final class PremiumSettingsWindowManager: PremiumSettingsWindowPresenting {
    typealias WindowFactory = @MainActor (NSRect, NSWindow.StyleMask) -> NSWindow

    static let shared = PremiumSettingsWindowManager(factories: .live)

    private let factories: PremiumSettingsWindowFactories
    private let windowFactory: WindowFactory
    private let activationHandler: @MainActor () -> Void
    private var windows: [PremiumSettingsDestination: NSWindow] = [:]
    private var delegates: [PremiumSettingsDestination: PremiumSettingsWindowDelegate] = [:]

    init(
        factories: PremiumSettingsWindowFactories,
        windowFactory: @escaping WindowFactory = { contentRect, styleMask in
            NSWindow(
                contentRect: contentRect,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
        },
        activationHandler: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.factories = factories
        self.windowFactory = windowFactory
        self.activationHandler = activationHandler
    }

    func present(_ destination: PremiumSettingsDestination) {
        if let window = windows[destination] {
            window.makeKeyAndOrderFront(nil)
            activationHandler()
            return
        }

        let definition = factories.makeDefinition(for: destination)
        let contentRect = NSRect(origin: .zero, size: definition.preferredSize)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = windowFactory(contentRect, styleMask)
        let hostingView = NSHostingView(
            rootView: PremiumSettingsWindowContent(
                accessibilityIdentifier: definition.accessibilityIdentifier,
                content: definition.content
            )
        )
        hostingView.sizingOptions = []

        window.title = definition.title
        window.identifier = NSUserInterfaceItemIdentifier(definition.accessibilityIdentifier)
        window.contentMinSize = definition.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = hostingView

        let autosaveName = "premium-settings.\(destination.rawValue)"
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)

        let delegate = PremiumSettingsWindowDelegate(destination: destination) { [weak self] destination in
            self?.windows[destination] = nil
            self?.delegates[destination] = nil
        }
        delegates[destination] = delegate
        windows[destination] = window
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        activationHandler()
    }

    func closeAll() {
        let openWindows = Array(windows.values)
        for window in openWindows {
            window.close()
        }
        windows.removeAll()
        delegates.removeAll()
    }

    func managedWindow(
        for destination: PremiumSettingsDestination
    ) -> NSWindow? {
        windows[destination]
    }
}

private struct PremiumSettingsWindowContent: View {
    let accessibilityIdentifier: String
    let content: AnyView

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

@MainActor
private final class PremiumSettingsWindowDelegate: NSObject, NSWindowDelegate {
    private let destination: PremiumSettingsDestination
    private let onClose: @MainActor (PremiumSettingsDestination) -> Void

    init(
        destination: PremiumSettingsDestination,
        onClose: @escaping @MainActor (PremiumSettingsDestination) -> Void
    ) {
        self.destination = destination
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose(destination)
    }
}

@MainActor
private struct PremiumCalendarMeetingSettingsWindow: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var premiumAccount: PremiumAccountService
    private let controllerFactory: @MainActor () -> CalendarMeetingAutomationController
    private let onManageAccess: () -> Void

    init(
        licenseService: LicenseService,
        premiumAccount: PremiumAccountService,
        controllerFactory: @escaping @MainActor () -> CalendarMeetingAutomationController,
        onManageAccess: @escaping () -> Void
    ) {
        self.license = licenseService
        self.premiumAccount = premiumAccount
        self.controllerFactory = controllerFactory
        self.onManageAccess = onManageAccess
    }

    var body: some View {
        if CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: license.hasCommercialLicense,
            hasPremiumEntitlement: premiumAccount.hasPremiumEntitlement
        ) {
            CalendarMeetingSettingsSection(controller: controllerFactory())
        } else {
            PremiumLockedDetailView(
                message: String(localized: "premium.window.calendar.locked"),
                onManageAccess: onManageAccess
            )
        }
    }
}

@MainActor
private struct PremiumCloudSyncSettingsWindow: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var premiumAccount: PremiumAccountService
    @ObservedObject private var syncController: CloudFolderSyncController
    private let onManageAccess: () -> Void

    init(
        licenseService: LicenseService,
        premiumAccount: PremiumAccountService,
        syncController: CloudFolderSyncController,
        onManageAccess: @escaping () -> Void
    ) {
        self.license = licenseService
        self.premiumAccount = premiumAccount
        self.syncController = syncController
        self.onManageAccess = onManageAccess
    }

    var body: some View {
        if premiumAccount.isSignedIn,
           premiumAccount.hasPremiumEntitlement,
           syncController.canUseSync {
            CloudFolderSyncSettingsView(controller: syncController)
        } else {
            PremiumLockedDetailView(
                message: lockedMessage,
                onManageAccess: onManageAccess
            )
        }
    }

    private var lockedMessage: String {
        if license.hasCommercialLicense,
           premiumAccount.isSignedIn,
           !premiumAccount.hasPremiumEntitlement {
            return String(localized: "premium.window.sync.linkRequired")
        }
        return String(localized: "premium.window.sync.locked")
    }
}
