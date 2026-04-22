import Foundation
import Security
import XCTest
@testable import TypeWhisper

final class CLISupportTests: XCTestCase {
    func testOutputFormatterRendersHumanReadableStatusAndModels() {
        let statusJSON = Data(#"{"status":"ready","engine":"parakeet","model":"tiny"}"#.utf8)
        let modelsJSON = Data(#"{"models":[{"id":"tiny","engine":"parakeet","name":"Tiny","status":"ready","selected":true}]}"#.utf8)

        XCTAssertEqual(OutputFormatter.formatStatus(statusJSON, json: false), "Ready - parakeet (tiny)")
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("tiny"))
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("*"))
    }

    func testPortDiscoveryUsesConfiguredPortFileAndFallback() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("TypeWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "9911".write(to: appDirectory.appendingPathComponent("api-port"), atomically: true, encoding: .utf8)

        XCTAssertEqual(PortDiscovery.discoverPort(dev: false, applicationSupportDirectory: applicationSupportRoot), 9911)
        XCTAssertEqual(PortDiscovery.discoverPort(dev: true, applicationSupportDirectory: applicationSupportRoot), PortDiscovery.defaultPort)
    }

    func testCLITranscribeLanguageOptionsRejectMixedExactAndHintFlags() {
        let options = CLITranscribeLanguageOptions(language: "de", languageHints: ["en", "nl"])
        XCTAssertEqual(
            options.validationError(),
            "Error: --language and --language-hint cannot be used together."
        )
    }

    @MainActor
    func testSupporterDiscordCreateClaimSessionPersistsPendingStatus() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = SupporterDiscordService(
            licenseService: LicenseService(),
            defaults: defaults,
            transport: { request in
                XCTAssertEqual(request.url?.path, "/claims/polar/start")
                let body = """
                {
                  "session_id": "session-123",
                  "claim_url": "https://claims.example.test/claims/polar/discord?session_id=session-123"
                }
                """
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            claimProofProvider: {
                SupporterClaimProof(key: "supporter-key", activationId: "activation-123", tier: .gold)
            },
            baseURLProvider: {
                URL(string: "https://claims.example.test")!
            }
        )

        let claimURL = await service.createClaimSession()

        XCTAssertEqual(claimURL?.absoluteString, "https://claims.example.test/claims/polar/discord?session_id=session-123")
        XCTAssertEqual(service.claimStatus.state, .pending)
        XCTAssertEqual(service.claimStatus.sessionId, "session-123")
    }

    @MainActor
    func testSupporterDiscordRefreshMapsLinkedStatus() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("session-123", forKey: UserDefaultsKeys.supporterDiscordSessionId)

        let persisted = SupporterDiscordClaimStatus(
            state: .pending,
            discordUsername: nil,
            linkedRoles: [],
            errorMessage: nil,
            sessionId: "session-123",
            updatedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(persisted), forKey: UserDefaultsKeys.supporterDiscordClaimStatus)

        let service = SupporterDiscordService(
            licenseService: LicenseService(),
            defaults: defaults,
            transport: { request in
                XCTAssertEqual(request.url?.path, "/claims/polar/status")
                XCTAssertTrue(request.url?.query?.contains("activation_id=activation-123") == true)
                let body = """
                {
                  "status": "linked",
                  "discord_username": "marco#1234",
                  "linked_roles": ["Supporter Gold"],
                  "session_id": "session-123"
                }
                """
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            claimProofProvider: {
                SupporterClaimProof(key: "supporter-key", activationId: "activation-123", tier: .gold)
            },
            baseURLProvider: {
                URL(string: "https://claims.example.test")!
            }
        )

        await service.refreshClaimStatus()

        XCTAssertEqual(service.claimStatus.state, .linked)
        XCTAssertEqual(service.claimStatus.discordUsername, "marco#1234")
        XCTAssertEqual(service.claimStatus.linkedRoles, ["Supporter Gold"])
        XCTAssertNil(service.claimStatus.errorMessage)
    }

