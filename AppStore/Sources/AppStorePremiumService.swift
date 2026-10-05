#if APPSTORE
import Combine
import Foundation
import StoreKit
import os

private enum AppStorePremiumError: LocalizedError {
    case productUnavailable
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            localizedAppText(
                "Premium is not available from the App Store right now.",
                de: "Premium ist im App Store gerade nicht verfügbar."
            )
        case .unverifiedTransaction:
            localizedAppText(
                "The App Store transaction could not be verified.",
                de: "Die App-Store-Transaktion konnte nicht verifiziert werden."
            )
        }
    }
}

/// StoreKit 2 Premium for the Mac App Store edition.
///
/// This service is the single source of truth for Premium access in the App
/// Store edition: access comes from an active App Store purchase or from a
/// verified entitlement of the signed-in TypeWhisper account (for example a
/// purchase on iPhone). Access is mirrored into `LicenseService`, so every
/// existing commercial gate and its publishers follow it.
///
/// Buying and restoring only need the App Store account. Signing in to a
/// TypeWhisper account stays optional and is used for cross-device sync; while
/// signed in, production purchases are linked to the account.
@MainActor
final class AppStorePremiumService: ObservableObject {
    nonisolated(unsafe) static var shared: AppStorePremiumService?

    static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
    static let privacyPolicyURL = URL(string: "https://www.typewhisper.com/en/privacy/")!
    static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    @Published private(set) var storeKitEntitlement: AppStorePremiumEntitlement?
    @Published private(set) var hasPremiumAccess: Bool
    @Published private(set) var products: [AppStorePremiumProduct: Product] = [:]
    @Published private(set) var monthlyTrialOffer: AppStorePremiumTrialOffer?
    @Published private(set) var hasLoadedProducts = false
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let licenseService: LicenseService
    private let premiumAccountService: PremiumAccountService
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "AppStorePremiumService")
    private var accountHasPremium: Bool
    private var hasLoadedEntitlements = false
    private var premiumTransaction: Transaction?
    private var syncedTransactionIDs: Set<UInt64> = []
    private var transactionUpdatesTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(licenseService: LicenseService, premiumAccountService: PremiumAccountService) {
        self.licenseService = licenseService
        self.premiumAccountService = premiumAccountService
        accountHasPremium = premiumAccountService.hasPremiumEntitlement
        // Until StoreKit answers, keep the last known access, so a launch does
        // not briefly lock Premium features and drop their settings.
        hasPremiumAccess = licenseService.hasCommercialLicense
    }

    deinit {
        transactionUpdatesTask?.cancel()
        expirationTask?.cancel()
    }

    // MARK: - State

    var isStoreKitPremiumActive: Bool {
        storeKitEntitlement?.isActive() == true
    }

    /// The App Store product that currently grants Premium on this Mac.
    var activeProduct: AppStorePremiumProduct? {
        isStoreKitPremiumActive ? storeKitEntitlement?.product : nil
    }

    /// Premium comes only from the TypeWhisper account, not from an App Store
    /// purchase on this Mac.
    var hasAccountOnlyAccess: Bool {
        !isStoreKitPremiumActive && accountHasPremium
    }

    var shouldShowPurchaseOptions: Bool {
        !hasPremiumAccess
    }

    var canUpgradeToLifetime: Bool {
        activeProduct == .monthly && products[.lifetime] != nil
    }

    func product(for product: AppStorePremiumProduct) -> Product? {
        products[product]
    }

    // MARK: - Lifecycle

    /// Starts listening for transactions and loads products and entitlements.
    /// Call once at launch, so purchases completed outside the app are applied.
    func start() {
        guard transactionUpdatesTask == nil else { return }

        transactionUpdatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.handle(update)
            }
        }

        premiumAccountService.$entitlement
            .map { $0?.isActive == true }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasPremium in
                guard let self else { return }
                self.accountHasPremium = hasPremium
                self.updateAccess()
                self.scheduleExpirationCheck()
            }
            .store(in: &cancellables)

        premiumAccountService.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.linkPurchaseToAccountIfNeeded() }
            }
            .store(in: &cancellables)

        Task {
            for await result in Transaction.unfinished {
                await handle(result)
            }
            async let productLoad: Void = loadProducts()
            await refreshEntitlements()
            await productLoad
            await linkPurchaseToAccountIfNeeded()
        }
    }

    // MARK: - Purchases

    func purchase(
        _ product: AppStorePremiumProduct,
        using purchaseAction: @MainActor (Product) async throws -> Product.PurchaseResult
    ) async {
        guard let storeProduct = products[product] else {
            errorMessage = AppStorePremiumError.productUnavailable.errorDescription
            return
        }

        await perform {
            let result = try await purchaseAction(storeProduct)
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    throw AppStorePremiumError.unverifiedTransaction
                }
                await refreshEntitlements(including: transaction)
                await transaction.finish()
                await linkToAccount(transaction, force: true)
            case .pending:
                statusMessage = localizedAppText(
                    "The purchase is waiting for approval. Premium unlocks as soon as it is approved.",
                    de: "Der Kauf wartet auf eine Bestätigung. Premium wird freigeschaltet, sobald er bestätigt ist."
                )
            case .userCancelled:
                break
            @unknown default:
                break
            }
        }
    }

    func restorePurchases() async {
        await perform {
            try await AppStore.sync()
            await refreshEntitlements()
            if let premiumTransaction {
                await linkToAccount(premiumTransaction, force: true)
            }
            statusMessage = isStoreKitPremiumActive
                ? localizedAppText("Your purchase was restored.", de: "Dein Kauf wurde wiederhergestellt.")
                : localizedAppText(
                    "No Premium purchase was found for this Apple Account.",
                    de: "Für diesen Apple Account wurde kein Premium-Kauf gefunden."
                )
        }
    }

    // MARK: - StoreKit

    private func loadProducts() async {
        do {
            let loadedProducts = try await Product.products(for: AppStorePremiumProduct.allCases.map(\.productID))
            products = Dictionary(
                loadedProducts.compactMap { product in
                    AppStorePremiumProduct(productID: product.id).map { ($0, product) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            monthlyTrialOffer = await Self.trialOffer(for: products[.monthly])
        } catch {
            monthlyTrialOffer = nil
            logger.error("Loading App Store products failed: \(error.localizedDescription, privacy: .public)")
        }
        hasLoadedProducts = true
    }

    private static func trialOffer(for product: Product?) async -> AppStorePremiumTrialOffer? {
        guard let subscription = product?.subscription,
              let offer = subscription.introductoryOffer else {
            return nil
        }
        let periodUnit: AppStorePremiumTrialOffer.PeriodUnit
        switch offer.period.unit {
        case .day: periodUnit = .day
        case .week: periodUnit = .week
        case .month: periodUnit = .month
        case .year: periodUnit = .year
        @unknown default: return nil
        }
        return AppStorePremiumPolicy.trialOffer(
            periodValue: offer.period.value,
            periodUnit: periodUnit,
            periodCount: offer.periodCount,
            isFreeTrial: offer.paymentMode == .freeTrial,
            isEligible: await subscription.isEligibleForIntroOffer
        )
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            logger.warning("Ignored an unverified App Store transaction")
            return
        }
        await refreshEntitlements(including: transaction)
        await transaction.finish()
        if AppStorePremiumProduct(productID: transaction.productID) != nil {
            await linkToAccount(transaction, force: true)
        }
    }

    /// Recomputes Premium from all current App Store entitlements. A transaction
    /// that just arrived is included, because `currentEntitlements` may not
    /// list it yet; revoked or expired updates then never outrank an active
    /// purchase.
    private func refreshEntitlements(including incoming: Transaction? = nil) async {
        var transactions: [Transaction] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  AppStorePremiumProduct(productID: transaction.productID) != nil else {
                continue
            }
            transactions.append(transaction)
        }
        if let incoming,
           AppStorePremiumProduct(productID: incoming.productID) != nil,
           !transactions.contains(where: { $0.id == incoming.id }) {
            transactions.append(incoming)
        }

        let resolved = AppStorePremiumPolicy.resolve(transactions.compactMap(Self.snapshot(from:)))
        storeKitEntitlement = resolved
        premiumTransaction = resolved.flatMap { entitlement in
            transactions.first { $0.id == entitlement.transactionID }
        }
        hasLoadedEntitlements = true
        updateAccess()
        scheduleExpirationCheck()
    }

    private static func snapshot(from transaction: Transaction) -> AppStorePremiumTransactionSnapshot? {
        guard let product = AppStorePremiumProduct(productID: transaction.productID) else { return nil }
        return AppStorePremiumTransactionSnapshot(
            transactionID: transaction.id,
            product: product,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded
        )
    }

    private func updateAccess() {
        // Before StoreKit has answered, the cached access stays in place.
        guard hasLoadedEntitlements else { return }

        let access = AppStorePremiumPolicy.hasPremiumAccess(
            storeKitEntitlement: storeKitEntitlement,
            hasAccountEntitlement: accountHasPremium
        )
        if hasPremiumAccess != access {
            hasPremiumAccess = access
        }
        let isLifetime = isStoreKitPremiumActive
            ? storeKitEntitlement?.isLifetime == true
            : premiumAccountService.entitlement?.isLifetime == true
        licenseService.applyAppStorePremiumAccess(isActive: access, isLifetime: isLifetime)
    }

    /// Subscriptions can lapse while the app runs without a transaction update,
    /// so access is checked again when the current period ends.
    private func scheduleExpirationCheck() {
        expirationTask?.cancel()
        let now = Date()
        let upcoming = [storeKitEntitlement?.expiresAt, premiumAccountService.entitlement?.expiresAt]
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
        guard let upcoming else {
            expirationTask = nil
            return
        }
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(upcoming.timeIntervalSinceNow + 1))
            guard !Task.isCancelled else { return }
            await self?.refreshEntitlements()
        }
    }

    // MARK: - Account

    /// Links the purchase that grants Premium to the signed-in account unless
    /// the account already carries equivalent access.
    private func linkPurchaseToAccountIfNeeded() async {
        guard let premiumTransaction, isStoreKitPremiumActive else { return }
        if accountHasPremium,
           premiumAccountService.entitlement?.isLifetime == true || storeKitEntitlement?.isLifetime == false {
            return
        }
        await linkToAccount(premiumTransaction, force: false)
    }

    private func linkToAccount(_ transaction: Transaction, force: Bool) async {
        guard premiumAccountService.isSignedIn,
              AppStorePremiumPolicy.shouldSyncToAccount(environment: transaction.environment) else {
            return
        }
        guard force || !syncedTransactionIDs.contains(transaction.id) else { return }

        do {
            try await premiumAccountService.syncStoreKitTransaction(transaction.id)
            syncedTransactionIDs.insert(transaction.id)
            logger.info("Linked App Store transaction to the TypeWhisper account")
        } catch {
            // The purchase stays valid on this Mac; only cross-device access is missing.
            logger.error("Linking the App Store transaction failed: \(error.localizedDescription, privacy: .public)")
            premiumAccountService.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        statusMessage = nil
        defer { isWorking = false }

        do {
            try await operation()
        } catch StoreKitError.userCancelled {
            // Cancelling the purchase or the App Store sign-in is not an error.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - License Gates

extension LicenseService {
    /// Mirrors App Store Premium into the commercial license state. The App
    /// Store edition has no Polar licenses, so every commercial gate and its
    /// publishers (`hasCommercialLicense`, `$licenseStatus`) follow Premium.
    func applyAppStorePremiumAccess(isActive: Bool, isLifetime: Bool) {
        let status: LicenseStatus = isActive ? .active : .unlicensed
        if licenseStatus != status {
            licenseStatus = status
        }
        let tier: LicenseTier? = isActive ? .individual : nil
        if licenseTier != tier {
            licenseTier = tier
        }
        let lifetime = isActive && isLifetime
        if licenseIsLifetime != lifetime {
            licenseIsLifetime = lifetime
        }
    }
}
#endif
