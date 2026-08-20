import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import SwiftUI

private func readPremiumAccountToken(service: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "access-token",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var value: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
          let data = value as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

enum PremiumSyncMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case automaticICloud
    case cloudFolder

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: String(localized: "premium.window.sync.mode.off")
        case .automaticICloud: String(localized: "premium.window.sync.mode.automaticICloud")
        case .cloudFolder: String(localized: "premium.window.sync.mode.cloudFolder")
        }
    }
}

private enum TypeWhisperBuildCapabilities {
    static var iCloudSyncEnabled: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TypeWhisperICloudEnabled") as? String else {
            return true
        }
        return !["no", "false", "0"].contains(value.lowercased())
    }
}

struct CrossDevicePremiumEntitlement: Codable, Equatable, Sendable {
    struct SignedClaims: Codable, Equatable, Sendable {
        let status: String
        let tier: String
        let source: String
        let isLifetime: Bool
        let expiresAt: Date?
        let deviceLimit: Int?
        let verifiedAt: Date
    }

    let status: String
    let tier: String
    let source: String
    let isLifetime: Bool
    let expiresAt: Date?
    let deviceLimit: Int?
    let verifiedAt: Date
    let signature: String?

    var isActive: Bool {
        guard status == "active" || status == "granted" else { return false }
        return expiresAt.map { $0 > Date() } ?? true
    }

    var signedClaims: SignedClaims {
        SignedClaims(
            status: status,
            tier: tier,
            source: source,
            isLifetime: isLifetime,
            expiresAt: expiresAt,
            deviceLimit: deviceLimit,
            verifiedAt: verifiedAt
        )
    }
}

struct CrossDevicePremiumEntitlementVerifier: Sendable {
    private let publicKey: P256.Signing.PublicKey

    init?(publicKeyBase64: String) {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? P256.Signing.PublicKey(rawRepresentation: keyData) else {
            return nil
        }
        publicKey = key
    }

    func verified(_ entitlement: CrossDevicePremiumEntitlement) -> CrossDevicePremiumEntitlement? {
        guard let signatureValue = entitlement.signature else { return nil }
        let components = signatureValue.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              let payload = Self.decodeBase64URL(String(components[0])),
              let signatureData = Self.decodeBase64URL(String(components[1])),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
              publicKey.isValidSignature(signature, for: payload) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(
            decodeISO8601DateWithOptionalFractionalSeconds
        )
        guard let claims = try? decoder.decode(
            CrossDevicePremiumEntitlement.SignedClaims.self,
            from: payload
        ), claims == entitlement.signedClaims else {
            return nil
        }
        return entitlement
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = base64.padding(
            toLength: ((base64.count + 3) / 4) * 4,
            withPad: "=",
            startingAt: 0
        )
        return Data(base64Encoded: padded)
    }
}

private enum PremiumAccountServiceError: LocalizedError {
    case invalidEntitlementSignature
    case commercialLicenseLinkFailed
    case appleSignInCancelled
    case invalidAppleAuthorizationCallback
    case appleAuthorizationFailed
    case secureRandomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidEntitlementSignature:
            String(localized: "The Premium entitlement signature could not be verified.")
        case .commercialLicenseLinkFailed:
            String(localized: "premium.window.access.linkFailed")
        case .appleSignInCancelled:
            nil
        case .invalidAppleAuthorizationCallback:
            String(localized: "The Sign in with Apple response could not be verified.")
        case .appleAuthorizationFailed:
            String(localized: "Sign in with Apple could not be completed.")
        case .secureRandomGenerationFailed:
            String(localized: "Secure sign-in data could not be generated.")
        }
    }
}

private func decodeISO8601DateWithOptionalFractionalSeconds(
    from decoder: Decoder
) throws -> Date {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let formatter = ISO8601DateFormatter()

    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) {
        return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) {
        return date
    }

    throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO 8601 date"
    )
}

@MainActor
protocol AppleWebAuthenticating: AnyObject {
    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL
}

private final class AppleWebAuthenticationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(continuation: CheckedContinuation<URL, Error>) {
        self.continuation = continuation
    }

    func resume(callbackURL: URL?, error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        if let callbackURL {
            continuation.resume(returning: callbackURL)
        } else {
            continuation.resume(throwing: error ?? URLError(.cancelled))
        }
    }
}

private func makeAppleWebAuthenticationSession(
    authorizationURL: URL,
    callbackScheme: String,
    completion: AppleWebAuthenticationCompletion
) -> ASWebAuthenticationSession {
    ASWebAuthenticationSession(
        url: authorizationURL,
        callbackURLScheme: callbackScheme
    ) { callbackURL, error in
        completion.resume(callbackURL: callbackURL, error: error)
    }
}

