import XCTest
@testable import TypeWhisper

@MainActor
final class PostUpdatePromptCoordinatorTests: XCTestCase {
    func testMissingVersionMarkerAndPendingWelcomeSeedsCurrentReleaseWithoutPrompting() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let license = LicenseService(defaults: defaults)
        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertFalse(coordinator.shouldPresentPrompt)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.lastSeenReleaseFingerprint), "1.3.0+123@stable")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease), "1.3.0+123@stable")
    }

    func testMissingVersionMarkerAndCompletedWelcomePromptsImmediately() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)

        let license = LicenseService(defaults: defaults)
        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertTrue(coordinator.shouldPresentPrompt)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.lastSeenReleaseFingerprint), "1.3.0+123@stable")
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease))
    }

    func testActiveCommercialLicenseSuppressesPrompt() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set("1.2.9+99@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        let license = LicenseService(defaults: defaults)
        license.licenseStatus = .active
        license.licenseTier = .individual

        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertFalse(coordinator.shouldPresentPrompt)
    }

    func testActiveSupporterSuppressesPrompt() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set("1.2.9+99@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        let license = LicenseService(defaults: defaults)
        license.supporterStatus = .active
        license.supporterTier = .gold

        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertFalse(coordinator.shouldPresentPrompt)
    }

    func testPersonalUseRequiresAcknowledgementForCurrentRelease() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set("1.2.9+99@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        let license = LicenseService(defaults: defaults)
        let currentRelease = "1.3.0+123@stable"

        var coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: currentRelease
        )
        XCTAssertTrue(coordinator.shouldPresentPrompt)

        coordinator.handlePersonalOSSSelection()

        XCTAssertEqual(license.usageIntent, .personalOSS)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease), currentRelease)
        XCTAssertFalse(coordinator.shouldPresentPrompt)

        coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: currentRelease
        )

        XCTAssertFalse(coordinator.shouldPresentPrompt)
    }

    func testBusinessIntentPromptsEveryLaunchUntilLicensed() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set(UsageIntent.team.rawValue, forKey: UserDefaultsKeys.usageIntent)
        defaults.set(LicenseUserType.business.rawValue, forKey: UserDefaultsKeys.userType)
        defaults.set("1.3.0+123@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)
        defaults.set("1.3.0+123@stable", forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease)

        let license = LicenseService(defaults: defaults)
        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertTrue(coordinator.shouldPresentPrompt)
    }

    func testWorkSelectionSetsWorkSoloWithoutAcknowledgingCurrentRelease() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set("1.2.9+99@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        let license = LicenseService(defaults: defaults)
        let currentRelease = "1.3.0+123@stable"
        var coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: currentRelease
        )

        coordinator.handleWorkUsageSelection()

        XCTAssertEqual(license.usageIntent, .workSolo)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease))
        XCTAssertFalse(coordinator.shouldPresentPrompt)

        coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: currentRelease
        )

        XCTAssertTrue(coordinator.shouldPresentPrompt)
    }

    func testExistingKeyAndSupporterActionsDismissOnlyForCurrentSession() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set(UsageIntent.workSolo.rawValue, forKey: UserDefaultsKeys.usageIntent)
        defaults.set(LicenseUserType.business.rawValue, forKey: UserDefaultsKeys.userType)
        defaults.set("1.3.0+123@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        let license = LicenseService(defaults: defaults)
        let currentRelease = "1.3.0+123@stable"

        var coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: currentRelease
        )
        XCTAssertTrue(coordinator.shouldPresentPrompt)

        coordinator.handleExistingKeySelection()
        XCTAssertFalse(coordinator.shouldPresentPrompt)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease))

        coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: currentRelease
        )
        XCTAssertTrue(coordinator.shouldPresentPrompt)

        coordinator.handleSupporterSelection()
        XCTAssertFalse(coordinator.shouldPresentPrompt)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease))
    }

    func testSettingsNavigationCoordinatorPublishesLicenseTargets() throws {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigateToLicense(target: .activationKey)
        let activationRequest = try XCTUnwrap(coordinator.request)
        XCTAssertEqual(activationRequest.tab, .license)
        XCTAssertEqual(activationRequest.licenseTarget, .activationKey)

        coordinator.navigateToLicense(target: .supporter)
        let supporterRequest = try XCTUnwrap(coordinator.request)
        XCTAssertEqual(supporterRequest.tab, .license)
        XCTAssertEqual(supporterRequest.licenseTarget, .supporter)
        XCTAssertNotEqual(activationRequest.id, supporterRequest.id)

        coordinator.navigate(to: .license, licenseTarget: .top)
        let topRequest = try XCTUnwrap(coordinator.request)
        XCTAssertEqual(topRequest.tab, .license)
        XCTAssertEqual(topRequest.licenseTarget, .top)
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "TypeWhisperTests.PostUpdatePrompt.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Failed to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
