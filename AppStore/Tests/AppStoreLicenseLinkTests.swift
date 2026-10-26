import AuthenticationServices
import CryptoKit
import Security
import XCTest
@testable import TypeWhisper

private actor LicenseLinkHTTPRecorder {
    private let responses: [String: String]
    private(set) var requests: [URLRequest] = []

    init(responses: [String: String]) {
        self.responses = responses
    }

    func execute(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url,
              let body = responses[url.path],
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            throw URLError(.badServerResponse)
        }
        return (Data(body.utf8), response)
    }
}

@MainActor
private final class LicenseLinkWebAuthenticator: AppleWebAuthenticating {
    private(set) var openedURLs: [URL] = []
    private let result: (URL) throws -> URL

    init(result: @escaping (URL) throws -> URL) {
        self.result = result
    }

    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        XCTAssertEqual(callbackScheme, "typewhisper")
        openedURLs.append(authorizationURL)
        return try result(authorizationURL)
    }
}

final class AppStoreLicenseLinkTests: XCTestCase {
    private static let baseURL = URL(string: "https://app.typewhisper.com")!
    private static let startResponse = """
    {
      "authorizationURL": "https://app.typewhisper.com/premium/polar/link?state=link-state",
      "state": "link-state",
      "expiresAt": "2099-07-19T12:10:00.000Z"
    }
    """

    @MainActor
    func testConnectsExistingLicenseWithPKCEAndUnlocksPremium() async throws {
        let privateKey = P256.Signing.PrivateKey()
        let exchangeResponse = try JSONSerialization.data(withJSONObject: [
            "entitlement": try XCTUnwrap(JSONSerialization.jsonObject(
                with: Self.entitlementEncoder.encode(try Self.signedPolarEntitlement(privateKey: privateKey))
            ) as? [String: Any]),
        ])
        let recorder = LicenseLinkHTTPRecorder(responses: [
            "/v1/entitlements/polar/web/start": Self.startResponse,
            "/v1/entitlements/polar/web/exchange": try XCTUnwrap(String(data: exchangeResponse, encoding: .utf8)),
        ])
        let authenticator = LicenseLinkWebAuthenticator { _ in
            URL(string: "typewhisper://premium-license/callback?state=link-state&code=one-time-code")!
        }
        let service = try makeSignedInService(recorder: recorder, authenticator: authenticator, privateKey: privateKey)
        defer { service.signOut() }

        try await service.connectExistingLicense()

        XCTAssertTrue(service.hasPremiumEntitlement)
        XCTAssertEqual(service.entitlement?.source, "polar")
        XCTAssertFalse(service.isWorking)
        XCTAssertEqual(authenticator.openedURLs.map(\.absoluteString), [
            "https://app.typewhisper.com/premium/polar/link?state=link-state",
        ])

        let requests = await recorder.requests
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/v1/entitlements/polar/web/start",
            "/v1/entitlements/polar/web/exchange",
        ])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-TypeWhisper-Platform"), "macos")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        }
        let start = try Self.jsonBody(requests[0])
        let exchange = try Self.jsonBody(requests[1])
        XCTAssertEqual(start["deviceName"], "Mac")
        XCTAssertEqual(exchange["state"], "link-state")
        XCTAssertEqual(exchange["code"], "one-time-code")
        let verifier = try XCTUnwrap(exchange["codeVerifier"])
        XCTAssertEqual(start["codeChallenge"], Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    @MainActor
    func testRejectsALinkPageOutsideTheAccountServiceBeforeOpeningIt() async throws {
        let recorder = LicenseLinkHTTPRecorder(responses: [
            "/v1/entitlements/polar/web/start": Self.startResponse
                .replacingOccurrences(of: "app.typewhisper.com", with: "license.example.com"),
        ])
        let authenticator = LicenseLinkWebAuthenticator { _ in
            XCTFail("The link page must not be opened")
            throw URLError(.cancelled)
        }
        let service = try makeSignedInService(recorder: recorder, authenticator: authenticator)
        defer { service.signOut() }

        await assertLinkFailure(.invalidResponse) { try await service.connectExistingLicense() }
        XCTAssertTrue(authenticator.openedURLs.isEmpty)
        XCTAssertFalse(service.hasPremiumEntitlement)
    }

    @MainActor
    func testClosingTheLinkPageReportsCancellationWithoutExchange() async throws {
        let recorder = LicenseLinkHTTPRecorder(responses: [
            "/v1/entitlements/polar/web/start": Self.startResponse,
        ])
        let authenticator = LicenseLinkWebAuthenticator { _ in
            throw ASWebAuthenticationSessionError(.canceledLogin)
        }
        let service = try makeSignedInService(recorder: recorder, authenticator: authenticator)
        defer { service.signOut() }

        await assertLinkFailure(.cancelled) { try await service.connectExistingLicense() }
        let paths = await recorder.requests.compactMap(\.url?.path)
        XCTAssertEqual(paths, ["/v1/entitlements/polar/web/start"])
        XCTAssertTrue(service.isSignedIn)
    }

    func testCallbackMustMatchTheLinkAttempt() throws {
        func code(_ callback: String) throws -> String {
            try AppStoreLicenseLink.authorizationCode(from: URL(string: callback)!, expectedState: "link-state")
        }

        XCTAssertEqual(try code("typewhisper://premium-license/callback?state=link-state&code=abc"), "abc")
        XCTAssertThrowsError(try code("typewhisper://premium-license/callback?state=other&code=abc")) {
            XCTAssertEqual($0 as? AppStoreLicenseLink.Failure, .invalidResponse)
        }
        XCTAssertThrowsError(try code("typewhisper://premium-auth/callback?state=link-state&code=abc")) {
            XCTAssertEqual($0 as? AppStoreLicenseLink.Failure, .invalidResponse)
        }
        XCTAssertThrowsError(try code("typewhisper://premium-license/callback?state=link-state&error=rejected")) {
            XCTAssertEqual($0 as? AppStoreLicenseLink.Failure, .notConnected)
        }
        XCTAssertFalse(AppStoreLicenseLink.isValidLinkURL(
            URL(string: "https://app.typewhisper.com/premium/other?state=x")!,
            accountBaseURL: Self.baseURL
        ))
        XCTAssertFalse(AppStoreLicenseLink.isValidLinkURL(
            URL(string: "http://app.typewhisper.com/premium/polar/link?state=x")!,
            accountBaseURL: Self.baseURL
        ))
    }

    // MARK: - Helpers

    @MainActor
    private func makeSignedInService(
        recorder: LicenseLinkHTTPRecorder,
        authenticator: LicenseLinkWebAuthenticator,
        privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()
    ) throws -> PremiumAccountService {
        let suiteName = "AppStoreLicenseLink-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: suiteName,
            kSecAttrAccount as String: "access-token",
            kSecValueData as String: Data("account-token".utf8),
        ] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)

        return PremiumAccountService(
            defaults: defaults,
            baseURL: Self.baseURL,
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )
    }

    @MainActor
    private func assertLinkFailure(
        _ expected: AppStoreLicenseLink.Failure,
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AppStoreLicenseLink.Failure, expected, file: file, line: line)
        }
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
    }

    private static func signedPolarEntitlement(
        privateKey: P256.Signing.PrivateKey
    ) throws -> CrossDevicePremiumEntitlement {
        let unsigned = CrossDevicePremiumEntitlement(
            status: "active",
            tier: "individual",
            source: "polar",
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
