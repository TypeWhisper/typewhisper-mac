import Foundation
import XCTest
@testable import TypeWhisper

@MainActor
final class CalendarMeetingAutomationControllerTests: XCTestCase {
    func testNotificationStartResponseOnlyArmsOccurrence() {
        let digest = String(repeating: "a", count: 64)

        XCTAssertEqual(
            CalendarMeetingAutomationController.automationUserAction(
                for: .armStart(digest)
            ),
            .armOccurrence(digest)
        )
        XCTAssertEqual(
            CalendarMeetingAutomationController.automationUserAction(
                for: .suppress(digest)
            ),
            .suppressOccurrence(digest)
        )
        XCTAssertNil(CalendarMeetingAutomationController.automationUserAction(
            for: .openPremiumSettings
        ))
    }

    func testFreeAndOffStatesNeverActivateOSServices() {
        XCTAssertFalse(CalendarMeetingAutomationController.shouldActivateOSServices(
            hasPremiumAccess: false,
            startMode: .automatic
        ))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldActivateOSServices(
            hasPremiumAccess: true,
            startMode: .off
        ))
        XCTAssertTrue(CalendarMeetingAutomationController.shouldActivateOSServices(
            hasPremiumAccess: true,
            startMode: .reminder
        ))
    }

    func testAutoStopRequiresFullyAuthorizedNotifications() {
        XCTAssertTrue(CalendarMeetingAutomationController.canUseAutoStopNotifications(
            authorization: .authorized
        ))
        for authorization in [
            CalendarMeetingNotificationAuthorization.notDetermined,
            .denied,
            .provisional,
            .ephemeral,
            .unknown
        ] {
            XCTAssertFalse(CalendarMeetingAutomationController.canUseAutoStopNotifications(
                authorization: authorization
            ))
        }
    }

    func testCommercialOrPremiumAccountUnlocksButSupporterDoesNotParticipate() {
        XCTAssertFalse(CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: false,
            hasPremiumEntitlement: false
        ))
        XCTAssertTrue(CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: true,
            hasPremiumEntitlement: false
        ))
        XCTAssertTrue(CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: false,
            hasPremiumEntitlement: true
        ))
    }

    func testBrowserURLResolutionRequiresRunningInput() {
        let input = MeetingAudioProcess(
            audioObjectID: 1,
            processID: 100,
            bundleIdentifier: SupportedMeetingBrowser.safari,
            isRunningInput: true,
            isRunningOutput: false
        )
        let outputOnly = MeetingAudioProcess(
            audioObjectID: 2,
            processID: 101,
            bundleIdentifier: SupportedMeetingBrowser.chrome,
            isRunningInput: false,
            isRunningOutput: true
        )
        let unsupported = MeetingAudioProcess(
            audioObjectID: 3,
            processID: 102,
            bundleIdentifier: SupportedMeetingBrowser.firefox,
            isRunningInput: true,
            isRunningOutput: false
        )

        XCTAssertTrue(CalendarMeetingAutomationController.shouldResolveBrowserURL(for: input))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldResolveBrowserURL(for: outputOnly))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldResolveBrowserURL(for: unsupported))
    }

    func testSuppressionFIFOIsUniqueAndBounded() {
        let initial = (0..<CalendarMeetingSuppressionList.capacity).map { "digest-\($0)" }
        let refreshed = CalendarMeetingSuppressionList.appending("digest-10", to: initial)
        XCTAssertEqual(refreshed.count, CalendarMeetingSuppressionList.capacity)
        XCTAssertEqual(refreshed.last, "digest-10")
        XCTAssertEqual(refreshed.filter { $0 == "digest-10" }.count, 1)

        let overflow = CalendarMeetingSuppressionList.appending("digest-new", to: refreshed)
        XCTAssertEqual(overflow.count, CalendarMeetingSuppressionList.capacity)
        XCTAssertFalse(overflow.contains("digest-0"))
        XCTAssertEqual(overflow.last, "digest-new")
    }

    func testDefaultSettingsDistinguishUninitializedFromIntentionallyEmptySelection() throws {
        let suiteName = "CalendarMeetingAutomationControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.calendarMeetingSelectedCalendarIDs))
        XCTAssertFalse(defaults.bool(forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized))

        defaults.set([], forKey: UserDefaultsKeys.calendarMeetingSelectedCalendarIDs)
        defaults.set(true, forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized)

        XCTAssertEqual(defaults.stringArray(forKey: UserDefaultsKeys.calendarMeetingSelectedCalendarIDs), [])
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.calendarMeetingCalendarSelectionInitialized))
    }

    func testFreshDefaultsDoNotInstallNotificationRouter() throws {
        let suiteName = "CalendarMeetingRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CalendarMeetingNotificationService.shouldInstallRouter(defaults: defaults))
        defaults.set(CalendarMeetingStartMode.reminder.rawValue, forKey: UserDefaultsKeys.calendarMeetingStartMode)
        XCTAssertTrue(CalendarMeetingNotificationService.shouldInstallRouter(defaults: defaults))
    }
}
