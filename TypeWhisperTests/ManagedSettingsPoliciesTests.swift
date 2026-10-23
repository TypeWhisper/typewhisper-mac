import ServiceManagement
import XCTest
@testable import TypeWhisper

private func snapshot(
    _ forced: [String: ManagedPolicyRawValue],
    revision: Int = 1
) -> ManagedPolicySnapshot {
    ManagedPolicyValidator.validate(ManagedPolicyReading(forcedValues: forced), revision: revision, readAt: Date())
}

private func recommended(_ values: [String: ManagedPolicyRawValue]) -> [String: ManagedPolicyRawValue] {
    [ManagedPolicyKeys.recommendedDictionary: .dictionary(values)]
}


final class ManagedOnboardingPolicyTests: XCTestCase {
    private let ready = ManagedSetupReadiness(engineReady: true, microphoneGranted: true, accessibilityGranted: true, hotkeyConfigured: true)


    func testSetupStaysClosedOnlyWhenEnforcedAndReady() {
        let enforced = snapshot(["SkipOnboardingWhenReady": .boolean(true)])
        XCTAssertTrue(ManagedOnboardingPolicy.skipsSetup(enforced, readiness: ready))

        var missingMicrophone = ready
        missingMicrophone.microphoneGranted = false
        XCTAssertFalse(ManagedOnboardingPolicy.skipsSetup(enforced, readiness: missingMicrophone))
        XCTAssertFalse(ManagedOnboardingPolicy.skipsSetup(snapshot(["SkipOnboardingWhenReady": .boolean(false)]), readiness: ready))
        XCTAssertFalse(ManagedOnboardingPolicy.skipsSetup(snapshot([:]), readiness: ready))
        XCTAssertFalse(ManagedOnboardingPolicy.skipsSetup(snapshot(["SkipOnboardingWhenReady": .integer(1)]), readiness: ready))
        XCTAssertFalse(ManagedOnboardingPolicy.skipsSetup(
            ManagedPolicyValidator.validate(.unreadable("test"), revision: 1, readAt: Date()).retainingValues(from: enforced),
            readiness: ready
        ))
    }

    func testSetupThatHasNotStartedOpensAtTheFirstMissingPrerequisite() {
        let enforced = snapshot(["SkipOnboardingWhenReady": .boolean(true)])
        var readiness = ready
        XCTAssertNil(ManagedOnboardingPolicy.initialStep(enforced, savedStep: 0, readiness: readiness))

        readiness.engineReady = false
        XCTAssertEqual(ManagedOnboardingPolicy.initialStep(enforced, savedStep: 0, readiness: readiness), 3)
        readiness.hotkeyConfigured = false
        XCTAssertEqual(ManagedOnboardingPolicy.initialStep(enforced, savedStep: 0, readiness: readiness), 2)
        readiness.accessibilityGranted = false
        XCTAssertEqual(ManagedOnboardingPolicy.initialStep(enforced, savedStep: 0, readiness: readiness), 1)

        XCTAssertNil(ManagedOnboardingPolicy.initialStep(enforced, savedStep: 2, readiness: readiness), "Progress is kept")
        XCTAssertNil(ManagedOnboardingPolicy.initialStep(snapshot([:]), savedStep: 0, readiness: readiness))
    }
}

@MainActor
final class LaunchAtLoginPolicyControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var loginItem: FakeLoginItem!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TypeWhisperTests.LaunchAtLogin.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        loginItem = FakeLoginItem()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testEnforcedValueChangesTheLoginItemLocksAndRestoresOnRemoval() {
        let controller = makeController()

