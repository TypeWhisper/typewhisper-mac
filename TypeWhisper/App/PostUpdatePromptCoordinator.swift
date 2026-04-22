import Foundation
import os

enum StartupSheetRoute: String, Identifiable {
    case welcome
    case postUpdateLicensing

    var id: String { rawValue }
}

@MainActor
final class PostUpdatePromptCoordinator {
    nonisolated(unsafe) static var shared: PostUpdatePromptCoordinator!

    private let defaults: UserDefaults
    private let licenseService: LicenseService
    private let currentReleaseFingerprint: String
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "PostUpdatePromptCoordinator")

    private var currentSessionDismissed = false

    init(
        defaults: UserDefaults = .standard,
        licenseService: LicenseService = LicenseService.shared,
        currentReleaseFingerprint: String = AppConstants.currentReleaseFingerprint
    ) {
        self.defaults = defaults
        self.licenseService = licenseService
        self.currentReleaseFingerprint = currentReleaseFingerprint

        bootstrapCurrentReleaseIfNeeded()
    }

    var shouldPresentPrompt: Bool {
        guard !currentSessionDismissed else { return false }
        guard !licenseService.needsWelcomeSheet else { return false }
        guard !hasActiveEntitlement else { return false }

        if licenseService.requiresCommercialLicense {
            return true
        }

        return acknowledgedReleaseFingerprint != currentReleaseFingerprint
    }

    var shouldAutoOpenSettingsOnLaunch: Bool {
        shouldPresentPrompt
    }

    var activeSheetRoute: StartupSheetRoute? {
        shouldPresentPrompt ? .postUpdateLicensing : nil
    }

    func handlePersonalOSSSelection() {
        licenseService.setUsageIntent(.personalOSS)
        acknowledgeCurrentRelease()
        dismissForCurrentSession()
    }

    func handleWorkUsageSelection() {
        licenseService.setUsageIntent(.workSolo)
        dismissForCurrentSession()
    }

    func handleExistingKeySelection() {
        dismissForCurrentSession()
    }

    func handleSupporterSelection() {
        dismissForCurrentSession()
    }

    func handleNotNowSelection() {
        handleSheetDismissedWithoutExplicitAction()
    }

    func handleSheetDismissedWithoutExplicitAction() {
        if licenseService.requiresCommercialLicense {
            dismissForCurrentSession()
            return
        }

        acknowledgeCurrentRelease()
        dismissForCurrentSession()
    }

    private var hasActiveEntitlement: Bool {
        licenseService.licenseStatus == .active || licenseService.supporterStatus == .active
    }

    private var lastSeenReleaseFingerprint: String? {
        defaults.string(forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)
    }

    private var acknowledgedReleaseFingerprint: String? {
        defaults.string(forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease)
    }

    private func dismissForCurrentSession() {
        currentSessionDismissed = true
    }

    private func acknowledgeCurrentRelease() {
        defaults.set(currentReleaseFingerprint, forKey: UserDefaultsKeys.lastAcknowledgedPostUpdatePromptRelease)
        logger.debug("Acknowledged post-update prompt for \(self.currentReleaseFingerprint, privacy: .public)")
    }

    private func bootstrapCurrentReleaseIfNeeded() {
        let previousRelease = lastSeenReleaseFingerprint
        defaults.set(currentReleaseFingerprint, forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        guard previousRelease == nil else {
            return
        }

        if licenseService.needsWelcomeSheet {
            acknowledgeCurrentRelease()
            dismissForCurrentSession()
            logger.debug("Seeded current release for fresh install session")
        } else {
            logger.debug("No previous release marker found; treating as existing installation")
        }
    }
}
