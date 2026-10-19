import Combine
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

final class ManagedUpdatePolicyTests: XCTestCase {
    func testSnapshotMapsModeChannelsAndAllowlist() {
        let policy = ManagedUpdatePolicy(snapshot: snapshot([
            "UpdateMode": .integer(1),
            "UpdateChannel": .integer(2),
            "AllowedUpdateChannels": .array([.string("stable"), .string("Release-Candidate"), .string("none")]),
            "Recommended": .dictionary(["UpdateChannel": .integer(1)]),
        ]))

        XCTAssertEqual(policy.mode, .checkOnly)
        XCTAssertEqual(policy.enforcedChannel, .releaseCandidate)
        XCTAssertEqual(policy.recommendedChannel, .daily)
        XCTAssertEqual(policy.allowedChannels, [.stable, .releaseCandidate])
        XCTAssertFalse(policy.isBlocked)
        XCTAssertTrue(policy.isManaged)
        XCTAssertTrue(policy.isChannelLocked)
    }

    func testUnmanagedPolicyLeavesUpdatesUnchanged() {
        let policy = ManagedUpdatePolicy(snapshot: snapshot([:]))

        XCTAssertEqual(policy, .unmanaged)
        XCTAssertFalse(policy.isManaged)
        XCTAssertNil(policy.checkRefusal(on: .daily))
        XCTAssertNil(policy.installRefusal(on: .daily, userInitiated: false, downloadsAutomatically: true))
        XCTAssertEqual(policy.selectableChannels(current: .stable), AppConstants.ReleaseChannel.allCases)
        XCTAssertFalse(policy.suppressesAutomaticCheckPrompt)
        XCTAssertNil(policy.conflict)
    }

    func testEffectiveChannelFollowsPrecedence() {
        let recommendation = ManagedUpdatePolicy(recommendedChannel: .releaseCandidate)
        XCTAssertEqual(recommendation.effectiveChannel(explicitChoice: nil, bundled: .stable), .init(value: .releaseCandidate, source: .recommendedPolicy))
        XCTAssertEqual(recommendation.effectiveChannel(explicitChoice: .stable, bundled: .daily), .init(value: .stable, source: .userPreference))

        let enforced = ManagedUpdatePolicy(enforcedChannel: .stable, recommendedChannel: .daily)
        XCTAssertEqual(enforced.effectiveChannel(explicitChoice: .daily, bundled: .daily), .init(value: .stable, source: .enforcedPolicy))
        XCTAssertEqual(ManagedUpdatePolicy.unmanaged.effectiveChannel(explicitChoice: nil, bundled: .daily), .init(value: .daily, source: .applicationDefault))
    }

    func testExternalModeRefusesChecksAndInstallations() {
        let policy = ManagedUpdatePolicy(mode: .external)

        XCTAssertNotNil(policy.checkRefusal(on: .stable))
        XCTAssertNotNil(policy.installRefusal(on: .stable, userInitiated: true, downloadsAutomatically: false))
        XCTAssertTrue(policy.suppressesAutomaticCheckPrompt)
    }

    func testCheckOnlyChecksButNeverInstalls() {
        let policy = ManagedUpdatePolicy(mode: .checkOnly)

        XCTAssertNil(policy.checkRefusal(on: .stable))
        XCTAssertNotNil(policy.installRefusal(on: .stable, userInitiated: true, downloadsAutomatically: false))
        XCTAssertNotNil(policy.installRefusal(on: .stable, userInitiated: false, downloadsAutomatically: false))
    }

    func testUserInitiatedRefusesOnlyUnattendedInstallation() {
        let policy = ManagedUpdatePolicy(mode: .userInitiated)

        XCTAssertNil(policy.checkRefusal(on: .stable))
        XCTAssertNil(policy.installRefusal(on: .stable, userInitiated: true, downloadsAutomatically: true))
        XCTAssertNil(policy.installRefusal(on: .stable, userInitiated: false, downloadsAutomatically: false))
        XCTAssertNotNil(policy.installRefusal(on: .stable, userInitiated: false, downloadsAutomatically: true))
    }

