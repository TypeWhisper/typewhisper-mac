import CryptoKit
import XCTest
@testable import TypeWhisper

@MainActor
final class AppStoreModulePremiumAccessTests: XCTestCase {
    func testAccountPremiumIsNoCommercialLicenseForModules() throws {
        let suiteName = "AppStoreModulePremiumAccess-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let privateKey = P256.Signing.PrivateKey()
        let entitlement = try Self.signedEntitlement(privateKey: privateKey)
        defaults.set(try Self.entitlementEncoder.encode(entitlement), forKey: "premium.account.cachedEntitlement")

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
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )
        let store = AppStorePremiumService(licenseService: licenseService, premiumAccountService: premiumAccountService)
        // The edition mirrors account Premium into the license service.
        licenseService.applyAppStorePremiumAccess(isActive: true, isLifetime: true)
        let reading = AppPremiumAccessReading(
            appStorePremiumService: store,
            licenseService: licenseService,
            premiumAccountService: premiumAccountService
        )

        XCTAssertTrue(licenseService.hasCommercialLicense)
        XCTAssertFalse(store.isStoreKitPremiumActive)
        XCTAssertEqual(reading.current, AppPremiumAccessReading.State(
            hasCommercialLicense: false,
            hasPremiumAccount: true,
            signedAccountEntitlement: entitlement.signature,
            combinedAccess: true
        ))
        XCTAssertTrue(reading.hasPremiumAccess)
    }

    private static func signedEntitlement(privateKey: P256.Signing.PrivateKey) throws -> CrossDevicePremiumEntitlement {
        let unsigned = CrossDevicePremiumEntitlement(
            status: "active",
            tier: "individual",
            source: "storeKit",
            isLifetime: true,
            expiresAt: nil,
            deviceLimit: 3,
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            signature: nil
        )
        let payload = try entitlementEncoder.encode(unsigned.signedClaims)
        let signature = try privateKey.signature(for: payload)
        return CrossDevicePremiumEntitlement(
            status: unsigned.status,
            tier: unsigned.tier,
            source: unsigned.source,
            isLifetime: unsigned.isLifetime,
            expiresAt: unsigned.expiresAt,
            deviceLimit: unsigned.deviceLimit,
            verifiedAt: unsigned.verifiedAt,
            signature: "\(base64URL(payload)).\(base64URL(signature.rawRepresentation))"
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let entitlementEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()
}
