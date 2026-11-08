import StoreKit
import XCTest
@testable import TypeWhisper

@MainActor
final class AppStorePremiumOfferCodeTests: XCTestCase {
    func testClosingTheOfferCodeSheetIsNoErrorButAFailureIs() async throws {
        let store = try makeStore()

        await store.offerCodeSheetClosed(.success(()))
        await store.offerCodeSheetClosed(.failure(StoreKitError.userCancelled))
        await store.finishOfferCodeRedemption(.failure(StoreKitError.userCancelled))
        XCTAssertNil(store.errorMessage)

        await store.finishOfferCodeRedemption(.failure(StoreKitError.notAvailableInStorefront))
        XCTAssertNotNil(store.errorMessage)

        store.beginOfferCodeRedemption()
        XCTAssertNil(store.errorMessage)
    }

    func testUnverifiedRedemptionThatLeavesPremiumLockedShowsAnError() async throws {
        let store = try makeStore()

        await store.applyUnverifiedRedemption()

        XCTAssertFalse(store.hasPremiumAccess)
        XCTAssertNotNil(store.errorMessage)
    }

    private func makeStore() throws -> AppStorePremiumService {
        let suiteName = "AppStorePremiumOfferCode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let licenseService = LicenseService(
            defaults: defaults,
            keychainServiceName: suiteName,
            keychainUpdate: { _, _ in errSecItemNotFound },
            keychainAdd: { _ in errSecSuccess },
            keychainCopyMatching: { _, _ in errSecItemNotFound },
            keychainDelete: { _ in errSecSuccess }
        )
        let premiumAccountService = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        return AppStorePremiumService(licenseService: licenseService, premiumAccountService: premiumAccountService)
    }
}
