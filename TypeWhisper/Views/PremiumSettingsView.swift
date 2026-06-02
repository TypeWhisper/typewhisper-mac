import SwiftUI

@MainActor
struct PremiumSettingsView: View {
    @Environment(\.openURL) private var openURL

    @ObservedObject private var license: LicenseService
    @ObservedObject private var syncController: CloudFolderSyncController

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
            VStack(alignment: .leading, spacing: 18) {
                premiumHeader
                if !license.hasCommercialLicense {
                    premiumUpsell
                } else {
                    CloudFolderSyncSettingsView(controller: syncController)
                }
            }
            .padding(22)
            .frame(maxWidth: 760, alignment: .topLeading)
        }
        .frame(minWidth: 560, minHeight: 360, alignment: .topLeading)
    }

    private var premiumHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.14)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "Premium"))
                        .font(.title2.weight(.semibold))

                    premiumStatus
                }

                Spacer(minLength: 16)
            }

            if license.isSupporter && !license.hasCommercialLicense {
                Label(String(localized: "Supporter status is active. Premium features require a Commercial license."), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var premiumUpsell: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "lock.open.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.14)))

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Unlock Premium features"))
                        .font(.headline)

                    Text(String(localized: "Cloud Folder Sync is available with a Commercial license. Sync dictionaries and snippets through your own iCloud Drive, Dropbox, OneDrive, Syncthing, or custom folder."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        openURL(AppConstants.Website.pricingURL)
                    } label: {
                        Label(String(localized: "Buy Commercial License"), systemImage: "cart")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    Button {
                        settingsNavigation.navigateToLicense(target: .activationKey)
                    } label: {
                        Label(String(localized: "Enter License Key"), systemImage: "key")
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.08)))
    }

    @ViewBuilder
    private var premiumStatus: some View {
        if license.hasCommercialLicense {
            Label(String(localized: "Commercial license active"), systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label(String(localized: "Commercial license required"), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
