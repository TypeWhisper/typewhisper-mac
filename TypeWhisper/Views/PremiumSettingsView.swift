import AuthenticationServices
import SwiftUI

@MainActor
struct PremiumSettingsView: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var syncController: CloudFolderSyncController
    @ObservedObject private var premiumAccount: PremiumAccountService
    @ObservedObject private var correctionLearningService: TargetAppCorrectionLearningService

    private let settingsNavigation: SettingsNavigationCoordinator
    private let windowPresenter: any PremiumSettingsWindowPresenting

    init(
        licenseService: LicenseService = LicenseService.shared,
        syncController: CloudFolderSyncController = ServiceContainer.shared.cloudFolderSyncController,
        premiumAccount: PremiumAccountService = ServiceContainer.shared.premiumAccountService,
        correctionLearningService: TargetAppCorrectionLearningService = ServiceContainer.shared.targetAppCorrectionLearningService,
        settingsNavigation: SettingsNavigationCoordinator = .shared,
        windowPresenter: any PremiumSettingsWindowPresenting = PremiumSettingsWindowManager.shared
    ) {
        self.license = licenseService
        self.syncController = syncController
        self.premiumAccount = premiumAccount
        self.correctionLearningService = correctionLearningService
        self.settingsNavigation = settingsNavigation
        self.windowPresenter = windowPresenter
    }

    private var access: PremiumFeatureAccessSnapshot {
        PremiumFeatureAccessSnapshot(
            hasCommercialLicense: license.hasCommercialLicense,
            hasPremiumEntitlement: premiumAccount.hasPremiumEntitlement,
            isSignedIn: premiumAccount.isSignedIn,
            isSupporter: license.isSupporter
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Premium"))
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    PremiumAccessStatusBar(
                        summary: access.summary,
                        onManageAccess: {
                            windowPresenter.present(.access)
                        }
                    )

                    if access.hasAnyPremiumAccess {
                        PremiumActiveFeatureOverview(
                            licenseService: license,
                            premiumAccount: premiumAccount,
                            syncController: syncController,
                            correctionLearningService: correctionLearningService,
                            calendarController: ServiceContainer.shared.calendarMeetingAutomationController,
                            windowPresenter: windowPresenter
                        )
                    } else {
                        PremiumLockedFeatureOverview(
                            isSupporter: license.isSupporter,
                            onUnlock: {
                                settingsNavigation.navigateToLicense(target: .top)
                            }
                        )
                    }
                }
                .padding(SettingsLayoutMetrics.pagePadding)
                .frame(maxWidth: 980, alignment: .topLeading)
            }
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
    }
}