    @MainActor
    func testSupporterDiscordCallbackRefreshesPolarClaimState() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = SupporterDiscordService(
            licenseService: LicenseService(),
            defaults: defaults,
            transport: { request in
                XCTAssertEqual(request.url?.path, "/claims/polar/status")
                XCTAssertTrue(request.url?.query?.contains("activation_id=activation-123") == true)
                XCTAssertTrue(request.url?.query?.contains("session_id=session-999") == true)
                let body = """
                {
                  "status": "linked",
                  "discord_username": "marco#1234",
                  "linked_roles": ["Supporter Gold"],
                  "session_id": "session-999"
                }
                """
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            claimProofProvider: {
                SupporterClaimProof(key: "supporter-key", activationId: "activation-123", tier: .gold)
            },
            baseURLProvider: {
                URL(string: "https://claims.example.test")!
            }
        )

        let handled = await service.handleCallbackURL(
            URL(string: "typewhisper://community/claim-result?flow=polar&status=linked&session_id=session-999")!
        )

        XCTAssertEqual(handled, true)
        XCTAssertEqual(service.claimStatus.state, .linked)
        XCTAssertEqual(service.claimStatus.sessionId, "session-999")
        XCTAssertEqual(service.claimStatus.discordUsername, "marco#1234")
        XCTAssertEqual(service.claimStatus.linkedRoles, ["Supporter Gold"])
    }

    @MainActor
    func testLicenseServiceMigratesLegacyPrivateUserTypeToPersonalOSS() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("private", forKey: UserDefaultsKeys.userType)

        let service = LicenseService(defaults: defaults)

