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
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "License"))
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                        Color.clear
                            .frame(height: 0)
                            .id(ScrollAnchor.top)

                        if license.isLicenseManaged {
                            managedLicenseSection
                        } else {
                            planSelectionSection
                        }

                        if shouldShowCommercialSection && !license.isLicenseManaged {
                            commercialSection
                        }

                        supporterSection
                            .id(ScrollAnchor.supporter)

                        if !license.isLicenseManaged {
                            sharedActivationSection
                                .id(ScrollAnchor.activationKey)
                        }
                    }
                    .padding(SettingsLayoutMetrics.pagePadding)
                }
                .frame(minWidth: 560, minHeight: 360)
                .onChange(of: activationNotice) { _, notice in
                    announceActivationResult(notice, isError: false)
                }
                .onChange(of: license.activationError) { _, error in
                    announceActivationResult(error, isError: true)
                }
                .onChange(of: license.supporterActivationError) { _, error in
                    announceActivationResult(error, isError: true)
                }
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
    }

    private var managedLicenseSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(localizedAppText("Managed by your organization", de: "Von deiner Organisation verwaltet"), systemImage: "building.2")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(localizedAppText(
                    "Your administrator provides the license. TypeWhisper activates it automatically without manual key entry.",
                    de: "Deine Administration stellt die Lizenz bereit. TypeWhisper aktiviert sie automatisch ohne manuelle Schlüsseleingabe."
                ))
                .foregroundStyle(.secondary)

                if license.isActivating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(activatingAccessibilityLabel)
                } else if let error = license.managedLicenseError {
                    // Only the red color marks this text as an error.
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityLabel(String(localized: "Error: \(error)"))
                } else if license.hasCommercialLicense {
                    Label(localizedAppText("Licensed", de: "Lizenziert"), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if let tier = license.licenseTier {
                        Text(activeTierLabel(for: tier))
                    }
                } else {
                    Text(commercialStatusTitle)
                        .foregroundStyle(.secondary)
                }

                Button(localizedAppText("Retry Activation", de: "Aktivierung erneut versuchen")) {
                    Task { await license.validateIfNeeded() }
                }
                .disabled(license.isActivating)
            }
        }
    }

    private var planSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizedAppText("Choose the plan that fits.", de: "Wähle den passenden Plan."))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(localizedAppText(
                "Everything stays on this page. Pick the plan that matches how you use TypeWhisper.",
                de: "Alles bleibt auf dieser Seite. Wähle den Plan, der zu deiner Nutzung von TypeWhisper passt."
            ))
            .foregroundStyle(.secondary)

            LazyVGrid(columns: planColumns, spacing: 12) {
                planSelectionButton(
                    title: localizedAppText("GPLv3 / OSS", de: "GPLv3 / OSS"),
                    price: localizedAppText("Free", de: "Kostenlos"),
                    description: localizedAppText(
                        "Install and run the GPL version as-is, including personal or internal use.",
                        de: "Installiere und nutze die GPL-Version unverändert, auch privat oder intern."
                    ),
                    systemImage: "checkmark.circle",
                    selected: license.usageIntent == .personalOSS && license.licenseTier != .enterprise,
                    accent: .green
                ) {
                    license.setUsageIntent(.personalOSS)
                }

                planSelectionButton(
                    title: localizedAppText("Individual", de: "Einzelnutzer"),
                    price: localizedAppText("from 5 EUR/mo", de: "ab 5 EUR/Monat"),
                    description: localizedAppText(
                        "Non-GPL terms, procurement, support, or proprietary distribution for one person.",
                        de: "Nicht-GPL-Bedingungen, Beschaffung, Support oder proprietäre Weiterverteilung für eine Person."
                    ),
                    systemImage: "briefcase",
                    selected: license.usageIntent == .workSolo && license.licenseTier != .enterprise,
                    accent: .accentColor
                ) {
                    license.setUsageIntent(.workSolo)
                }

                planSelectionButton(
                    title: String(localized: "Team"),
                    price: localizedAppText("from 19 EUR/mo", de: "ab 19 EUR/Monat"),
                    description: localizedAppText(
                        "Procurement, support, managed seats, and up to 10 devices.",
                        de: "Beschaffung, Support, verwaltete Plätze und bis zu 10 Geräte."
                    ),
                    systemImage: "person.3",
                    selected: license.usageIntent == .team && license.licenseTier != .enterprise,
                    accent: .accentColor
                ) {
                    license.setUsageIntent(.team)
                }

                planSelectionButton(
                    title: localizedAppText("Enterprise", de: "Unternehmensplan"),
                    price: localizedAppText("from 199 EUR/mo", de: "ab 199 EUR/Monat"),
                    description: localizedAppText(
                        "Up to 50 devices, a reply within one business day, and help with rollout and security reviews.",
                        de: "Bis zu 50 Geräte, Antwort innerhalb eines Arbeitstags und Hilfe bei Rollout und Security-Reviews."
                    ),
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
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(localizedAppText("Already have a key?", de: "Bereits einen Schlüssel?"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                Text(localizedAppText(
                    "Enter any TypeWhisper key here. The app automatically detects whether it is Supporter, Individual, Team, or Enterprise.",
                    de: "Gib hier einen beliebigen TypeWhisper-Schlüssel ein. Die App erkennt automatisch, ob es ein Supporter-, Einzelnutzer-, Team- oder Unternehmensschlüssel ist."
                ))
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
                    Label(localizedAppText("Manage Purchases", de: "Käufe verwalten"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .modifier(PointingHandCursorModifier())

                Text(localizedAppText(
                    "Use this if you already bought a commercial or supporter license and want to manage it in Polar.",
                    de: "Nutze das, wenn du bereits eine kommerzielle oder Supporter-Lizenz gekauft hast und sie in Polar verwalten möchtest."
                ))
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
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(localizedAppText("Pricing in short", de: "Preise im Überblick"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    if let selectedCommercialTier {
                        LazyVGrid(columns: planColumns, alignment: .leading, spacing: 12) {
                            ForEach(commercialPurchaseCadences(for: selectedCommercialTier), id: \.self) { cadence in
                                if let pricing = commercialPurchaseOptionCopy(for: selectedCommercialTier, cadence: cadence),
                                   let description = purchaseDescription(for: selectedCommercialTier, cadence: cadence) {
                                    purchaseOptionCard(
                                        for: selectedCommercialTier,
                                        cadence: cadence,
                                        pricing: pricing,
                                        description: description
                                    )
                                }
                            }
                        }

                        Text(purchaseOptionsNote(for: selectedCommercialTier))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if selectedCommercialTier == .enterprise {
                            Button {
                                openURL(AppConstants.Website.licensingEmailURL)
                            } label: {
                                Label(
                                    localizedAppText("More than 50 devices? Contact sales", de: "Mehr als 50 Geräte? Vertrieb kontaktieren"),
                                    systemImage: "envelope"
                                )
                            }
                            .buttonStyle(.link)
                            .modifier(PointingHandCursorModifier())
                        }

                        pricingWebsiteLink
                    }
                }
            }

            SettingsCard {
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
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(localizedAppText("Licensed", de: "Lizenziert"), systemImage: "checkmark.seal.fill")
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

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(localizedAppText("Manage this Mac and your subscription", de: "Diesen Mac und dein Abo verwalten"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    pricingWebsiteLink

                    actionButton(title: localizedAppText("Manage Subscription", de: "Abo verwalten"), systemImage: "arrow.up.right.square") {
                        openURL(URL(string: AppConstants.Polar.customerPortalURL))
                    }

                    Text(localizedAppText(
                        "Opens the Polar.sh customer portal where you can manage your subscription, update payment methods, or cancel.",
                        de: "Öffnet das Polar.sh-Kundenportal, in dem du dein Abo verwalten, Zahlungsmethoden aktualisieren oder kündigen kannst."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    actionButton(title: localizedAppText("Deactivate License on This Mac", de: "Lizenz auf diesem Mac deaktivieren"), systemImage: "trash", role: .destructive) {
                        Task { await license.deactivateLicense() }
                    }

                    Text(localizedAppText(
                        "Removes the license from this device. You can reactivate it on another Mac.",
                        de: "Entfernt die Lizenz von diesem Gerät. Du kannst sie auf einem anderen Mac erneut aktivieren."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = license.deactivationError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                            .accessibilityLabel(String(localized: "Error: \(error)"))
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
                localizedAppText(
                    "View full pricing and FAQs on the website",
                    de: "Vollständige Preise und FAQ auf der Website"
                ),
                systemImage: "globe"
            )
        }
        .buttonStyle(.link)
        .modifier(PointingHandCursorModifier())
    }

    // MARK: - Supporter

    private var supporterSection: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(localizedAppText("Supporter", de: "Supporter"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

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
                        actionButton(title: localizedAppText("Manage Purchase", de: "Kauf verwalten"), systemImage: "arrow.up.right.square") {
                            openURL(URL(string: AppConstants.Polar.customerPortalURL))
                        }

                        actionButton(
                            title: localizedAppText("Deactivate Supporter License", de: "Supporter-Lizenz deaktivieren"),
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
                            .accessibilityLabel(String(localized: "Error: \(error)"))
                    }
                } else {
                    if license.isLicenseManaged {
                        Text(localizedAppText(
                            "Activate a personal supporter key. Your organization's commercial license stays unchanged.",
                            de: "Aktiviere einen persönlichen Supporter-Schlüssel. Die kommerzielle Lizenz deiner Organisation bleibt unverändert."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        keyActivationField(
                            input: $licenseKeyInput,
                            isActivating: license.isSupporterActivating,
                            error: license.supporterActivationError
                        ) {
                            await license.activateSupporterKey(licenseKeyInput)
                            if license.isSupporter { licenseKeyInput = "" }
                        }
                    } else {
                        Text(localizedAppText(
                            "If you already bought a supporter key, enter it above. GitHub Sponsors can still be claimed on the web.",
                            de: "Wenn du bereits einen Supporter-Schlüssel gekauft hast, gib ihn oben ein. GitHub Sponsors kannst du weiter im Web bestätigen."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    actionButton(
                        title: localizedAppText("Claim GitHub Sponsors status on the web", de: "GitHub-Sponsors-Status im Web bestätigen"),
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
        localizedAppText(
            "Supporter status is personal and optional. It can exist alongside GPLv3 / OSS, Individual, Team, or Enterprise, but it never grants commercial license terms.",
            de: "Supporter-Status ist persönlich und optional. Er kann neben GPLv3 / OSS, Einzelnutzer, Team oder Unternehmensplan bestehen, gewährt aber nie kommerzielle Lizenzbedingungen."
        )
    }

    @ViewBuilder
    private func keyActivationField(
        input: Binding<String>,
        isActivating: Bool,
        error: String?,
        action: @escaping () async -> Void
    ) -> some View {
        HStack {
            TextField(localizedAppText("TYPEWHISPER-xxxx-xxxx", de: "TYPEWHISPER-xxxx-xxxx"), text: input)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .licenseKey)
                .accessibilityLabel(localizedAppText(
                    "License key",
                    de: "Lizenzschlüssel",
                    ja: "ライセンスキー",
                    zh: "许可证密钥"
                ))

            Button(localizedAppText("Activate", de: "Aktivieren")) {
                Task { await action() }
            }
            .disabled(input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isActivating)
        }

        if isActivating {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(activatingAccessibilityLabel)
        }

        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
                .accessibilityLabel(String(localized: "Error: \(error)"))
        }
    }

    private var activatingAccessibilityLabel: String {
        localizedAppText("Activating license", de: "Lizenz wird aktiviert", ja: "ライセンスを有効化中", zh: "正在激活许可证")
    }

    /// The result of an activation appears below the field, where VoiceOver focus usually is not.
    private func announceActivationResult(_ message: String?, isError: Bool) {
        guard let message, !message.isEmpty else { return }
        // The shared service filters repeats; errors interrupt current speech.
        let announcer = ServiceContainer.shared.accessibilityAnnouncementService
        if isError {
            announcer.announceError(message)
        } else {
            announcer.announce(message)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func supporterDiscordSection(tier: SupporterTier) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch supporterDiscord.claimStatus.state {
            case .unavailable, .unlinked:
                Label(localizedAppText("Discord not connected", de: "Discord nicht verbunden"), systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(.secondary)

                Text(localizedAppText(
                    "Connect Discord to claim your \(supporterTierDisplayName(tier)) supporter status in the community server.",
                    de: "Verbinde Discord, um deinen \(supporterTierDisplayName(tier))-Supporter-Status im Community-Server zu bestätigen.",
                    ja: "Discordを連携して、コミュニティサーバーで\(supporterTierDisplayName(tier))サポーターステータスを受け取ります。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: localizedAppText("Connect Discord", de: "Discord verbinden"), systemImage: "person.crop.circle.badge.plus") {
                    Task { await openClaimURL(await supporterDiscord.createClaimSession()) }
                }
            case .pending:
                Label(localizedAppText("Claim in progress", de: "Bestätigung läuft"), systemImage: "clock.badge")
                    .foregroundStyle(.orange)

                Text(localizedAppText(
                    "Finish the Discord authorization flow in your browser, then refresh the status here.",
                    de: "Schließe den Discord-Autorisierungsablauf im Browser ab und aktualisiere den Status dann hier."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: localizedAppText("Reconnect Discord", de: "Discord erneut verbinden"), systemImage: "arrow.clockwise.circle") {
                    Task { await openClaimURL(await supporterDiscord.reconnect()) }
                }

                actionButton(title: localizedAppText("Refresh Discord Status", de: "Discord-Status aktualisieren"), systemImage: "arrow.clockwise") {
                    Task { await supporterDiscord.refreshClaimStatus() }
                }
            case .linked:
                Label(localizedAppText("Discord connected", de: "Discord verbunden"), systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)

                if let username = supporterDiscord.claimStatus.discordUsername {
                    Text(localizedAppText("Linked account: \(username)", de: "Verknüpftes Konto: \(username)", ja: "連携済みアカウント: \(username)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !supporterDiscord.claimStatus.linkedRoles.isEmpty {
                    Text(localizedAppText(
                        "Active roles: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))",
                        de: "Aktive Rollen: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))",
                        ja: "有効なロール: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                actionButton(title: localizedAppText("Refresh Discord Status", de: "Discord-Status aktualisieren"), systemImage: "arrow.clockwise") {
                    Task { await supporterDiscord.refreshClaimStatus() }
                }

                actionButton(title: localizedAppText("Reconnect Discord", de: "Discord erneut verbinden"), systemImage: "link.badge.plus") {
                    Task { await openClaimURL(await supporterDiscord.reconnect()) }
                }
            case .failed:
                Label(localizedAppText("Discord claim failed", de: "Discord-Bestätigung fehlgeschlagen"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(supporterDiscord.claimStatus.errorMessage ?? localizedAppText(
                    "The Discord claim service returned an unknown error.",
                    de: "Der Discord-Bestätigungsdienst hat einen unbekannten Fehler zurückgegeben."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                actionButton(title: localizedAppText("Retry Discord Claim", de: "Discord-Bestätigung erneut versuchen"), systemImage: "arrow.clockwise.circle") {
                    Task { await openClaimURL(await supporterDiscord.reconnect()) }
                }

                actionButton(title: localizedAppText("Refresh Discord Status", de: "Discord-Status aktualisieren"), systemImage: "arrow.clockwise") {
                    Task { await supporterDiscord.refreshClaimStatus() }
                }
            }

            if supporterDiscord.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText(
                        "Checking Discord status",
                        de: "Discord-Status wird geprüft",
                        ja: "Discordのステータスを確認中",
                        zh: "正在检查 Discord 状态"
                    ))
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
        // The border and the check mark show the chosen plan only visually.
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            return localizedAppText("Licensed", de: "Lizenziert")
        case .expired:
            return localizedAppText("License expired or revoked", de: "Lizenz abgelaufen oder widerrufen")
        case .unlicensed:
            return localizedAppText("No active commercial license", de: "Keine aktive kommerzielle Lizenz")
        }
    }

    private var commercialStatusDescription: String {
        switch license.usageIntent {
        case .personalOSS:
            return ""
        case .workSolo:
            return localizedAppText(
                "Individual covers one person who needs non-GPL terms, procurement, support, or proprietary distribution on up to 3 devices.",
                de: "Der Einzelnutzer-Plan deckt eine Person ab, die Nicht-GPL-Bedingungen, Beschaffung, Support oder proprietäre Weiterverteilung auf bis zu 3 Geräten braucht."
            )
        case .team:
            return localizedAppText(
                "Team covers procurement-friendly licensing, support, managed seats, and up to 10 devices.",
                de: "Team deckt beschaffungsfreundliche Lizenzierung, Support, verwaltete Plätze und bis zu 10 Geräte ab."
            )
        case .enterprise:
            return localizedAppText(
                "Enterprise covers up to 50 devices with a reply within one business day and help with rollout and security reviews. For more devices, contact sales.",
                de: "Der Unternehmensplan deckt bis zu 50 Geräte ab, mit Antwort innerhalb eines Arbeitstags und Hilfe bei Rollout und Security-Reviews. Für mehr Geräte kontaktiere den Vertrieb."
            )
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
                return localizedAppText(
                    "This Mac is covered by Individual commercial license terms on up to 3 devices.",
                    de: "Dieser Mac ist durch kommerzielle Einzelnutzer-Bedingungen auf bis zu 3 Geräten abgedeckt."
                )
            case .team:
                return localizedAppText(
                    "This Mac is covered by a team license for up to 10 devices.",
                    de: "Dieser Mac ist durch eine Team-Lizenz für bis zu 10 Geräte abgedeckt."
                )
            case .enterprise:
                return localizedAppText(
                    "This Mac is covered by an enterprise license for your organization's rollout.",
                    de: "Dieser Mac ist durch eine Unternehmenslizenz für den Rollout deiner Organisation abgedeckt."
                )
            }
        }

        return localizedAppText(
            "This Mac has an active commercial license.",
            de: "Dieser Mac hat eine aktive kommerzielle Lizenz."
        )
    }

    private func purchaseDescription(for tier: LicenseTier, cadence: CommercialPurchaseCadence) -> String? {
        switch (tier, cadence) {
        case (.individual, .monthly):
            return localizedAppText(
                "Individual commercial license terms for up to 3 devices with recurring billing.",
                de: "Kommerzielle Einzelnutzer-Bedingungen für bis zu 3 Geräte mit wiederkehrender Abrechnung."
            )
        case (.team, .monthly):
            return localizedAppText(
                "Keeps a team of up to 10 devices covered with a recurring plan.",
                de: "Deckt ein Team mit bis zu 10 Geräten über einen wiederkehrenden Plan ab."
            )
        case (.enterprise, .monthly):
            return localizedAppText(
                "Recurring plan for up to 50 devices with faster support.",
                de: "Wiederkehrender Plan für bis zu 50 Geräte mit schnellerem Support."
            )
        case (.individual, .yearly):
            return localizedAppText(
                "The same 3-device Individual tier, billed once a year.",
                de: "Dasselbe Einzelnutzer-Paket mit 3 Geräten, einmal im Jahr abgerechnet."
            )
        case (.team, .yearly):
            return localizedAppText(
                "The same Team tier with up to 10 devices, billed once a year.",
                de: "Dasselbe Team-Paket mit bis zu 10 Geräten, einmal im Jahr abgerechnet."
            )
        case (.enterprise, .yearly):
            return localizedAppText(
                "The same Enterprise tier with up to 50 devices, billed once a year.",
                de: "Dasselbe Unternehmens-Paket mit bis zu 50 Geräten, einmal im Jahr abgerechnet."
            )
        case (.individual, .lifetime):
            return localizedAppText(
                "One payment for the same 3-device Individual tier, with no monthly renewal.",
                de: "Eine Zahlung für dasselbe Einzelnutzer-Paket mit 3 Geräten, ohne monatliche Verlängerung."
            )
        case (.team, .lifetime):
            return localizedAppText(
                "One payment for the same Team tier with up to 10 devices and no renewal cycle.",
                de: "Eine Zahlung für dasselbe Team-Paket mit bis zu 10 Geräten und ohne Verlängerungszyklus."
            )
        case (.enterprise, .lifetime):
            return nil
        }
    }

    private func purchaseOptionsNote(for tier: LicenseTier) -> String {
        if commercialPurchaseCadences(for: tier).contains(.lifetime) {
            return localizedAppText(
                "Monthly and yearly renew automatically; a year costs ten monthly prices. Lifetime is a one-time purchase for the same tier.",
                de: "Monats- und Jahresabo verlängern sich automatisch; ein Jahr kostet zehn Monatspreise. Die Dauerlizenz ist ein einmaliger Kauf für dasselbe Paket."
            )
        }
        return localizedAppText(
            "Enterprise is available as a monthly or yearly subscription; a year costs ten monthly prices.",
            de: "Den Unternehmensplan gibt es als Monats- oder Jahresabo; ein Jahr kostet zehn Monatspreise."
        )
    }

    private func purchaseOptionCard(
        for tier: LicenseTier,
        cadence: CommercialPurchaseCadence,
        pricing: CommercialPurchaseOptionCopy,
        description: String
    ) -> some View {
        let open = { openURL(commercialCheckoutURL(for: tier, cadence: cadence)) }

        return Group {
            switch cadence {
            case .monthly:
                purchaseOptionCard(
                    eyebrow: localizedAppText("Flexible", de: "Flexibel"),
                    title: localizedAppText("Monthly subscription", de: "Monatsabo"),
                    pricing: pricing,
                    description: description,
                    systemImage: "calendar",
                    accent: .accentColor,
                    action: open
                )
            case .yearly:
                purchaseOptionCard(
                    eyebrow: localizedAppText("Billed yearly", de: "Jährliche Abrechnung"),
                    title: localizedAppText("Yearly subscription", de: "Jahresabo"),
                    pricing: pricing,
                    description: description,
                    systemImage: "calendar.badge.clock",
                    accent: .green,
                    action: open
                )
            case .lifetime:
                purchaseOptionCard(
                    eyebrow: localizedAppText("One-time purchase", de: "Einmalkauf"),
                    title: localizedAppText("Lifetime", de: "Dauerlizenz"),
                    pricing: pricing,
                    description: description,
                    systemImage: "infinity",
                    accent: Color(red: 0.96, green: 0.69, blue: 0.22),
                    badge: localizedAppText("Best Value", de: "Bestes Angebot"),
                    emphasized: true,
                    action: open
                )
            }
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

    private func commercialCheckoutURL(for tier: LicenseTier, cadence: CommercialPurchaseCadence) -> URL? {
        let urlString: String? = switch (tier, cadence) {
        case (.individual, .monthly): AppConstants.Polar.checkoutURLIndividual
        case (.team, .monthly): AppConstants.Polar.checkoutURLTeam
        case (.enterprise, .monthly): AppConstants.Polar.checkoutURLEnterprise
        case (.individual, .yearly): AppConstants.Polar.checkoutURLIndividualYearly
        case (.team, .yearly): AppConstants.Polar.checkoutURLTeamYearly
        case (.enterprise, .yearly): AppConstants.Polar.checkoutURLEnterpriseYearly
        case (.individual, .lifetime): AppConstants.Polar.checkoutURLIndividualLifetime
        case (.team, .lifetime): AppConstants.Polar.checkoutURLTeamLifetime
        case (.enterprise, .lifetime): nil
        }
        guard let urlString else { return nil }

        return AppConstants.Polar.appCheckoutURL(
            baseURL: urlString,
            content: "settings_\(tier.rawValue)_\(cadence.rawValue)"
        )
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
                ? localizedAppText(" (Lifetime)", de: " (Dauerlizenz)", ja: "（永久ライセンス）")
                : ""
            return localizedAppText(
                "Detected commercial key: \(businessTierDisplayName(tier))\(lifetimeSuffix).",
                de: "Kommerzieller Schlüssel erkannt: \(businessTierDisplayName(tier))\(lifetimeSuffix).",
                ja: "商用キーを検出しました: \(businessTierDisplayName(tier))\(lifetimeSuffix)。"
            )
        case .supporter(let tier):
            return localizedAppText(
                "Detected supporter key: \(supporterTierDisplayName(tier)).",
                de: "Supporter-Schlüssel erkannt: \(supporterTierDisplayName(tier)).",
                ja: "サポーターキーを検出しました: \(supporterTierDisplayName(tier))。"
            )
        }
    }

    private func activeTierLabel(for tier: LicenseTier) -> String {
        let lifetimeSuffix = license.licenseIsLifetime
            ? localizedAppText(", Lifetime", de: ", Dauerlizenz", ja: "、永久ライセンス")
            : ""
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
            openURL(
                AppConstants.Polar.appCheckoutURL(
                    baseURL: url,
                    content: "settings_\(tier.rawValue)_one_time"
                )
            )
        } label: {
            VStack(spacing: 6) {
                Image(systemName: supporterTierIcon(tier))
                    .foregroundStyle(supporterTierColor(tier))
                    .accessibilityHidden(true)
                Text(supporterTierDisplayName(tier))
                    .font(.caption.bold())
                Text("\(price) EUR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        // Only the prominent button style marks the tier you already support with.
        .accessibilityValue(isCurrentTier
            ? localizedAppText("Your current tier", de: "Deine aktuelle Stufe", ja: "現在のランク", zh: "你当前的等级")
            : "")

        if isCurrentTier {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func businessTierDisplayName(_ tier: LicenseTier) -> String {
        switch tier {
        case .individual: return localizedAppText("Individual", de: "Einzelnutzer", ja: "個人")
        case .team: return localizedAppText("Team", de: "Team", ja: "チーム")
        case .enterprise: return localizedAppText("Enterprise", de: "Unternehmensplan", ja: "エンタープライズ")
        }
    }

    private func supporterTierDisplayName(_ tier: SupporterTier) -> String {
        switch tier {
        case .bronze: return localizedAppText("Bronze", de: "Bronze", ja: "ブロンズ")
        case .silver: return localizedAppText("Silver", de: "Silber", ja: "シルバー")
        case .gold: return localizedAppText("Gold", de: "Gold", ja: "ゴールド")
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

enum CommercialPurchaseCadence: String, CaseIterable {
    case monthly
    case yearly
    case lifetime
}

/// The ways a tier can be bought. Enterprise is sold as a subscription only.
func commercialPurchaseCadences(for tier: LicenseTier) -> [CommercialPurchaseCadence] {
    switch tier {
    case .individual, .team:
        [.monthly, .yearly, .lifetime]
    case .enterprise:
        [.monthly, .yearly]
    }
}

struct CommercialPurchaseOptionCopy: Equatable {
    let price: String
    let billingLabel: String
    let detail: String
}

func commercialPurchaseOptionCopy(for tier: LicenseTier, cadence: CommercialPurchaseCadence) -> CommercialPurchaseOptionCopy? {
    let monthly = localizedAppText("per month", de: "pro Monat")
    let yearly = localizedAppText("per year", de: "pro Jahr")
    let oneTime = localizedAppText("one-time", de: "einmalig")
    let twoMonthsFree = localizedAppText("Two months free", de: "Zwei Monate gratis")
    let payOnce = localizedAppText("Pay once, keep this tier", de: "Einmal zahlen, dieses Tier behalten")

    switch (tier, cadence) {
    case (.individual, .monthly):
        return CommercialPurchaseOptionCopy(
            price: "5 EUR",
            billingLabel: monthly,
            detail: localizedAppText("Lower upfront cost", de: "Geringerer Einstiegspreis")
        )
    case (.individual, .yearly):
        return CommercialPurchaseOptionCopy(price: "50 EUR", billingLabel: yearly, detail: twoMonthsFree)
    case (.individual, .lifetime):
        return CommercialPurchaseOptionCopy(price: "99 EUR", billingLabel: oneTime, detail: payOnce)
    case (.team, .monthly):
        return CommercialPurchaseOptionCopy(
            price: "19 EUR",
            billingLabel: monthly,
            detail: localizedAppText("Recurring billing", de: "Wiederkehrende Abrechnung")
        )
    case (.team, .yearly):
        return CommercialPurchaseOptionCopy(price: "190 EUR", billingLabel: yearly, detail: twoMonthsFree)
    case (.team, .lifetime):
        return CommercialPurchaseOptionCopy(price: "299 EUR", billingLabel: oneTime, detail: payOnce)
    case (.enterprise, .monthly):
        return CommercialPurchaseOptionCopy(
            price: "199 EUR",
            billingLabel: monthly,
            detail: localizedAppText("Recurring billing", de: "Wiederkehrende Abrechnung")
        )
    case (.enterprise, .yearly):
        return CommercialPurchaseOptionCopy(
            price: localizedAppText("1,990 EUR", de: "1.990 EUR"),
            billingLabel: yearly,
            detail: twoMonthsFree
        )
    case (.enterprise, .lifetime):
        return nil
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                                .accessibilityHidden(true)

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
            .offset(y: isHovering && !reduceMotion ? -1 : 0)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            .accessibilityHidden(true)
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
        .offset(y: isHovering && !reduceMotion ? -1 : 0)
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
