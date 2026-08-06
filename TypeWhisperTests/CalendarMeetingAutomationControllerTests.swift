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

    func testCalendarPermissionActionsCoverEveryAuthorizationState() {
        XCTAssertEqual(
            CalendarMeetingCalendarAuthorization.notDetermined.permissionAction,
            .requestAccess
        )
        XCTAssertEqual(
            CalendarMeetingCalendarAuthorization.denied.permissionAction,
            .openSystemSettings
        )
        XCTAssertEqual(
            CalendarMeetingCalendarAuthorization.writeOnly.permissionAction,
            .openSystemSettings
        )
        XCTAssertEqual(
            CalendarMeetingCalendarAuthorization.unknown.permissionAction,
            .openSystemSettings
        )
        XCTAssertEqual(
            CalendarMeetingCalendarAuthorization.restricted.permissionAction,
            .unavailable
        )
        XCTAssertEqual(
            CalendarMeetingCalendarAuthorization.fullAccess.permissionAction,
            .none
        )
    }

    func testCalendarAccessRequestRequiresPremiumActiveModeAndNoRequestInFlight() {
        XCTAssertTrue(CalendarMeetingAutomationController.shouldStartCalendarAccessRequest(
            hasPremiumAccess: true,
            startMode: .reminder,
            isRequestInFlight: false
        ))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldStartCalendarAccessRequest(
            hasPremiumAccess: true,
            startMode: .automatic,
            isRequestInFlight: true
        ))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldStartCalendarAccessRequest(
            hasPremiumAccess: true,
            startMode: .off,
            isRequestInFlight: false
        ))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldStartCalendarAccessRequest(
            hasPremiumAccess: false,
            startMode: .automatic,
            isRequestInFlight: false
        ))
    }

    func testNotificationRequestRequiresFullCalendarAccess() {
        for authorization in [
            CalendarMeetingCalendarAuthorization.notDetermined,
            .denied,
            .restricted,
            .writeOnly,
            .unknown
        ] {
            XCTAssertFalse(CalendarMeetingAutomationController.shouldRequestNotifications(
                hasPremiumAccess: true,
                startMode: .reminder,
                calendarAuthorization: authorization
            ))
        }
        XCTAssertTrue(CalendarMeetingAutomationController.shouldRequestNotifications(
            hasPremiumAccess: true,
            startMode: .automatic,
            calendarAuthorization: .fullAccess
        ))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldRequestNotifications(
            hasPremiumAccess: true,
            startMode: .off,
            calendarAuthorization: .fullAccess
        ))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldRequestNotifications(
            hasPremiumAccess: false,
            startMode: .automatic,
            calendarAuthorization: .fullAccess
        ))
    }

    func testCalendarAccessRequestReturnsGrantedAuthorization() async {
        let provider = CalendarMeetingEventProviderStub(
            authorization: .notDetermined,
            authorizationAfterRequest: .fullAccess,
            requestResult: .value(true)
        )

        let outcome = await requestCalendarMeetingCalendarAccess(using: provider)

        XCTAssertEqual(outcome, CalendarMeetingCalendarAccessRequestOutcome(
            authorization: .fullAccess,
            failure: nil
        ))
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testCalendarAccessRequestSurfacesIncompleteRequest() async {
        let provider = CalendarMeetingEventProviderStub(
            authorization: .notDetermined,
            requestResult: .value(false)
        )

        let outcome = await requestCalendarMeetingCalendarAccess(using: provider)

        XCTAssertEqual(outcome, CalendarMeetingCalendarAccessRequestOutcome(
            authorization: .notDetermined,
            failure: .notCompleted
        ))
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testCalendarAccessRequestPreservesDeniedStatusWithoutSyntheticFailure() async {
        let provider = CalendarMeetingEventProviderStub(
            authorization: .denied,
            requestResult: .value(false)
        )

        let outcome = await requestCalendarMeetingCalendarAccess(using: provider)

        XCTAssertEqual(outcome, CalendarMeetingCalendarAccessRequestOutcome(
            authorization: .denied,
            failure: nil
        ))
    }

    func testCalendarAccessRequestSurfacesSystemError() async {
        let provider = CalendarMeetingEventProviderStub(
            authorization: .notDetermined,
            requestResult: .failure(domain: "EKErrorDomain", code: 99)
        )

        let outcome = await requestCalendarMeetingCalendarAccess(using: provider)

        XCTAssertEqual(outcome, CalendarMeetingCalendarAccessRequestOutcome(
            authorization: .notDetermined,
            failure: .system(domain: "EKErrorDomain", code: 99)
        ))
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

    func testBrowserURLResolutionAcceptsInputOrOutputForCameraFallback() {
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
        XCTAssertTrue(CalendarMeetingAutomationController.shouldResolveBrowserURL(for: outputOnly))
        XCTAssertFalse(CalendarMeetingAutomationController.shouldResolveBrowserURL(for: unsupported))
    }

    func testResolvedNonMeetingBrowserURLIsSignalAbsenceNotCollectorFailure() throws {
        XCTAssertEqual(
            CalendarMeetingAutomationController.browserURLResolution(for: nil),
            .unavailable
        )
        XCTAssertEqual(
            CalendarMeetingAutomationController.browserURLResolution(
                for: URL(string: "https://example.com/after-leaving")
            ),
            .nonMeeting
        )

        let meetURL = try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        guard case .meeting(let link) = CalendarMeetingAutomationController
            .browserURLResolution(for: meetURL) else {
            return XCTFail("Expected a canonical Google Meet resolution")
        }
        XCTAssertEqual(link.provider, .googleMeet)
    }

    func testBrowserHelpersAreAggregatedOncePerCanonicalBrowser() throws {
        let chromeInput = MeetingAudioProcess(
            audioObjectID: 12,
            processID: 120,
            bundleIdentifier: SupportedMeetingBrowser.chrome + ".helper.renderer",
            isRunningInput: true,
            isRunningOutput: false
        )
        let chromeOutput = MeetingAudioProcess(
            audioObjectID: 11,
            processID: 110,
            bundleIdentifier: SupportedMeetingBrowser.chrome + ".helper",
            isRunningInput: false,
            isRunningOutput: true
        )
        let brave = MeetingAudioProcess(
            audioObjectID: 21,
            processID: 210,
            bundleIdentifier: SupportedMeetingBrowser.brave,
            isRunningInput: true,
            isRunningOutput: true
        )
        let safariInput = MeetingAudioProcess(
            audioObjectID: 31,
            processID: 310,
            bundleIdentifier: BrowserAudioProcessAttribution.safariWebKitGPUProcess,
            isRunningInput: true,
            isRunningOutput: false
        )
        let safariOutput = MeetingAudioProcess(
            audioObjectID: 32,
            processID: 320,
            bundleIdentifier: BrowserAudioProcessAttribution.safariWebKitGPUProcess,
            isRunningInput: false,
            isRunningOutput: true
        )

        let aggregated = CalendarMeetingAutomationController.aggregatedBrowserProcesses([
            chromeInput,
            chromeOutput,
            brave,
            safariInput,
            safariOutput
        ])

        XCTAssertEqual(aggregated.count, 3)
        let chrome = try XCTUnwrap(aggregated.first {
            $0.bundleIdentifier == SupportedMeetingBrowser.chrome
        })
        XCTAssertEqual(chrome.processID, chromeOutput.processID)
        XCTAssertEqual(chrome.audioObjectID, chromeOutput.audioObjectID)
        XCTAssertTrue(chrome.isRunningInput)
        XCTAssertTrue(chrome.isRunningOutput)

        let safari = try XCTUnwrap(aggregated.first {
            $0.bundleIdentifier == SupportedMeetingBrowser.safari
        })
        XCTAssertEqual(safari.processID, safariInput.processID)
        XCTAssertEqual(safari.audioObjectID, safariInput.audioObjectID)
        XCTAssertTrue(safari.isRunningInput)
        XCTAssertTrue(safari.isRunningOutput)
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

private actor CalendarMeetingEventProviderStub: CalendarMeetingEventProviding {
    enum RequestResult: Sendable {
        case value(Bool)
        case failure(domain: String, code: Int)
    }

    private var authorization: CalendarMeetingCalendarAuthorization
    private let authorizationAfterRequest: CalendarMeetingCalendarAuthorization?
    private let requestResult: RequestResult
    private var recordedRequestCount = 0

    init(
        authorization: CalendarMeetingCalendarAuthorization,
        authorizationAfterRequest: CalendarMeetingCalendarAuthorization? = nil,
        requestResult: RequestResult
    ) {
        self.authorization = authorization
        self.authorizationAfterRequest = authorizationAfterRequest
        self.requestResult = requestResult
    }

    func authorizationStatus() -> CalendarMeetingCalendarAuthorization {
        authorization
    }

    func requestFullAccess() throws -> Bool {
        recordedRequestCount += 1
        if let authorizationAfterRequest {
            authorization = authorizationAfterRequest
        }
        switch requestResult {
        case .value(let granted):
            return granted
        case .failure(let domain, let code):
            throw NSError(domain: domain, code: code)
        }
    }

    func requestCount() -> Int {
        recordedRequestCount
    }

    func calendars() -> [CalendarMeetingCalendar] {
        []
    }

    func occurrences(
        in interval: DateInterval,
        calendarIDs: Set<String>
    ) -> [CalendarMeetingOccurrence] {
        []
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}
