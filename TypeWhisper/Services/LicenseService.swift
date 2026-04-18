import Combine
import Foundation
import Security
import os

enum UsageIntent: String, CaseIterable, Sendable {
    case personalOSS
    case workSolo
    case team
    case enterprise
}

enum LicenseUserType: String, Sendable {
    case privateUser = "private"
    case business = "business"
}

enum LicenseStatus: String, Sendable {
    case unlicensed
    case active = "polar_active"
    case expired = "polar_expired"
}

enum LicenseTier: String, Sendable {
    case individual
    case team
    case enterprise
}

enum SupporterTier: String, CaseIterable, Sendable {
    case bronze
    case silver
    case gold
}

enum ActivatedEntitlement: Equatable, Sendable {
    case commercial(tier: LicenseTier, isLifetime: Bool)
    case supporter(tier: SupporterTier)
}

struct PolarActivationResponse: Codable {
    let id: String
}

struct PolarValidationResponse: Codable {
    let id: String
    let status: String
    let expiresAt: String?
    let benefitId: String?
    let benefit: PolarBenefit?

    enum CodingKeys: String, CodingKey {
        case id, status
        case expiresAt = "expires_at"
        case benefitId = "benefit_id"
        case benefit
    }

    struct PolarBenefit: Codable {
        let id: String
        let description: String?
    }

    var resolvedBenefitID: String? {
        benefit?.id ?? benefitId
    }

    var resolvedBenefitDescription: String? {
        benefit?.description
    }
}

struct PolarErrorResponse: Codable {
    let detail: String?
    let type: String?
}

typealias LicenseDataTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

private struct KnownPolarBenefit<Value: Sendable>: Sendable {
    let id: String
    let name: String
    let value: Value
}

private let knownPolarCommercialBenefits: [KnownPolarBenefit<LicenseTier>] = [
    KnownPolarBenefit(
        id: "a4c0b152-0b91-4588-b8f8-779870affba9",
        name: "Individual Business License",
        value: .individual
    ),
    KnownPolarBenefit(
        id: "4eb5fa60-ed43-475d-a9b1-c837e67307e5",
        name: "Lifetime Business License",
        value: .individual
    ),
    KnownPolarBenefit(
        id: "5138b20a-57ba-48aa-a664-2139cd6df0de",
        name: "Team Business License",
        value: .team
    ),
    KnownPolarBenefit(
        id: "afc8fac1-0e8f-4bb7-a1bc-60c8250b9923",
        name: "Lifetime Team Business License",
        value: .team
    ),
    KnownPolarBenefit(
        id: "40b82917-f74e-4cc3-8165-937f1f47b294",
        name: "Enterprise Business License",
        value: .enterprise
    ),
    KnownPolarBenefit(
        id: "1857c2ed-3f80-4a8a-93c7-c1d67e02db2e",
        name: "Lifetime Enterprise Business License",
        value: .enterprise
    ),
]

private let knownPolarSupporterBenefits: [KnownPolarBenefit<SupporterTier>] = [
    KnownPolarBenefit(
        id: "d3eef5ed-bc8c-469d-809b-79fdfe5fc8e8",
        name: "Supporter Bronze License",
        value: .bronze
    ),
    KnownPolarBenefit(
        id: "9ca12e41-b407-4368-9745-76b72ff2c7c2",
        name: "Supporter Silver License",
        value: .silver
    ),
    KnownPolarBenefit(
        id: "0c695b7a-2f3a-4797-81c7-1410dbb76cc2",
        name: "Supporter Gold License",
        value: .gold
    ),
]

private let polarCommercialBenefitIDs = Dictionary(
    uniqueKeysWithValues: knownPolarCommercialBenefits.map { ($0.id, $0.value) }
)

private let polarSupporterBenefitIDs = Dictionary(
    uniqueKeysWithValues: knownPolarSupporterBenefits.map { ($0.id, $0.value) }
)

private let knownPolarBenefitNames = Dictionary(
    uniqueKeysWithValues:
        knownPolarCommercialBenefits.map { ($0.id, $0.name) } +
        knownPolarSupporterBenefits.map { ($0.id, $0.name) }
)