        XCTAssertEqual(service.usageIntent, .personalOSS)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.usageIntent), UsageIntent.personalOSS.rawValue)
    }

    @MainActor
    func testLicenseServiceMigratesLegacyBusinessUserTypeToWorkSolo() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("business", forKey: UserDefaultsKeys.userType)

        let service = LicenseService(defaults: defaults)

        XCTAssertEqual(service.usageIntent, .workSolo)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.usageIntent), UsageIntent.workSolo.rawValue)
    }

    func testLicenseTierInferenceMapsKnownPolarBenefitIDs() {
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "a4c0b152-0b91-4588-b8f8-779870affba9",
                benefitDescription: "Individual Business License"
            ),
            .individual
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "4eb5fa60-ed43-475d-a9b1-c837e67307e5",
                benefitDescription: "Lifetime Business License"
            ),
            .individual
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "5138b20a-57ba-48aa-a664-2139cd6df0de",
                benefitDescription: "Team Business License"
            ),
            .team
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "afc8fac1-0e8f-4bb7-a1bc-60c8250b9923",
                benefitDescription: "Lifetime Team Business License"
            ),
            .team
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "40b82917-f74e-4cc3-8165-937f1f47b294",
                benefitDescription: "Enterprise Business License"
            ),
            .enterprise
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "1857c2ed-3f80-4a8a-93c7-c1d67e02db2e",
                benefitDescription: "Lifetime Enterprise Business License"
            ),
            .enterprise
        )
    }

    func testLicenseTierInferenceReturnsNilForUnknownBenefit() {
        XCTAssertNil(
            LicenseService.inferLicenseTier(benefitID: "benefit_custom", benefitDescription: "Custom internal grant")
        )
    }

    func testLicenseTierInferenceFallsBackToLegacyDescriptionMatching() {
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "legacy-benefit",
                benefitDescription: "Freelancer single-seat license for 2 devices"
            ),
            .individual
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "legacy-benefit",
                benefitDescription: "Small teams up to 10 devices"
            ),
            .team
        )
        XCTAssertEqual(
            LicenseService.inferLicenseTier(
                benefitID: "legacy-benefit",
                benefitDescription: "Unlimited devices and priority support"
            ),
            .enterprise
        )
    }

    func testSupporterTierInferenceMapsKnownPolarBenefitIDs() {
        XCTAssertEqual(
            LicenseService.inferSupporterTier(
                benefitID: "0c695b7a-2f3a-4797-81c7-1410dbb76cc2",
                benefitDescription: "Supporter Gold License"
            ),
            .gold
        )
        XCTAssertEqual(
            LicenseService.inferSupporterTier(
                benefitID: "9ca12e41-b407-4368-9745-76b72ff2c7c2",
                benefitDescription: "Supporter Silver License"
            ),
            .silver
        )
        XCTAssertEqual(
            LicenseService.inferSupporterTier(
                benefitID: "d3eef5ed-bc8c-469d-809b-79fdfe5fc8e8",
                benefitDescription: "Supporter Bronze License"
            ),
            .bronze
        )
    }

    func testSupporterTierInferenceFallsBackToLegacyDescriptionMatching() {
        XCTAssertEqual(
            LicenseService.inferSupporterTier(
                benefitID: "legacy-supporter",
                benefitDescription: "Gold supporter"
            ),
            .gold
        )
        XCTAssertEqual(
            LicenseService.inferSupporterTier(
                benefitID: "legacy-supporter",
                benefitDescription: "Silver supporter"
            ),
            .silver
        )
        XCTAssertEqual(
            LicenseService.inferSupporterTier(
                benefitID: "legacy-supporter",
                benefitDescription: "Bronze supporter"
            ),
            .bronze
        )
    }

    func testCommercialPurchaseOptionCopyMapsPriceAndBillingLabels() {
        XCTAssertEqual(
            commercialPurchaseOptionCopy(for: .individual, cadence: .monthly),
            CommercialPurchaseOptionCopy(
                price: "5 EUR",
                billingLabel: localizedAppText("per month", de: "pro Monat"),
                detail: localizedAppText("Lower upfront cost", de: "Geringerer Einstiegspreis")
            )
        )

        XCTAssertEqual(
            commercialPurchaseOptionCopy(for: .team, cadence: .lifetime),
            CommercialPurchaseOptionCopy(
                price: "299 EUR",
                billingLabel: localizedAppText("one-time", de: "einmalig"),
                detail: localizedAppText("Pay once, keep this tier", de: "Einmal zahlen, dieses Tier behalten")
            )
        )

        XCTAssertEqual(
            commercialPurchaseOptionCopy(for: .enterprise, cadence: .monthly),
            CommercialPurchaseOptionCopy(
                price: "99 EUR",
                billingLabel: localizedAppText("per month", de: "pro Monat"),
                detail: localizedAppText("Recurring billing", de: "Wiederkehrende Abrechnung")
            )
        )
    }

    @MainActor
    func testActivateAnyKeyRoutesCommercialBenefitIntoCommercialState() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.Universal.\(UUID().uuidString)"
        defer {
            Self.deleteKeychainValue(service: keychainServiceName, account: "polar-license")
            Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter")
        }

        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                switch request.url?.path {
                case "/v1/customer-portal/license-keys/activate":
                    let body = #"{"id":"activation-123"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
                case "/v1/customer-portal/license-keys/validate":
                    let body = #"{"id":"activation-123","status":"granted","expires_at":null,"benefit_id":"40b82917-f74e-4cc3-8165-937f1f47b294"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    let body = #"{"detail":"unexpected"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 500))
                }
            }
        )

        let entitlement = await service.activateAnyKey("TYPEWHISPER-ENT-123")

        XCTAssertEqual(entitlement, .commercial(tier: .enterprise, isLifetime: true))
        XCTAssertEqual(service.licenseStatus, .active)
        XCTAssertEqual(service.licenseTier, .enterprise)
        XCTAssertEqual(service.usageIntent, .enterprise)
        XCTAssertTrue(service.licenseIsLifetime)
        XCTAssertEqual(
            Self.loadKeychainValue(service: keychainServiceName, account: "polar-license"),
            "TYPEWHISPER-ENT-123|activation-123"
        )
        XCTAssertNil(Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter"))
    }

    @MainActor
    func testActivateAnyKeyRoutesSupporterBenefitIntoSupporterState() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.Universal.\(UUID().uuidString)"
        defer {
            Self.deleteKeychainValue(service: keychainServiceName, account: "polar-license")
            Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter")
        }

        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                switch request.url?.path {
                case "/v1/customer-portal/license-keys/activate":
                    let body = #"{"id":"activation-999"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
                case "/v1/customer-portal/license-keys/validate":
                    let body = #"{"id":"activation-999","status":"granted","expires_at":"2027-01-01T00:00:00Z","benefit_id":"0c695b7a-2f3a-4797-81c7-1410dbb76cc2"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
                default:
                    XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                    let body = #"{"detail":"unexpected"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 500))
                }
            }
        )

        let entitlement = await service.activateAnyKey("TYPEWHISPER-SUP-999")

        XCTAssertEqual(entitlement, .supporter(tier: .gold))
        XCTAssertEqual(service.supporterStatus, .active)
        XCTAssertEqual(service.supporterTier, .gold)
        XCTAssertEqual(service.licenseStatus, .unlicensed)
        XCTAssertNil(service.licenseTier)
        XCTAssertEqual(
            Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter"),
            "TYPEWHISPER-SUP-999|activation-999"
        )
        XCTAssertNil(Self.loadKeychainValue(service: keychainServiceName, account: "polar-license"))
    }

    @MainActor
    func testSupporterDeactivationClearsLocalStateWhenPolarActivationIsMissing() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.Supporter.\(UUID().uuidString)"
        defer { Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter") }

        Self.storeKeychainValue(
            "supporter-key|activation-123",
            service: keychainServiceName,
            account: "polar-supporter"
        )

        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                XCTAssertEqual(request.url?.path, "/v1/customer-portal/license-keys/deactivate")
                let body = #"{"error":"ResourceNotFound","detail":"Not found"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 404))
            }
        )

        service.supporterStatus = .active
        service.supporterTier = .bronze
        defaults.set(Date(), forKey: UserDefaultsKeys.lastSupporterValidation)

        await service.deactivateSupporterLicense()

        XCTAssertEqual(service.supporterStatus, .unlicensed)
        XCTAssertNil(service.supporterTier)
        XCTAssertNil(service.supporterDeactivationError)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.lastSupporterValidation))
        XCTAssertNil(Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter"))
    }

    @MainActor
    func testSupporterValidationClearsLocalStateWhenPolarActivationIsMissing() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.Supporter.\(UUID().uuidString)"
        defer { Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter") }

        Self.storeKeychainValue(
            "supporter-key|activation-123",
            service: keychainServiceName,
            account: "polar-supporter"
        )

        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                XCTAssertEqual(request.url?.path, "/v1/customer-portal/license-keys/validate")
                let body = #"{"error":"ResourceNotFound","detail":"Not found"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 404))
            }
        )

        service.supporterStatus = .active
        service.supporterTier = .gold
        defaults.set(Date.distantPast, forKey: UserDefaultsKeys.lastSupporterValidation)

        await service.validateSupporterIfNeeded()

        XCTAssertEqual(service.supporterStatus, .unlicensed)
        XCTAssertNil(service.supporterTier)
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.lastSupporterValidation))
        XCTAssertNil(Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter"))
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "TypeWhisperTests.SupporterDiscord.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Failed to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private static func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private static func storeKeychainValue(_ value: String, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = Data(value.utf8)
        XCTAssertEqual(SecItemAdd(addQuery as CFDictionary, nil), errSecSuccess)
    }

    private static func loadKeychainValue(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychainValue(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