    func testAllowlistRefusesOtherChannelsAndAnEmptyListTurnsUpdatesOff() {
        let stableOnly = ManagedUpdatePolicy(snapshot: snapshot(["AllowedUpdateChannels": .array([.string("stable")])]))
        XCTAssertNil(stableOnly.checkRefusal(on: .stable))
        XCTAssertNotNil(stableOnly.checkRefusal(on: .daily))
        XCTAssertEqual(stableOnly.selectableChannels(current: .stable), [.stable])
        XCTAssertEqual(stableOnly.selectableChannels(current: .daily), [.stable, .daily])
        XCTAssertFalse(stableOnly.isChannelLocked)

        for entries: [ManagedPolicyRawValue] in [[], [.string("none")]] {
            let off = ManagedUpdatePolicy(snapshot: snapshot(["AllowedUpdateChannels": .array(entries)]))
            XCTAssertEqual(off.allowedChannels, [])
            XCTAssertNotNil(off.checkRefusal(on: .stable))
            XCTAssertTrue(off.suppressesAutomaticCheckPrompt)
        }
    }

    func testEnforcedChannelOutsideTheAllowlistIsAConflictNotASwitch() {
        let policy = ManagedUpdatePolicy(snapshot: snapshot([
            "UpdateChannel": .integer(1),
            "AllowedUpdateChannels": .array([.string("stable")]),
        ]))

        XCTAssertEqual(policy.effectiveChannel(explicitChoice: .stable, bundled: .stable).value, .daily)
        XCTAssertNotNil(policy.checkRefusal(on: .daily))
        XCTAssertNotNil(policy.conflict)
    }

    func testInvalidOrUnreadablePolicyBlocksUpdates() {
        let invalidMode = ManagedUpdatePolicy(snapshot: snapshot(["UpdateMode": .integer(7)]))
        XCTAssertTrue(invalidMode.isBlocked)
        XCTAssertTrue(invalidMode.isChannelLocked)
        XCTAssertNotNil(invalidMode.checkRefusal(on: .stable))

        let unreadable = ManagedUpdatePolicy(snapshot: ManagedPolicyValidator.validate(.unreadable("test"), revision: 1, readAt: Date()))
        XCTAssertTrue(unreadable.isBlocked)
        XCTAssertNotNil(unreadable.checkRefusal(on: .stable))

        let invalidRecommendation = ManagedUpdatePolicy(snapshot: snapshot(recommended(["UpdateChannel": .integer(9)])))
        XCTAssertFalse(invalidRecommendation.isBlocked)
        XCTAssertNil(invalidRecommendation.checkRefusal(on: .stable))
    }
}

@MainActor
final class ManagedUpdateCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TypeWhisperTests.ManagedUpdates.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testRecommendationAppliesUntilTheUserChoosesAndNeverOverwritesTheChoice() {
        let source = PolicySource(recommended(["UpdateChannel": .integer(2)]))
        let coordinator = makeCoordinator(source)

        XCTAssertNil(coordinator.explicitChannel)
        XCTAssertEqual(coordinator.effectiveChannel, .init(value: .releaseCandidate, source: .recommendedPolicy))

        defaults.set(AppConstants.ReleaseChannel.stable.rawValue, forKey: UserDefaultsKeys.updateChannel)
        XCTAssertEqual(coordinator.effectiveChannel, .init(value: .stable, source: .userPreference))