@MainActor
final class AppleWebAuthenticationSession: NSObject, AppleWebAuthenticating, ASWebAuthenticationPresentationContextProviding {
    private var authenticationSession: ASWebAuthenticationSession?
    private let fallbackWindow = NSWindow()

    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        defer { authenticationSession = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = AppleWebAuthenticationCompletion(continuation: continuation)
            let session = makeAppleWebAuthenticationSession(
                authorizationURL: authorizationURL,
                callbackScheme: callbackScheme,
                completion: completion
            )
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                completion.resume(
                    callbackURL: nil,
                    error: URLError(.cannotLoadFromNetwork)
                )
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? fallbackWindow
    }
}

@MainActor
final class PremiumAccountService: ObservableObject {
    private struct AccountSession: Decodable {
        let accessToken: String
        let entitlement: CrossDevicePremiumEntitlement?
    }
    private struct EntitlementResponse: Decodable { let entitlement: CrossDevicePremiumEntitlement? }
    private struct DeviceDetachResponse: Decodable {
        let ok: Bool
        let released: Bool
    }
    private struct ErrorResponse: Decodable { let error: String }
    private struct AppleWebStartResponse: Decodable {
        let authorizationURL: URL
        let state: String
        let expiresAt: Date
    }

    private enum Keys {
        static let cachedEntitlement = "premium.account.cachedEntitlement"
        static let lastRefresh = "premium.account.lastRefresh"
        static let deviceID = "premium.account.deviceID"
    }

    @Published private(set) var entitlement: CrossDevicePremiumEntitlement?
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let requestExecutor: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let keychainService: String
    private let deviceID: String
    private let entitlementVerifier: CrossDevicePremiumEntitlementVerifier?
    private let appleWebAuthenticator: any AppleWebAuthenticating
    private var startupTokenTask: Task<Void, Never>?

    private static let productionEntitlementPublicKeyBase64 =
        "8ZwFh+yrpkZZ1VsZgjpZcOz2h3jKpGG93MTdRaCPqXFn/Loqh8u36hB9FLho+ozwuHbaNeoN1MxM2/AJKyBNvQ=="

    var hasPremiumEntitlement: Bool { entitlement?.isActive == true }

    #if DEBUG
    func prepareScreenshotFixture(hasPremiumAccess: Bool) {
        startupTokenTask?.cancel()
        startupTokenTask = nil
        isSignedIn = hasPremiumAccess
        errorMessage = nil
        entitlement = hasPremiumAccess
            ? CrossDevicePremiumEntitlement(
                status: "active",
                tier: "individual",
                source: "screenshot-fixture",
                isLifetime: true,
                expiresAt: nil,
                deviceLimit: 3,
                verifiedAt: Date(),
                signature: nil
            )
            : nil
    }
    #endif

    init(
        defaults: UserDefaults = .standard,
        baseURL: URL? = nil,
        session: URLSession = .shared,
        requestExecutor: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        appleWebAuthenticator: (any AppleWebAuthenticating)? = nil,
        keychainService: String = AppConstants.isScreenshotAutomation
            ? "com.typewhisper.mac.screenshots.premium-account"
            : "com.typewhisper.mac.premium-account",
        entitlementPublicKeyBase64: String = PremiumAccountService.productionEntitlementPublicKeyBase64,
        isSignedInOverride: Bool? = nil,
        automaticallyRefresh: Bool = true,
        startupTokenReader: @escaping @Sendable (String) -> String? = readPremiumAccountToken
    ) {
        self.defaults = defaults
        self.baseURL = baseURL
            ?? (Bundle.main.object(forInfoDictionaryKey: "TypeWhisperAccountBaseURL") as? String)
                .flatMap(URL.init(string:))
            ?? URL(string: "https://app.typewhisper.com")!
        self.requestExecutor = requestExecutor ?? { try await session.data(for: $0) }
        self.appleWebAuthenticator = appleWebAuthenticator ?? AppleWebAuthenticationSession()
        self.keychainService = keychainService
        entitlementVerifier = CrossDevicePremiumEntitlementVerifier(
            publicKeyBase64: entitlementPublicKeyBase64
        )
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(
            decodeISO8601DateWithOptionalFractionalSeconds
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let existing = defaults.string(forKey: Keys.deviceID) {
            deviceID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Keys.deviceID)
            deviceID = generated
        }
        if let data = defaults.data(forKey: Keys.cachedEntitlement),
           let cached = try? decoder.decode(CrossDevicePremiumEntitlement.self, from: data),
           let verified = entitlementVerifier?.verified(cached) {
            entitlement = verified
        } else {
            entitlement = nil
            defaults.removeObject(forKey: Keys.cachedEntitlement)
        }
        isSignedIn = isSignedInOverride ?? false
        if let isSignedInOverride {
            if isSignedInOverride, automaticallyRefresh {
                Task { await refreshIfNeeded() }
            }
        } else {
            startupTokenTask = Task { @MainActor [weak self] in
                let hasStoredToken = await Task.detached {
                    startupTokenReader(keychainService) != nil
                }.value
                guard !Task.isCancelled, let self else { return }
                self.isSignedIn = hasStoredToken
                self.startupTokenTask = nil
                if hasStoredToken, automaticallyRefresh {
                    await self.refreshIfNeeded()
                }
            }
        }
    }