        controller.apply(snapshot(["LaunchAtLogin": .boolean(true)]), setupCompleted: true)
        XCTAssertEqual(loginItem.status, .enabled)
        XCTAssertTrue(controller.isLocked)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState) as? Bool, false)

        controller.setUserChoice(false)
        XCTAssertEqual(loginItem.status, .enabled, "A locked setting ignores the toggle")

        controller.apply(snapshot([:]), setupCompleted: true)
        XCTAssertEqual(loginItem.status, .notRegistered)
        XCTAssertFalse(controller.isLocked)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState))
    }

    func testRetainedStateIsTheOneBeforeTheFirstEnforcement() {
        loginItem.status = .enabled
        let controller = makeController()

        controller.apply(snapshot(["LaunchAtLogin": .boolean(false)]), setupCompleted: true)
        XCTAssertEqual(loginItem.status, .notRegistered)
        controller.apply(snapshot(["LaunchAtLogin": .boolean(true)]), setupCompleted: true)
        controller.apply(snapshot(["LaunchAtLogin": .boolean(false)]), setupCompleted: true)
        controller.apply(snapshot([:]), setupCompleted: true)

        XCTAssertEqual(loginItem.status, .enabled)
    }

    func testFailedRestoreKeepsTheRetainedStateForTheNextPass() {
        let controller = makeController()
        controller.apply(snapshot(["LaunchAtLogin": .boolean(true)]), setupCompleted: true)
        loginItem.failsNextChange = true

        controller.apply(snapshot([:]), setupCompleted: true)
        XCTAssertEqual(loginItem.status, .enabled)
        XCTAssertNotNil(controller.lastErrorDescription)
        XCTAssertNotNil(defaults.object(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState))

        controller.apply(snapshot([:]), setupCompleted: true)
        XCTAssertEqual(loginItem.status, .notRegistered)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.managedLaunchAtLoginRetainedState))
    }

    func testRecommendationAppliesOnceToANewProfileWithoutAChoice() {
        let controller = makeController()
        let recommendation = snapshot(recommended(["LaunchAtLogin": .boolean(true)]))

        controller.apply(recommendation, setupCompleted: false)
        XCTAssertEqual(loginItem.status, .enabled)
        XCTAssertFalse(controller.isLocked)

        loginItem.status = .notRegistered
        controller.apply(recommendation, setupCompleted: false)
        XCTAssertEqual(loginItem.status, .notRegistered, "The recommendation applies only once")
    }

    func testRecommendationNeverReplacesACompletedSetupOrAUserChoice() {
        let recommendation = snapshot(recommended(["LaunchAtLogin": .boolean(true)]))
        makeController().apply(recommendation, setupCompleted: true)
        XCTAssertEqual(loginItem.status, .notRegistered)

        let controller = makeController()
        controller.setUserChoice(false)
        controller.apply(recommendation, setupCompleted: false)
        XCTAssertEqual(loginItem.status, .notRegistered)
    }

    func testUnreadablePolicyLocksWithoutChangingAnything() {
        let controller = makeController()
        controller.apply(ManagedPolicyValidator.validate(.unreadable("test"), revision: 1, readAt: Date()), setupCompleted: true)

        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(loginItem.changes, 0)
        controller.setUserChoice(true)
        XCTAssertEqual(loginItem.changes, 0)
    }

    func testInitialPolicyLocksTheSettingWithoutChangingTheLoginItem() {
        let controller = LaunchAtLoginPolicyController(
            loginItem: loginItem,
            defaults: defaults,
            snapshot: snapshot(["LaunchAtLogin": .boolean(true)])
        )

        XCTAssertTrue(controller.isLocked)
        XCTAssertEqual(loginItem.changes, 0)
        XCTAssertFalse(makeController().isLocked)
    }

    func testUserChoiceRegistersWhenUnmanaged() {
        let controller = makeController()

        controller.setUserChoice(true)

        XCTAssertEqual(loginItem.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.launchAtLoginUserChoice) as? Bool, true)
    }

    private func makeController() -> LaunchAtLoginPolicyController {
        LaunchAtLoginPolicyController(loginItem: loginItem, defaults: defaults)
    }
}

@MainActor
private final class FakeLoginItem: LoginItemRegistering {
    struct ChangeFailed: Error {}

    var status: SMAppService.Status = .notRegistered
    var failsNextChange = false
    private(set) var changes = 0

    func register() throws {
        try change(to: .enabled)
    }

    func unregister() throws {
        try change(to: .notRegistered)
    }

    private func change(to newStatus: SMAppService.Status) throws {
        if failsNextChange {
            failsNextChange = false
            throw ChangeFailed()
        }
        changes += 1
        status = newStatus
    }
}
