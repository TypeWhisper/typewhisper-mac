import AppKit
import SwiftUI

struct LicenseSettingsView: View {
    private enum ScrollAnchor: Hashable {
        case top
        case supporter
        case activationKey
    }

    private enum FocusField: Hashable {
        case licenseKey
    }

    @ObservedObject private var license = LicenseService.shared
    @ObservedObject private var supporterDiscord =
        SupporterDiscordService.shared ?? SupporterDiscordService(licenseService: LicenseService.shared)
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared

    @State private var licenseKeyInput = ""
    @State private var activationNotice: String?
    @FocusState private var focusedField: FocusField?

    private let planColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let planDescriptionMinHeight: CGFloat = 52

    private var shouldShowCommercialSection: Bool {
        license.requiresCommercialLicense || license.licenseStatus == .active
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear
                        .frame(height: 0)
                        .id(ScrollAnchor.top)

                    planSelectionSection

                    if shouldShowCommercialSection {
                        commercialSection
                    }

                    supporterSection
                        .id(ScrollAnchor.supporter)

                    sharedActivationSection
                        .id(ScrollAnchor.activationKey)
                }
                .padding(20)
            }
            .frame(minWidth: 560, minHeight: 360)
            .task(id: "\(license.supporterStatus.rawValue)-\(license.supporterTier?.rawValue ?? "none")") {
                if license.isSupporter {
                    await supporterDiscord.refreshStatusIfNeeded()
                } else {
                    supporterDiscord.handleSupporterEntitlementRemoved()
                }
            }
            .onReceive(settingsNavigation.$request.compactMap { $0 }) { request in
                guard request.tab == .license else { return }
                handleNavigation(request.licenseTarget ?? .top, proxy: proxy)
            }
        }
    }

    private var planSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Choose the plan that fits."))
                .font(.headline)

            Text(String(localized: "Everything stays on this page. Pick the plan that matches how you use TypeWhisper."))
            .foregroundStyle(.secondary)

            LazyVGrid(columns: planColumns, spacing: 12) {
                planSelectionButton(
                    title: String(localized: "GPLv3 / OSS"),
                    price: String(localized: "Free"),
                    description: String(localized: "Install and run the GPL version as-is, including personal or internal use."),
                    systemImage: "checkmark.circle",
                    selected: license.usageIntent == .personalOSS && license.licenseTier != .enterprise,
                    accent: .green
                ) {
                    license.setUsageIntent(.personalOSS)
                }

                planSelectionButton(
                    title: String(localized: "Individual"),
                    price: String(localized: "from 5 EUR/mo"),
                    description: String(localized: "Non-GPL terms, procurement, support, or proprietary distribution for one person."),
                    systemImage: "briefcase",
                    selected: license.usageIntent == .workSolo && license.licenseTier != .enterprise,
                    accent: .accentColor
                ) {
                    license.setUsageIntent(.workSolo)
                }

                planSelectionButton(
                    title: "Team",
                    price: String(localized: "from 19 EUR/mo"),
                    description: String(localized: "Procurement, support, managed seats, and up to 10 devices."),
                    systemImage: "person.3",
                    selected: license.usageIntent == .team && license.licenseTier != .enterprise,
                    accent: .accentColor
                ) {
                    license.setUsageIntent(.team)
                }

                planSelectionButton(
                    title: String(localized: "Enterprise"),
                    price: String(localized: "from 99 EUR/mo"),
                    description: String(localized: "Company-wide rollout, procurement, and compliance-heavy setups."),
                    systemImage: "building.2",
                    selected: license.usageIntent == .enterprise || license.licenseTier == .enterprise,
                    accent: .orange
                ) {
                    license.setUsageIntent(.enterprise)
                }
            }
        }
    }

    private var sharedActivationSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Already have a key?"))
                    .font(.headline)

                Text(String(localized: "Enter any TypeWhisper key here. The app automatically detects whether it is Supporter, Individual, Team, or Enterprise."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                keyActivationField(
                    input: $licenseKeyInput,
                    isActivating: license.isActivating,
                    error: license.activationError
                ) {
                    await activateDetectedKey()
                }

                if let activationNotice {
                    Label(activationNotice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }

                Button {
                    openURL(URL(string: AppConstants.Polar.customerPortalURL))
                } label: {
                    Label(String(localized: "Manage Purchases"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .modifier(PointingHandCursorModifier())

                Text(String(localized: "Use this if you already bought a commercial or supporter license and want to manage it in Polar."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var commercialSection: some View {
        if license.licenseStatus == .active {
            activeCommercialSection
        } else {
            inactiveCommercialSection
        }
    }

    private var inactiveCommercialSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Pricing in short"))
                        .font(.headline)

                    if let selectedCommercialTier {
                        HStack(alignment: .top, spacing: 12) {
                            purchaseOptionCard(
                                eyebrow: String(localized: "Flexible"),
                                title: String(localized: "Monthly subscription"),
                                pricing: commercialPurchaseOptionCopy(for: selectedCommercialTier, cadence: .monthly),
                                description: monthlyPurchaseDescription(for: selectedCommercialTier),
                                systemImage: "calendar",
                                accent: .accentColor
                            ) {
                                openURL(selectedCommercialMonthlyURL)
                            }

                            purchaseOptionCard(
                                eyebrow: String(localized: "One-time purchase"),
                                title: String(localized: "Lifetime"),
                                pricing: commercialPurchaseOptionCopy(for: selectedCommercialTier, cadence: .lifetime),
                                description: lifetimePurchaseDescription(for: selectedCommercialTier),
                                systemImage: "infinity",
                                accent: Color(red: 0.96, green: 0.69, blue: 0.22),
                                badge: String(localized: "Best Value"),
                                emphasized: true
                            ) {
                                openURL(selectedCommercialLifetimeURL)
                            }
                        }

                        Text(String(localized: "Monthly is recurring. Lifetime is a one-time purchase for the same tier."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        pricingWebsiteLink
                    }
                }
            }

            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label(commercialStatusTitle, systemImage: commercialStatusSymbol)
                        .foregroundStyle(commercialStatusColor)
                        .font(.headline)

                    Text(commercialStatusDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var activeCommercialSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(String(localized: "Licensed"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.headline)

                        if let tier = license.licenseTier {
                            Text(activeTierLabel(for: tier))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(activeCommercialDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "Manage this Mac and your subscription"))
                        .font(.headline)

                    pricingWebsiteLink

                    actionButton(title: String(localized: "Manage Subscription"), systemImage: "arrow.up.right.square") {
                        openURL(URL(string: AppConstants.Polar.customerPortalURL))
                    }

                    Text(String(localized: "Opens the Polar.sh customer portal where you can manage your subscription, update payment methods, or cancel."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    actionButton(title: String(localized: "Deactivate License on This Mac"), systemImage: "trash", role: .destructive) {
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
            }
        }
    }

    private var pricingWebsiteLink: some View {
        Button {
            openURL(AppConstants.Website.pricingURL)
        } label: {
            Label(
                String(localized: "View full pricing and FAQs on the website"),
                systemImage: "globe"
            )
        }
        .buttonStyle(.link)
        .modifier(PointingHandCursorModifier())
    }

    // MARK: - Supporter

    private var supporterSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Supporter"))
                    .font(.headline)

                Text(supporterDescriptionText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if license.isSupporter, let tier = license.supporterTier {
                    HStack {
                        SupporterBadgeView(tier: tier)
                        Spacer()
                    }

                    supporterDiscordSection(tier: tier)

                    HStack(spacing: 10) {
                        actionButton(title: String(localized: "Manage Purchase"), systemImage: "arrow.up.right.square") {
                            openURL(URL(string: AppConstants.Polar.customerPortalURL))
                        }

                        actionButton(
                            title: String(localized: "Deactivate Supporter License"),
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            Task { await license.deactivateSupporterLicense() }
                        }
                    }

                    if let error = license.supporterDeactivationError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                } else {
                    Text(String(localized: "If you already bought a supporter key, enter it above. GitHub Sponsors can still be claimed on the web."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    actionButton(
                        title: String(localized: "Claim GitHub Sponsors status on the web"),
                        systemImage: "link"
                    ) {
                        openURL(supporterDiscord.githubSponsorsURL)
                    }
                }

                HStack(spacing: 12) {
                    supporterTierButton(tier: .bronze, price: "10")
                    supporterTierButton(tier: .silver, price: "25")
                    supporterTierButton(tier: .gold, price: "50")
                }
            }
        }
    }

    // MARK: - Shared Key Activation

    private var supporterDescriptionText: String {
        String(localized: "Supporter status is personal and optional. It can exist alongside GPLv3 / OSS, Individual, Team, or Enterprise, but it never grants commercial license terms.")
    }

    @ViewBuilder
    private func keyActivationField(
        input: Binding<String>,
        isActivating: Bool,
        error: String?,
        action: @escaping () async -> Void
    ) -> some View {
        HStack {
            TextField(String(localized: "TYPEWHISPER-xxxx-xxxx"), text: input)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .licenseKey)

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
                Label(String(localized: "Discord not connected"), systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(.secondary)

                Text(String(localized: "Connect Discord to claim your \(supporterTierDisplayName(tier)) supporter status in the community server."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: String(localized: "Connect Discord"), systemImage: "person.crop.circle.badge.plus") {
                    Task { await openClaimURL(await supporterDiscord.createClaimSession()) }
                }
            case .pending:
                Label(String(localized: "Claim in progress"), systemImage: "clock.badge")
                    .foregroundStyle(.orange)

                Text(String(localized: "Finish the Discord authorization flow in your browser, then refresh the status here."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: String(localized: "Reconnect Discord"), systemImage: "arrow.clockwise.circle") {
                    Task { await openClaimURL(await supporterDiscord.reconnect()) }
                }

                actionButton(title: String(localized: "Refresh Discord Status"), systemImage: "arrow.clockwise") {
                    Task { await supporterDiscord.refreshClaimStatus() }
                }
            case .linked:
                Label(String(localized: "Discord connected"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)

                if let username = supporterDiscord.claimStatus.discordUsername {
                    Text(String(localized: "Linked account: \(username)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !supporterDiscord.claimStatus.linkedRoles.isEmpty {
                    Text(String(localized: "Active roles: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))"))"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                actionButton(title: String(localized: "Refresh Discord Status"), systemImage: "arrow.clockwise") {
                    Task { await supporterDiscord.refreshClaimStatus() }
                }

                actionButton(title: String(localized: "Reconnect Discord"), systemImage: "link.badge.plus") {
                    Task { await openClaimURL(await supporterDiscord.reconnect()) }
                }
            case .failed:
                Label(String(localized: "Discord claim failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(supporterDiscord.claimStatus.errorMessage ?? String(localized: "The Discord claim service returned an unknown error."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: String(localized: "Retry Discord Claim"), systemImage: "arrow.clockwise.circle") {
                    Task { await openClaimURL(await supporterDiscord.reconnect()) }
                }

                actionButton(title: String(localized: "Refresh Discord Status"), systemImage: "arrow.clockwise") {
                    Task { await supporterDiscord.refreshClaimStatus() }
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

    private func planSelectionButton(
        title: String,
        price: String,
        description: String,
        systemImage: String,
        selected: Bool,
        accent: Color,
        trailingLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            planSummaryCard(
                title: title,
                price: price,
                description: description,
                systemImage: systemImage,
                selected: selected,
                accent: accent,
                trailingLabel: trailingLabel
            )
        }
        .buttonStyle(.plain)
    }

    private func planSummaryCard(
        title: String,
        price: String,
        description: String,
        systemImage: String,
        selected: Bool,
        accent: Color,
        trailingLabel: String? = nil
    ) -> some View {
        PlanSelectionCardView(
            title: title,
            price: price,
            description: description,
            systemImage: systemImage,
            selected: selected,
            accent: accent,
            trailingLabel: trailingLabel,
            descriptionMinHeight: planDescriptionMinHeight
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func purchaseOptionCard(
        eyebrow: String,
        title: String,
        pricing: CommercialPurchaseOptionCopy,
        description: String,
        systemImage: String,
        accent: Color,
        badge: String? = nil,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        PurchaseOptionCardView(
            eyebrow: eyebrow,
            title: title,
            pricing: pricing,
            description: description,
            systemImage: systemImage,
            accent: accent,
            badge: badge,
            emphasized: emphasized,
            action: action
        )
    }

    @ViewBuilder
    private func actionButton(
        title: String,
        systemImage: String,
        prominent: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var commercialStatusTitle: String {
        switch license.licenseStatus {
        case .active:
            return String(localized: "Licensed")
        case .expired:
            return String(localized: "License expired or revoked")
        case .unlicensed:
            return String(localized: "No active commercial license")
        }
    }

    private var commercialStatusDescription: String {
        switch license.usageIntent {
        case .personalOSS:
            return ""
        case .workSolo:
            return String(localized: "Individual covers one person who needs non-GPL terms, procurement, support, or proprietary distribution on up to 2 devices.")
        case .team:
            return String(localized: "Team covers procurement-friendly licensing, support, managed seats, and up to 10 devices.")
        case .enterprise:
            return String(localized: "Enterprise covers company-wide rollout, procurement, and unlimited devices.")
        }
    }

    private var commercialStatusSymbol: String {
        switch license.licenseStatus {
        case .active:
            "checkmark.seal.fill"
        case .expired:
            "exclamationmark.triangle.fill"
        case .unlicensed:
            "briefcase"
        }
    }

    private var commercialStatusColor: Color {
        switch license.licenseStatus {
        case .active:
            .green
        case .expired:
            .orange
        case .unlicensed:
            .accentColor
        }
    }

    private var activeCommercialDescription: String {
        if let tier = license.licenseTier {
            switch tier {
            case .individual:
                return String(localized: "This Mac is covered by Individual commercial license terms on up to 2 devices.")
            case .team:
                return String(localized: "This Mac is covered by a team license for up to 10 devices.")
            case .enterprise:
                return String(localized: "This Mac is covered by an enterprise license for company-wide rollout and unlimited devices.")
            }
        }

        return String(localized: "This Mac has an active commercial license.")
    }

    private func monthlyPurchaseDescription(for tier: LicenseTier) -> String {
        switch tier {
        case .individual:
            return String(localized: "Individual commercial license terms for up to 2 devices with recurring billing.")
        case .team:
            return String(localized: "Keeps a team of up to 10 devices covered with a recurring plan.")
        case .enterprise:
            return String(localized: "Recurring company-wide plan for rollout, procurement, and unlimited devices.")
        }
    }

    private func lifetimePurchaseDescription(for tier: LicenseTier) -> String {
        switch tier {
        case .individual:
            return String(localized: "One payment for the same 2-device Individual tier, with no monthly renewal.")
        case .team:
            return String(localized: "One payment for the same Team tier with up to 10 devices and no renewal cycle.")
        case .enterprise:
            return String(localized: "One payment for the same Enterprise rollout tier with unlimited devices.")
        }
    }

    private var selectedCommercialTier: LicenseTier? {
        switch license.usageIntent {
        case .personalOSS:
            return nil
        case .workSolo:
            return .individual
        case .team:
            return .team
        case .enterprise:
            return .enterprise
        }
    }

    private var selectedCommercialMonthlyURL: URL? {
        guard let tier = selectedCommercialTier else { return nil }

        let urlString: String = switch tier {
        case .individual:
            AppConstants.Polar.checkoutURLIndividual
        case .team:
            AppConstants.Polar.checkoutURLTeam
        case .enterprise:
            AppConstants.Polar.checkoutURLEnterprise
        }

        return URL(string: urlString)
    }

    private var selectedCommercialLifetimeURL: URL? {
        guard let tier = selectedCommercialTier else { return nil }

        let urlString: String = switch tier {
        case .individual:
            AppConstants.Polar.checkoutURLIndividualLifetime
        case .team:
            AppConstants.Polar.checkoutURLTeamLifetime
        case .enterprise:
            AppConstants.Polar.checkoutURLEnterpriseLifetime
        }

        return URL(string: urlString)
    }

    @MainActor
    private func activateDetectedKey() async {
        activationNotice = nil

        let trimmedKey = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        if let activatedEntitlement = await license.activateAnyKey(trimmedKey) {
            licenseKeyInput = ""
            activationNotice = activationSuccessText(for: activatedEntitlement)
        }
    }

    private func activationSuccessText(for entitlement: ActivatedEntitlement) -> String {
        switch entitlement {
        case .commercial(let tier, let isLifetime):
            let lifetimeSuffix = isLifetime
                ? String(localized: " (Lifetime)")
                : ""
            return String(localized: "Detected commercial key: \(businessTierDisplayName(tier))\(lifetimeSuffix).")
        case .supporter(let tier):
            return String(localized: "Detected supporter key: \(supporterTierDisplayName(tier)).")
        }
    }

    private func activeTierLabel(for tier: LicenseTier) -> String {
        let lifetimeSuffix = license.licenseIsLifetime ? String(localized: ", Lifetime") : ""
        return "(\(businessTierDisplayName(tier))\(lifetimeSuffix))"
    }

    private func openURL(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openClaimURL(_ url: URL?) async {
        openURL(url)
    }

    private func handleNavigation(_ target: LicenseSettingsNavigationTarget, proxy: ScrollViewProxy) {
        focusedField = nil

        withAnimation(.easeInOut(duration: 0.15)) {
            switch target {
            case .top:
                proxy.scrollTo(ScrollAnchor.top, anchor: .top)
            case .supporter:
                proxy.scrollTo(ScrollAnchor.supporter, anchor: .top)
            case .activationKey:
                proxy.scrollTo(ScrollAnchor.activationKey, anchor: .top)
            }
        }

        guard target == .activationKey else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            focusedField = .licenseKey
        }
    }

    @ViewBuilder
    private func supporterTierButton(tier: SupporterTier, price: String) -> some View {
        let isCurrentTier = license.isSupporter && license.supporterTier == tier

        let button = Button {
            let url: String = switch tier {
            case .bronze: AppConstants.Polar.checkoutURLSupporterBronze
            case .silver: AppConstants.Polar.checkoutURLSupporterSilver
            case .gold: AppConstants.Polar.checkoutURLSupporterGold
            }
            openURL(URL(string: url))
        } label: {
            VStack(spacing: 6) {
                Image(systemName: supporterTierIcon(tier))
                    .foregroundStyle(supporterTierColor(tier))
                Text(supporterTierDisplayName(tier))
                    .font(.caption.bold())
                Text("\(price) EUR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }

        if isCurrentTier {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func businessTierDisplayName(_ tier: LicenseTier) -> String {
        switch tier {
        case .individual: return String(localized: "Individual")
        case .team: return String(localized: "Team")
        case .enterprise: return String(localized: "Enterprise")
        }
    }

    private func supporterTierDisplayName(_ tier: SupporterTier) -> String {
        switch tier {
        case .bronze: return String(localized: "Bronze")
        case .silver: return String(localized: "Silver")
        case .gold: return String(localized: "Gold")
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

enum CommercialPurchaseCadence {
    case monthly
    case lifetime
}

struct CommercialPurchaseOptionCopy: Equatable {
    let price: String
    let billingLabel: String
    let detail: String
}

func commercialPurchaseOptionCopy(for tier: LicenseTier, cadence: CommercialPurchaseCadence) -> CommercialPurchaseOptionCopy {
    switch (tier, cadence) {
    case (.individual, .monthly):
        CommercialPurchaseOptionCopy(
            price: "5 EUR",
            billingLabel: String(localized: "per month"),
            detail: String(localized: "Lower upfront cost")
        )
    case (.individual, .lifetime):
        CommercialPurchaseOptionCopy(
            price: "99 EUR",
            billingLabel: String(localized: "one-time"),
            detail: String(localized: "Pay once, keep this tier")
        )
    case (.team, .monthly):
        CommercialPurchaseOptionCopy(
            price: "19 EUR",
            billingLabel: String(localized: "per month"),
            detail: String(localized: "Recurring billing")
        )
    case (.team, .lifetime):
        CommercialPurchaseOptionCopy(
            price: "299 EUR",
            billingLabel: String(localized: "one-time"),
            detail: String(localized: "Pay once, keep this tier")
        )
    case (.enterprise, .monthly):
        CommercialPurchaseOptionCopy(
            price: "99 EUR",
            billingLabel: String(localized: "per month"),
            detail: String(localized: "Recurring billing")
        )
    case (.enterprise, .lifetime):
        CommercialPurchaseOptionCopy(
            price: "999 EUR",
            billingLabel: String(localized: "one-time"),
            detail: String(localized: "Pay once, keep this tier")
        )
    }
}

private struct PanelCard<Content: View>: View {
    let selected: Bool
    let accent: Color
    @ViewBuilder let content: Content

    init(
        selected: Bool = false,
        accent: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) {
        self.selected = selected
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
    }
}

private struct PurchaseOptionCardView: View {
    let eyebrow: String
    let title: String
    let pricing: CommercialPurchaseOptionCopy
    let description: String
    let systemImage: String
    let accent: Color
    let badge: String?
    let emphasized: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: emphasized
                                        ? [accent.opacity(isHovering ? 0.25 : 0.22), accent.opacity(isHovering ? 0.08 : 0.05), .clear]
                                        : [accent.opacity(isHovering ? 0.17 : 0.14), accent.opacity(isHovering ? 0.06 : 0.04), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                accent.opacity(emphasized
                                    ? (isHovering ? 0.56 : 0.45)
                                    : (isHovering ? 0.34 : 0.22)
                                ),
                                lineWidth: isHovering ? 1.2 : 1
                            )
                    }

                if emphasized {
                    Circle()
                        .fill(accent.opacity(isHovering ? 0.15 : 0.12))
                        .frame(width: 84, height: 84)
                        .blur(radius: isHovering ? 18 : 16)
                        .offset(x: 16, y: -12)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(accent.opacity(emphasized ? 0.2 : 0.13))
                                        .frame(width: 34, height: 34)

                                    Image(systemName: systemImage)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(accent)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(eyebrow)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(accent)

                                    Text(title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                }
                            }

                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        VStack(alignment: .trailing, spacing: 6) {
                            Text(pricing.price)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)

                            Text(pricing.billingLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent)
                        }
                        .padding(.top, 22)
                    }

                    Text(pricing.detail)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(emphasized ? accent : .secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 152, alignment: .leading)

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent.opacity(0.18))
                        )
                        .foregroundStyle(accent)
                        .padding(12)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .offset(y: isHovering ? -1 : 0)
            .shadow(
                color: accent.opacity(emphasized
                    ? (isHovering ? 0.14 : 0.10)
                    : (isHovering ? 0.08 : 0.04)
                ),
                radius: emphasized ? (isHovering ? 10 : 8) : (isHovering ? 6 : 4),
                y: isHovering ? 4 : (emphasized ? 3 : 1)
            )
            .animation(.easeOut(duration: 0.14), value: isHovering)
        }
        .buttonStyle(.plain)
        .modifier(PointingHandCursorModifier())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct PlanSelectionCardView: View {
    let title: String
    let price: String
    let description: String
    let systemImage: String
    let selected: Bool
    let accent: Color
    let trailingLabel: String?
    let descriptionMinHeight: CGFloat

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: selected
                                    ? [accent.opacity(isHovering ? 0.10 : 0.08), accent.opacity(isHovering ? 0.04 : 0.02), .clear]
                                    : [accent.opacity(isHovering ? 0.05 : 0.0), .clear, .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            selected
                                ? accent.opacity(isHovering ? 0.92 : 0.80)
                                : accent.opacity(isHovering ? 0.28 : 0.08),
                            lineWidth: selected ? (isHovering ? 1.8 : 1.5) : (isHovering ? 1.2 : 1)
                        )
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                    } else if let trailingLabel {
                        Text(trailingLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }

                Text(price)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: descriptionMinHeight, alignment: .topLeading)
            }
            .padding(16)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .offset(y: isHovering ? -1 : 0)
        .shadow(
            color: (selected ? accent : .black).opacity(isHovering ? 0.12 : 0.05),
            radius: isHovering ? 7 : 4,
            y: isHovering ? 4 : 1
        )
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .modifier(PointingHandCursorModifier())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct PointingHandCursorModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering

                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                guard isHovering else { return }
                NSCursor.pop()
                isHovering = false
            }
    }
}
