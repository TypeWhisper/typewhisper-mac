import SwiftUI

struct LicenseSettingsView: View {
    @ObservedObject private var license = LicenseService.shared
    @ObservedObject private var supporterDiscord =
        SupporterDiscordService.shared ?? SupporterDiscordService(licenseService: LicenseService.shared)

    @State private var licenseKeyInput = ""
    @State private var supporterKeyInput = ""

    private var isPrivateUser: Bool {
        license.userType == .privateUser
    }

    var body: some View {
        Form {
            userTypeSection

            if isPrivateUser {
                privateStatusSection
                supporterSection
            } else {
                businessSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .task(id: "\(license.supporterStatus.rawValue)-\(license.supporterTier?.rawValue ?? "none")") {
            if license.isSupporter {
                await supporterDiscord.refreshStatusIfNeeded()
            } else {
                supporterDiscord.handleSupporterEntitlementRemoved()
            }
        }
    }

    // MARK: - User Type

    private var userTypeSection: some View {
        Section(String(localized: "User Type")) {
            Picker(String(localized: "I use TypeWhisper"), selection: Binding(
                get: { license.userType ?? .privateUser },
                set: { license.setUserType($0) }
            )) {
                Text(String(localized: "Personal / OSS")).tag(LicenseUserType.privateUser)
                Text(String(localized: "Proprietary")).tag(LicenseUserType.business)
            }
            .pickerStyle(.segmented)

            Text(String(localized: "Personal use and GPL-compliant open-source use are free. Proprietary or otherwise non-GPL-compliant use requires a commercial license."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Private

    private var privateStatusSection: some View {
        Section(String(localized: "License Status")) {
            Label(String(localized: "Free for personal and GPL-compliant open-source use"), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
    }

    // MARK: - Business

    @ViewBuilder
    private var businessSection: some View {
        Section(String(localized: "License Status")) {
            businessStatusView
        }

        if license.licenseStatus == .active {
            Section(String(localized: "Manage")) {
                Button {
                    if let url = URL(string: AppConstants.Polar.customerPortalURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "Manage Subscription"), systemImage: "arrow.up.right.square")
                }

                Text(String(localized: "Opens the Polar.sh customer portal where you can manage your subscription, update payment methods, or cancel."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(String(localized: "Deactivate License on This Mac"), role: .destructive) {
                    Task { await license.deactivateLicense() }
                }

                Text(String(localized: "Removes the license from this device. You can reactivate it on another Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = license.deactivationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        } else {
            Section(String(localized: "Purchase a License")) {
                Text(String(localized: "Monthly Subscription"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 16) {
                    businessTierButton(tier: .individual, price: "5", suffix: String(localized: "EUR/mo"), url: AppConstants.Polar.checkoutURLIndividual)
                    businessTierButton(tier: .team, price: "19", suffix: String(localized: "EUR/mo"), url: AppConstants.Polar.checkoutURLTeam)
                    businessTierButton(tier: .enterprise, price: "99", suffix: String(localized: "EUR/mo"), url: AppConstants.Polar.checkoutURLEnterprise)
                }

                Text(String(localized: "Lifetime (one-time)"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 16) {
                    businessTierButton(tier: .individual, price: "99", suffix: String(localized: "EUR"), url: AppConstants.Polar.checkoutURLIndividualLifetime)
                    businessTierButton(tier: .team, price: "299", suffix: String(localized: "EUR"), url: AppConstants.Polar.checkoutURLTeamLifetime)
                    businessTierButton(tier: .enterprise, price: "999", suffix: String(localized: "EUR"), url: AppConstants.Polar.checkoutURLEnterpriseLifetime)
                }

                Text(String(localized: "Pay-what-you-want starting at the listed price. Click a tier to open the checkout page."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                keyActivationField(
                    input: $licenseKeyInput,
                    isActivating: license.isActivating,
                    error: license.activationError
                ) {
                    await license.activateLicenseKey(licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    @ViewBuilder
    private var businessStatusView: some View {
        switch license.licenseStatus {
        case .active:
            HStack {
                Label(String(localized: "Licensed"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let tier = license.licenseTier {
                    let lifetimeLabel = license.licenseIsLifetime ? String(localized: ", Lifetime") : ""
                    Text("(\(businessTierDisplayName(tier))\(lifetimeLabel))")
                        .foregroundStyle(.secondary)
                }
            }
        case .expired:
            Label(String(localized: "License expired or revoked"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unlicensed:
            Label(String(localized: "No active commercial license"), systemImage: "key")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Supporter

    @ViewBuilder
    private var supporterSection: some View {
        if license.isSupporter, let tier = license.supporterTier {
            Section(String(localized: "Supporter Status")) {
                HStack {
                    SupporterBadgeView(tier: tier)
                    Spacer()
                }

                supporterDiscordSection(tier: tier)

                Button {
                    if let url = URL(string: AppConstants.Polar.customerPortalURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(String(localized: "Manage Purchase"), systemImage: "arrow.up.right.square")
                }

                Button(String(localized: "Deactivate Supporter License"), role: .destructive) {
                    Task { await license.deactivateSupporterLicense() }
                }

                if let error = license.supporterDeactivationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        } else {
            Section(String(localized: "Support TypeWhisper")) {
                Text(String(localized: "TypeWhisper is free for personal use. If you'd like to support development, grab a supporter license for a Discord role and an in-app badge."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    supporterTierButton(tier: .bronze, price: "10")
                    supporterTierButton(tier: .silver, price: "25")
                    supporterTierButton(tier: .gold, price: "50")
                }
                .padding(.vertical, 4)

                Button {
                    NSWorkspace.shared.open(supporterDiscord.githubSponsorsURL)
                } label: {
                    Label("Claim GitHub Sponsors status on the web", systemImage: "link")
                }

                keyActivationField(
                    input: $supporterKeyInput,
                    isActivating: license.isSupporterActivating,
                    error: license.supporterActivationError
                ) {
                    await license.activateSupporterKey(supporterKeyInput.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    // MARK: - Shared Key Activation

    @ViewBuilder
    private func keyActivationField(
        input: Binding<String>,
        isActivating: Bool,
        error: String?,
        action: @escaping () async -> Void
    ) -> some View {
        Text(String(localized: "Already have a key?"))
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

        HStack {
            TextField(String(localized: "TYPEWHISPER-xxxx-xxxx"), text: input)
                .textFieldStyle(.roundedBorder)

            Button(String(localized: "Activate")) {
                Task { await action() }
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
        }

        if isActivating {
            ProgressView()
                .controlSize(.small)
        }

        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func supporterDiscordSection(tier: SupporterTier) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch supporterDiscord.claimStatus.state {
            case .unavailable, .unlinked:
                Label("Discord not connected", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(.secondary)

                Text("Connect Discord to claim your \(supporterTierDisplayName(tier)) supporter status in the community server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: "Connect Discord", systemImage: "person.crop.circle.badge.plus") {
                    await openClaimURL(await supporterDiscord.createClaimSession())
                }
            case .pending:
                Label("Claim in progress", systemImage: "clock.badge")
                    .foregroundStyle(.orange)

                Text("Finish the Discord authorization flow in your browser, then refresh the status here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: "Reconnect Discord", systemImage: "arrow.clockwise.circle") {
                    await openClaimURL(await supporterDiscord.reconnect())
                }

                actionButton(title: "Refresh Discord Status", systemImage: "arrow.clockwise") {
                    await supporterDiscord.refreshClaimStatus()
                }
            case .linked:
                Label("Discord connected", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)

                if let username = supporterDiscord.claimStatus.discordUsername {
                    Text("Linked account: \(username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !supporterDiscord.claimStatus.linkedRoles.isEmpty {
                    Text("Active roles: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                actionButton(title: "Refresh Discord Status", systemImage: "arrow.clockwise") {
                    await supporterDiscord.refreshClaimStatus()
                }

                actionButton(title: "Reconnect Discord", systemImage: "link.badge.plus") {
                    await openClaimURL(await supporterDiscord.reconnect())
                }
            case .failed:
                Label("Discord claim failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(supporterDiscord.claimStatus.errorMessage ?? "The Discord claim service returned an unknown error.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: "Retry Discord Claim", systemImage: "arrow.clockwise.circle") {
                    await openClaimURL(await supporterDiscord.reconnect())
                }

                actionButton(title: "Refresh Discord Status", systemImage: "arrow.clockwise") {
                    await supporterDiscord.refreshClaimStatus()
                }
            }

            if supporterDiscord.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if let message = supporterDiscord.claimStatus.errorMessage,
               supporterDiscord.claimStatus.state == .linked {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(supporterDiscord.isWorking)
    }

    private func openClaimURL(_ url: URL?) async {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func businessTierButton(tier: LicenseTier, price: String, suffix: String, url: String) -> some View {
        Button {
            if let checkoutURL = URL(string: url) {
                NSWorkspace.shared.open(checkoutURL)
            }
        } label: {
            VStack(spacing: 4) {
                Text(businessTierDisplayName(tier))
                    .font(.caption.bold())
                Text(businessTierFeature(tier))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(String(localized: "from \(price) \(suffix)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private func businessTierDisplayName(_ tier: LicenseTier) -> String {
        switch tier {
        case .individual: return "Individual"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        }
    }

    private func businessTierFeature(_ tier: LicenseTier) -> String {
        switch tier {
        case .individual: return String(localized: "2 devices")
        case .team: return String(localized: "10 devices")
        case .enterprise: return String(localized: "Unlimited devices")
        }
    }

    private func supporterTierButton(tier: SupporterTier, price: String) -> some View {
        Button {
            let url: String = switch tier {
            case .bronze: AppConstants.Polar.checkoutURLSupporterBronze
            case .silver: AppConstants.Polar.checkoutURLSupporterSilver
            case .gold: AppConstants.Polar.checkoutURLSupporterGold
            }
            if let checkoutURL = URL(string: url) {
                NSWorkspace.shared.open(checkoutURL)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: supporterTierIcon(tier))
                    .foregroundStyle(supporterTierColor(tier))
                Text(supporterTierDisplayName(tier))
                    .font(.caption.bold())
                Text(String(localized: "\(price) EUR"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private func supporterTierDisplayName(_ tier: SupporterTier) -> String {
        switch tier {
        case .bronze: return "Bronze"
        case .silver: return "Silver"
        case .gold: return "Gold"
        }
    }

    private func supporterTierIcon(_ tier: SupporterTier) -> String {
        switch tier {
        case .bronze: return "heart.fill"
        case .silver: return "star.fill"
        case .gold: return "crown.fill"
        }
    }

    private func supporterTierColor(_ tier: SupporterTier) -> Color {
        switch tier {
        case .bronze: return Color(red: 0.804, green: 0.498, blue: 0.196)
        case .silver: return Color(red: 0.753, green: 0.753, blue: 0.753)
        case .gold: return Color(red: 1.0, green: 0.843, blue: 0.0)
        }
    }
}