@MainActor
final class LicenseService: ObservableObject {
    nonisolated(unsafe) static var shared: LicenseService!

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "LicenseService")
    private let validationInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let supporterValidationInterval: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    private let defaults: UserDefaults
    private let dataTransport: LicenseDataTransport
    private let keychainServiceName: String

    // MARK: - Published state (Business)

    @Published var usageIntent: UsageIntent {
        didSet {
            defaults.set(usageIntent.rawValue, forKey: UserDefaultsKeys.usageIntent)
            defaults.set(Self.legacyUserType(for: usageIntent).rawValue, forKey: UserDefaultsKeys.userType)
        }
    }
    @Published var licenseStatus: LicenseStatus {
        didSet { defaults.set(licenseStatus.rawValue, forKey: UserDefaultsKeys.licenseStatus) }
    }
    @Published var licenseTier: LicenseTier? {
        didSet { defaults.set(licenseTier?.rawValue, forKey: UserDefaultsKeys.licenseTier) }
    }
    @Published var licenseIsLifetime: Bool {
        didSet { defaults.set(licenseIsLifetime, forKey: UserDefaultsKeys.licenseIsLifetime) }
    }
    @Published var isActivating = false
    @Published var activationError: String?
    @Published var deactivationError: String?

    // MARK: - Published state (Supporter)

    @Published var supporterTier: SupporterTier? {
        didSet { defaults.set(supporterTier?.rawValue, forKey: UserDefaultsKeys.supporterTier) }
    }
    @Published var supporterStatus: LicenseStatus {
        didSet { defaults.set(supporterStatus.rawValue, forKey: UserDefaultsKeys.supporterStatus) }
    }
    @Published var isSupporterActivating = false
    @Published var supporterActivationError: String?
    @Published var supporterDeactivationError: String?

    private enum ExpectedEntitlementKind {
        case any
        case commercial
        case supporter
    }

    var isSupporter: Bool { supporterStatus == .active && supporterTier != nil }
    var supporterClaimProof: SupporterClaimProof? {
        guard supporterStatus == .active,
              let supporterTier,
              let stored = loadSupporterFromKeychain() else { return nil }

        return SupporterClaimProof(
            key: stored.key,
            activationId: stored.activationId,
            tier: supporterTier
        )
    }

    var needsWelcomeSheet: Bool {
        !defaults.bool(forKey: UserDefaultsKeys.welcomeSheetShown)
    }

    var shouldShowReminder: Bool {
        requiresCommercialLicense && licenseStatus != .active
    }

    var requiresCommercialLicense: Bool {
        usageIntent != .personalOSS
    }

    var shouldShowWorkUsagePrompt: Bool {
        usageIntent == .personalOSS && licenseStatus != .active
    }

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        keychainServiceName: String = AppConstants.keychainServicePrefix + "license",
        dataTransport: @escaping LicenseDataTransport = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.defaults = defaults
        self.keychainServiceName = keychainServiceName
        self.dataTransport = dataTransport

        let migratedUsageIntent = Self.migrateUsageIntent(defaults: defaults)

        // Business license state
        self.usageIntent = migratedUsageIntent

        if let raw = defaults.string(forKey: UserDefaultsKeys.licenseStatus),
           let status = LicenseStatus(rawValue: raw) {
            self.licenseStatus = status
        } else {
            self.licenseStatus = .unlicensed
        }
        if let raw = defaults.string(forKey: UserDefaultsKeys.licenseTier) {
            self.licenseTier = LicenseTier(rawValue: raw)
        } else {
            self.licenseTier = nil
        }
        self.licenseIsLifetime = defaults.bool(forKey: UserDefaultsKeys.licenseIsLifetime)

        // Supporter state
        if let raw = defaults.string(forKey: UserDefaultsKeys.supporterStatus),
           let status = LicenseStatus(rawValue: raw) {
            self.supporterStatus = status
        } else {
            self.supporterStatus = .unlicensed
        }
        if let raw = defaults.string(forKey: UserDefaultsKeys.supporterTier) {
            self.supporterTier = SupporterTier(rawValue: raw)
        } else {
            self.supporterTier = nil
        }
    }

    // MARK: - Welcome Sheet

    func markWelcomeSheetShown() {
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
    }

    func setUsageIntent(_ intent: UsageIntent) {
        usageIntent = intent
        markWelcomeSheetShown()
    }

    func setUserType(_ type: LicenseUserType) {
        let mappedIntent: UsageIntent = switch type {
        case .privateUser:
            .personalOSS
        case .business:
            .workSolo
        }
        setUsageIntent(mappedIntent)
    }

    // MARK: - Polar License Key

    func activateAnyKey(_ key: String) async -> ActivatedEntitlement? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }

        isActivating = true
        activationError = nil
        deactivationError = nil
        supporterActivationError = nil
        supporterDeactivationError = nil
        defer { isActivating = false }

        do {
            let entitlement = try await activateKey(trimmedKey, expecting: .any)
            logger.info("Universal key activation succeeded")
            return entitlement
        } catch {
            activationError = error.localizedDescription
            logger.error("Universal key activation failed: \(error)")
            return nil
        }
    }

    func activateLicenseKey(_ key: String) async {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isActivating = true
        activationError = nil
        deactivationError = nil
        defer { isActivating = false }

        do {
            _ = try await activateKey(trimmedKey, expecting: .commercial)
            logger.info("Commercial key activated via Polar")
        } catch {
            activationError = error.localizedDescription
            logger.error("License activation failed: \(error)")
        }
    }

    func validateLicense() async {
        guard let (key, activationId) = loadLicenseFromKeychain() else { return }

        do {
            let response = try await polarValidate(key: key, activationId: activationId)
            if response.status == "granted" {
                licenseStatus = .active
                licenseIsLifetime = response.expiresAt == nil
                licenseTier = Self.inferLicenseTier(
                    benefitID: response.resolvedBenefitID,
                    benefitDescription: response.resolvedBenefitDescription
                )
                defaults.set(Date(), forKey: UserDefaultsKeys.lastLicenseValidation)
                logger.info("License validation successful (lifetime: \(self.licenseIsLifetime))")
            } else {
                licenseStatus = .expired
                licenseTier = nil
                logger.warning("License revoked or disabled (status: \(response.status))")
            }
        } catch {
            if Self.isPolarResourceMissing(error) {
                logger.warning("Stored license activation no longer exists on Polar; clearing local license state")
                clearLicenseState()
            } else {
                logger.error("License validation failed: \(error)")
                // Keep current status on network errors - don't downgrade offline users
            }
        }
    }

    func validateIfNeeded() async {
        guard hasStoredLicense else {
            if licenseStatus != .unlicensed || licenseTier != nil {
                licenseStatus = .unlicensed
                licenseTier = nil
            }
            return
        }

        if licenseStatus != .active {
            await validateLicense()
            return
        }

        guard let lastValidation = defaults.object(forKey: UserDefaultsKeys.lastLicenseValidation) as? Date else {
            await validateLicense()
            return
        }
        if Date().timeIntervalSince(lastValidation) > validationInterval {
            await validateLicense()
        }
    }

    func deactivateLicense() async {
        guard let (key, activationId) = loadLicenseFromKeychain() else { return }
        deactivationError = nil

        do {
            try await polarDeactivate(key: key, activationId: activationId)
            logger.info("License deactivated on Polar")

            clearLicenseState()
        } catch {
            if Self.isPolarResourceMissing(error) {
                logger.warning("License activation was already missing on Polar during deactivation; clearing local state")
                clearLicenseState()
            } else {
                deactivationError = error.localizedDescription
                logger.error("Polar deactivation failed: \(error)")
            }
        }
    }

    // MARK: - Supporter License

    func activateSupporterKey(_ key: String) async {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isSupporterActivating = true
        supporterActivationError = nil
        supporterDeactivationError = nil
        defer { isSupporterActivating = false }

        do {
            _ = try await activateKey(trimmedKey, expecting: .supporter)
            logger.info("Supporter key activated via Polar")
        } catch {
            supporterActivationError = error.localizedDescription
            logger.error("Supporter activation failed: \(error)")
        }
    }

    func validateSupporterIfNeeded() async {
        guard let (key, activationId) = loadSupporterFromKeychain() else {
            if supporterStatus != .unlicensed || supporterTier != nil {
                supporterStatus = .unlicensed
                supporterTier = nil
            }
            SupporterDiscordService.shared?.handleSupporterEntitlementRemoved()
            return
        }

        if supporterStatus != .active {
            await validateSupporter(key: key, activationId: activationId)
            return
        }

        guard let lastValidation = defaults.object(forKey: UserDefaultsKeys.lastSupporterValidation) as? Date else {
            await validateSupporter(key: key, activationId: activationId)
            return
        }
        if Date().timeIntervalSince(lastValidation) > supporterValidationInterval {
            await validateSupporter(key: key, activationId: activationId)
        }
    }

    private func validateSupporter(key: String, activationId: String) async {
        do {
            let response = try await polarValidate(key: key, activationId: activationId)
            if response.status == "granted" {
                supporterStatus = .active
                supporterTier = Self.inferSupporterTier(
                    benefitID: response.resolvedBenefitID,
                    benefitDescription: response.resolvedBenefitDescription
                ) ?? .bronze
                defaults.set(Date(), forKey: UserDefaultsKeys.lastSupporterValidation)
                logger.info("Supporter validation successful")
            } else {
                supporterStatus = .expired
                supporterTier = nil
                SupporterDiscordService.shared?.handleSupporterEntitlementRemoved()
                logger.warning("Supporter revoked or disabled (status: \(response.status))")
            }
        } catch {
            if Self.isPolarResourceMissing(error) {
                logger.warning("Stored supporter activation no longer exists on Polar; clearing local supporter state")
                clearSupporterState()
            } else {
                logger.error("Supporter validation failed: \(error)")
            }
        }
    }

    func deactivateSupporterLicense() async {
        guard let (key, activationId) = loadSupporterFromKeychain() else { return }
        supporterDeactivationError = nil

        do {
            try await polarDeactivate(key: key, activationId: activationId)
            logger.info("Supporter deactivated on Polar")

            clearSupporterState()
        } catch {
            if Self.isPolarResourceMissing(error) {
                logger.warning("Supporter activation was already missing on Polar during deactivation; clearing local state")
                clearSupporterState()
            } else {
                supporterDeactivationError = error.localizedDescription
                logger.error("Supporter deactivation failed: \(error)")
            }
        }
    }

    private func activateKey(_ key: String, expecting expectedEntitlement: ExpectedEntitlementKind) async throws -> ActivatedEntitlement {
        let response = try await polarActivate(key: key)

        do {
            let validation = try await polarValidate(key: key, activationId: response.id)
            guard validation.status == "granted" else {
                throw LicenseError.activationFailed(
                    localizedAppText(
                        "This entitlement is not active.",
                        de: "Dieses Entitlement ist nicht aktiv."
                    )
                )
            }

            let benefitID = validation.resolvedBenefitID
            let benefitDescription = validation.resolvedBenefitDescription

            if let supporterTier = Self.inferSupporterTier(benefitID: benefitID, benefitDescription: benefitDescription) {
                guard expectedEntitlement != .commercial else {
                    throw LicenseError.activationFailed(
                        localizedAppText(
                            "This key belongs to a supporter tier, not a commercial license.",
                            de: "Dieser Schlüssel gehört zu einem Supporter-Tier, nicht zu einer kommerziellen Lizenz."
                        )
                    )
                }

                applySupporterActivation(
                    key: key,
                    activationId: response.id,
                    tier: supporterTier
                )
                return .supporter(tier: supporterTier)
            }

            if let licenseTier = Self.inferLicenseTier(benefitID: benefitID, benefitDescription: benefitDescription) {
                guard expectedEntitlement != .supporter else {
                    throw LicenseError.activationFailed(
                        localizedAppText(
                            "This key belongs to a commercial license, not a supporter tier.",
                            de: "Dieser Schlüssel gehört zu einer kommerziellen Lizenz, nicht zu einem Supporter-Tier."
                        )
                    )
                }

                let isLifetime = validation.expiresAt == nil
                applyCommercialActivation(
                    key: key,
                    activationId: response.id,
                    tier: licenseTier,
                    isLifetime: isLifetime
                )
                return .commercial(tier: licenseTier, isLifetime: isLifetime)
            }

            let normalizedBenefitID = Self.normalizeBenefitIdentifier(benefitID)
            let benefitName = normalizedBenefitID.flatMap { knownPolarBenefitNames[$0] } ?? benefitDescription ?? "unknown"
            logger.error(
                "Unknown Polar entitlement during activation (benefitID: \(benefitID ?? "nil"), benefitName: \(benefitName))"
            )

            throw LicenseError.activationFailed(
                localizedAppText(
                    "This key could not be matched to a known TypeWhisper entitlement.",
                    de: "Dieser Schlüssel konnte keinem bekannten TypeWhisper-Entitlement zugeordnet werden."
                )
            )
        } catch {
            try? await polarDeactivate(key: key, activationId: response.id)
            throw error
        }
    }

    nonisolated static func inferLicenseTier(benefitID: String?, benefitDescription: String?) -> LicenseTier? {
        if let normalizedBenefitID = normalizeBenefitIdentifier(benefitID),
           let tier = polarCommercialBenefitIDs[normalizedBenefitID] {
            return tier
        }

        let haystack = [benefitID, benefitDescription]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard !haystack.isEmpty else { return nil }

        if haystack.contains("enterprise") || haystack.contains("unlimited device") {
            return .enterprise
        }
        if haystack.contains("team") || haystack.contains("10 device") || haystack.contains("small teams") {
            return .team
        }
        if haystack.contains("individual") || haystack.contains("single-seat") || haystack.contains("single seat") ||
            haystack.contains("freelancer") || haystack.contains("2 device") {
            return .individual
        }

        return nil
    }

    nonisolated static func inferSupporterTier(benefitID: String?, benefitDescription: String?) -> SupporterTier? {
        if let normalizedBenefitID = normalizeBenefitIdentifier(benefitID),
           let tier = polarSupporterBenefitIDs[normalizedBenefitID] {
            return tier
        }

        let haystack = [benefitID, benefitDescription]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        guard haystack.contains("supporter") ||
                haystack.contains("bronze") ||
                haystack.contains("silver") ||
                haystack.contains("gold") else {
            return nil
        }

        if haystack.contains("gold") { return .gold }
        if haystack.contains("silver") { return .silver }
        return .bronze
    }

    nonisolated private static func normalizeBenefitIdentifier(_ benefitID: String?) -> String? {
        let normalized = benefitID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private static func migrateUsageIntent(defaults: UserDefaults) -> UsageIntent {
        if let raw = defaults.string(forKey: UserDefaultsKeys.usageIntent),
           let intent = UsageIntent(rawValue: raw) {
            defaults.set(legacyUserType(for: intent).rawValue, forKey: UserDefaultsKeys.userType)
            return intent
        }

        let migrated: UsageIntent
        if let raw = defaults.string(forKey: UserDefaultsKeys.userType),
           let legacy = LicenseUserType(rawValue: raw) {
            migrated = switch legacy {
            case .privateUser:
                .personalOSS
            case .business:
                .workSolo
            }
        } else {
            migrated = .personalOSS
        }

        defaults.set(migrated.rawValue, forKey: UserDefaultsKeys.usageIntent)
        defaults.set(legacyUserType(for: migrated).rawValue, forKey: UserDefaultsKeys.userType)
        return migrated
    }

    private static func legacyUserType(for intent: UsageIntent) -> LicenseUserType {
        switch intent {
        case .personalOSS:
            .privateUser
        case .workSolo, .team, .enterprise:
            .business
        }
    }

    // MARK: - Polar API

    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorNetworkConnectionLost {
            logger.info("Network connection lost, retrying once...")
            try await Task.sleep(for: .milliseconds(500))
            return try await operation()
        }
    }

    private func polarActivate(key: String) async throws -> PolarActivationResponse {
        let url = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let deviceLabel = Host.current().localizedName ?? "Mac"
        let body: [String: Any] = [
            "key": key,
            "organization_id": AppConstants.Polar.organizationId,
            "label": deviceLabel,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await withRetry { try await dataTransport(request) }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        if httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(PolarActivationResponse.self, from: data)
        } else {
            throw LicenseError.activationFailed(Self.polarErrorDetail(from: data, statusCode: httpResponse.statusCode))
        }
    }

    private func polarValidate(key: String, activationId: String) async throws -> PolarValidationResponse {
        let url = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": AppConstants.Polar.organizationId,
            "activation_id": activationId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await withRetry { try await dataTransport(request) }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        if httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(PolarValidationResponse.self, from: data)
        } else {
            throw LicenseError.validationFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.polarErrorDetail(from: data, statusCode: httpResponse.statusCode)
            )
        }
    }

    private func polarDeactivate(key: String, activationId: String) async throws {
        let url = URL(string: "https://api.polar.sh/v1/customer-portal/license-keys/deactivate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "key": key,
            "organization_id": AppConstants.Polar.organizationId,
            "activation_id": activationId,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await withRetry { try await dataTransport(request) }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw LicenseError.deactivationFailed(
                statusCode: httpResponse.statusCode,
                detail: Self.polarErrorDetail(from: data, statusCode: httpResponse.statusCode)
            )
        }
    }

    // MARK: - Keychain

    private var keychainService: String { keychainServiceName }
    private var hasStoredLicense: Bool { loadLicenseFromKeychain() != nil }

    private func clearLicenseState() {
        removeLicenseFromKeychain()
        licenseStatus = .unlicensed
        licenseTier = nil
        licenseIsLifetime = false
        defaults.removeObject(forKey: UserDefaultsKeys.lastLicenseValidation)
    }

    private func saveLicenseToKeychain(key: String, activationId: String) {
        let data = "\(key)|\(activationId)".data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "polar-license",
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadLicenseFromKeychain() -> (key: String, activationId: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "polar-license",
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = string.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (key: String(parts[0]), activationId: String(parts[1]))
    }

    private func removeLicenseFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "polar-license",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func applyCommercialActivation(
        key: String,
        activationId: String,
        tier: LicenseTier,
        isLifetime: Bool
    ) {
        saveLicenseToKeychain(key: key, activationId: activationId)
        licenseStatus = .active
        licenseTier = tier
        licenseIsLifetime = isLifetime
        usageIntent = Self.usageIntent(for: tier)
        defaults.set(Date(), forKey: UserDefaultsKeys.lastLicenseValidation)
    }

    // MARK: - Supporter Keychain

    private func saveSupporterToKeychain(key: String, activationId: String) {
        let data = "\(key)|\(activationId)".data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "polar-supporter",
        ]

        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadSupporterFromKeychain() -> (key: String, activationId: String)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "polar-supporter",
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = string.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (key: String(parts[0]), activationId: String(parts[1]))
    }

    private func removeSupporterFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "polar-supporter",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func clearSupporterState() {
        removeSupporterFromKeychain()
        supporterStatus = .unlicensed
        supporterTier = nil
        defaults.removeObject(forKey: UserDefaultsKeys.lastSupporterValidation)
        SupporterDiscordService.shared?.handleSupporterEntitlementRemoved()
    }

    private func applySupporterActivation(
        key: String,
        activationId: String,
        tier: SupporterTier
    ) {
        saveSupporterToKeychain(key: key, activationId: activationId)
        supporterStatus = .active
        supporterTier = tier
        defaults.set(Date(), forKey: UserDefaultsKeys.lastSupporterValidation)
    }

    private static func usageIntent(for tier: LicenseTier) -> UsageIntent {
        switch tier {
        case .individual:
            .workSolo
        case .team:
            .team
        case .enterprise:
            .enterprise
        }
    }

    private static func polarErrorDetail(from data: Data, statusCode: Int) -> String {
        let errorResponse = try? JSONDecoder().decode(PolarErrorResponse.self, from: data)
        return errorResponse?.detail ?? errorResponse?.type ?? "HTTP \(statusCode)"
    }

    private static func isPolarResourceMissing(_ error: Error) -> Bool {
        guard let licenseError = error as? LicenseError else {
            return false
        }
        return licenseError.isResourceMissing
    }
}

