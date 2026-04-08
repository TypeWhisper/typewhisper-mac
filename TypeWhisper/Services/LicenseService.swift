import Combine
import Foundation
import Security
import os

enum LicenseUserType: String {
    case privateUser = "private"
    case business = "business"
}

enum LicenseStatus: String {
    case unlicensed
    case active = "polar_active"
    case expired = "polar_expired"
}

enum LicenseTier: String {
    case individual
    case team
    case enterprise
}

enum SupporterTier: String, CaseIterable {
    case bronze
    case silver
    case gold
}

struct PolarActivationResponse: Codable {
    let id: String
}

struct PolarValidationResponse: Codable {
    let id: String
    let status: String
    let expiresAt: String?
    let benefit: PolarBenefit?

    enum CodingKeys: String, CodingKey {
        case id, status
        case expiresAt = "expires_at"
        case benefit
    }

    struct PolarBenefit: Codable {
        let id: String
        let description: String?
    }
}

struct PolarErrorResponse: Codable {
    let detail: String?
    let type: String?
}

@MainActor
final class LicenseService: ObservableObject {
    nonisolated(unsafe) static var shared: LicenseService!

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "LicenseService")
    private let keychainKeyPrefix = AppConstants.keychainServicePrefix
    private let validationInterval: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let supporterValidationInterval: TimeInterval = 30 * 24 * 60 * 60 // 30 days

    // MARK: - Published state (Business)

    @Published var userType: LicenseUserType? {
        didSet { UserDefaults.standard.set(userType?.rawValue, forKey: UserDefaultsKeys.userType) }
    }
    @Published var licenseStatus: LicenseStatus {
        didSet { UserDefaults.standard.set(licenseStatus.rawValue, forKey: UserDefaultsKeys.licenseStatus) }
    }
    @Published var licenseTier: LicenseTier? {
        didSet { UserDefaults.standard.set(licenseTier?.rawValue, forKey: UserDefaultsKeys.licenseTier) }
    }
    @Published var licenseIsLifetime: Bool {
        didSet { UserDefaults.standard.set(licenseIsLifetime, forKey: UserDefaultsKeys.licenseIsLifetime) }
    }
    @Published var isActivating = false
    @Published var activationError: String?
    @Published var deactivationError: String?

    // MARK: - Published state (Supporter)

    @Published var supporterTier: SupporterTier? {
        didSet { UserDefaults.standard.set(supporterTier?.rawValue, forKey: UserDefaultsKeys.supporterTier) }
    }
    @Published var supporterStatus: LicenseStatus {
        didSet { UserDefaults.standard.set(supporterStatus.rawValue, forKey: UserDefaultsKeys.supporterStatus) }
    }
    @Published var isSupporterActivating = false
    @Published var supporterActivationError: String?
    @Published var supporterDeactivationError: String?

    var isSupporter: Bool { supporterStatus == .active && supporterTier != nil }

    var needsWelcomeSheet: Bool {
        !UserDefaults.standard.bool(forKey: UserDefaultsKeys.welcomeSheetShown)
    }

    var shouldShowReminder: Bool {
        userType == .business && licenseStatus != .active
    }

    // MARK: - Init

    init() {
        // Business license state
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.userType) {
            self.userType = LicenseUserType(rawValue: raw)
        } else {
            self.userType = nil
        }
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.licenseStatus),
           let status = LicenseStatus(rawValue: raw) {
            self.licenseStatus = status
        } else {
            self.licenseStatus = .unlicensed
        }
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.licenseTier) {
            self.licenseTier = LicenseTier(rawValue: raw)
        } else {
            self.licenseTier = nil
        }
        self.licenseIsLifetime = UserDefaults.standard.bool(forKey: UserDefaultsKeys.licenseIsLifetime)

        // Supporter state
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.supporterStatus),
           let status = LicenseStatus(rawValue: raw) {
            self.supporterStatus = status
        } else {
            self.supporterStatus = .unlicensed
        }
        if let raw = UserDefaults.standard.string(forKey: UserDefaultsKeys.supporterTier) {
            self.supporterTier = SupporterTier(rawValue: raw)
        } else {
            self.supporterTier = nil
        }
    }

    // MARK: - Welcome Sheet

    func markWelcomeSheetShown() {
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
    }

    func setUserType(_ type: LicenseUserType) {
        userType = type
        markWelcomeSheetShown()
    }

    // MARK: - Polar License Key

    func activateLicenseKey(_ key: String) async {
        isActivating = true
        activationError = nil
        deactivationError = nil

        do {
            let response = try await polarActivate(key: key)
            saveLicenseToKeychain(key: key, activationId: response.id)
            licenseStatus = .active
            UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastLicenseValidation)

            // Detect lifetime vs subscription
            let validation = try? await polarValidate(key: key, activationId: response.id)
            licenseIsLifetime = validation?.expiresAt == nil

            logger.info("License activated via Polar (activation: \(response.id), lifetime: \(self.licenseIsLifetime))")
        } catch {
            activationError = error.localizedDescription
            logger.error("License activation failed: \(error)")
        }

        isActivating = false
    }

    func validateLicense() async {
        guard let (key, activationId) = loadLicenseFromKeychain() else { return }

        do {
            let response = try await polarValidate(key: key, activationId: activationId)
            if response.status == "granted" {
                licenseStatus = .active
                licenseIsLifetime = response.expiresAt == nil
                UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastLicenseValidation)
                logger.info("License validation successful (lifetime: \(self.licenseIsLifetime))")
            } else {
                licenseStatus = .expired
                logger.warning("License revoked or disabled (status: \(response.status))")
            }
        } catch {
            logger.error("License validation failed: \(error)")
            // Keep current status on network errors - don't downgrade offline users
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

        guard let lastValidation = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastLicenseValidation) as? Date else {
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

            removeLicenseFromKeychain()
            licenseStatus = .unlicensed
            licenseTier = nil
            licenseIsLifetime = false
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.lastLicenseValidation)
        } catch {
            deactivationError = error.localizedDescription
            logger.error("Polar deactivation failed: \(error)")
        }
    }

    // MARK: - Supporter License

    func activateSupporterKey(_ key: String) async {
        isSupporterActivating = true
        supporterActivationError = nil
        supporterDeactivationError = nil

        do {
            let response = try await polarActivate(key: key)
            saveSupporterToKeychain(key: key, activationId: response.id)
            supporterStatus = .active
            UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastSupporterValidation)

            // Detect tier from benefit description
            if let validation = try? await polarValidate(key: key, activationId: response.id),
               let description = validation.benefit?.description?.lowercased() {
                if description.contains("gold") {
                    supporterTier = .gold
                } else if description.contains("silver") {
                    supporterTier = .silver
                } else {
                    supporterTier = .bronze
                }
            } else {
                supporterTier = .bronze
            }

            logger.info("Supporter activated via Polar (activation: \(response.id), tier: \(self.supporterTier?.rawValue ?? "unknown"))")
        } catch {
            supporterActivationError = error.localizedDescription
            logger.error("Supporter activation failed: \(error)")
        }

        isSupporterActivating = false
    }

    func validateSupporterIfNeeded() async {
        guard let (key, activationId) = loadSupporterFromKeychain() else {
            if supporterStatus != .unlicensed || supporterTier != nil {
                supporterStatus = .unlicensed
                supporterTier = nil
            }
            return
        }

        if supporterStatus != .active {
            await validateSupporter(key: key, activationId: activationId)
            return
        }

        guard let lastValidation = UserDefaults.standard.object(forKey: UserDefaultsKeys.lastSupporterValidation) as? Date else {
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
                UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.lastSupporterValidation)
                logger.info("Supporter validation successful")
            } else {
                supporterStatus = .expired
                logger.warning("Supporter revoked or disabled (status: \(response.status))")
            }
        } catch {
            logger.error("Supporter validation failed: \(error)")
        }
    }

    func deactivateSupporterLicense() async {
        guard let (key, activationId) = loadSupporterFromKeychain() else { return }
        supporterDeactivationError = nil

        do {
            try await polarDeactivate(key: key, activationId: activationId)
            logger.info("Supporter deactivated on Polar")

            removeSupporterFromKeychain()
            supporterStatus = .unlicensed
            supporterTier = nil
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.lastSupporterValidation)
        } catch {
            supporterDeactivationError = error.localizedDescription
            logger.error("Supporter deactivation failed: \(error)")
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

        let (data, response) = try await withRetry { try await URLSession.shared.data(for: request) }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        if httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(PolarActivationResponse.self, from: data)
        } else {
            let errorResponse = try? JSONDecoder().decode(PolarErrorResponse.self, from: data)
            throw LicenseError.activationFailed(errorResponse?.detail ?? "HTTP \(httpResponse.statusCode)")
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

        let (data, response) = try await withRetry { try await URLSession.shared.data(for: request) }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LicenseError.networkError
        }

        if httpResponse.statusCode == 200 {
            return try JSONDecoder().decode(PolarValidationResponse.self, from: data)
        } else {
            throw LicenseError.validationFailed("HTTP \(httpResponse.statusCode)")
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

        let (_, response) = try await withRetry { try await URLSession.shared.data(for: request) }
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw LicenseError.deactivationFailed
        }
    }

    // MARK: - Keychain

    private var keychainService: String { keychainKeyPrefix + "license" }
    private var hasStoredLicense: Bool { loadLicenseFromKeychain() != nil }

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
}

// MARK: - Errors

enum LicenseError: LocalizedError {
    case networkError
    case activationFailed(String)
    case validationFailed(String)
    case deactivationFailed

    var errorDescription: String? {
        switch self {
        case .networkError:
            return String(localized: "Network error. Please check your internet connection.")
        case .activationFailed(let detail):
            return String(localized: "Activation failed: \(detail)")
        case .validationFailed(let detail):
            return String(localized: "Validation failed: \(detail)")
        case .deactivationFailed:
            return String(localized: "Deactivation failed. Please try again.")
        }
    }
}
