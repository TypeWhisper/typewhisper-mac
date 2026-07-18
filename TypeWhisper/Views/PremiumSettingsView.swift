import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
struct PremiumSettingsView: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var syncController: CloudFolderSyncController
    @ObservedObject private var premiumAccount: PremiumAccountService
    @ObservedObject private var correctionLearningService: TargetAppCorrectionLearningService
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningEnabled) private var targetAppCorrectionLearningEnabled = false
    @State private var appleNonceHash: String?
    @State private var confirmingAccountDeletion = false

    private let settingsNavigation: SettingsNavigationCoordinator

    init(
        licenseService: LicenseService = LicenseService.shared,
        syncController: CloudFolderSyncController = ServiceContainer.shared.cloudFolderSyncController,
        premiumAccount: PremiumAccountService = ServiceContainer.shared.premiumAccountService,
        correctionLearningService: TargetAppCorrectionLearningService = ServiceContainer.shared.targetAppCorrectionLearningService,
        settingsNavigation: SettingsNavigationCoordinator = .shared
    ) {
        self.license = licenseService
        self.syncController = syncController
        self.premiumAccount = premiumAccount
        self.correctionLearningService = correctionLearningService
        self.settingsNavigation = settingsNavigation
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Premium"))
            Divider()

            ScrollView {
                premiumAccountCard

                if license.hasCommercialLicense || premiumAccount.hasPremiumEntitlement {
                    premiumControlCenter
                } else {
                    lockedPremiumLanding
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
        .alert(String(localized: "Delete TypeWhisper Account?"), isPresented: $confirmingAccountDeletion) {
            Button(String(localized: "Delete Account"), role: .destructive) {
                Task { await premiumAccount.deleteAccount() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This removes the account and entitlement link. Local entries and private cloud files are not deleted."))
        }
    }

    private var premiumAccountCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(String(localized: "Cross-device Premium Account"), systemImage: "person.crop.circle")
                        .font(.headline)
                    Spacer()
                    if premiumAccount.hasPremiumEntitlement {
                        Label(String(localized: "Premium active"), systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }

                if premiumAccount.isSignedIn {
                    Text(String(localized: "Your Apple account keeps Polar and App Store entitlements available on Mac and iPhone."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button(String(localized: "Sign Out")) { premiumAccount.signOut() }
                        Button(String(localized: "Delete Account"), role: .destructive) { confirmingAccountDeletion = true }
                    }
                } else {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                        let nonceHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
                            .map { String(format: "%02x", $0) }
                            .joined()
                        appleNonceHash = nonceHash
                        request.nonce = nonceHash
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                                  let tokenData = credential.identityToken,
                                  let identityToken = String(data: tokenData, encoding: .utf8),
                                  let nonceHash = appleNonceHash else { return }
                            appleNonceHash = nil
                            let authorizationCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
                            Task {
                                await premiumAccount.signIn(
                                    identityToken: identityToken,
                                    authorizationCode: authorizationCode,
                                    nonceHash: nonceHash,
                                    polarLicenseKey: license.commercialLicenseKeyForAccountLink
                                )
                            }
                        case .failure(let error):
                            appleNonceHash = nil
                            if (error as? ASAuthorizationError)?.code != .canceled {
                                premiumAccount.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .signInWithAppleButtonStyle(.whiteOutline)
                    .frame(width: 240, height: 38)

                    Text(String(localized: "Sync data stays in your selected cloud location and never passes through the TypeWhisper account service."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = premiumAccount.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
        .padding(.top, SettingsLayoutMetrics.pagePadding)
    }

    private var featureColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 14, alignment: .top)
        ]
    }

    private var statusColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12, alignment: .top)
        ]
    }

    private var lockedPremiumLanding: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
            lockedPremiumHero

            LazyVGrid(columns: featureColumns, alignment: .leading, spacing: 14) {
                premiumLandingFeatureCard(
                    icon: "wand.and.sparkles",
                    iconColor: .yellow,
                    title: String(localized: "Automatic Correction Learning"),
                    description: String(localized: "TypeWhisper learns confident corrections after direct insertion, without asking for every edit."),
                    examples: [
                        PremiumCorrectionExample(before: "teh", after: "the"),
                        PremiumCorrectionExample(before: "recieve", after: "receive")
                    ]
                )

                premiumLandingFeatureCard(
                    icon: "cloud",
                    iconColor: .blue,
                    title: String(localized: "Cloud Folder Sync"),
                    description: String(localized: "Keep dictionaries and snippets available wherever your cloud folder syncs."),
                    badges: [
                        String(localized: "iCloud Drive"),
                        String(localized: "Dropbox"),
                        String(localized: "OneDrive"),
                        String(localized: "Syncthing"),
                        String(localized: "Custom folder")
                    ]
                )
            }

            premiumLicenseCallout

            if license.isSupporter {
                Label(String(localized: "Supporter status is active. Premium features require a Commercial license."), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(SettingsLayoutMetrics.pagePadding)
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    private var lockedPremiumHero: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: SettingsLayoutMetrics.cardSpacing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 58, height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius, style: .continuous)
                            .fill(.yellow.opacity(0.13))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "TypeWhisper gets better with every workflow"))
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(String(localized: "Teach TypeWhisper your corrections and keep dictionaries and snippets in sync across Macs."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(String(localized: "Commercial license required"), systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.yellow.opacity(0.13)))
                }

                Spacer(minLength: 12)
            }
        }
        .frame(maxWidth: 640, alignment: .topLeading)
    }

    private func premiumLandingFeatureCard(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        examples: [PremiumCorrectionExample] = [],
        badges: [String] = []
    ) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(iconColor)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius, style: .continuous)
                                .fill(iconColor.opacity(0.12))
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)

                        lockedPremiumBadge
                    }
                }

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !examples.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(String(localized: "Correction examples"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(examples) { example in
                            correctionExampleRow(example)
                        }
                    }
                }

                if !badges.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(String(localized: "Works with"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        FlexibleTagRow(items: badges)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
    }

    private var premiumLicenseCallout: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 12) {
                Label(String(localized: "A Commercial license unlocks both premium features."), systemImage: "lock.open")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                premiumLockedActionButton
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var premiumLockedActionButton: some View {
        Button {
            settingsNavigation.navigateToLicense(target: .top)
        } label: {
            Label(String(localized: "Buy or Enter License Key"), systemImage: "key")
        }
        .buttonStyle(.borderedProminent)
    }

    private var lockedPremiumBadge: some View {
        Label(String(localized: "Premium"), systemImage: "lock.fill")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
            .lineLimit(1)
    }

    private var premiumControlCenter: some View {
        VStack(alignment: .leading, spacing: 18) {
            premiumControlHeader

            LazyVGrid(columns: statusColumns, alignment: .leading, spacing: 12) {
                premiumStatusTile(
                    icon: "wand.and.sparkles",
                    iconColor: targetAppCorrectionLearningEnabled ? .green : .secondary,
                    title: String(localized: "Learning"),
                    value: targetAppCorrectionLearningEnabled ? String(localized: "On") : String(localized: "Off"),
                    description: String(localized: "Learns after direct insertion")
                )

                premiumStatusTile(
                    icon: "cloud",
                    iconColor: cloudSyncStatusColor,
                    title: String(localized: "Sync"),
                    value: cloudSyncStatusText,
                    description: cloudSyncDetailText
                )
            }

            targetAppCorrectionLearningSection

            CloudFolderSyncSettingsView(controller: syncController)
        }
        .padding(SettingsLayoutMetrics.pagePadding)
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    private var premiumControlHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius, style: .continuous)
                        .fill(.yellow.opacity(0.13))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Premium Control Center"))
                    .font(.title2.weight(.semibold))

                Text(license.hasCommercialLicense
                     ? String(localized: "Commercial license active. Manage correction learning and sync from one place.")
                     : String(localized: "Premium account active. Manage cross-device sync from one place."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Label(String(localized: "Active"), systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.green.opacity(0.13)))
        }
    }

    private func premiumStatusTile(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        description: String
    ) -> some View {
        SettingsCard {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(iconColor)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius, style: .continuous)
                            .fill(iconColor.opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(value)
                        .font(.headline)
                        .lineLimit(1)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var targetAppCorrectionLearningSection: some View {
        PremiumControlSection(
            icon: "wand.and.sparkles",
            iconColor: .yellow,
            title: String(localized: "Automatic Correction Learning"),
            description: String(localized: "Corrections are learned only when edits are confident. Ambiguous changes are skipped."),
            statusText: targetAppCorrectionLearningEnabled ? String(localized: "On") : String(localized: "Off"),
            statusColor: targetAppCorrectionLearningEnabled ? .green : .secondary
        ) {
            Toggle(
                String(localized: "Learn corrections from edits after insertion"),
                isOn: targetAppCorrectionLearningBinding
            )
            .toggleStyle(.switch)

            if let attempt = correctionLearningService.latestAttempt {
                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: correctionLearningOutcomeIcon(attempt.outcome))
                        .foregroundStyle(correctionLearningOutcomeColor(attempt.outcome))
                        .frame(width: 18)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(correctionLearningOutcomeText(attempt.outcome))
                            .font(.callout.weight(.medium))

                        HStack(spacing: 4) {
                            Text(localizedAppText("Last attempt", de: "Letzter Versuch"))
                            Text(attempt.timestamp, style: .relative)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if attempt.learnedCorrectionCount > 0 {
                            Text(String.localizedStringWithFormat(
                                localizedAppText("%d corrections learned", de: "%d Korrekturen gelernt"),
                                attempt.learnedCorrectionCount
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    if let commitSignal = attempt.commitSignal {
                        Text(correctionLearningCommitSignalText(commitSignal))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(String(localized: "Correction examples"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                correctionExampleRow(PremiumCorrectionExample(before: "teh", after: "the"))
                correctionExampleRow(PremiumCorrectionExample(before: "recieve", after: "receive"))
            }
        }
    }

    private func correctionLearningOutcomeText(_ outcome: TargetAppCorrectionLearningOutcome) -> String {
        switch outcome {
        case .learned:
            localizedAppText("Correction learned", de: "Korrektur gelernt")
        case .unsupportedTextObservation:
            localizedAppText("Text could not be observed", de: "Text konnte nicht beobachtet werden")
        case .noEdit:
            localizedAppText("No edit detected", de: "Keine Bearbeitung erkannt")
        case .ambiguousEdit:
            localizedAppText("Ambiguous edit skipped", de: "Mehrdeutige Bearbeitung übersprungen")
        case .noCommitBeforeTimeout:
            localizedAppText("No completion signal detected", de: "Kein Abschlusssignal erkannt")
        case .duplicateCorrection:
            localizedAppText("Correction already exists", de: "Korrektur ist bereits vorhanden")
        case .cancelled:
            localizedAppText("Learning attempt cancelled", de: "Lernversuch abgebrochen")
        case .failed:
            localizedAppText("Correction could not be saved", de: "Korrektur konnte nicht gespeichert werden")
        }
    }

    private func correctionLearningOutcomeIcon(_ outcome: TargetAppCorrectionLearningOutcome) -> String {
        switch outcome {
        case .learned:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .unsupportedTextObservation, .ambiguousEdit, .noCommitBeforeTimeout:
            "info.circle.fill"
        case .noEdit, .duplicateCorrection, .cancelled:
            "minus.circle.fill"
        }
    }

    private func correctionLearningOutcomeColor(_ outcome: TargetAppCorrectionLearningOutcome) -> Color {
        switch outcome {
        case .learned:
            .green
        case .failed:
            .red
        case .unsupportedTextObservation, .ambiguousEdit, .noCommitBeforeTimeout:
            .yellow
        case .noEdit, .duplicateCorrection, .cancelled:
            .secondary
        }
    }

    private func correctionLearningCommitSignalText(_ signal: TargetAppCorrectionCommitSignal) -> String {
        switch signal {
        case .returnKey:
            localizedAppText("Return", de: "Return")
        case .keypadEnterKey:
            localizedAppText("Enter", de: "Enter")
        case .tabKey:
            localizedAppText("Tab", de: "Tab")
        case .focusChanged:
            localizedAppText("Focus changed", de: "Fokuswechsel")
        case .activeApplicationChanged:
            localizedAppText("App changed", de: "App-Wechsel")
        }
    }

    private var targetAppCorrectionLearningBinding: Binding<Bool> {
        Binding(
            get: {
                license.hasCommercialLicense && targetAppCorrectionLearningEnabled
            },
            set: { newValue in
                guard license.hasCommercialLicense else { return }
                targetAppCorrectionLearningEnabled = newValue
            }
        )
    }

    private func correctionExampleRow(_ example: PremiumCorrectionExample) -> some View {
        HStack(spacing: 8) {
            Text(example.before)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .strikethrough(true, color: .secondary)
                .foregroundStyle(.secondary)

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(example.after)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var cloudSyncStatusText: String {
        if syncController.isSyncing {
            return String(localized: "Syncing")
        }

        if !syncController.isConfigured || !syncController.canUseSync {
            return String(localized: "Not set up")
        }

        if syncController.pendingChanges > 0 {
            return String.localizedStringWithFormat(
                String(localized: "%d pending"),
                syncController.pendingChanges
            )
        }

        return String(localized: "Ready")
    }

    private var cloudSyncDetailText: String {
        (syncController.isConfigured && syncController.canUseSync)
            ? syncController.mode.displayName
            : String(localized: "Sync is off")
    }

    private var cloudSyncStatusColor: Color {
        if syncController.isSyncing {
            return .blue
        }

        if !syncController.isConfigured || !syncController.canUseSync {
            return .secondary
        }

        return syncController.pendingChanges > 0 ? .yellow : .green
    }
}

private struct PremiumCorrectionExample: Identifiable {
    let before: String
    let after: String

    var id: String {
        "\(before)->\(after)"
    }
}

private struct PremiumControlSection<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let statusText: String
    let statusColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(iconColor)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius, style: .continuous)
                                .fill(iconColor.opacity(0.12))
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)

                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(statusColor.opacity(0.13)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(.leading, 50)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct FlexibleTagRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }
        }
    }
}