    func signInWithApple(
        commercialLicenseProof: CommercialLicenseLinkProof?
    ) async {
        await perform {
            let nonce = try Self.randomBase64URLToken()
            let codeVerifier = try Self.randomBase64URLToken()
            let nonceHash = Self.sha256Hex(nonce)
            let codeChallenge = Self.sha256Base64URL(codeVerifier)
            let start: AppleWebStartResponse = try await request(
                path: "/v1/auth/apple/web/start",
                method: "POST",
                body: try encoder.encode([
                    "nonceHash": nonceHash,
                    "codeChallenge": codeChallenge,
                ]),
                authenticated: false
            )
            guard start.expiresAt > Date(),
                  start.authorizationURL.scheme == "https",
                  start.authorizationURL.host == "appleid.apple.com" else {
                throw PremiumAccountServiceError.invalidAppleAuthorizationCallback
            }

            let callbackURL: URL
            do {
                callbackURL = try await appleWebAuthenticator.authenticate(
                    at: start.authorizationURL,
                    callbackScheme: "typewhisper"
                )
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                throw PremiumAccountServiceError.appleSignInCancelled
            } catch let error as URLError where error.code == .cancelled {
                throw PremiumAccountServiceError.appleSignInCancelled
            }

            let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            let values = (callback?.queryItems ?? []).reduce(into: [String: String]()) { result, item in
                if result[item.name] == nil, let value = item.value {
                    result[item.name] = value
                }
            }
            guard callbackURL.scheme == "typewhisper",
                  callbackURL.host == "premium-auth",
                  callbackURL.path == "/callback",
                  values["state"] == start.state else {
                throw PremiumAccountServiceError.invalidAppleAuthorizationCallback
            }
            if values["error"] == "user_cancelled_authorize" {
                throw PremiumAccountServiceError.appleSignInCancelled
            }
            guard values["error"] == nil, let code = values["code"], !code.isEmpty else {
                throw PremiumAccountServiceError.appleAuthorizationFailed
            }

            let accountSession: AccountSession = try await request(
                path: "/v1/auth/apple/web/exchange",
                method: "POST",
                body: try encoder.encode([
                    "state": start.state,
                    "code": code,
                    "codeVerifier": codeVerifier,
                ]),
                authenticated: false
            )
            try await acceptAccountSession(
                accountSession,
                commercialLicenseProof: commercialLicenseProof
            )
        }
    }

    func refreshIfNeeded() async {
        guard isSignedIn else { return }
        if hasPremiumEntitlement,
           let last = defaults.object(forKey: Keys.lastRefresh) as? Date,
           Date().timeIntervalSince(last) < 7 * 24 * 60 * 60 { return }
        do { try await refresh() }
        catch { if entitlement == nil { errorMessage = error.localizedDescription } }
    }

    func signOut() {
        clearAuthorizationState()
    }

    func signOutFromAccount() async {
        await perform {
            let response: DeviceDetachResponse = try await request(
                path: "/v1/entitlements/polar/device/current",
                method: "DELETE"
            )
            guard response.ok else { throw URLError(.badServerResponse) }
            _ = response.released
            clearAuthorizationState()
        }
    }

    func linkCommercialLicense(_ proof: CommercialLicenseLinkProof) async {
        await perform {
            let entitlement = try await attachCommercialLicense(proof)
            try acceptEntitlement(entitlement)
            guard hasPremiumEntitlement else {
                throw PremiumAccountServiceError.commercialLicenseLinkFailed
            }
            defaults.set(Date(), forKey: Keys.lastRefresh)
        }
    }

    func deleteAccount() async {
        await perform {
            let _: [String: Bool] = try await request(path: "/v1/account", method: "DELETE")
            signOut()
        }
    }

    private func refresh() async throws {
        let response: EntitlementResponse = try await request(path: "/v1/entitlements/current")
        try acceptEntitlement(response.entitlement)
        defaults.set(Date(), forKey: Keys.lastRefresh)
    }

    private func acceptAccountSession(
        _ accountSession: AccountSession,
        commercialLicenseProof: CommercialLicenseLinkProof?
    ) async throws {
        startupTokenTask?.cancel()
        startupTokenTask = nil
        try Self.saveToken(accountSession.accessToken, service: keychainService)
        isSignedIn = true
        try acceptEntitlement(accountSession.entitlement)
        if let commercialLicenseProof,
           !commercialLicenseProof.key.isEmpty,
           !commercialLicenseProof.activationId.isEmpty {
            do {
                try acceptEntitlement(
                    try await attachCommercialLicense(commercialLicenseProof)
                )
            } catch {
                clearAuthorizationState()
                throw error
            }
        } else {
            try await refresh()
        }
    }

    private func attachCommercialLicense(
        _ proof: CommercialLicenseLinkProof
    ) async throws -> CrossDevicePremiumEntitlement? {
        let response: EntitlementResponse = try await request(
            path: "/v1/entitlements/polar/device/attach",
            method: "POST",
            body: try encoder.encode([
                "licenseKey": proof.key,
                "activationId": proof.activationId,
            ])
        )
        return response.entitlement
    }

