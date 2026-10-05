#if APPSTORE
import Foundation
import StoreKit

/// The Premium products of the Mac App Store edition. They are shared with the
/// iOS app (universal purchase), so a purchase on one platform unlocks both.
enum AppStorePremiumProduct: String, CaseIterable, Identifiable, Sendable {
    case monthly
    case lifetime

    var id: String { rawValue }

    var productID: String {
        switch self {
        case .monthly:
            "com.typewhisper.premium.individual.monthly"
        case .lifetime:
            "com.typewhisper.premium.individual.lifetime"
        }
    }

    var isLifetime: Bool { self == .lifetime }

    init?(productID: String) {
        guard let product = Self.allCases.first(where: { $0.productID == productID }) else {
            return nil
        }
        self = product
    }
}

/// The parts of a StoreKit transaction that decide Premium access, so the
/// decision can be made and tested without StoreKit.
struct AppStorePremiumTransactionSnapshot: Equatable, Sendable {
    let transactionID: UInt64
    let product: AppStorePremiumProduct
    let purchaseDate: Date
    let expirationDate: Date?
    let revocationDate: Date?
    let isUpgraded: Bool

    init(
        transactionID: UInt64,
        product: AppStorePremiumProduct,
        purchaseDate: Date,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        isUpgraded: Bool = false
    ) {
        self.transactionID = transactionID
        self.product = product
        self.purchaseDate = purchaseDate
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
    }
}

/// Premium access granted by an App Store purchase on this Mac.
struct AppStorePremiumEntitlement: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case active
        case expired
        case revoked
    }

    let transactionID: UInt64
    let product: AppStorePremiumProduct
    let status: Status
    let expiresAt: Date?

    var isLifetime: Bool { product.isLifetime }

    func isActive(at now: Date = Date()) -> Bool {
        guard status == .active else { return false }
        return expiresAt.map { $0 > now } ?? true
    }
}

struct AppStorePremiumTrialOffer: Equatable, Sendable {
    enum PeriodUnit: Equatable, Sendable {
        case day
        case week
        case month
        case year
    }

    let periodValue: Int
    let periodUnit: PeriodUnit

    /// The localized trial length, for example "2 weeks".
    var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .full

        var components = DateComponents()
        switch periodUnit {
        case .day:
            components.day = periodValue
        case .week:
            components.weekOfMonth = periodValue
        case .month:
            components.month = periodValue
        case .year:
            components.year = periodValue
        }
        return formatter.string(from: components) ?? String(periodValue)
    }
}

/// Pure decisions about App Store Premium, kept apart from StoreKit so they can
/// be unit tested.
enum AppStorePremiumPolicy {
    static func status(
        revocationDate: Date?,
        expirationDate: Date?,
        isUpgraded: Bool = false,
        now: Date = Date()
    ) -> AppStorePremiumEntitlement.Status {
        if revocationDate != nil {
            return .revoked
        }
        if isUpgraded || expirationDate.map({ $0 <= now }) == true {
            return .expired
        }
        return .active
    }

    static func entitlement(
        from snapshot: AppStorePremiumTransactionSnapshot,
        now: Date = Date()
    ) -> AppStorePremiumEntitlement {
        AppStorePremiumEntitlement(
            transactionID: snapshot.transactionID,
            product: snapshot.product,
            status: status(
                revocationDate: snapshot.revocationDate,
                expirationDate: snapshot.expirationDate,
                isUpgraded: snapshot.isUpgraded,
                now: now
            ),
            expiresAt: snapshot.expirationDate
        )
    }

    /// Picks the entitlement that grants Premium from all known transactions.
    ///
    /// An active lifetime purchase always wins, so an expired, refunded or
    /// still running monthly subscription never replaces it. Among active
    /// subscriptions the one that runs longest wins. Without any active
    /// transaction the most recent inactive one is returned for display.
    static func resolve(
        _ snapshots: [AppStorePremiumTransactionSnapshot],
        now: Date = Date()
    ) -> AppStorePremiumEntitlement? {
        let entitlements = snapshots.map { entitlement(from: $0, now: now) }
        let active = entitlements.filter { $0.isActive(at: now) }

        if let lifetime = active.first(where: \.isLifetime) {
            return lifetime
        }
        if let subscription = active.max(by: { lhs, rhs in
            (lhs.expiresAt ?? .distantFuture) < (rhs.expiresAt ?? .distantFuture)
        }) {
            return subscription
        }

        let latestInactive = snapshots
            .sorted { $0.purchaseDate < $1.purchaseDate }
            .last
        return latestInactive.map { entitlement(from: $0, now: now) }
    }

    static func hasPremiumAccess(
        storeKitEntitlement: AppStorePremiumEntitlement?,
        hasAccountEntitlement: Bool,
        now: Date = Date()
    ) -> Bool {
        storeKitEntitlement?.isActive(at: now) == true || hasAccountEntitlement
    }

    /// Only production purchases are linked to the TypeWhisper account. Sandbox
    /// and Xcode transactions cannot be verified by the backend.
    static func shouldSyncToAccount(environment: AppStore.Environment) -> Bool {
        environment == .production
    }

    static func trialOffer(
        periodValue: Int,
        periodUnit: AppStorePremiumTrialOffer.PeriodUnit,
        periodCount: Int,
        isFreeTrial: Bool,
        isEligible: Bool
    ) -> AppStorePremiumTrialOffer? {
        guard isFreeTrial, isEligible, periodValue > 0, periodCount > 0 else {
            return nil
        }
        return AppStorePremiumTrialOffer(
            periodValue: periodValue * periodCount,
            periodUnit: periodUnit
        )
    }
}
#endif