// MARK: - Errors

enum LicenseError: LocalizedError {
    case networkError
    case activationFailed(String)
    case validationFailed(statusCode: Int, detail: String)
    case deactivationFailed(statusCode: Int, detail: String)

    var isResourceMissing: Bool {
        switch self {
        case .validationFailed(let statusCode, _), .deactivationFailed(let statusCode, _):
            statusCode == 404
        case .networkError, .activationFailed:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .networkError:
            return String(localized: "Network error. Please check your internet connection.")
        case .activationFailed(let detail):
            return String(localized: "Activation failed: \(detail)")
        case .validationFailed(_, let detail):
            return String(localized: "Validation failed: \(detail)")
        case .deactivationFailed(_, let detail):
            if detail.isEmpty {
                return String(localized: "Deactivation failed. Please try again.")
            }
            return String(localized: "Deactivation failed: \(detail)")
        }
    }
}

// MARK: - Discord Claim Models

struct SupporterClaimProof: Equatable, Sendable {
    let key: String
    let activationId: String
    let tier: SupporterTier
}

struct SupporterDiscordClaimStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case unavailable
        case unlinked
        case pending
        case linked
        case failed
    }

    var state: State
    var discordUsername: String?
    var linkedRoles: [String]
    var errorMessage: String?
    var sessionId: String?
    var updatedAt: Date

    static let unavailable = SupporterDiscordClaimStatus(
        state: .unavailable,
        discordUsername: nil,
        linkedRoles: [],
        errorMessage: nil,
        sessionId: nil,
        updatedAt: Date()
    )
}

