import StoreKit
import XCTest
@testable import TypeWhisper

final class AppStorePremiumPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func monthly(
        id: UInt64,
        expiresIn interval: TimeInterval,
        revoked: Bool = false,
        purchasedAgo: TimeInterval = 86_400
    ) -> AppStorePremiumTransactionSnapshot {
        AppStorePremiumTransactionSnapshot(
            transactionID: id,
            product: .monthly,
            purchaseDate: now.addingTimeInterval(-purchasedAgo),
            expirationDate: now.addingTimeInterval(interval),
            revocationDate: revoked ? now.addingTimeInterval(-60) : nil
        )
    }

    private func lifetime(id: UInt64, revoked: Bool = false) -> AppStorePremiumTransactionSnapshot {
        AppStorePremiumTransactionSnapshot(
            transactionID: id,
            product: .lifetime,
            purchaseDate: now.addingTimeInterval(-30 * 86_400),
            revocationDate: revoked ? now.addingTimeInterval(-60) : nil
        )
    }

    // MARK: - Products

    func testProductIDsMatchTheSharedIOSProducts() {
        XCTAssertEqual(AppStorePremiumProduct.monthly.productID, "com.typewhisper.premium.individual.monthly")
        XCTAssertEqual(AppStorePremiumProduct.lifetime.productID, "com.typewhisper.premium.individual.lifetime")
        XCTAssertEqual(AppStorePremiumProduct(productID: "com.typewhisper.premium.individual.lifetime"), .lifetime)
        XCTAssertNil(AppStorePremiumProduct(productID: "com.typewhisper.other"))
    }

    // MARK: - Status

    func testRevocationWinsOverExpiration() {
        XCTAssertEqual(
            AppStorePremiumPolicy.status(
                revocationDate: now,
                expirationDate: now.addingTimeInterval(3_600),
                now: now
            ),
            .revoked
        )
    }

    func testPastExpirationAndUpgradedSubscriptionsAreExpired() {
        XCTAssertEqual(
            AppStorePremiumPolicy.status(revocationDate: nil, expirationDate: now, now: now),
            .expired
        )
        XCTAssertEqual(
            AppStorePremiumPolicy.status(
                revocationDate: nil,
                expirationDate: now.addingTimeInterval(3_600),
                isUpgraded: true,
                now: now
            ),
            .expired
        )
        XCTAssertEqual(
            AppStorePremiumPolicy.status(revocationDate: nil, expirationDate: nil, now: now),
            .active
        )
    }

    // MARK: - Lifetime Precedence

    func testActiveLifetimeWinsOverActiveSubscription() {
        let resolved = AppStorePremiumPolicy.resolve(
            [monthly(id: 1, expiresIn: 7 * 86_400), lifetime(id: 2)],
            now: now
        )

        XCTAssertEqual(resolved?.product, .lifetime)
        XCTAssertEqual(resolved?.isActive(at: now), true)
    }

    func testExpiredSubscriptionNeverReplacesActiveLifetime() {
        let resolved = AppStorePremiumPolicy.resolve(
            [lifetime(id: 2), monthly(id: 3, expiresIn: -60, purchasedAgo: 60)],
            now: now
        )

        XCTAssertEqual(resolved?.transactionID, 2)
        XCTAssertEqual(resolved?.isActive(at: now), true)
    }

    func testRefundedSubscriptionNeverReplacesActiveLifetime() {
        let resolved = AppStorePremiumPolicy.resolve(
            [lifetime(id: 2), monthly(id: 3, expiresIn: 7 * 86_400, revoked: true, purchasedAgo: 60)],
            now: now
        )

        XCTAssertEqual(resolved?.transactionID, 2)
        XCTAssertEqual(resolved?.status, .active)
    }

    func testRefundedLifetimeFallsBackToActiveSubscription() {
        let resolved = AppStorePremiumPolicy.resolve(
            [lifetime(id: 2, revoked: true), monthly(id: 1, expiresIn: 7 * 86_400)],
            now: now
        )

        XCTAssertEqual(resolved?.transactionID, 1)
        XCTAssertEqual(resolved?.isActive(at: now), true)
    }

    func testLongestRunningSubscriptionWins() {
        let resolved = AppStorePremiumPolicy.resolve(
            [monthly(id: 1, expiresIn: 86_400), monthly(id: 2, expiresIn: 20 * 86_400)],
            now: now
        )

        XCTAssertEqual(resolved?.transactionID, 2)
    }

    func testOnlyInactiveTransactionsGrantNoAccess() {
        let resolved = AppStorePremiumPolicy.resolve(
            [monthly(id: 1, expiresIn: -86_400, purchasedAgo: 40 * 86_400), monthly(id: 2, expiresIn: -60)],
            now: now
        )

        XCTAssertEqual(resolved?.transactionID, 2)
        XCTAssertEqual(resolved?.status, .expired)
        XCTAssertFalse(
            AppStorePremiumPolicy.hasPremiumAccess(
                storeKitEntitlement: resolved,
                hasAccountEntitlement: false,
                now: now
            )
        )
    }

    func testNoTransactionsResolveToNothing() {
        XCTAssertNil(AppStorePremiumPolicy.resolve([], now: now))
    }

    // MARK: - Access

    func testAccountEntitlementGrantsAccessWithoutPurchase() {
        XCTAssertTrue(
            AppStorePremiumPolicy.hasPremiumAccess(
                storeKitEntitlement: nil,
                hasAccountEntitlement: true,
                now: now
            )
        )
        XCTAssertFalse(
            AppStorePremiumPolicy.hasPremiumAccess(
                storeKitEntitlement: nil,
                hasAccountEntitlement: false,
                now: now
            )
        )
    }

    func testSubscriptionLapsesAtItsExpirationDate() {
        let entitlement = AppStorePremiumPolicy.entitlement(
            from: monthly(id: 1, expiresIn: 3_600),
            now: now
        )

        XCTAssertTrue(entitlement.isActive(at: now))
        XCTAssertFalse(entitlement.isActive(at: now.addingTimeInterval(3_600)))
    }

    // MARK: - Account Sync

    func testOnlyProductionTransactionsAreLinkedToTheAccount() {
        XCTAssertTrue(AppStorePremiumPolicy.shouldSyncToAccount(environment: .production))
        XCTAssertFalse(AppStorePremiumPolicy.shouldSyncToAccount(environment: .sandbox))
        XCTAssertFalse(AppStorePremiumPolicy.shouldSyncToAccount(environment: .xcode))
    }

    // MARK: - Trial

    func testEligibleFreeTrialIsOffered() {
        let offer = AppStorePremiumPolicy.trialOffer(
            periodValue: 2,
            periodUnit: .week,
            periodCount: 1,
            isFreeTrial: true,
            isEligible: true
        )

        XCTAssertEqual(offer, AppStorePremiumTrialOffer(periodValue: 2, periodUnit: .week))
    }

    func testTrialIsHiddenWhenIneligibleOrNotFree() {
        XCTAssertNil(
            AppStorePremiumPolicy.trialOffer(
                periodValue: 2,
                periodUnit: .week,
                periodCount: 1,
                isFreeTrial: true,
                isEligible: false
            )
        )
        XCTAssertNil(
            AppStorePremiumPolicy.trialOffer(
                periodValue: 1,
                periodUnit: .month,
                periodCount: 1,
                isFreeTrial: false,
                isEligible: true
            )
        )
    }
}
