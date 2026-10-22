import AppKit
import Combine
import XCTest
@testable import TypeWhisper

@MainActor
final class WhatsNewCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TypeWhisperTests.WhatsNew.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: UserDefaultsKeys.setupWizardCompleted)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testExistingInstallationWithoutMarkerGetsHighlightsAheadOfOtherPrompts() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.shouldDeferAutomaticSheets)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hasUnseenContent)
    }

    func testFreshInstallationSeedsContentAndKeepsSetupFirst() {
        defaults.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
        let coordinator = WhatsNewCoordinator(defaults: defaults, contentVersion: 2)

        XCTAssertFalse(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator, setupRequired: true), .setup)
        defaults.set(true, forKey: UserDefaultsKeys.setupWizardCompleted)
        let nextLaunch = WhatsNewCoordinator(defaults: defaults, contentVersion: 2)
        XCTAssertFalse(nextLaunch.hasUnseenContent)
        XCTAssertEqual(launch(nextLaunch, otherPromptsPending: false), .none)
    }

    func testSetupWinsEvenWhenItIsResetAfterInitialization() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator, setupRequired: true), .setup)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testFirstTimeSetupStillOpensOnANonDefaultLaunch() {
        defaults.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.suppressForCurrentLaunch()

        XCTAssertEqual(launch(coordinator, normal: false, setupRequired: true), .setup)
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertFalse(coordinator.hasUnseenContent)
    }

    func testFirstTimeSetupKeepsPriorityWhenActivityWasDetectedAtLaunch() {
        defaults.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.updateOperationInProgress(true)

        XCTAssertEqual(launch(coordinator, setupRequired: true, busy: true), .setup)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testAcknowledgementPersistsAcrossLaunchesAndBuildChanges() {
        let coordinator = WhatsNewCoordinator(defaults: defaults, contentVersion: 2)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        coordinator.acknowledgePresentation()

        XCTAssertFalse(coordinator.shouldDeferAutomaticSheets)
        defaults.set("99.0+123@daily", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)
        let nextLaunch = WhatsNewCoordinator(defaults: defaults, contentVersion: 2)
        XCTAssertFalse(nextLaunch.hasUnseenContent)
        XCTAssertEqual(launch(nextLaunch, otherPromptsPending: false), .none)
    }

    func testOnlyNewerContentBecomesPending() {
        defaults.set(2, forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
        XCTAssertFalse(WhatsNewCoordinator(defaults: defaults, contentVersion: 1).hasUnseenContent)
        XCTAssertFalse(WhatsNewCoordinator(defaults: defaults, contentVersion: 2).hasUnseenContent)
        XCTAssertTrue(WhatsNewCoordinator(defaults: defaults, contentVersion: 3).hasUnseenContent)
    }

    func testFreshInstallSeedingNeverDowngradesSavedVersion() {
        defaults.set(3, forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
        defaults.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
        _ = WhatsNewCoordinator(defaults: defaults, contentVersion: 2)
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion), 3)
    }

    func testURLOrServiceLaunchStaysWindowlessAndDoesNotConsumeContent() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator, normal: false), .none)
        XCTAssertTrue(coordinator.isSuppressedForLaunch)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(WhatsNewCoordinator(defaults: defaults)), .whatsNew)
    }

    func testActionArrivingDuringLaunchDelayCancelsAllAutomaticPrompts() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.suppressForCurrentLaunch()

        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testExplicitNavigationDuringLaunchWinsOverHighlights() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.handleWindowRequest()
        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertTrue(coordinator.hasUnseenContent)
    }

    func testStartupSettingsWindowDoesNotSuppressItsOwnPromo() {
        defaults.set(WhatsNewContent.version, forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .settings)
        coordinator.handleWindowRequest()
        XCTAssertFalse(coordinator.isSuppressedForLaunch)
    }

    func testBusyLaunchNeverRetriesWhenOperationFinishesOrSettingsReopen() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)

        XCTAssertEqual(launch(coordinator, busy: true), .none)
        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertTrue(coordinator.hasUnseenContent)
    }

    func testSkippedHighlightsDoNotSuppressOtherPromptsOnLaterSettingsVisits() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.suppressForCurrentLaunch()
        XCTAssertTrue(coordinator.shouldDeferAutomaticSheets)
        XCTAssertEqual(launch(coordinator, normal: false), .none)

        coordinator.handleWindowRequest()

        XCTAssertFalse(coordinator.shouldDeferAutomaticSheets)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testFinishedDictationDoesNotSuppressOtherPromptsForTheRestOfTheSession() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        coordinator.acknowledgePresentation()

        coordinator.updateOperationInProgress(true)
        XCTAssertTrue(coordinator.shouldDeferAutomaticSheets)
        coordinator.updateOperationInProgress(false)
        coordinator.handleWindowRequest()

        XCTAssertFalse(coordinator.shouldDeferAutomaticSheets)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testOverlappingActivityNotifiesIdleOnlyAfterAllWorkFinishesWithoutRetryingHighlights() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        let recording = CurrentValueSubject<Bool, Never>(false)
        let transcription = CurrentValueSubject<Bool, Never>(false)
        var idleTransitions = 0
        coordinator.activityDidBecomeIdle = {
            XCTAssertFalse(coordinator.operationInProgress)
            idleTransitions += 1
        }
        coordinator.observeActivity([recording.eraseToAnyPublisher(), transcription.eraseToAnyPublisher()])
        XCTAssertEqual(idleTransitions, 0)
        XCTAssertEqual(launch(coordinator), .whatsNew)

        recording.send(true)
        transcription.send(true)
        recording.send(false)
        XCTAssertTrue(coordinator.operationInProgress)
        XCTAssertEqual(idleTransitions, 0)
        transcription.send(false)

        XCTAssertFalse(coordinator.shouldDeferAutomaticSheets)
        XCTAssertEqual(idleTransitions, 1)
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
        transcription.send(false)
        XCTAssertTrue(coordinator.beginManualPresentation())
        coordinator.acknowledgePresentation()
        XCTAssertEqual(idleTransitions, 1, "Closing the overview must not request another startup sheet")
    }

    func testInterruptionClosesVisibleOverviewBeforeActionAndKeepsContentPending() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        var dismissals = 0
        coordinator.dismissPresentation = {
            dismissals += 1
            XCTAssertFalse(coordinator.isPresenting)
            // The window delegate must not treat an interruption as a user skip.
            coordinator.acknowledgePresentation()
        }

        coordinator.suppressForCurrentLaunch()
        coordinator.suppressForCurrentLaunch()

        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertEqual(launch(WhatsNewCoordinator(defaults: defaults)), .whatsNew)
    }

    func testAcknowledgementWithoutPresentationDoesNotConsumeContent() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.acknowledgePresentation()
        XCTAssertTrue(coordinator.hasUnseenContent)
    }

    func testClosingDoesNotQueueAnotherStartupPrompt() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        coordinator.acknowledgePresentation()
        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertFalse(coordinator.isPresenting)
    }

    func testManualPresentationCanReopenAcknowledgedContentWithoutResettingVersion() {
        defaults.set(3, forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
        let coordinator = WhatsNewCoordinator(defaults: defaults, contentVersion: 2)

        XCTAssertTrue(coordinator.beginManualPresentation())
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertFalse(coordinator.hasUnseenContent)
        coordinator.acknowledgePresentation()

        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion), 3)
        XCTAssertTrue(coordinator.beginManualPresentation())
        coordinator.acknowledgePresentation()
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testManualPresentationIsAvailableAfterAnActionSuppressedAutomaticPresentation() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator, normal: false), .none)

        XCTAssertTrue(coordinator.beginManualPresentation())
        XCTAssertTrue(coordinator.isSuppressedForLaunch)
        XCTAssertTrue(coordinator.hasUnseenContent)
        coordinator.acknowledgePresentation()

        XCTAssertFalse(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testManualPresentationBeforeLaunchDecisionPreventsAutomaticPrompts() {
        defaults.set(WhatsNewContent.version, forKey: UserDefaultsKeys.lastSeenWhatsNewContentVersion)
        let coordinator = WhatsNewCoordinator(defaults: defaults)

        XCTAssertTrue(coordinator.beginManualPresentation())
        XCTAssertTrue(coordinator.shouldDeferAutomaticSheets)
        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertTrue(coordinator.isPresenting)
        coordinator.acknowledgePresentation()

        // Later Settings visits may show their existing prompts. Dismissal itself
        // must not run another automatic window presentation.
        XCTAssertFalse(coordinator.shouldDeferAutomaticSheets)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testNavigationKeepsManualWindowOpenButAnActionStillClosesIt() throws {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.beginManualPresentation())
        let controller = WhatsNewWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)

        coordinator.handleWindowRequest()

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertTrue(coordinator.shouldDeferAutomaticSheets)
        coordinator.suppressForCurrentLaunch()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(coordinator.hasUnseenContent)
    }

    func testBusyManualRequestDoesNotQueuePresentationWhenOperationFinishes() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        coordinator.updateOperationInProgress(true)

        XCTAssertFalse(coordinator.beginManualPresentation())
        XCTAssertFalse(coordinator.isPresenting)
        coordinator.updateOperationInProgress(false)

        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
        XCTAssertTrue(coordinator.beginManualPresentation())
    }

    func testManualPresentationRechecksActivityBeforeOpening() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)

        XCTAssertFalse(coordinator.operationInProgress)
        XCTAssertFalse(coordinator.beginManualPresentation(operationInProgress: true))
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testOperationStartingAfterManualPresentationClosesWindowWithoutAcknowledging() throws {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertTrue(coordinator.beginManualPresentation())
        let controller = WhatsNewWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)

        coordinator.updateOperationInProgress(true)

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hasUnseenContent)

        coordinator.updateOperationInProgress(false)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(coordinator.beginManualPresentation())
        controller.showWindow(nil)
        XCTAssertTrue(window.isVisible)
        controller.close()
        XCTAssertFalse(coordinator.hasUnseenContent)
    }

    func testWindowCloseAcknowledgesContentWithoutOpeningAnotherWindow() throws {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        let controller = WhatsNewWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isRestorable)
        controller.showWindow(nil)
        controller.close()

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testOverviewIsManagedForDockVisibilityWhileOpen() throws {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        let controller = WhatsNewWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        let appDelegate = AppDelegate()
        controller.showWindow(nil)
        defer { controller.close() }

        XCTAssertTrue(appDelegate.isManagedWindow(window))
        XCTAssertTrue(DockIconVisibility.shouldShowDockIcon(
            showMenuBarIcon: false,
            dockIconBehavior: .onlyWhileWindowOpen,
            hasVisibleManagedWindow: appDelegate.isManagedWindow(window) && window.isVisible
        ))
        controller.close()
        XCTAssertFalse(DockIconVisibility.shouldShowDockIcon(
            showMenuBarIcon: false,
            dockIconBehavior: .onlyWhileWindowOpen,
            hasVisibleManagedWindow: appDelegate.isManagedWindow(window) && window.isVisible
        ))
    }

    func testAttachedSheetRemainsABlockerAfterTrackedActivityEnds() async {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        coordinator.updateOperationInProgress(true)
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        sheet.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer {
            parent.close()
            sheet.close()
        }
        let ended = expectation(description: "blocking sheet ends")
        parent.beginSheet(sheet) { _ in ended.fulfill() }

        coordinator.updateOperationInProgress(false)
        XCTAssertFalse(coordinator.operationInProgress)
        XCTAssertTrue(AppDelegate.hasBlockingModalPresentation)
        parent.endSheet(sheet)
        await fulfillment(of: [ended], timeout: 2)

        XCTAssertFalse(AppDelegate.hasBlockingModalPresentation)
        XCTAssertEqual(launch(coordinator), .none, "Ending a sheet must not retry update highlights")
    }

    func testModalSessionRemainsABlockerUntilItEnds() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let session = NSApp.beginModalSession(for: panel)
        _ = NSApp.runModalSession(session)

        XCTAssertTrue(AppDelegate.hasBlockingModalPresentation)
        NSApp.endModalSession(session)

        XCTAssertFalse(AppDelegate.hasBlockingModalPresentation)
    }

    func testInterruptionClosesActualWindowWithoutAcknowledging() throws {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        XCTAssertEqual(launch(coordinator), .whatsNew)
        let controller = WhatsNewWindowController(coordinator: coordinator)
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)

        coordinator.suppressForCurrentLaunch()

        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(coordinator.hasUnseenContent)
    }

    func testIncomingURLDismissesOverviewBeforeRoutingTheAction() {
        let coordinator = WhatsNewCoordinator(defaults: defaults)
        let previous = WhatsNewCoordinator.shared
        WhatsNewCoordinator.shared = coordinator
        defer { WhatsNewCoordinator.shared = previous }
        XCTAssertEqual(launch(coordinator), .whatsNew)
        let controller = WhatsNewWindowController(coordinator: coordinator)
        controller.showWindow(nil)

        AppDelegate().application(NSApplication.shared, open: [URL(string: "typewhisper://test-action")!])

        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertTrue(coordinator.hasUnseenContent)
        XCTAssertEqual(launch(coordinator), .none)
    }

    func testOnlyExplicitDefaultLaunchWithoutNotificationAllowsAutomaticHighlights() {
        let name = NSApplication.didFinishLaunchingNotification
        XCTAssertFalse(AppDelegate.isNormalLaunch(Notification(name: name)))
        XCTAssertFalse(AppDelegate.isNormalLaunch(Notification(name: name, userInfo: [
            NSApplication.launchIsDefaultUserInfoKey: false
        ])))
        XCTAssertTrue(AppDelegate.isNormalLaunch(Notification(name: name, userInfo: [
            NSApplication.launchIsDefaultUserInfoKey: true
        ])))
        XCTAssertFalse(AppDelegate.isNormalLaunch(Notification(name: name, userInfo: [
            NSApplication.launchIsDefaultUserInfoKey: true,
            NSApplication.launchUserNotificationUserInfoKey: "notification payload"
        ])))
    }

    private func launch(
        _ coordinator: WhatsNewCoordinator,
        normal: Bool = true,
        setupRequired: Bool = false,
        busy: Bool = false,
        otherPromptsPending: Bool = true
    ) -> InitialWindowPresentation {
        coordinator.presentationForLaunch(
            isNormalLaunch: normal,
            setupWizardRequired: setupRequired,
            operationInProgress: busy
        )
    }
}