private struct SupporterDiscordStartRequest: Encodable {
    let key: String
    let activationId: String
    let tier: String
    let appVersion: String
}

private struct SupporterDiscordStartResponse: Decodable {
    let sessionId: String
    let claimURL: URL

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case claimURL = "claim_url"
    }
}

private struct SupporterDiscordStatusResponse: Decodable {
    let status: String
    let discordUsername: String?
    let linkedRoles: [String]
    let errorMessage: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case status
        case discordUsername = "discord_username"
        case linkedRoles = "linked_roles"
        case errorMessage = "error"
        case sessionId = "session_id"
    }
}

private struct SupporterDiscordServiceErrorResponse: Decodable {
    let error: String
}

private struct SupporterDiscordCallbackPayload: Sendable {
    let flow: String?
    let status: String?
    let sessionId: String?
    let errorMessage: String?
}

enum SupporterDiscordServiceError: LocalizedError {
    case notEligible
    case invalidBaseURL
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEligible:
            return "An active supporter license is required before you can claim Discord status."
        case .invalidBaseURL:
            return "The Discord claim service URL is not configured correctly."
        case .invalidResponse:
            return "The Discord claim service returned an invalid response."
        case .requestFailed(let message):
            return message
        }
    }
}

typealias SupporterDiscordTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