@MainActor
struct PremiumAccessSettingsView: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var premiumAccount: PremiumAccountService
    @State private var confirmingAccountDeletion = false

    private let settingsNavigation: SettingsNavigationCoordinator

    init(
        licenseService: LicenseService,
        premiumAccount: PremiumAccountService,
        settingsNavigation: SettingsNavigationCoordinator
    ) {
        self.license = licenseService
        self.premiumAccount = premiumAccount
        self.settingsNavigation = settingsNavigation
    }

    private var access: PremiumFeatureAccessSnapshot {
        PremiumFeatureAccessSnapshot(
            hasCommercialLicense: license.hasCommercialLicense,
            hasPremiumEntitlement: premiumAccount.hasPremiumEntitlement,
            isSignedIn: premiumAccount.isSignedIn,
            isSupporter: license.isSupporter
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "person.crop.circle.badge.checkmark",
                accent: .purple,
                title: String(localized: "premium.window.access.title"),
                description: String(localized: "premium.window.access.description"),
                status: accessTitle,
                statusColor: access.hasAnyPremiumAccess ? .green : .secondary
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        String(localized: "premium.window.access.currentAccess"),
                        systemImage: access.hasAnyPremiumAccess ? "checkmark.seal.fill" : "lock.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(access.hasAnyPremiumAccess ? .green : .secondary)

                    Text(accessTitle)
                        .font(.callout)
                        .accessibilityIdentifier("premium.window.access.status")

                    Button {
                        settingsNavigation.navigateToLicense(target: .top)
                    } label: {
                        Label(
                            String(localized: "premium.window.access.manageLicense"),
                            systemImage: "key"
                        )
                    }
                    .accessibilityIdentifier("premium.window.access.manageLicense")
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(
                            String(localized: "premium.window.access.accountTitle"),
                            systemImage: "person.crop.circle"
                        )
                        .font(.headline)

                        Spacer()

                        if premiumAccount.hasPremiumEntitlement {
                            Label(
                                String(localized: "premium.window.access.accountActive"),
                                systemImage: "checkmark.seal.fill"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                        }
                    }

                    if premiumAccount.isSignedIn {
                        Text(String(localized: "premium.window.access.signedInDescription"))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if license.hasCommercialLicense,
                           !premiumAccount.hasPremiumEntitlement,
                           let proof = license.commercialLicenseProofForAccountLink {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(String(localized: "premium.window.access.linkDescription"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button {
                                    Task {
                                        await premiumAccount.linkCommercialLicense(proof)
                                    }
                                } label: {
                                    Label(
                                        String(localized: "premium.window.access.linkLicense"),
                                        systemImage: "link"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(premiumAccount.isWorking)
                                .accessibilityIdentifier("premium.window.access.linkLicense")
                            }
                            .padding(.vertical, 2)
                        }

                        HStack(spacing: 8) {
                            Button(String(localized: "premium.window.access.signOut")) {
                                Task { await premiumAccount.signOutFromAccount() }
                            }
                            .disabled(premiumAccount.isWorking)
                            .accessibilityIdentifier("premium.window.access.signOut")

                            Button(String(localized: "premium.window.access.deleteAccount"), role: .destructive) {
                                confirmingAccountDeletion = true
                            }
                            .disabled(premiumAccount.isWorking)
                            .accessibilityIdentifier("premium.window.access.deleteAccount")
                        }
                    } else {
                        AppKitSignInWithAppleButton {
                            Task {
                                await premiumAccount.signInWithApple(
                                    commercialLicenseProof: license.commercialLicenseProofForAccountLink
                                )
                            }
                        }
                        .frame(width: 240, height: 38)
                        .disabled(premiumAccount.isWorking)
                        .accessibilityIdentifier("premium.window.access.signIn")

                        Text(String(localized: "premium.window.access.signInDescription"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if premiumAccount.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let errorMessage = premiumAccount.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Label(
                String(localized: "premium.window.access.privacy"),
                systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .alert(
            String(localized: "premium.window.access.deleteConfirmationTitle"),
            isPresented: $confirmingAccountDeletion
        ) {
            Button(String(localized: "premium.window.access.deleteAccount"), role: .destructive) {
                Task { await premiumAccount.deleteAccount() }
            }
            Button(String(localized: "premium.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "premium.window.access.deleteConfirmationMessage"))
        }
    }

    private var accessTitle: String {
        access.summary.localizedTitle
    }
}

@MainActor
struct PremiumCorrectionLearningSettingsView: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var correctionLearningService: TargetAppCorrectionLearningService
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningEnabled) private var learningEnabled = false

    private let onManageAccess: () -> Void

    init(
        licenseService: LicenseService,
        correctionLearningService: TargetAppCorrectionLearningService,
        onManageAccess: @escaping () -> Void
    ) {
        self.license = licenseService
        self.correctionLearningService = correctionLearningService
        self.onManageAccess = onManageAccess
    }

    var body: some View {
        if license.hasCommercialLicense {
            enabledContent
        } else {
            PremiumLockedDetailView(
                message: String(localized: "premium.window.learning.locked"),
                onManageAccess: onManageAccess
            )
        }
    }

    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "wand.and.sparkles",
                accent: .yellow,
                title: String(localized: "premium.hub.learning.title"),
                description: String(localized: "premium.window.learning.description"),
                status: learningEnabled
                    ? String(localized: "premium.hub.status.on")
                    : String(localized: "premium.hub.status.off"),
                statusColor: learningEnabled ? .green : .secondary
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        String(localized: "premium.window.learning.toggle"),
                        isOn: learningBinding
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("premium.learning.enabled")

                    Text(String(localized: "premium.window.learning.help"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.learning.lastActivity"))
                        .font(.headline)

                    if let attempt = correctionLearningService.latestAttempt {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: PremiumCorrectionLearningCopy.outcomeIcon(attempt.outcome))
                                .foregroundStyle(PremiumCorrectionLearningCopy.outcomeColor(attempt.outcome))
                                .frame(width: 18)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(PremiumCorrectionLearningCopy.outcomeText(attempt.outcome))
                                    .font(.callout.weight(.medium))

                                Text(attempt.timestamp, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if attempt.learnedCorrectionCount > 0 {
                                    Text(String.localizedStringWithFormat(
                                        String(localized: "premium.window.learning.correctionsLearnedFormat"),
                                        attempt.learnedCorrectionCount
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 8)

                            if let commitSignal = attempt.commitSignal {
                                Text(PremiumCorrectionLearningCopy.commitSignalText(commitSignal))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                        .accessibilityElement(children: .combine)
                    } else {
                        Label(
                            String(localized: "premium.window.learning.noActivity"),
                            systemImage: "clock"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "premium.window.learning.examplesTitle"))
                        .font(.headline)

                    Text(String(localized: "premium.window.learning.examplesHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(PremiumCorrectionExamples.current.enumerated()), id: \.offset) { _, example in
                        PremiumCorrectionExampleRow(before: example.before, after: example.after)
                    }
                }
            }
        }
    }

    private var learningBinding: Binding<Bool> {
        Binding(
            get: { license.hasCommercialLicense && learningEnabled },
            set: { newValue in
                guard license.hasCommercialLicense else { return }
                learningEnabled = newValue
            }
        )
    }
}

struct AppKitSignInWithAppleButton: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(
            authorizationButtonType: .signIn,
            authorizationButtonStyle: .whiteOutline
        )
        button.target = context.coordinator
        button.action = #selector(Coordinator.activate)
        button.isEnabled = context.environment.isEnabled
        return button
    }

    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = context.environment.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func activate() {
            action()
        }
    }
}
