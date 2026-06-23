import SwiftUI

@MainActor
struct PremiumSettingsView: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var syncController: CloudFolderSyncController
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningEnabled) private var targetAppCorrectionLearningEnabled = false

    private let settingsNavigation: SettingsNavigationCoordinator

    init(
        licenseService: LicenseService = LicenseService.shared,
        syncController: CloudFolderSyncController = ServiceContainer.shared.cloudFolderSyncController,
        settingsNavigation: SettingsNavigationCoordinator = .shared
    ) {
        self.license = licenseService
        self.syncController = syncController
        self.settingsNavigation = settingsNavigation
    }

    var body: some View {
        ScrollView {
            if license.hasCommercialLicense {
                premiumControlCenter
            } else {
                lockedPremiumLanding
            }
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 16) {
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
        .padding(22)
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    private var lockedPremiumHero: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 58, height: 58)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.yellow.opacity(0.13)))
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
        .padding(18)
        .frame(maxWidth: 640, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func premiumLandingFeatureCard(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        examples: [PremiumCorrectionExample] = [],
        badges: [String] = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(iconColor.opacity(0.12)))
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
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var premiumLicenseCallout: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(String(localized: "A Commercial license unlocks both premium features."), systemImage: "lock.open")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            premiumLockedActionButton
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
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
            .background(Color.white.opacity(0.08))
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
        .padding(22)
        .frame(maxWidth: 760, alignment: .topLeading)
    }

    private var premiumControlHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.yellow.opacity(0.13)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Premium Control Center"))
                    .font(.title2.weight(.semibold))

                Text(String(localized: "Commercial license active. Manage correction learning and sync from one place."))
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
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(iconColor.opacity(0.12)))
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
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
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

            VStack(alignment: .leading, spacing: 7) {
                Text(String(localized: "Correction examples"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                correctionExampleRow(PremiumCorrectionExample(before: "teh", after: "the"))
                correctionExampleRow(PremiumCorrectionExample(before: "recieve", after: "receive"))
            }
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
                .fill(Color.black.opacity(0.16))
        )
    }

    private var cloudSyncStatusText: String {
        if syncController.isSyncing {
            return String(localized: "Syncing")
        }

        if syncController.selectedFolderURL == nil {
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
        syncController.selectedFolderURL == nil
            ? String(localized: "No folder selected")
            : String(localized: "Folder selected")
    }

    private var cloudSyncStatusColor: Color {
        if syncController.isSyncing {
            return .blue
        }

        if syncController.selectedFolderURL == nil {
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(iconColor.opacity(0.12)))
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
        )
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
                            .fill(Color.white.opacity(0.08))
                    )
            }
        }
    }
}