@MainActor
final class SupporterDiscordService: ObservableObject {
    nonisolated(unsafe) static var shared: SupporterDiscordService?

    @Published private(set) var claimStatus: SupporterDiscordClaimStatus
    @Published private(set) var isWorking = false

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "SupporterDiscordService")
    private let defaults: UserDefaults
    private let transport: SupporterDiscordTransport
    private let claimProofProvider: @MainActor () -> SupporterClaimProof?
    private let baseURLProvider: @MainActor () -> URL

    init(
        licenseService: LicenseService,
        defaults: UserDefaults = .standard,
        transport: @escaping SupporterDiscordTransport = { request in
            try await URLSession.shared.data(for: request)
        },
        claimProofProvider: (@MainActor () -> SupporterClaimProof?)? = nil,
        baseURLProvider: (@MainActor () -> URL)? = nil
    ) {
        self.defaults = defaults
        self.transport = transport
        self.claimProofProvider = claimProofProvider ?? { licenseService.supporterClaimProof }
        self.baseURLProvider = baseURLProvider ?? { AppConstants.DiscordClaim.baseURL }
        self.claimStatus = Self.loadPersistedStatus(defaults: defaults)
    }

    var githubSponsorsURL: URL {
        AppConstants.DiscordClaim.githubSponsorsURL
    }

    static func canHandleCallbackURL(_ url: URL) -> Bool {
        AppConstants.DiscordClaim.isCallbackURL(url)
    }

    @discardableResult
    func createClaimSession() async -> URL? {
        guard let proof = claimProofProvider() else {
            handleSupporterEntitlementRemoved()
            claimStatus = Self.status(
                from: claimStatus,
                state: .failed,
                errorMessage: SupporterDiscordServiceError.notEligible.errorDescription
            )
            persist()
            return nil
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let endpoint = try endpointURL(path: "/claims/polar/start")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                SupporterDiscordStartRequest(
                    key: proof.key,
                    activationId: proof.activationId,
                    tier: proof.tier.rawValue,
                    appVersion: AppConstants.appVersion
                )
            )

            let response: SupporterDiscordStartResponse = try await send(request)
            claimStatus = SupporterDiscordClaimStatus(
                state: .pending,
                discordUsername: nil,
                linkedRoles: [],
                errorMessage: nil,
                sessionId: response.sessionId,
                updatedAt: Date()
            )
            persist()
            logger.info("Started Discord claim session \(response.sessionId, privacy: .public)")
            return response.claimURL
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            claimStatus = Self.status(from: claimStatus, state: .failed, errorMessage: message)
            persist()
            logger.error("Failed to start Discord claim session: \(message, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func reconnect() async -> URL? {
        claimStatus = SupporterDiscordClaimStatus(
            state: .unlinked,
            discordUsername: nil,
            linkedRoles: [],
            errorMessage: nil,
            sessionId: nil,
            updatedAt: Date()
        )
        persist()
        return await createClaimSession()
    }

    func refreshStatusIfNeeded() async {
        guard claimProofProvider() != nil else {
            handleSupporterEntitlementRemoved()
            return
        }

        guard claimStatus.state == .pending || claimStatus.state == .linked || claimStatus.sessionId != nil else {
            return
        }

        await refreshClaimStatus()
    }

    func refreshClaimStatus() async {
        guard let proof = claimProofProvider() else {
            handleSupporterEntitlementRemoved()
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            let statusURL = try statusEndpointURL(
                activationId: proof.activationId,
                sessionId: claimStatus.sessionId
            )
            var request = URLRequest(url: statusURL)
            request.httpMethod = "GET"

            let response: SupporterDiscordStatusResponse = try await send(request)
            claimStatus = Self.status(
                from: claimStatus,
                state: Self.mapState(response.status),
                discordUsername: response.discordUsername,
                linkedRoles: response.linkedRoles,
                errorMessage: response.errorMessage,
                sessionId: response.sessionId != nil ? .some(response.sessionId) : nil
            )
            persist()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("Failed to refresh Discord claim status: \(message, privacy: .public)")

            if claimStatus.state == .linked {
                claimStatus = Self.status(from: claimStatus, errorMessage: message)
            } else {
                claimStatus = Self.status(from: claimStatus, state: .failed, errorMessage: message)
            }
            persist()
        }
    }

    @discardableResult
    func handleCallbackURL(_ url: URL) async -> Bool {
        guard let payload = Self.parseCallbackURL(url) else {
            return false
        }

        guard payload.flow == nil || payload.flow == "polar" else {
            return true
        }

        claimStatus = Self.status(
            from: claimStatus,
            state: Self.mapCallbackState(payload.status),
            errorMessage: payload.errorMessage.map(Optional.some) ?? nil,
            sessionId: payload.sessionId.map(Optional.some) ?? nil
        )
        persist()

        await refreshClaimStatus()
        return true
    }

    func handleSupporterEntitlementRemoved() {
        claimStatus = SupporterDiscordClaimStatus(
            state: .unavailable,
            discordUsername: nil,
            linkedRoles: [],
            errorMessage: nil,
            sessionId: nil,
            updatedAt: Date()
        )
        defaults.removeObject(forKey: UserDefaultsKeys.supporterDiscordSessionId)
        persist()
    }

    private func endpointURL(path: String) throws -> URL {
        let baseURL = baseURLProvider()
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw SupporterDiscordServiceError.invalidBaseURL
        }
        components.path = path
        guard let url = components.url else {
            throw SupporterDiscordServiceError.invalidBaseURL
        }
        return url
    }

    private func statusEndpointURL(activationId: String, sessionId: String?) throws -> URL {
        let url = try endpointURL(path: "/claims/polar/status")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SupporterDiscordServiceError.invalidBaseURL
        }
        var queryItems = [URLQueryItem(name: "activation_id", value: activationId)]
        if let sessionId, !sessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "session_id", value: sessionId))
        }
        components.queryItems = queryItems
        guard let composed = components.url else {
            throw SupporterDiscordServiceError.invalidBaseURL
        }
        return composed
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await transport(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupporterDiscordServiceError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? JSONDecoder().decode(SupporterDiscordServiceErrorResponse.self, from: data) {
                throw SupporterDiscordServiceError.requestFailed(errorResponse.error)
            }
            throw SupporterDiscordServiceError.requestFailed("Discord claim service returned HTTP \(httpResponse.statusCode).")
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SupporterDiscordServiceError.invalidResponse
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(claimStatus) {
            defaults.set(data, forKey: UserDefaultsKeys.supporterDiscordClaimStatus)
        }
        defaults.set(claimStatus.sessionId, forKey: UserDefaultsKeys.supporterDiscordSessionId)
    }

    private static func loadPersistedStatus(defaults: UserDefaults) -> SupporterDiscordClaimStatus {
        if let data = defaults.data(forKey: UserDefaultsKeys.supporterDiscordClaimStatus),
           let status = try? JSONDecoder().decode(SupporterDiscordClaimStatus.self, from: data) {
            return status
        }
        return .unavailable
    }

    private static func mapState(_ rawValue: String) -> SupporterDiscordClaimStatus.State {
        switch rawValue {
        case "unlinked":
            return .unlinked
        case "pending":
            return .pending
        case "linked":
            return .linked
        case "failed":
            return .failed
        default:
            return .failed
        }
    }

    private static func mapCallbackState(_ rawValue: String?) -> SupporterDiscordClaimStatus.State? {
        guard let rawValue else { return nil }
        switch rawValue {
        case "linked", "pending":
            return .pending
        case "unlinked":
            return .unlinked
        case "failed", "expired":
            return .failed
        default:
            return nil
        }
    }

    private static func parseCallbackURL(_ url: URL) -> SupporterDiscordCallbackPayload? {
        guard canHandleCallbackURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        return SupporterDiscordCallbackPayload(
            flow: value("flow"),
            status: value("status"),
            sessionId: value("session_id"),
            errorMessage: value("error")
        )
    }

    private static func status(
        from current: SupporterDiscordClaimStatus,
        state: SupporterDiscordClaimStatus.State? = nil,
        discordUsername: String?? = nil,
        linkedRoles: [String]? = nil,
        errorMessage: String?? = nil,
        sessionId: String?? = nil
    ) -> SupporterDiscordClaimStatus {
        SupporterDiscordClaimStatus(
            state: state ?? current.state,
            discordUsername: discordUsername ?? current.discordUsername,
            linkedRoles: linkedRoles ?? current.linkedRoles,
            errorMessage: errorMessage ?? current.errorMessage,
            sessionId: sessionId ?? current.sessionId,
            updatedAt: Date()
        )
    }
}
