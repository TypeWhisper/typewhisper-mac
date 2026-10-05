#if APPSTORE
import StoreKit
import SwiftUI

/// The App Store part of the Premium settings page. It replaces the license
/// page of the direct-distribution app: products with their localized App
/// Store prices, the free trial when the customer is eligible, renewal terms,
/// Restore Purchases, subscription management and the legal links.
@MainActor
struct AppStorePremiumStoreView: View {
    @ObservedObject private var store: AppStorePremiumService
    @Environment(\.purchase) private var purchaseAction
    @Environment(\.openURL) private var openURL
    @State private var confirmingLifetimeUpgrade = false

    init(store: AppStorePremiumService = ServiceContainer.shared.appStorePremiumService) {
        self.store = store
    }

    var body: some View {
        SettingsCard(accent: store.hasPremiumAccess ? .green : .yellow) {
            VStack(alignment: .leading, spacing: 16) {
                PremiumSettingsDetailHeader(
                    icon: "crown.fill",
                    accent: .yellow,
                    title: "TypeWhisper Premium",
                    description: statusDescription,
                    status: store.hasPremiumAccess
                        ? String(localized: "premium.window.access.accountActive")
                        : String(localized: "premium.hub.access.locked"),
                    statusColor: store.hasPremiumAccess ? .green : .secondary
                )

                if store.shouldShowPurchaseOptions {
                    AppStorePremiumBenefitsList()
                    Divider()
                    purchaseOptions
                } else if store.canUpgradeToLifetime, let lifetime = store.product(for: .lifetime) {
                    Button(lifetimePurchaseTitle(lifetime)) {
                        confirmingLifetimeUpgrade = true
                    }
                    .disabled(store.isWorking)
                    .accessibilityIdentifier("premium.store.lifetimeUpgrade")
                }

                Divider()
                accountActions
                legalLinks
                messages
            }
        }
        .confirmationDialog(
            localizedAppText("Buy Lifetime Access?", de: "Lifetime-Zugang kaufen?"),
            isPresented: $confirmingLifetimeUpgrade,
            titleVisibility: .visible
        ) {
            if let lifetime = store.product(for: .lifetime) {
                Button(lifetimePurchaseTitle(lifetime)) {
                    purchase(.lifetime)
                }
            }
            Button(String(localized: "Manage Subscription")) {
                openURL(AppStorePremiumService.manageSubscriptionsURL)
            }
            Button(String(localized: "premium.common.cancel"), role: .cancel) {}
        } message: {
            Text(localizedAppText(
                "Your App Store subscription is not canceled automatically. After Lifetime is active, cancel the subscription to avoid another renewal.",
                de: "Dein App-Store-Abo wird nicht automatisch gekündigt. Kündige das Abo, sobald Lifetime aktiv ist, um eine weitere Verlängerung zu vermeiden."
            ))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var purchaseOptions: some View {
        let monthly = store.product(for: .monthly)
        let lifetime = store.product(for: .lifetime)

        if !store.hasLoadedProducts {
            ProgressView()
                .controlSize(.small)
        } else if monthly == nil && lifetime == nil {
            Label(
                localizedAppText(
                    "App Store purchases are currently unavailable.",
                    de: "Käufe im App Store sind gerade nicht verfügbar."
                ),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 16) {
                if let monthly {
                    purchaseOption(
                        title: monthly.displayName,
                        buttonTitle: monthlyPurchaseTitle(monthly),
                        terms: monthlyRenewalTerms(monthly),
                        isProminent: true,
                        accessibilityIdentifier: "premium.store.monthly"
                    ) {
                        purchase(.monthly)
                    }
                }

                if let lifetime {
                    purchaseOption(
                        title: lifetime.displayName,
                        buttonTitle: lifetimePurchaseTitle(lifetime),
                        terms: localizedAppText("One-time purchase, no subscription.", de: "Einmaliger Kauf, kein Abo."),
                        isProminent: false,
                        accessibilityIdentifier: "premium.store.lifetime"
                    ) {
                        purchase(.lifetime)
                    }
                }
            }

            Text(localizedAppText(
                "Purchases use your Apple Account. A TypeWhisper account is only needed to sync across devices.",
                de: "Käufe laufen über deinen Apple Account. Ein TypeWhisper-Konto brauchst du nur für die Synchronisierung zwischen Geräten."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func purchaseOption(
        title: String,
        buttonTitle: String,
        terms: String,
        isProminent: Bool,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            if isProminent {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.isWorking)
                    .accessibilityIdentifier(accessibilityIdentifier)
            } else {
                Button(buttonTitle, action: action)
                    .controlSize(.large)
                    .disabled(store.isWorking)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }

            Text(terms)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var accountActions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await store.restorePurchases() }
            } label: {
                Label(
                    localizedAppText("Restore Purchases", de: "Käufe wiederherstellen"),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(store.isWorking)
            .accessibilityIdentifier("premium.store.restore")

            if store.activeProduct == .monthly {
                Link(destination: AppStorePremiumService.manageSubscriptionsURL) {
                    Label(String(localized: "Manage Subscription"), systemImage: "creditcard")
                }
                .accessibilityIdentifier("premium.store.manageSubscription")
            }

            Spacer(minLength: 0)

            if store.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var legalLinks: some View {
        HStack(spacing: 16) {
            Link(destination: AppStorePremiumService.privacyPolicyURL) {
                Label(localizedAppText("Privacy Policy", de: "Datenschutzerklärung"), systemImage: "hand.raised")
            }
            .accessibilityIdentifier("premium.store.privacyPolicy")

            Link(destination: AppStorePremiumService.termsOfUseURL) {
                Label(localizedAppText("Terms of Use (EULA)", de: "Nutzungsbedingungen (EULA)"), systemImage: "doc.text")
            }
            .accessibilityIdentifier("premium.store.termsOfUse")
        }
        .font(.caption)
    }

    @ViewBuilder
    private var messages: some View {
        if let statusMessage = store.statusMessage {
            Label(statusMessage, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let errorMessage = store.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Copy

    private var statusDescription: String {
        switch store.activeProduct {
        case .lifetime:
            return localizedAppText(
                "Your lifetime purchase unlocks all Premium features.",
                de: "Dein Lifetime-Kauf schaltet alle Premium-Funktionen frei."
            )
        case .monthly:
            if let expiresAt = store.storeKitEntitlement?.expiresAt {
                let date = expiresAt.formatted(date: .abbreviated, time: .omitted)
                return localizedAppText(
                    "Your monthly subscription unlocks all Premium features. Current period until \(date).",
                    de: "Dein Monatsabo schaltet alle Premium-Funktionen frei. Aktueller Zeitraum bis \(date)."
                )
            }
            return localizedAppText(
                "Your monthly subscription unlocks all Premium features.",
                de: "Dein Monatsabo schaltet alle Premium-Funktionen frei."
            )
        case nil:
            if store.hasAccountOnlyAccess {
                return localizedAppText(
                    "Premium is active through your TypeWhisper account.",
                    de: "Premium ist über dein TypeWhisper-Konto aktiv."
                )
            }
            return AppStorePremiumCopy.lockedDescription
        }
    }

    private func monthlyPurchaseTitle(_ product: Product) -> String {
        if let trial = store.monthlyTrialOffer {
            return localizedAppText(
                "Try Free for \(trial.durationText)",
                de: "\(trial.durationText) kostenlos testen"
            )
        }
        return localizedAppText(
            "Subscribe for \(product.displayPrice) per Month",
            de: "Für \(product.displayPrice) pro Monat abonnieren"
        )
    }

    private func monthlyRenewalTerms(_ product: Product) -> String {
        let price = product.displayPrice
        let renewal: String
        if let trial = store.monthlyTrialOffer {
            renewal = localizedAppText(
                "\(trial.durationText) free, then \(price) per month. Renews automatically until canceled.",
                de: "\(trial.durationText) kostenlos, danach \(price) pro Monat. Verlängert sich automatisch, bis du kündigst."
            )
        } else {
            renewal = localizedAppText(
                "One month. Renews automatically for \(price) per month until canceled.",
                de: "Ein Monat. Verlängert sich automatisch für \(price) pro Monat, bis du kündigst."
            )
        }
        let cancellation = localizedAppText(
            "Payment is charged to your Apple Account. Cancel at least 24 hours before the end of the current period in your App Store account settings.",
            de: "Die Zahlung erfolgt über deinen Apple Account. Kündige spätestens 24 Stunden vor Ende des aktuellen Zeitraums in den Einstellungen deines App-Store-Kontos."
        )
        return "\(renewal) \(cancellation)"
    }

    private func lifetimePurchaseTitle(_ product: Product) -> String {
        localizedAppText(
            "Buy Lifetime for \(product.displayPrice)",
            de: "Lifetime für \(product.displayPrice) kaufen"
        )
    }

    // MARK: - Actions

    private func purchase(_ product: AppStorePremiumProduct) {
        let purchaseAction = purchaseAction
        Task {
            await store.purchase(product) { try await purchaseAction($0) }
        }
    }
}

/// What Premium unlocks in the Mac App Store edition, shown before purchase.
struct AppStorePremiumBenefitsList: View {
    private struct Benefit: Identifiable {
        let id: String
        let systemImage: String
        let accent: Color
        let title: String
        let detail: String
    }

    private var benefits: [Benefit] {
        [
            Benefit(
                id: "calendarMeeting",
                systemImage: "calendar.badge.clock",
                accent: .blue,
                title: String(localized: "premium.hub.calendar.title"),
                detail: String(localized: "premium.hub.calendar.description")
            ),
            Benefit(
                id: "cloudSync",
                systemImage: "cloud",
                accent: .cyan,
                title: String(localized: "premium.hub.sync.title"),
                detail: String(localized: "premium.hub.sync.description")
            ),
            Benefit(
                id: "automaticFallback",
                systemImage: "arrow.triangle.2.circlepath",
                accent: .green,
                title: localizedAppText("Automatic Fallback", de: "Automatischer Fallback"),
                detail: localizedAppText(
                    "Retries failed dictations with a second engine and can race it when the primary engine is slow.",
                    de: "Wiederholt fehlgeschlagene Diktate mit einer zweiten Engine und kann sie parallel starten, wenn die primäre Engine langsam ist."
                )
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(benefits) { benefit in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: benefit.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(benefit.accent)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(benefit.accent.opacity(0.13))
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(benefit.title)
                            .font(.body.weight(.medium))
                        Text(benefit.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("premium.benefit.\(benefit.id)")
            }
        }
    }
}
/// Premium wording of this edition. Correction learning is not part of it.
enum AppStorePremiumCopy {
    static var lockedDescription: String {
        localizedAppText(
            "Record scheduled meetings automatically, retry failed dictations with a second engine, and keep your dictionary and snippets in sync.",
            de: "Nimm geplante Meetings automatisch auf, wiederhole fehlgeschlagene Diktate mit einer zweiten Engine und halte Wörterbuch und Snippets synchron.",
            ja: "予定されたミーティングを自動で録音し、失敗した音声入力を別のエンジンで再試行し、辞書とスニペットを同期します。",
            zh: "自动录制已安排的会议，用第二个引擎重试失败的听写，并同步你的词典和片段。"
        )
    }
}
#endif