    private func acceptEntitlement(_ value: CrossDevicePremiumEntitlement?) throws {
        guard let value else {
            entitlement = nil
            defaults.removeObject(forKey: Keys.cachedEntitlement)
            return
        }
        guard let verified = entitlementVerifier?.verified(value) else {
            entitlement = nil
            defaults.removeObject(forKey: Keys.cachedEntitlement)
            throw PremiumAccountServiceError.invalidEntitlementSignature
        }
        entitlement = verified
        if let data = try? encoder.encode(verified) {
            defaults.set(data, forKey: Keys.cachedEntitlement)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { try await operation() }
        catch PremiumAccountServiceError.appleSignInCancelled {}
        catch { errorMessage = error.localizedDescription }
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceID, forHTTPHeaderField: "X-TypeWhisper-Device-ID")
        request.setValue("macos", forHTTPHeaderField: "X-TypeWhisper-Platform")
        request.setValue("2", forHTTPHeaderField: "X-TypeWhisper-Entitlement-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if authenticated {
            guard let token = Self.readToken(service: keychainService) else {
                throw NSError(domain: "PremiumAccount", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sign in with Apple first."])
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await requestExecutor(request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if authenticated, http.statusCode == 401 || http.statusCode == 403 {
                clearAuthorizationState()
            }
            let message = (try? decoder.decode(ErrorResponse.self, from: data).error) ?? "Account request failed (HTTP \(http.statusCode))."
            throw NSError(domain: "PremiumAccount", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try decoder.decode(Response.self, from: data)
    }

    func clearAuthorizationForHTTPStatus(_ statusCode: Int) {
        guard statusCode == 401 || statusCode == 403 else { return }
        clearAuthorizationState()
    }

    private func clearAuthorizationState() {
        startupTokenTask?.cancel()
        startupTokenTask = nil
        Self.deleteToken(service: keychainService)
        isSignedIn = false
        entitlement = nil
        defaults.removeObject(forKey: Keys.cachedEntitlement)
        defaults.removeObject(forKey: Keys.lastRefresh)
    }

    private static func readToken(service: String) -> String? {
        readPremiumAccountToken(service: service)
    }

    private static func saveToken(_ token: String, service: String) throws {
        deleteToken(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "access-token",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func deleteToken(service: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "access-token",
        ] as CFDictionary)
    }

    private static func randomBase64URLToken(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PremiumAccountServiceError.secureRandomGenerationFailed
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func sha256Base64URL(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class CloudFolderSyncController: ObservableObject {
    private enum Keys {
        static let mode = "premiumSync.mode"
        static let automaticSyncState = "premiumSync.iCloudState"
        static let folderBookmark = "cloudFolderSync.folderBookmark"
        static let syncState = "cloudFolderSync.syncState"
        static let legacyFolderBookmark = "plugin.com.typewhisper.cloud-folder-sync.folderBookmark"
        static let legacySyncState = "plugin.com.typewhisper.cloud-folder-sync.syncState"
    }

    private let premiumAccountService: PremiumAccountService
    private let syncStore: any UserDataSyncStore
    private let defaults: UserDefaults
    private let automaticICloudBridge: any PremiumICloudBridging
    private let automaticICloudAvailable: Bool
    private let historyService: HistoryService?
    let historySyncPreferences: HistorySyncPreferences?
    private var customState: CloudFolderSyncState
    private var automaticState: CloudFolderSyncState
    private var localChangeObserverId: UUID?
    private var scheduledSyncTask: Task<Void, Never>?
    private var automaticPollTask: Task<Void, Never>?
    private var entitlementCancellable: AnyCancellable?
    private var needsResync = false

    @Published private(set) var mode: PremiumSyncMode
    @Published private(set) var selectedFolderURL: URL?
    @Published private(set) var provider: CloudFolderSyncProvider = .custom
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var pendingChanges = 0
    @Published private(set) var deviceCount = 0
    @Published private(set) var devices: [CloudFolderSyncDeviceRecord] = []
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    var canUseSync: Bool {
        AppConstants.isPremiumSyncSmokeTest
            || (premiumAccountService.isSignedIn && premiumAccountService.hasPremiumEntitlement)
    }

    var availableModes: [PremiumSyncMode] {
        automaticICloudAvailable ? PremiumSyncMode.allCases : [.off, .cloudFolder]
    }

    var selectedFolderDisplayName: String {
        switch mode {
        case .automaticICloud: String(localized: "premium.window.sync.privateICloudContainer")
        case .cloudFolder: selectedFolderURL?.path(percentEncoded: false)
            ?? String(localized: "premium.window.sync.noFolderSelected")
        case .off: String(localized: "premium.window.sync.syncOff")
        }
    }

    var isConfigured: Bool { mode == .automaticICloud || (mode == .cloudFolder && selectedFolderURL != nil) }

    init(
        premiumAccountService: PremiumAccountService,
        syncStore: any UserDataSyncStore,
        historyService: HistoryService? = nil,
        historySyncPreferences: HistorySyncPreferences? = nil,
        defaults: UserDefaults = .standard,
        automaticICloudBridge: any PremiumICloudBridging = PremiumICloudBridgeClient(),
        automaticICloudAvailable: Bool? = nil
    ) {
        self.premiumAccountService = premiumAccountService
        self.syncStore = syncStore
        self.historyService = historyService
        self.historySyncPreferences = historySyncPreferences
        self.defaults = defaults
        self.automaticICloudBridge = automaticICloudBridge
        self.automaticICloudAvailable = automaticICloudAvailable
            ?? (TypeWhisperBuildCapabilities.iCloudSyncEnabled && automaticICloudBridge.isAvailable)
        self.customState = Self.loadState(from: defaults, key: Keys.syncState, legacyKey: Keys.legacySyncState)
        self.automaticState = Self.loadState(from: defaults, key: Keys.automaticSyncState)
        let storedMode = defaults.string(forKey: Keys.mode).flatMap(PremiumSyncMode.init(rawValue:))
        let requestedMode = AppConstants.isPremiumSyncSmokeTest
            ? PremiumSyncMode.automaticICloud
            : storedMode ?? (defaults.data(forKey: Keys.folderBookmark) != nil ? .cloudFolder : .off)
        self.mode = requestedMode == .automaticICloud && !self.automaticICloudAvailable ? .off : requestedMode
        self.lastSyncDate = mode == .automaticICloud ? automaticState.lastSyncAt : customState.lastSyncAt

        restoreSelectedFolder()
        if mode == .automaticICloud { provider = .iCloudDrive }
        installLocalChangeObserver()
        updateICloudObservation()
        entitlementCancellable = premiumAccountService.$entitlement
            .combineLatest(premiumAccountService.$isSignedIn)
            .dropFirst()
            .sink { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.isConfigured, self.canUseSync else { return }
                    await self.syncNow()
                }
            }
        if isConfigured, canUseSync {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.isConfigured, self.canUseSync else { return }
                await self.syncNow()
            }
        }
    }

    deinit {
        scheduledSyncTask?.cancel()
        automaticPollTask?.cancel()
    }

    func deactivate() {
        scheduledSyncTask?.cancel()
        if let localChangeObserverId {
            syncStore.removeLocalChangeObserver(localChangeObserverId)
            self.localChangeObserverId = nil
        }
        stopICloudObservation()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a cloud-synced folder for TypeWhisper.")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await selectCustomFolder(url) }
    }

    func setMode(_ newMode: PremiumSyncMode) async {
        guard automaticICloudAvailable || newMode != .automaticICloud else { return }
        guard newMode != mode, !isSyncing else { return }
        if isConfigured, canUseSync { await syncNow() }
        guard !isSyncing else { return }
        mode = newMode
        if newMode == .automaticICloud { provider = .iCloudDrive }
        if newMode == .cloudFolder, let selectedFolderURL {
            provider = CloudFolderSyncProvider.detect(folderURL: selectedFolderURL)
        }
        defaults.set(newMode.rawValue, forKey: Keys.mode)
        pendingChanges = 0
        statusMessage = nil
        errorMessage = nil
        updateICloudObservation()
        lastSyncDate = state(for: newMode)?.lastSyncAt
        if isConfigured { await syncNow() }
    }

    func setHistorySyncEnabled(_ enabled: Bool) async {
        guard let historySyncPreferences,
              historySyncPreferences.isEnabled != enabled else { return }
        historySyncPreferences.isEnabled = enabled
        objectWillChange.send()
        if enabled, isConfigured, canUseSync {
            await syncNow()
        }
    }

    func setHistoryAudioSyncEnabled(_ enabled: Bool) {
        historySyncPreferences?.isAudioEnabled = enabled
        objectWillChange.send()
    }

    func clearFolder() {
        guard !isSyncing else { return }
        scheduledSyncTask?.cancel()
        selectedFolderURL = nil
        provider = .custom
        resetCustomSyncState()
        removeDefault(forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
        pendingChanges = 0
        devices = []
        deviceCount = 0
        statusMessage = nil
        errorMessage = nil
        if mode == .cloudFolder {
            mode = .off
            defaults.set(mode.rawValue, forKey: Keys.mode)
        }
    }

    func syncNow() async {
        if AppConstants.isScreenshotAutomation {
            isSyncing = false
            return
        }

        let syncMode = mode
        guard syncMode != .off else { return }
        guard canUseSync else {
            errorMessage = CloudFolderSyncError.notEntitled.localizedDescription
            return
        }
        guard let folderURL = activeFolderURL(for: syncMode) else { return }
        guard !isSyncing else {
            needsResync = true
            return
        }

        errorMessage = nil
        isSyncing = true
        let accessed = syncMode == .cloudFolder && folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                folderURL.stopAccessingSecurityScopedResource()
            }
            isSyncing = false
            if needsResync {
                needsResync = false
                Task { @MainActor [weak self] in
                    await self?.syncNow()
                }
            }
        }

        do {
            if syncMode == .automaticICloud {
                try await automaticICloudBridge.synchronize()
            }
            var syncState = state(for: syncMode) ?? CloudFolderSyncState()
            let result = try await CloudFolderSyncEngine.sync(
                folderURL: folderURL,
                store: syncStore,
                state: &syncState,
                entitlements: PaidEntitlements(canUseCloudFolderSync: canUseSync),
                historyOriginDeviceID: historySyncPreferences?.deviceID
            )
            setState(syncState, for: syncMode)
            if syncMode == .automaticICloud {
                try await automaticICloudBridge.synchronize()
            }
            let audioDiagnostics = await installPendingSynchronizedAudio(in: folderURL)
            guard mode == syncMode else { return }
            lastSyncDate = result.syncedAt
            pendingChanges = 0
            devices = result.devices
            deviceCount = devices.count
            let synchronizedChanges = result.operationsWritten + result.mutationsApplied
            let diagnostics = result.diagnostics + audioDiagnostics
            if diagnostics.isEmpty {
                statusMessage = String.localizedStringWithFormat(
                    String(localized: "Synced %lld changes."), Int64(synchronizedChanges)
                )
            } else {
                statusMessage = String.localizedStringWithFormat(
                    String(localized: "Synced %lld changes; skipped %lld invalid files."),
                    Int64(synchronizedChanges), Int64(diagnostics.count)
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectCustomFolder(_ url: URL) async {
        guard !isSyncing else { return }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if isConfigured, canUseSync { await syncNow() }
        guard !isSyncing else { return }
        if selectedFolderURL != url {
            scheduledSyncTask?.cancel()
            resetCustomSyncState()
            pendingChanges = 0
            statusMessage = nil
            errorMessage = nil
        }
        selectedFolderURL = url
        mode = .cloudFolder
        defaults.set(mode.rawValue, forKey: Keys.mode)
        provider = CloudFolderSyncProvider.detect(folderURL: url)
        saveDefault(bookmark, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
        await syncNow()
    }

    private func restoreSelectedFolder() {
        guard let data = migratedData(forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            selectedFolderURL = url
            provider = CloudFolderSyncProvider.detect(folderURL: url)
            if isStale {
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                saveDefault(bookmark, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
            } else if defaults.object(forKey: Keys.folderBookmark) == nil {
                saveDefault(data, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installLocalChangeObserver() {
        localChangeObserverId = syncStore.observeLocalChanges { [weak self] in
            self?.scheduleSyncAfterLocalChange()
        }
    }

    private func scheduleSyncAfterLocalChange() {
        guard isConfigured, canUseSync else { return }
        pendingChanges += 1
        if isSyncing {
            needsResync = true
            return
        }
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                await self?.syncNow()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func updateICloudObservation() {
        stopICloudObservation()
        guard mode == .automaticICloud, automaticICloudBridge.isAvailable else { return }
        automaticPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                    try Task.checkCancellation()
                    guard let self, self.mode == .automaticICloud, self.canUseSync else {
                        continue
                    }
                    await self.syncNow()
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    private func stopICloudObservation() {
        automaticPollTask?.cancel()
        automaticPollTask = nil
    }

    private func resetCustomSyncState() {
        customState = CloudFolderSyncState()
        lastSyncDate = nil
        removeDefault(forKey: Keys.syncState, legacyKey: Keys.legacySyncState)
    }

    private func saveState(_ state: CloudFolderSyncState, key: String, legacyKey: String? = nil) {
        guard let data = try? Self.encoder.encode(state) else { return }
        defaults.set(data, forKey: key)
        if let legacyKey { defaults.removeObject(forKey: legacyKey) }
    }

    private func migratedData(forKey key: String, legacyKey: String) -> Data? {
        if let data = defaults.data(forKey: key) {
            return data
        }
        return defaults.data(forKey: legacyKey)
    }

    private func saveDefault(_ value: Any, forKey key: String, legacyKey: String) {
        defaults.set(value, forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private func removeDefault(forKey key: String, legacyKey: String) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private static func loadState(from defaults: UserDefaults, key: String, legacyKey: String? = nil) -> CloudFolderSyncState {
        let data = defaults.data(forKey: key) ?? legacyKey.flatMap(defaults.data(forKey:))
        guard let data,
              let state = try? decoder.decode(CloudFolderSyncState.self, from: data) else {
            return CloudFolderSyncState()
        }
        return state
    }

    private func state(for mode: PremiumSyncMode) -> CloudFolderSyncState? {
        switch mode {
        case .off: nil
        case .automaticICloud: automaticState
        case .cloudFolder: customState
        }
    }

    private func setState(_ state: CloudFolderSyncState, for mode: PremiumSyncMode) {
        switch mode {
        case .off: return
        case .automaticICloud:
            automaticState = state
            saveState(state, key: Keys.automaticSyncState)
        case .cloudFolder:
            customState = state
            saveState(state, key: Keys.syncState, legacyKey: Keys.legacySyncState)
        }
    }

    private func activeFolderURL(for mode: PremiumSyncMode? = nil) -> URL? {
        switch mode ?? self.mode {
        case .off: return nil
        case .cloudFolder:
            guard let selectedFolderURL else {
                errorMessage = String(localized: "Choose a sync folder first.")
                return nil
            }
            return selectedFolderURL
        case .automaticICloud:
            guard let folderURL = automaticICloudBridge.localFolderURL else {
                errorMessage = PremiumICloudBridgeError.appGroupUnavailable.localizedDescription
                return nil
            }
            return folderURL
        }
    }

    func installPendingSynchronizedAudio(
        in folderURL: URL
    ) async -> [CloudFolderSyncDiagnostic] {
        guard let historySyncPreferences,
              historySyncPreferences.isEnabled,
              historySyncPreferences.isAudioEnabled,
              let historyService else {
            return []
        }
        let pending = historyService.records.compactMap { record -> (UUID, UserDataSyncHistoryAudioV1)? in
            guard historyService.audioFileURL(for: record) == nil,
                  let descriptor = historyService.synchronizedAudioDescriptor(for: record),
                  historySyncPreferences.shouldReceiveSynchronizedAudio(
                      createdAt: descriptor.createdAt
                  ) else {
                return nil
            }
            return (record.id, descriptor)
        }
        guard !pending.isEmpty else { return [] }

        let packageURL = CloudFolderSyncEngine.packageURL(for: folderURL)
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        for (recordID, descriptor) in pending {
            do {
                let sourceURL = try await Task.detached(priority: .utility) {
                    try await HistorySyncAssetStore.verifiedAssetURL(
                        packageURL: packageURL,
                        descriptor: descriptor
                    )
                }.value
                try historyService.installSynchronizedAudio(
                    recordID: recordID,
                    sourceURL: sourceURL
                )
            } catch {
                diagnostics.append(.init(
                    kind: .audioTransferFailed,
                    fileName: descriptor.relativeAssetPath
                ))
            }
        }
        return diagnostics
    }

    #if DEBUG
    func prepareScreenshotFixture(hasPremiumAccess: Bool) {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        stopICloudObservation()
        selectedFolderURL = nil
        mode = hasPremiumAccess ? .automaticICloud : .off
        provider = hasPremiumAccess ? .iCloudDrive : .custom
        lastSyncDate = hasPremiumAccess ? AppConstants.screenshotFixtureReferenceDate : nil
        pendingChanges = 0
        if AppConstants.screenshotState == "history" {
            deviceCount = 2
            devices = [
                CloudFolderSyncDeviceRecord(
                    deviceId: "screenshot-mac",
                    historyOriginDeviceID: historySyncPreferences?.deviceID
                        ?? "screenshot-mac-history",
                    platform: "macOS",
                    appVersion: "1.7.0",
                    updatedAt: AppConstants.screenshotFixtureReferenceDate,
                    name: "MacBook Pro"
                ),
                CloudFolderSyncDeviceRecord(
                    deviceId: "screenshot-iphone",
                    historyOriginDeviceID: "screenshot-iphone-history",
                    platform: "iOS",
                    appVersion: "1.1.0",
                    updatedAt: AppConstants.screenshotFixtureReferenceDate,
                    name: "iPhone 16 Pro"
                ),
            ]
        } else {
            deviceCount = hasPremiumAccess ? 2 : 0
            devices = []
        }
        isSyncing = false
        errorMessage = nil
        statusMessage = nil
    }
    #endif

    func deletePrivateSyncFolder() async {
        guard !isSyncing else { return }
        let deletedMode = mode
        guard let folderURL = activeFolderURL(for: deletedMode) else { return }
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        stopICloudObservation()
        mode = .off
        defaults.set(mode.rawValue, forKey: Keys.mode)
        pendingChanges = 0

        let accessed = deletedMode == .cloudFolder && folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            if deletedMode == .automaticICloud {
                try await automaticICloudBridge.deleteRemotePackage()
            }
            let packageURL = CloudFolderSyncEngine.packageURL(for: folderURL)
            if FileManager.default.fileExists(atPath: packageURL.path) { try FileManager.default.removeItem(at: packageURL) }
            setState(CloudFolderSyncState(), for: deletedMode)
            lastSyncDate = nil
            deviceCount = 0
            devices = []
            statusMessage = String(localized: "The private sync folder was deleted. Local data was kept.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct CloudFolderSyncSettingsView: View {
    @ObservedObject var controller: CloudFolderSyncController
    @State private var confirmingSyncFolderDeletion = false
    @State private var confirmingHistorySync = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "cloud",
                accent: .cyan,
                title: String(localized: "premium.hub.sync.title"),
                description: String(localized: "premium.window.sync.description"),
                status: statusText,
                statusColor: statusColor
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.sync.modeTitle"))
                        .font(.headline)

                    Picker(String(localized: "premium.window.sync.modePicker"), selection: Binding(
                        get: { controller.mode },
                        set: { mode in Task { await controller.setMode(mode) } }
                    )) {
                        ForEach(controller.availableModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(controller.isSyncing)
                    .accessibilityIdentifier("premium.sync.mode")

                    Toggle(
                        String(localized: "Sync History & Inbox"),
                        isOn: Binding(
                            get: { controller.historySyncPreferences?.isEnabled == true },
                            set: { enabled in
                                if enabled {
                                    confirmingHistorySync = true
                                } else {
                                    Task { await controller.setHistorySyncEnabled(false) }
                                }
                            }
                        )
                    )
                    .disabled(controller.mode == .off || controller.isSyncing)
                    .accessibilityIdentifier("premium.sync.history")

                    if controller.historySyncPreferences?.isEnabled == true {
                        Toggle(
                            String(localized: "Sync Audio for New Entries"),
                            isOn: Binding(
                                get: { controller.historySyncPreferences?.isAudioEnabled == true },
                                set: { controller.setHistoryAudioSyncEnabled($0) }
                            )
                        )
                        .disabled(controller.mode == .off || controller.isSyncing)
                        .accessibilityIdentifier("premium.sync.historyAudio")
                    }

                    Text(String(localized: "premium.window.sync.modeHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.sync.statusTitle"))
                        .font(.headline)

                    statusRow(title: String(localized: "premium.window.sync.provider"), value: controller.provider.displayName, systemImage: "cloud")
                    statusRow(title: String(localized: "premium.window.sync.folder"), value: controller.selectedFolderDisplayName, systemImage: "folder")
                    statusRow(title: String(localized: "premium.window.sync.lastSync"), value: lastSyncText, systemImage: "clock")
                    statusRow(title: String(localized: "premium.window.sync.pending"), value: "\(controller.pendingChanges)", systemImage: "arrow.triangle.2.circlepath")
                    statusRow(title: String(localized: "premium.window.sync.devices"), value: "\(controller.deviceCount)", systemImage: "laptopcomputer.and.iphone")
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.sync.actionsTitle"))
                        .font(.headline)

                    HStack(spacing: 8) {
                        Button {
                            controller.chooseFolder()
                        } label: {
                            Label(String(localized: "premium.window.sync.chooseFolder"), systemImage: "folder.badge.plus")
                        }
                        .disabled(!controller.canUseSync || controller.isSyncing)
                        .accessibilityIdentifier("premium.sync.chooseFolder")

                        Button {
                            Task { await controller.syncNow() }
                        } label: {
                            if controller.isSyncing {
                                Label(String(localized: "premium.window.sync.syncing"), systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label(String(localized: "premium.window.sync.syncNow"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(!controller.canUseSync || !controller.isConfigured || controller.isSyncing)
                        .accessibilityIdentifier("premium.sync.syncNow")

                        Button {
                            controller.clearFolder()
                        } label: {
                            Label(String(localized: "premium.window.sync.clear"), systemImage: "xmark.circle")
                        }
                        .disabled(controller.selectedFolderURL == nil || controller.isSyncing)
                        .accessibilityIdentifier("premium.sync.clearFolder")
                    }
                }
            }

            SettingsCard(accent: .red) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "premium.window.sync.deleteTitle"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "premium.window.sync.deleteHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button(role: .destructive) {
                        confirmingSyncFolderDeletion = true
                    } label: {
                        Label(String(localized: "premium.window.sync.deleteData"), systemImage: "trash")
                    }
                    .disabled(!controller.isConfigured || controller.isSyncing)
                    .accessibilityIdentifier("premium.sync.deleteData")
                }
            }

            if let status = controller.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .confirmationDialog(
            String(localized: "premium.window.sync.deleteConfirmationTitle"),
            isPresented: $confirmingSyncFolderDeletion
        ) {
            Button(String(localized: "premium.window.sync.deleteConfirmationAction"), role: .destructive) {
                Task { await controller.deletePrivateSyncFolder() }
            }
            Button(String(localized: "premium.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "premium.window.sync.deleteConfirmationMessage"))
        }
        .confirmationDialog(
            String(localized: "Sync History & Inbox?"),
            isPresented: $confirmingHistorySync
        ) {
            Button(String(localized: "Enable History Sync")) {
                Task { await controller.setHistorySyncEnabled(true) }
            }
            Button(String(localized: "premium.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Existing transcription text and metadata will be added to your private sync folder. Audio is synchronized only for new entries created after you enable this feature."))
        }
    }

    private func statusRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var lastSyncText: String {
        guard let date = controller.lastSyncDate else {
            return String(localized: "premium.window.sync.never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusText: String {
        if controller.isSyncing {
            return String(localized: "premium.window.sync.syncing")
        }
        return controller.mode.displayName
    }

    private var statusColor: Color {
        if controller.isSyncing {
            return .blue
        }
        return controller.mode == .off ? .secondary : .green
    }
}