        source.forced = ["UpdateChannel": .integer(1)]
        source.service.refresh()
        XCTAssertEqual(coordinator.effectiveChannel, .init(value: .daily, source: .enforcedPolicy))
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.updateChannel), "stable")

        source.forced = [:]
        source.service.refresh()
        XCTAssertEqual(coordinator.effectiveChannel.value, .stable)
    }

    func testCheckOnlyAnnouncesTheVersionAndRefusesInstallation() throws {
        let coordinator = makeCoordinator(PolicySource(["UpdateMode": .integer(1)]))

        XCTAssertNoThrow(try coordinator.authorizeCheck())
        XCTAssertThrowsError(try coordinator.authorizeUpdate(version: "1.9.0", userInitiated: true, downloadsAutomatically: false)) { error in
            XCTAssertEqual(
                (error as NSError).localizedDescription,
                ManagedUpdatePolicy(mode: .checkOnly).installRefusal(on: .stable, userInitiated: true, downloadsAutomatically: false)
            )
        }
        XCTAssertEqual(coordinator.announcedVersion, "1.9.0")
    }

    func testExternalRefusesWithoutAnnouncing() {
        let coordinator = makeCoordinator(PolicySource(["UpdateMode": .integer(0)]))

        XCTAssertThrowsError(try coordinator.authorizeCheck())
        XCTAssertNotNil(coordinator.checkRefusal)
        XCTAssertThrowsError(try coordinator.authorizeUpdate(version: "1.9.0", userInitiated: true, downloadsAutomatically: false))
        XCTAssertNil(coordinator.announcedVersion)
    }

    func testPolicyChangeDropsTheAnnouncementAndNotifies() throws {
        let source = PolicySource(["UpdateMode": .integer(1)])
        let coordinator = makeCoordinator(source)
        var changes: [(ManagedUpdatePolicy, ManagedUpdatePolicy)] = []
        coordinator.onPolicyChange = { changes.append(($0, $1)) }
        _ = try? coordinator.authorizeUpdate(version: "1.9.0", userInitiated: false, downloadsAutomatically: false)

        source.forced = ["UpdateMode": .integer(2)]
        source.service.refresh()

        XCTAssertNil(coordinator.announcedVersion)
        XCTAssertEqual(changes.map { $0.0.mode }, [.checkOnly])
        XCTAssertEqual(changes.map { $0.1.mode }, [.userInitiated])
        XCTAssertNoThrow(try coordinator.authorizeUpdate(version: "1.9.0", userInitiated: true, downloadsAutomatically: true))

        source.service.refresh()
        XCTAssertEqual(changes.count, 1, "An unchanged policy does not notify")
    }

    private func makeCoordinator(_ source: PolicySource) -> ManagedUpdateCoordinator {
        source.service.refresh()
        return ManagedUpdateCoordinator(policyService: source.service, defaults: defaults, bundledChannel: .stable)
    }
}

final class ManagedPromptAndOnboardingPolicyTests: XCTestCase {
    private let ready = ManagedSetupReadiness(engineReady: true, microphoneGranted: true, accessibilityGranted: true, hotkeyConfigured: true)

    func testOptionalPromptsFollowEnforcedThenRecommendedValues() {
        XCTAssertFalse(ManagedPromptPolicy.suppressesOptionalPrompts(snapshot([:])))
        XCTAssertTrue(ManagedPromptPolicy.suppressesOptionalPrompts(snapshot(["SuppressOptionalPrompts": .boolean(true)])))
        XCTAssertTrue(ManagedPromptPolicy.suppressesOptionalPrompts(snapshot(recommended(["SuppressOptionalPrompts": .boolean(true)]))))
        var both = recommended(["SuppressOptionalPrompts": .boolean(true)])
        both["SuppressOptionalPrompts"] = .boolean(false)
        XCTAssertFalse(ManagedPromptPolicy.suppressesOptionalPrompts(snapshot(both)))
    }

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
private final class PolicySource {
    private final class Source: ManagedPolicySource, @unchecked Sendable {
        var forced: [String: ManagedPolicyRawValue] = [:]
        func read() -> ManagedPolicyReading { ManagedPolicyReading(forcedValues: forced) }
    }

    private let source = Source()
    let service: ManagedPolicyService

    var forced: [String: ManagedPolicyRawValue] {
        get { source.forced }
        set { source.forced = newValue }
    }

    init(_ forced: [String: ManagedPolicyRawValue]) {
        source.forced = forced
        service = ManagedPolicyService(source: source, fallbackTicks: { AsyncStream { _ in } })
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
