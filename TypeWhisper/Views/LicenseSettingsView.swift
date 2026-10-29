import AppKit
import SwiftUI

struct LicenseSettingsView: View {
    private enum ScrollAnchor: Hashable {
        case top
        case purchase
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

    @State private var purchaseCadence: CommercialPurchaseCadence = .monthly
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var planColumnsPerRow = 4
    /// Counts clicks on a plan, so choosing the current plan again still scrolls.
    @State private var planChoiceCount = 0

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "License"))
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id(ScrollAnchor.top)

                        heroSection

                        if license.isLicenseManaged {
                            managedLicenseSection
                        } else {
                            planTableSection

                            if license.licenseStatus == .active {
                                activeLicenseSection
                            } else if license.requiresCommercialLicense {
                                purchaseSection
                                    .id(ScrollAnchor.purchase)
                            }
                        }

                        supporterSection
                            .id(ScrollAnchor.supporter)

                        if !license.isLicenseManaged {
                            sharedActivationSection
                                .id(ScrollAnchor.activationKey)
                        }
                    }
                    .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                    .frame(maxWidth: 980, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        // Four plans side by side need room for their facts.
                        planColumnsPerRow = width >= 760 ? 4 : 2
                    }
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
                .onChange(of: planChoiceCount) { _, _ in
                    scrollToPurchase(after: license.usageIntent, proxy: proxy)
                }
            }
        }
    }

    // MARK: - Hero

    /// The page opens like the pricing page of the website: a label, one
    /// headline, the lede and the waveform logo. Its content follows the
    /// license state, so a licensed Mac reads its tier first.
    @ViewBuilder
    private var heroSection: some View {
        if license.isLicenseManaged {
            LicenseHeroView(
                eyebrow: localizedAppText("Managed license", de: "Verwaltete Lizenz"),
                headline: localizedAppText("Managed by your organization", de: "Von deiner Organisation verwaltet"),
                lede: localizedAppText(
                    "Your administrator provides the license. TypeWhisper activates it automatically without manual key entry.",
                    de: "Deine Administration stellt die Lizenz bereit. TypeWhisper aktiviert sie automatisch ohne manuelle Schlüsseleingabe."
                ),
                statusSymbol: "building.2",
                statusColor: .secondary
            )
        } else if license.licenseStatus == .active {
            LicenseHeroView(
                eyebrow: localizedAppText("Licensed", de: "Lizenziert"),
                headline: license.licenseTier.map(activeTierTitle) ?? localizedAppText("Licensed", de: "Lizenziert"),
                lede: activeCommercialDescription,
                statusSymbol: "checkmark.seal.fill",
                statusColor: .green,
                trustItems: trustItems
            )
        } else {
            LicenseHeroView(
                eyebrow: localizedAppText("Licensing", de: "Lizenzierung"),
                headline: localizedAppText(
                    "Open source under GPLv3. Premium when you need it.",
                    de: "Open Source unter GPLv3. Premium, wenn du es brauchst."
                ),
                lede: localizedAppText(
                    "Core dictation stays free and open source. A commercial license unlocks Sync Dictionary & Snippets, Learn from Corrections, non-GPL terms, procurement, and support.",
                    de: "Der Diktier-Core bleibt kostenlos und Open Source. Eine kommerzielle Lizenz schaltet „Wörterbuch & Snippets synchronisieren“, „Aus Korrekturen lernen“, Nicht-GPL-Bedingungen, Beschaffung und Support frei."
                ),
                trustItems: trustItems
            )
        }
    }

    private var trustItems: [String] {
        [
            localizedAppText("Local first", de: "Lokal zuerst"),
            localizedAppText("Local engines keep audio on your Mac", de: "Lokale Engines behalten Audio auf deinem Mac"),
            localizedAppText("The core app stays open source", de: "Die Kern-App bleibt Open Source"),
        ]
    }

    private var managedLicenseSection: some View {
        licenseSection(eyebrow: String(localized: "Status")) {
            VStack(alignment: .leading, spacing: 12) {
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

    // MARK: - Plans

    /// The plans side by side like a price list: hairlines instead of boxes,
    /// the chosen plan carries the accent. Choosing a plan records how this
    /// Mac is used, as before.
    private var planTableSection: some View {
        licenseSection(eyebrow: localizedAppText("Plans", de: "Pläne")) {
            LicensePlanTableView(columns: planColumns, perRow: planColumnsPerRow)
        }
    }

    private var planColumns: [LicensePlanColumnModel] {
        // "Your plan" names the tier this Mac is licensed for; the selection
        // only records how it is used and can differ from it.
        let licensedTier = license.licenseStatus == .active ? license.licenseTier : nil
        let perMonth = localizedAppText("per month", de: "pro Monat")
        func monthlyPrice(_ tier: LicenseTier) -> String {
            commercialPurchaseOptionCopy(for: tier, cadence: .monthly)?.price ?? ""
        }
        return [
            LicensePlanColumnModel(
                id: .personalOSS,
                name: localizedAppText("GPLv3 / OSS", de: "GPLv3 / OSS"),
                price: localizedAppText("Free", de: "Kostenlos"),
                priceUnit: localizedAppText("No account needed", de: "Kein Konto nötig"),
                audience: localizedAppText("Personal or internal use", de: "Persönliche oder interne Nutzung"),
                facts: [
                    localizedAppText("Dictation, local engines, workflows, and add-ons", de: "Diktat, lokale Engines, Workflows und Add-ons"),
                    localizedAppText("Community support on Discord", de: "Community-Support auf Discord"),
                    localizedAppText("Full source code on GitHub", de: "Voller Quellcode auf GitHub"),
                ],
                selected: license.usageIntent == .personalOSS,
                isLicensed: false,
                action: { choosePlan(.personalOSS) }
            ),
            LicensePlanColumnModel(
                id: .workSolo,
                name: localizedAppText("Individual", de: "Einzelnutzer"),
                price: monthlyPrice(.individual),
                priceUnit: perMonth,
                audience: localizedAppText("For one person", de: "Für eine Person"),
                facts: [
                    localizedAppText("Up to 3 devices", de: "Bis zu 3 Geräte"),
                    localizedAppText("Sync Dictionary & Snippets, Learn from Corrections", de: "Wörterbuch & Snippets synchronisieren, Aus Korrekturen lernen"),
                    localizedAppText("Non-GPL terms, invoices, and support", de: "Nicht-GPL-Bedingungen, Rechnungen und Support"),
                ],
                selected: license.usageIntent == .workSolo,
                isLicensed: licensedTier == .individual,
                action: { choosePlan(.workSolo) }
            ),
            LicensePlanColumnModel(
                id: .team,
                name: String(localized: "Team"),
                price: monthlyPrice(.team),
                priceUnit: perMonth,
                audience: localizedAppText("For small teams", de: "Für kleine Teams"),
                facts: [
                    localizedAppText("Up to 10 devices", de: "Bis zu 10 Geräte"),
                    localizedAppText("Everything in Individual included", de: "Alles aus Einzelnutzer enthalten"),
                    localizedAppText("One invoice for the whole team", de: "Eine Rechnung für das ganze Team"),
                ],
                selected: license.usageIntent == .team,
                isLicensed: licensedTier == .team,
                action: { choosePlan(.team) }
            ),
            LicensePlanColumnModel(
                id: .enterprise,
                name: localizedAppText("Enterprise", de: "Unternehmensplan"),
                price: monthlyPrice(.enterprise),
                priceUnit: perMonth,
                audience: localizedAppText("For organizations", de: "Für Organisationen"),
                facts: [
                    localizedAppText("Up to 50 devices", de: "Bis zu 50 Geräte"),
                    localizedAppText("Everything in Team included", de: "Alles aus Team enthalten"),
                    localizedAppText("Reply within one business day", de: "Antwort innerhalb eines Arbeitstags"),
                    localizedAppText("Help with rollout and security reviews", de: "Hilfe bei Rollout und Security-Reviews"),
                ],
                selected: license.usageIntent == .enterprise,
                isLicensed: licensedTier == .enterprise,
                action: { choosePlan(.enterprise) }
            ),
        ]
    }

    // MARK: - Purchase

    /// One card for the chosen plan: pick how to pay, see one price, buy.
    @ViewBuilder
    private var purchaseSection: some View {
        if let tier = selectedCommercialTier {
            let cadences = commercialPurchaseCadences(for: tier)
            let cadence = commercialPurchaseCadence(for: tier, preferring: purchaseCadence)

            licenseSection(eyebrow: localizedAppText("Purchase", de: "Kauf")) {
                VStack(alignment: .leading, spacing: 14) {
                    if license.licenseStatus == .expired {
                        Label(commercialStatusTitle, systemImage: commercialStatusSymbol)
                            .foregroundStyle(commercialStatusColor)
                            .font(.callout.weight(.semibold))
                    }

                    SettingsCard {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(businessTierDisplayName(tier))
                                        .font(.title3.weight(.semibold))
                                        .accessibilityAddTraits(.isHeader)

                                    Spacer(minLength: 16)

                                    Picker(
                                        localizedAppText("Billing", de: "Abrechnung"),
                                        selection: Binding(
                                            get: { cadence },
                                            set: { purchaseCadence = $0 }
                                        )
                                    ) {
                                        ForEach(cadences, id: \.self) { option in
                                            Text(cadenceTitle(option)).tag(option)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .fixedSize()
                                }

                                // The picker shows Yearly where the other plans show Lifetime.
                                if tier == .enterprise {
                                    Text(localizedAppText(
                                        "Enterprise: yearly subscription instead of Lifetime",
                                        de: "Unternehmensplan: Jahresabo statt Dauerlizenz"
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                    .multilineTextAlignment(.trailing)
                                }
                            }

                            if let pricing = commercialPurchaseOptionCopy(for: tier, cadence: cadence) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(pricing.price)
                                            .font(.system(size: 34, weight: .semibold))
                                            .kerning(-0.5)
                                            .monospacedDigit()
                                        Text(pricing.billingLabel)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                        // The monthly detail only restates the price.
                                        if cadence != .monthly {
                                            Text(pricing.detail)
                                                .font(.callout.weight(.medium))
                                                .foregroundStyle(cadence == .yearly ? Color.accentColor : Color.secondary)
                                        }
                                    }
                                    .accessibilityElement(children: .combine)

                                    if let description = purchaseDescription(for: tier, cadence: cadence) {
                                        Text(description)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                HStack(alignment: .firstTextBaseline, spacing: 14) {
                                    Button {
                                        openURL(commercialCheckoutURL(for: tier, cadence: cadence))
                                    } label: {
                                        Label(localizedAppText("Get this license", de: "Lizenz holen"), systemImage: "arrow.up.right")
                                            .labelStyle(.titleAndIcon)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .modifier(PointingHandCursorModifier())

                                    Text(localizedAppText(
                                        "Pay what you want from the listed price. Checkout opens at polar.sh in your browser.",
                                        de: "Zahl, was du willst, ab dem angegebenen Preis. Der Kauf öffnet sich bei polar.sh im Browser."
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            if tier == .enterprise {
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
                        }
                    }

                    pricingWebsiteLink
                }
            }
        }
    }

    private func cadenceTitle(_ cadence: CommercialPurchaseCadence) -> String {
        switch cadence {
        case .monthly: localizedAppText("Monthly", de: "Monatlich")
        case .yearly: localizedAppText("Yearly", de: "Jährlich")
        case .lifetime: localizedAppText("Lifetime", de: "Dauerlizenz")
        }
    }

    private var activeLicenseSection: some View {
        licenseSection(eyebrow: localizedAppText("Your license", de: "Deine Lizenz")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    actionButton(title: localizedAppText("Manage Subscription", de: "Abo verwalten"), systemImage: "arrow.up.right.square") {
                        openURL(URL(string: AppConstants.Polar.customerPortalURL))
                    }

                    actionButton(title: localizedAppText("Deactivate License on This Mac", de: "Lizenz auf diesem Mac deaktivieren"), systemImage: "trash", role: .destructive) {
                        Task { await license.deactivateLicense() }
                    }
                }
                .fixedSize()

                Text(localizedAppText(
                    "Opens the Polar.sh customer portal where you can manage your subscription, update payment methods, or cancel. Deactivating removes the license from this device; you can reactivate it on another Mac.",
                    de: "Öffnet das Polar.sh-Kundenportal, in dem du dein Abo verwalten, Zahlungsmethoden aktualisieren oder kündigen kannst. Das Deaktivieren entfernt die Lizenz von diesem Gerät; du kannst sie auf einem anderen Mac erneut aktivieren."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let error = license.deactivationError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .accessibilityLabel(String(localized: "Error: \(error)"))
                }

                pricingWebsiteLink
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
        licenseSection(eyebrow: localizedAppText("Supporter", de: "Supporter")) {
            VStack(alignment: .leading, spacing: 12) {
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
                    .fixedSize()

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
                            "If you already bought a supporter key, enter it below. GitHub Sponsors can still be claimed on the web.",
                            de: "Wenn du bereits einen Supporter-Schlüssel gekauft hast, gib ihn unten ein. GitHub Sponsors kannst du weiter im Web bestätigen."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Active supporters can still move to another tier.
                HStack(spacing: 12) {
                    supporterTierButton(tier: .bronze, price: "10")
                    supporterTierButton(tier: .silver, price: "25")
                    supporterTierButton(tier: .gold, price: "50")
                }
                .frame(maxWidth: 420)

                if !license.isSupporter {
                    Button {
                        openURL(supporterDiscord.githubSponsorsURL)
                    } label: {
                        Label(
                            localizedAppText("Claim GitHub Sponsors status on the web", de: "GitHub-Sponsors-Status im Web bestätigen"),
                            systemImage: "link"
                        )
                    }
                    .buttonStyle(.link)
                    .modifier(PointingHandCursorModifier())
                }
            }
        }
    }

    // MARK: - License key

    private var sharedActivationSection: some View {
        licenseSection(eyebrow: localizedAppText("License key", de: "Lizenzschlüssel")) {
            VStack(alignment: .leading, spacing: 12) {
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
                .frame(maxWidth: 520)

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

    /// A section of the page: a hairline, a small label and the content.
    private func licenseSection<Content: View>(
        eyebrow: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LicenseHairline()
                .padding(.bottom, 8)
            LicenseEyebrow(eyebrow)
            content()
        }
        .padding(.bottom, 28)
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
                    zh: "许可证密钥",
                    zhHant: "授權金鑰"
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
        localizedAppText("Activating license", de: "Lizenz wird aktiviert", ja: "ライセンスを有効化中", zh: "正在激活许可证", zhHant: "正在啟用授權")
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
                    ja: "Discordを連携して、コミュニティサーバーで\(supporterTierDisplayName(tier))サポーターステータスを受け取ります。",
                    zhHant: "連結 Discord，即可在社群伺服器中領取你的 \(supporterTierDisplayName(tier)) 支援者身份。",
                    es: "Conecta Discord para reclamar tu estado de Supporter \(supporterTierDisplayName(tier)) en el servidor de la comunidad."
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
                    Text(localizedAppText("Linked account: \(username)", de: "Verknüpftes Konto: \(username)", ja: "連携済みアカウント: \(username)", zhHant: "已連結帳號：\(username)", es: "Cuenta vinculada: \(username)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !supporterDiscord.claimStatus.linkedRoles.isEmpty {
                    Text(localizedAppText(
                        "Active roles: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))",
                        de: "Aktive Rollen: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))",
                        ja: "有効なロール: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))",
                        zhHant: "已啟用的身份組：\(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))",
                        es: "Roles activos: \(supporterDiscord.claimStatus.linkedRoles.joined(separator: ", "))"
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
                        zh: "正在检查 Discord 状态",
                        zhHant: "正在檢查 Discord 狀態"
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
        case (.individual, .yearly), (.team, .yearly), (.enterprise, .lifetime):
            return nil
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
        case (.enterprise, .yearly): AppConstants.Polar.checkoutURLEnterpriseYearly
        case (.individual, .lifetime): AppConstants.Polar.checkoutURLIndividualLifetime
        case (.team, .lifetime): AppConstants.Polar.checkoutURLTeamLifetime
        case (.individual, .yearly), (.team, .yearly), (.enterprise, .lifetime): nil
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
                ja: "商用キーを検出しました: \(businessTierDisplayName(tier))\(lifetimeSuffix)。",
                zhHant: "偵測到商業金鑰：\(businessTierDisplayName(tier))\(lifetimeSuffix)。",
                es: "Clave comercial detectada: \(businessTierDisplayName(tier))\(lifetimeSuffix)."
            )
        case .supporter(let tier):
            return localizedAppText(
                "Detected supporter key: \(supporterTierDisplayName(tier)).",
                de: "Supporter-Schlüssel erkannt: \(supporterTierDisplayName(tier)).",
                ja: "サポーターキーを検出しました: \(supporterTierDisplayName(tier))。",
                zhHant: "偵測到支援者金鑰：\(supporterTierDisplayName(tier))。",
                es: "Clave de Supporter detectada: \(supporterTierDisplayName(tier))."
            )
        }
    }

    /// "Individual, Lifetime": the tier of the active license as a headline.
    private func activeTierTitle(_ tier: LicenseTier) -> String {
        let lifetimeSuffix = license.licenseIsLifetime
            ? localizedAppText(", Lifetime", de: ", Dauerlizenz", ja: "、永久ライセンス")
            : ""
        return "\(businessTierDisplayName(tier))\(lifetimeSuffix)"
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

    /// Choosing a paid plan brings its purchase card into view, which sits
    /// below the plans and is often outside the window.
    private func choosePlan(_ intent: UsageIntent) {
        license.setUsageIntent(intent)
        planChoiceCount += 1
    }

    private func scrollToPurchase(after intent: UsageIntent, proxy: ScrollViewProxy) {
        guard intent != .personalOSS,
              !license.isLicenseManaged,
              license.licenseStatus != .active,
              license.requiresCommercialLicense else { return }

        // The purchase card appears with this change; scroll once it is laid out.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                proxy.scrollTo(ScrollAnchor.purchase, anchor: .top)
            }
        }
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
            ? localizedAppText("Your current tier", de: "Deine aktuelle Stufe", ja: "現在のランク", zh: "你当前的等级", zhHant: "你目前的等級")
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

/// The ways a tier can be bought. Individual and Team are sold monthly or as
/// Lifetime; Enterprise is a subscription only and the one tier sold yearly.
func commercialPurchaseCadences(for tier: LicenseTier) -> [CommercialPurchaseCadence] {
    switch tier {
    case .individual, .team:
        [.monthly, .lifetime]
    case .enterprise:
        [.monthly, .yearly]
    }
}

/// The billing choice to show for a tier. Enterprise offers its yearly
/// subscription in place of Lifetime, so switching plans keeps the second
/// option selected instead of falling back to monthly.
func commercialPurchaseCadence(for tier: LicenseTier, preferring preferred: CommercialPurchaseCadence) -> CommercialPurchaseCadence {
    switch (tier, preferred) {
    case (.enterprise, .lifetime):
        .yearly
    case (.individual, .yearly), (.team, .yearly):
        .lifetime
    default:
        preferred
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
    case (.individual, .lifetime):
        return CommercialPurchaseOptionCopy(price: "99 EUR", billingLabel: oneTime, detail: payOnce)
    case (.team, .monthly):
        return CommercialPurchaseOptionCopy(
            price: "19 EUR",
            billingLabel: monthly,
            detail: localizedAppText("Recurring billing", de: "Wiederkehrende Abrechnung")
        )
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
    case (.individual, .yearly), (.team, .yearly), (.enterprise, .lifetime):
        return nil
    }
}

// MARK: - Page building blocks

/// Small blue label above a section, set like the mono labels of the website.
private struct LicenseEyebrow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .kerning(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Color.accentColor)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct LicenseHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: 1)
    }
}

/// The three-bar mark of the website as a bullet.
private struct LicenseBarMark: View {
    private let heights: [CGFloat] = [0.45, 1.0, 0.65]

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 10 * heights[index])
            }
        }
        .frame(width: 12, height: 10)
        .accessibilityHidden(true)
    }
}

/// Label, headline, lede and the waveform logo; optionally a status symbol
/// beside the label and a row of trust points below.
private struct LicenseHeroView: View {
    let eyebrow: String
    let headline: String
    let lede: String
    var statusSymbol: String? = nil
    var statusColor: Color = .green
    var trustItems: [String] = []

    @State private var isLogoHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        if let statusSymbol {
                            Image(systemName: statusSymbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor)
                                .accessibilityHidden(true)
                        }
                        LicenseEyebrow(eyebrow)
                    }

                    Text(headline)
                        .font(.system(size: 30, weight: .semibold))
                        .kerning(-0.6)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        // Narrow enough that the headline breaks after its first sentence.
                        .frame(maxWidth: 460, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)

                    Text(lede)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560, alignment: .leading)
                }

                Spacer(minLength: 0)

                // Decorative; the bars pulse on hover like the logo on the About page.
                WaveformLogoView(isActive: isLogoHovering && !reduceMotion)
                    .frame(width: 64, height: 64)
                    .padding(.top, 6)
                    .onHover { isLogoHovering = $0 }
                    .accessibilityHidden(true)
            }

            if !trustItems.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    ForEach(trustItems, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            LicenseBarMark()
                            Text(item)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 28)
    }
}

/// One plan of the price list. Choosing it records the usage intent.
private struct LicensePlanColumnModel: Identifiable {
    let id: UsageIntent
    let name: String
    let price: String
    let priceUnit: String
    let audience: String
    let facts: [String]
    let selected: Bool
    /// The active license covers this plan.
    let isLicensed: Bool
    let action: () -> Void
}

/// Plans side by side, separated by hairlines; two rows on narrow pages.
private struct LicensePlanTableView: View {
    let columns: [LicensePlanColumnModel]
    let perRow: Int

    private var rows: [[LicensePlanColumnModel]] {
        let count = max(1, perRow)
        return stride(from: 0, to: columns.count, by: count).map { start in
            Array(columns[start..<min(start + count, columns.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                if rowIndex > 0 {
                    LicenseHairline()
                }
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element.id) { index, column in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.1))
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                        LicensePlanColumnView(model: column)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                // The hairline closes the row at the top; the accent rule of
                // the chosen plan draws over it.
                .background(alignment: .top) { LicenseHairline() }
            }
        }
    }
}

private struct LicensePlanColumnView: View {
    let model: LicensePlanColumnModel

    @State private var isHovering = false

    private var statusTitle: String {
        if model.isLicensed {
            return localizedAppText("Your plan", de: "Dein Plan")
        }
        if model.selected {
            return localizedAppText("Selected", de: "Ausgewählt")
        }
        return localizedAppText("Choose", de: "Auswählen")
    }

    var body: some View {
        Button(action: model.action) {
            VStack(alignment: .leading, spacing: 0) {
                // The accent rule names the chosen plan without a box.
                Rectangle()
                    .fill(model.selected ? Color.accentColor : Color.clear)
                    .frame(height: 2)

                VStack(alignment: .leading, spacing: 14) {
                    Text(model.name)
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.price)
                            .font(.system(size: 26, weight: .semibold))
                            .kerning(-0.4)
                            .monospacedDigit()
                        Text(model.priceUnit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(model.audience)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.facts, id: \.self) { fact in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                LicenseBarMark()
                                Text(fact)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 5) {
                        if model.selected || model.isLicensed {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .accessibilityHidden(true)
                        }
                        Text(statusTitle)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.selected || model.isLicensed ? Color.primary : Color.accentColor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                model.selected
                    ? Color.accentColor.opacity(0.06)
                    : Color.primary.opacity(isHovering ? 0.03 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PointingHandCursorModifier())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        // The rule and the check mark show the chosen plan only visually.
        .accessibilityAddTraits(model.selected ? .isSelected : [])
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
