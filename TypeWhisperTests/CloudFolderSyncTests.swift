import CryptoKit
import XCTest
@testable import TypeWhisper

@MainActor
// @unchecked Sendable is safe here because @MainActor serializes all access in tests,
// so there are no concurrent cross-thread mutations. Revisit this if the store
// gains nonisolated mutable state or loses MainActor isolation.
private final class InMemoryUserDataSyncStore: UserDataSyncStore, @unchecked Sendable {
    var dictionaryEntries: [UserDataSyncDictionaryEntry]
    var snippets: [UserDataSyncSnippet]
    var historyRecords: [UserDataSyncHistoryRecord]
    var deletedHistoryRecords: [UserDataSyncHistoryDeletion]
    var appliedMutations: [UserDataSyncMutation] = []
    private var observers: [UUID: @MainActor @Sendable () -> Void] = [:]

    init(
        dictionaryEntries: [UserDataSyncDictionaryEntry] = [],
        snippets: [UserDataSyncSnippet] = [],
        historyRecords: [UserDataSyncHistoryRecord] = [],
        deletedHistoryRecords: [UserDataSyncHistoryDeletion] = []
    ) {
        self.dictionaryEntries = dictionaryEntries
        self.snippets = snippets
        self.historyRecords = historyRecords
        self.deletedHistoryRecords = deletedHistoryRecords
    }

    func snapshot() -> UserDataSyncSnapshot {
        UserDataSyncSnapshot(
            dictionaryEntries: dictionaryEntries,
            snippets: snippets,
            historyRecords: historyRecords,
            deletedHistoryRecords: deletedHistoryRecords
        )
    }

    func apply(_ mutations: [UserDataSyncMutation]) throws {
        appliedMutations.append(contentsOf: mutations)

        for mutation in mutations {
            switch mutation {
            case .upsertDictionary(let entry):
                let itemID = UserDataSyncIdentity.dictionaryItemID(entryType: entry.entryType, original: entry.original)
                let existing = dictionaryEntries.first {
                    UserDataSyncIdentity.dictionaryItemID(
                        entryType: $0.entryType,
                        original: $0.original
                    ) == itemID
                }
                dictionaryEntries.removeAll {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original) == itemID
                }
                if entry.entryType == .term,
                   !entry.ctcMinSimilarityFieldPresent {
                    dictionaryEntries.append(
                        UserDataSyncDictionaryEntry(
                            entryType: entry.entryType,
                            original: entry.original,
                            replacement: entry.replacement,
                            caseSensitive: entry.caseSensitive,
                            isEnabled: entry.isEnabled,
                            source: entry.source,
                            ctcMinSimilarity: existing?.ctcMinSimilarity,
                            createdAt: entry.createdAt,
                            updatedAt: entry.updatedAt
                        )
                    )
                } else {
                    dictionaryEntries.append(entry)
                }
            case .deleteDictionary(let itemID):
                dictionaryEntries.removeAll {
                    UserDataSyncIdentity.dictionaryItemID(entryType: $0.entryType, original: $0.original) == itemID
                }
            case .upsertSnippet(let snippet):
                let itemID = UserDataSyncIdentity.snippetItemID(trigger: snippet.trigger)
                snippets.removeAll {
                    UserDataSyncIdentity.snippetItemID(trigger: $0.trigger) == itemID
                }
                snippets.append(snippet)
            case .deleteSnippet(let itemID):
                snippets.removeAll {
                    UserDataSyncIdentity.snippetItemID(trigger: $0.trigger) == itemID
                }
            case .upsertHistoryContent(let content):
                upsertHistory(content: content)
            case .upsertHistoryInbox(let inbox):
                upsertHistory(inbox: inbox)
            case .upsertHistoryAudio(let audio):
                upsertHistory(audio: audio)
            case .deleteHistory(let recordID):
                historyRecords.removeAll { $0.content.recordID == recordID }
            }
        }
    }

    private func upsertHistory(content: UserDataSyncHistoryContentV1) {
        let existing = historyRecords.first { $0.content.recordID == content.recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: content,
                inbox: existing?.inbox ?? Self.placeholderInbox(
                    recordID: content.recordID,
                    updatedAt: content.createdAt
                ),
                audio: existing?.audio,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: existing?.audioEligible ?? false
            )
        )
    }

    private func upsertHistory(inbox: UserDataSyncHistoryInboxV1) {
        let existing = historyRecords.first { $0.content.recordID == inbox.recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: existing?.content ?? Self.placeholderContent(
                    recordID: inbox.recordID,
                    updatedAt: inbox.updatedAt
                ),
                inbox: inbox,
                audio: existing?.audio,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: existing?.audioEligible ?? false
            )
        )
    }

    private func upsertHistory(audio: UserDataSyncHistoryAudioV1) {
        let existing = historyRecords.first { $0.content.recordID == audio.recordID }
        replaceHistory(
            UserDataSyncHistoryRecord(
                content: existing?.content ?? Self.placeholderContent(
                    recordID: audio.recordID,
                    updatedAt: audio.createdAt
                ),
                inbox: existing?.inbox ?? Self.placeholderInbox(
                    recordID: audio.recordID,
                    updatedAt: audio.createdAt
                ),
                audio: audio,
                localAudioFileURL: existing?.localAudioFileURL,
                audioEligible: false
            )
        )
    }

    private func replaceHistory(_ record: UserDataSyncHistoryRecord) {
        historyRecords.removeAll { $0.content.recordID == record.content.recordID }
        historyRecords.append(record)
    }

    private static func placeholderContent(
        recordID: UUID,
        updatedAt: Date
    ) -> UserDataSyncHistoryContentV1 {
        UserDataSyncHistoryContentV1(
            recordID: recordID,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            originDeviceID: "remote",
            originPlatform: "unknown",
            source: "other",
            processingState: "importing",
            rawTranscript: "",
            finalText: "",
            durationSeconds: 0,
            engineDisplayName: "remote"
        )
    }

    private static func placeholderInbox(
        recordID: UUID,
        updatedAt: Date
    ) -> UserDataSyncHistoryInboxV1 {
        UserDataSyncHistoryInboxV1(
            recordID: recordID,
            updatedAt: updatedAt,
            state: "none",
            kind: nil,
            completionPolicy: .explicit,
            completedAt: nil,
            safeAction: nil
        )
    }

    @discardableResult
    func observeLocalChanges(_ handler: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeLocalChangeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func notifyLocalChange() {
        for observer in Array(observers.values) {
            observer()
        }
    }
}

private actor PremiumAccountHTTPRecorder {
    private let responses: [String: String]
    private let statusCodes: [String: Int]
    private(set) var requests: [URLRequest] = []

    init(
        responses: [String: String],
        statusCodes: [String: Int] = [:]
    ) {
        self.responses = responses
        self.statusCodes = statusCodes
    }

    func execute(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let body = responses[path],
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCodes[path] ?? 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            throw URLError(.badServerResponse)
        }
        return (Data(body.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private final class BlockingPremiumTokenReader: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var released = false
    private var storedReadCount = 0
    private var storedReadWasOnMainThread = false

    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    var readWasOnMainThread: Bool {
        lock.withLock { storedReadWasOnMainThread }
    }

    func read(service: String) -> String? {
        lock.withLock {
            storedReadCount += 1
            storedReadWasOnMainThread = Thread.isMainThread
        }
        releaseSemaphore.wait()
        return "stored-token"
    }

    func release() {
        let shouldSignal = lock.withLock {
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal {
            releaseSemaphore.signal()
        }
    }
}

private final class RecordingPremiumICloudBridge: PremiumICloudBridging, @unchecked Sendable {
    let isAvailable = true
    let localFolderURL: URL?

    private let lock = NSLock()
    private var storedSynchronizeCount = 0
    private var storedDeleteCount = 0

    var synchronizeCount: Int { lock.withLock { storedSynchronizeCount } }
    var deleteCount: Int { lock.withLock { storedDeleteCount } }

    init(localFolderURL: URL) {
        self.localFolderURL = localFolderURL
    }

    func synchronize() async throws {
        lock.withLock { storedSynchronizeCount += 1 }
    }

    func deleteRemotePackage() async throws {
        lock.withLock { storedDeleteCount += 1 }
    }
}

@MainActor
private final class PremiumAppleWebAuthenticator: AppleWebAuthenticating {
    private(set) var authorizationURLs: [URL] = []
    let callbackURL: URL

    init(callbackURL: URL) {
        self.callbackURL = callbackURL
    }

    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        authorizationURLs.append(authorizationURL)
        XCTAssertEqual(callbackScheme, "typewhisper")
        return callbackURL
    }
}

final class CloudFolderSyncTests: XCTestCase {
    @MainActor
    func testPremiumAccountDefersStartupTokenReadOffMainThread() async throws {
        let suiteName = "PremiumStartupToken-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reader = BlockingPremiumTokenReader()
        defer { reader.release() }

        let service = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: nil,
            automaticallyRefresh: false,
            startupTokenReader: { reader.read(service: $0) }
        )

        XCTAssertEqual(reader.readCount, 0)
        XCTAssertFalse(service.isSignedIn)

        for _ in 0..<100 {
            if reader.readCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertFalse(reader.readWasOnMainThread)
        XCTAssertFalse(service.isSignedIn)

        reader.release()
        for _ in 0..<100 {
            if service.isSignedIn { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(service.isSignedIn)
    }

    func testProductionPublicKeyStillVerifiesLegacyTwoDeviceEntitlement() throws {
        let response = """
        {
          "status": "active",
          "tier": "individual",
          "source": "storeKit",
          "isLifetime": false,
          "expiresAt": "2026-08-01T00:00:00Z",
          "deviceLimit": 2,
          "verifiedAt": "2026-07-16T12:00:00Z",
          "signature": "eyJzdGF0dXMiOiJhY3RpdmUiLCJ0aWVyIjoiaW5kaXZpZHVhbCIsInNvdXJjZSI6InN0b3JlS2l0IiwiaXNMaWZldGltZSI6ZmFsc2UsImV4cGlyZXNBdCI6IjIwMjYtMDgtMDFUMDA6MDA6MDBaIiwiZGV2aWNlTGltaXQiOjIsInZlcmlmaWVkQXQiOiIyMDI2LTA3LTE2VDEyOjAwOjAwWiJ9.zUbfGhBQzTCXdp3Epq0FKr_J-tX7PC_pGMN-X9G2LcNd7XiP_rW4PLObpJxY6lhJVLg1Oh-k9lHNPfkK4NmS5w"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entitlement = try decoder.decode(
            CrossDevicePremiumEntitlement.self,
            from: Data(response.utf8)
        )
        let verifier = try XCTUnwrap(CrossDevicePremiumEntitlementVerifier(
            publicKeyBase64: "8ZwFh+yrpkZZ1VsZgjpZcOz2h3jKpGG93MTdRaCPqXFn/Loqh8u36hB9FLho+ozwuHbaNeoN1MxM2/AJKyBNvQ=="
        ))

        XCTAssertEqual(verifier.verified(entitlement), entitlement)
    }

    @MainActor
    func testPremiumAccountAcceptsOnlyAuthenticallySignedCachedEntitlements() throws {
        let suiteName = "PremiumEntitlementSignature-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let privateKey = P256.Signing.PrivateKey()
        let valid = try Self.signedEntitlement(privateKey: privateKey)
        defaults.set(
            try Self.entitlementEncoder.encode(valid),
            forKey: "premium.account.cachedEntitlement"
        )

        let validService = PremiumAccountService(
            defaults: defaults,
            keychainService: "\(suiteName).valid",
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )
        XCTAssertEqual(validService.entitlement, valid)
        XCTAssertTrue(validService.hasPremiumEntitlement)

        let tampered = CrossDevicePremiumEntitlement(
            status: valid.status,
            tier: "enterprise",
            source: valid.source,
            isLifetime: valid.isLifetime,
            expiresAt: valid.expiresAt,
            deviceLimit: valid.deviceLimit,
            verifiedAt: valid.verifiedAt,
            signature: valid.signature
        )
        defaults.set(
            try Self.entitlementEncoder.encode(tampered),
            forKey: "premium.account.cachedEntitlement"
        )

        let tamperedService = PremiumAccountService(
            defaults: defaults,
            keychainService: "\(suiteName).tampered",
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )
        XCTAssertNil(tamperedService.entitlement)
        XCTAssertFalse(tamperedService.hasPremiumEntitlement)
        XCTAssertNil(defaults.data(forKey: "premium.account.cachedEntitlement"))
    }

    @MainActor
    func testPremiumAccountRefreshesRecentMissingEntitlementAfterPurchase() async throws {
        let suiteName = "PremiumMissingEntitlementRefresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let privateKey = P256.Signing.PrivateKey()
        let entitlement = try Self.signedEntitlement(privateKey: privateKey)
        let entitlementObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.entitlementEncoder.encode(entitlement)
            ) as? [String: Any]
        )
        let responseData = try JSONSerialization.data(
            withJSONObject: ["entitlement": entitlementObject]
        )
        let recorder = PremiumAccountHTTPRecorder(responses: [
            "/v1/auth/apple/web/start": """
            {
              "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
              "state": "server-state",
              "expiresAt": "2099-07-19T12:10:00.000Z"
            }
            """,
            "/v1/auth/apple/web/exchange": """
            {"accessToken": "account-token", "entitlement": null}
            """,
            "/v1/entitlements/polar/device/attach": """
            {"entitlement": null}
            """,
            "/v1/entitlements/current": try XCTUnwrap(
                String(data: responseData, encoding: .utf8)
            ),
        ])
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=server-state&code=exchange-code"
            ))
        )

        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        defer { service.signOut() }

        await service.signInWithApple(
            commercialLicenseProof: CommercialLicenseLinkProof(
                key: "polar-license",
                activationId: "polar-activation"
            )
        )
        XCTAssertTrue(service.isSignedIn)
        XCTAssertNil(service.entitlement)
        defaults.set(Date(), forKey: "premium.account.lastRefresh")

        await service.refreshIfNeeded()

        XCTAssertEqual(service.entitlement, entitlement)
        XCTAssertTrue(service.hasPremiumEntitlement)
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(
            requests.compactMap(\.url?.path),
            [
                "/v1/auth/apple/web/start",
                "/v1/auth/apple/web/exchange",
                "/v1/entitlements/polar/device/attach",
                "/v1/entitlements/current",
            ]
        )
    }

    @MainActor
    func testPremiumAccountKeepsRecentActiveEntitlementRefreshThrottled() async throws {
        let suiteName = "PremiumActiveEntitlementRefresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let privateKey = P256.Signing.PrivateKey()
        let entitlement = try Self.signedEntitlement(privateKey: privateKey)
        defaults.set(
            try Self.entitlementEncoder.encode(entitlement),
            forKey: "premium.account.cachedEntitlement"
        )
        defaults.set(Date(), forKey: "premium.account.lastRefresh")
        let recorder = PremiumAccountHTTPRecorder(responses: [:])
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            keychainService: suiteName,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )

        await service.refreshIfNeeded()

        XCTAssertEqual(service.entitlement, entitlement)
        let requests = await recorder.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testPremiumAccountLinksCommercialLicenseAfterSignIn() async throws {
        let suiteName = "PremiumCommercialLink-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let privateKey = P256.Signing.PrivateKey()
        let entitlement = try Self.signedEntitlement(privateKey: privateKey)
        let entitlementObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.entitlementEncoder.encode(entitlement)
            ) as? [String: Any]
        )
        let attachResponse = try JSONSerialization.data(
            withJSONObject: ["entitlement": entitlementObject]
        )
        let recorder = PremiumAccountHTTPRecorder(responses: [
            "/v1/auth/apple/web/start": """
            {
              "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
              "state": "server-state",
              "expiresAt": "2099-07-19T12:10:00.000Z"
            }
            """,
            "/v1/auth/apple/web/exchange": """
            {"accessToken": "account-token", "entitlement": null}
            """,
            "/v1/entitlements/current": """
            {"entitlement": null}
            """,
            "/v1/entitlements/polar/device/attach": try XCTUnwrap(
                String(data: attachResponse, encoding: .utf8)
            ),
        ])
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=server-state&code=exchange-code"
            ))
        )
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        defer { service.signOut() }

        await service.signInWithApple(commercialLicenseProof: nil)
        XCTAssertTrue(service.isSignedIn)
        XCTAssertFalse(service.hasPremiumEntitlement)

        await service.linkCommercialLicense(
            CommercialLicenseLinkProof(
                key: "polar-license",
                activationId: "polar-activation"
            )
        )

        XCTAssertEqual(service.entitlement, entitlement)
        XCTAssertTrue(service.hasPremiumEntitlement)
        XCTAssertNil(service.errorMessage)
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(
            requests.compactMap(\.url?.path),
            [
                "/v1/auth/apple/web/start",
                "/v1/auth/apple/web/exchange",
                "/v1/entitlements/current",
                "/v1/entitlements/polar/device/attach",
            ]
        )
    }

    @MainActor
    func testAuthorizationFailureClearsSignedEntitlementButTransientFailureDoesNot() throws {
        let suiteName = "PremiumEntitlementAuthorization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let privateKey = P256.Signing.PrivateKey()
        let entitlement = try Self.signedEntitlement(privateKey: privateKey)
        defaults.set(
            try Self.entitlementEncoder.encode(entitlement),
            forKey: "premium.account.cachedEntitlement"
        )

        let service = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )

        service.clearAuthorizationForHTTPStatus(503)
        XCTAssertTrue(service.isSignedIn)
        XCTAssertEqual(service.entitlement, entitlement)

        service.clearAuthorizationForHTTPStatus(401)
        XCTAssertFalse(service.isSignedIn)
        XCTAssertNil(service.entitlement)
        XCTAssertNil(defaults.data(forKey: "premium.account.cachedEntitlement"))
    }

    @MainActor
    func testPremiumAccountUsesAppleWebAuthWithStatePKCEAndAttachesExistingPolarActivation() async throws {
        let suiteName = "PremiumAppleWebAuth-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = PremiumAccountHTTPRecorder(responses: [
            "/v1/auth/apple/web/start": """
            {
              "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
              "state": "server-state",
              "expiresAt": "2099-07-19T12:10:00.000Z"
            }
            """,
            "/v1/auth/apple/web/exchange": """
            {"accessToken": "account-token", "entitlement": null}
            """,
            "/v1/entitlements/polar/device/attach": """
            {"entitlement": null}
            """,
            "/v1/entitlements/polar/device/current": """
            {"ok": true, "released": false}
            """,
        ])
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=server-state&code=exchange-code"
            ))
        )
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        defer { service.signOut() }

        await service.signInWithApple(
            commercialLicenseProof: CommercialLicenseLinkProof(
                key: "polar-license",
                activationId: "polar-activation"
            )
        )

        XCTAssertTrue(service.isSignedIn)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(
            authenticator.authorizationURLs.map(\.host),
            ["appleid.apple.com"]
        )
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(
            requests.compactMap(\.url?.path),
            [
                "/v1/auth/apple/web/start",
                "/v1/auth/apple/web/exchange",
                "/v1/entitlements/polar/device/attach",
            ]
        )

        let startRequest = try XCTUnwrap(
            requests.first { $0.url?.path == "/v1/auth/apple/web/start" }
        )
        let exchangeRequest = try XCTUnwrap(
            requests.first { $0.url?.path == "/v1/auth/apple/web/exchange" }
        )
        let attachRequest = try XCTUnwrap(
            requests.first {
                $0.url?.path == "/v1/entitlements/polar/device/attach"
            }
        )

        let startBody = try XCTUnwrap(startRequest.httpBody)
        let startJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: startBody) as? [String: String]
        )
        XCTAssertEqual(startJSON["nonceHash"]?.count, 64)
        XCTAssertTrue(startJSON["nonceHash"]?.allSatisfy(\.isHexDigit) == true)

        let exchangeBody = try XCTUnwrap(exchangeRequest.httpBody)
        let exchangeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exchangeBody) as? [String: String]
        )
        XCTAssertEqual(exchangeJSON["state"], "server-state")
        XCTAssertEqual(exchangeJSON["code"], "exchange-code")
        let verifier = try XCTUnwrap(exchangeJSON["codeVerifier"])
        let expectedChallenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(startJSON["codeChallenge"], expectedChallenge)
        XCTAssertEqual(
            attachRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer account-token"
        )
        XCTAssertEqual(
            attachRequest.value(
                forHTTPHeaderField: "X-TypeWhisper-Entitlement-Version"
            ),
            "2"
        )
        let attachBody = try XCTUnwrap(attachRequest.httpBody)
        let attachJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: attachBody)
                as? [String: String]
        )
        XCTAssertEqual(attachJSON["licenseKey"], "polar-license")
        XCTAssertEqual(attachJSON["activationId"], "polar-activation")

        await service.signOutFromAccount()
        XCTAssertFalse(service.isSignedIn)
        let finalRequests = await recorder.recordedRequests()
        XCTAssertEqual(
            finalRequests.last?.url?.path,
            "/v1/entitlements/polar/device/current"
        )
        XCTAssertEqual(finalRequests.last?.httpMethod, "DELETE")
    }

    @MainActor
    func testPremiumAccountRollsBackSessionWhenPolarAttachmentFails() async throws {
        let suiteName = "PremiumAppleWebAuthAttachFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = PremiumAccountHTTPRecorder(
            responses: [
                "/v1/auth/apple/web/start": """
                {
                  "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
                  "state": "server-state",
                  "expiresAt": "2099-07-19T12:10:00.000Z"
                }
                """,
                "/v1/auth/apple/web/exchange": """
                {"accessToken": "account-token", "entitlement": null}
                """,
                "/v1/entitlements/polar/device/attach": """
                {"error": "Polar activation could not be attached."}
                """,
            ],
            statusCodes: [
                "/v1/entitlements/polar/device/attach": 503,
            ]
        )
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=server-state&code=exchange-code"
            ))
        )
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        defer { service.signOut() }

        await service.signInWithApple(
            commercialLicenseProof: CommercialLicenseLinkProof(
                key: "polar-license",
                activationId: "polar-activation"
            )
        )

        XCTAssertFalse(service.isSignedIn)
        XCTAssertNil(service.entitlement)
        XCTAssertEqual(
            service.errorMessage,
            "Polar activation could not be attached."
        )
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(
            requests.compactMap(\.url?.path),
            [
                "/v1/auth/apple/web/start",
                "/v1/auth/apple/web/exchange",
                "/v1/entitlements/polar/device/attach",
            ]
        )
    }

    @MainActor
    func testPremiumAccountKeepsAppleCancellationSilent() async throws {
        let suiteName = "PremiumAppleWebAuthCancel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = PremiumAccountHTTPRecorder(responses: [
            "/v1/auth/apple/web/start": """
            {
              "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
              "state": "server-state",
              "expiresAt": "2099-07-19T12:10:00.000Z"
            }
            """,
        ])
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=server-state&error=user_cancelled_authorize"
            ))
        )
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )

        await service.signInWithApple(commercialLicenseProof: nil)

        XCTAssertFalse(service.isSignedIn)
        XCTAssertNil(service.errorMessage)
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testPremiumAccountRejectsMismatchedAppleCallbackState() async throws {
        let suiteName = "PremiumAppleWebAuthStateMismatch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = PremiumAccountHTTPRecorder(responses: [
            "/v1/auth/apple/web/start": """
            {
              "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
              "state": "server-state",
              "expiresAt": "2099-07-19T12:10:00.000Z"
            }
            """,
        ])
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=wrong-state&code=exchange-code"
            ))
        )
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )

        await service.signInWithApple(commercialLicenseProof: nil)

        XCTAssertFalse(service.isSignedIn)
        XCTAssertNotNil(service.errorMessage)
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.compactMap(\.url?.path), ["/v1/auth/apple/web/start"])
    }

    @MainActor
    func testPremiumAccountRejectsExpiredAppleWebStart() async throws {
        let suiteName = "PremiumAppleWebAuthExpired-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recorder = PremiumAccountHTTPRecorder(responses: [
            "/v1/auth/apple/web/start": """
            {
              "authorizationURL": "https://appleid.apple.com/auth/authorize?state=server-state",
              "state": "server-state",
              "expiresAt": "2020-07-19T12:10:00.000Z"
            }
            """,
        ])
        let authenticator = PremiumAppleWebAuthenticator(
            callbackURL: try XCTUnwrap(URL(
                string: "typewhisper://premium-auth/callback?state=server-state&code=exchange-code"
            ))
        )
        let service = PremiumAccountService(
            defaults: defaults,
            baseURL: URL(string: "https://app.typewhisper.com"),
            requestExecutor: { request in try await recorder.execute(request) },
            appleWebAuthenticator: authenticator,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )

        await service.signInWithApple(commercialLicenseProof: nil)

        XCTAssertFalse(service.isSignedIn)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(authenticator.authorizationURLs.isEmpty)
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.compactMap(\.url?.path), ["/v1/auth/apple/web/start"])
    }

    @MainActor
    func testAutomaticSyncStateSurvivesModeToggle() async throws {
        let suiteName = "PremiumSyncModeState-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expectedState = CloudFolderSyncState(
            deviceId: "mac-existing",
            knownLocalItemIDs: ["dictionary:term:typewhisper"],
            exportedItemVersions: ["dictionary:term:typewhisper": "v1"],
            appliedOperationIDs: ["remote-operation"],
            lastSyncAt: Self.date(20)
        )
        defaults.set(
            try Self.stateEncoder.encode(expectedState),
            forKey: "premiumSync.iCloudState"
        )
        defaults.set(PremiumSyncMode.off.rawValue, forKey: "premiumSync.mode")

        let account = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        let store = InMemoryUserDataSyncStore()
        let controller = CloudFolderSyncController(
            premiumAccountService: account,
            syncStore: store,
            defaults: defaults
        )
        defer { controller.deactivate() }

        await controller.setMode(.automaticICloud)

        let persistedData = try XCTUnwrap(defaults.data(forKey: "premiumSync.iCloudState"))
        XCTAssertEqual(try Self.stateDecoder.decode(CloudFolderSyncState.self, from: persistedData), expectedState)
    }

    @MainActor
    func testAutomaticSyncMirrorsThroughBridgeBeforeAndAfterEngine() async throws {
        let suiteName = "PremiumSyncBridge-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncBridge")
        defer { TestSupport.remove(folder) }

        let privateKey = P256.Signing.PrivateKey()
        let entitlement = try Self.signedEntitlement(privateKey: privateKey)
        defaults.set(
            try Self.entitlementEncoder.encode(entitlement),
            forKey: "premium.account.cachedEntitlement"
        )
        defaults.set(PremiumSyncMode.off.rawValue, forKey: "premiumSync.mode")

        let account = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            entitlementPublicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            isSignedInOverride: true,
            automaticallyRefresh: false
        )
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            UserDataSyncDictionaryEntry(
                entryType: .term,
                original: "bridge-test",
                replacement: "Bridge Test",
                caseSensitive: false,
                isEnabled: true,
                source: .manual,
                ctcMinSimilarity: nil,
                createdAt: Self.date(10),
                updatedAt: Self.date(10)
            ),
        ])
        let bridge = RecordingPremiumICloudBridge(localFolderURL: folder)
        let controller = CloudFolderSyncController(
            premiumAccountService: account,
            syncStore: store,
            defaults: defaults,
            automaticICloudBridge: bridge,
            automaticICloudAvailable: true
        )
        defer { controller.deactivate() }

        await controller.setMode(.automaticICloud)

        XCTAssertEqual(bridge.synchronizeCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CloudFolderSyncEngine.packageURL(for: folder).path
        ))
        XCTAssertNil(controller.errorMessage)
    }

    @MainActor
    func testNoICloudBuildHidesAutomaticModeWithoutOverwritingStoredChoice() async throws {
        let suiteName = "PremiumSyncNoICloud-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PremiumSyncMode.automaticICloud.rawValue, forKey: "premiumSync.mode")

        let account = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        let controller = CloudFolderSyncController(
            premiumAccountService: account,
            syncStore: InMemoryUserDataSyncStore(),
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }

        XCTAssertEqual(controller.availableModes, [.off, .cloudFolder])
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(defaults.string(forKey: "premiumSync.mode"), PremiumSyncMode.automaticICloud.rawValue)

        await controller.setMode(.automaticICloud)

        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(defaults.string(forKey: "premiumSync.mode"), PremiumSyncMode.automaticICloud.rawValue)
    }

    @MainActor
    func testDeletingPrivateFolderStopsSyncBeforeRemovingPackage() async throws {
        let suiteName = "PremiumSyncDelete-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "PremiumSyncDelete")
        defer { TestSupport.remove(folder) }

        let bookmark = try folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: "cloudFolderSync.folderBookmark")
        defaults.set(PremiumSyncMode.cloudFolder.rawValue, forKey: "premiumSync.mode")
        let packageURL = CloudFolderSyncEngine.packageURL(for: folder)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        let account = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        let store = InMemoryUserDataSyncStore()
        let controller = CloudFolderSyncController(
            premiumAccountService: account,
            syncStore: store,
            defaults: defaults
        )
        defer { controller.deactivate() }

        await controller.deletePrivateSyncFolder()
        store.notifyLocalChange()
        await Task.yield()

        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
    }

    func testICloudBridgeMirrorCopiesBothDirectionsAndKeepsNewestContent() throws {
        let localRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeLocal")
        let remoteRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeRemote")
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }

        let localPackage = localRoot.appendingPathComponent("typewhisper-sync", isDirectory: true)
        let remotePackage = remoteRoot.appendingPathComponent("typewhisper-sync", isDirectory: true)
        let localOnly = localPackage.appendingPathComponent("ops/mac/local.json")
        let remoteOnly = remotePackage.appendingPathComponent("ops/ios/remote.json")
        let localManifest = localPackage.appendingPathComponent("manifest.json")
        let remoteManifest = remotePackage.appendingPathComponent("manifest.json")

        for file in [localOnly, remoteOnly, localManifest, remoteManifest] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("local-operation".utf8).write(to: localOnly)
        try Data("remote-operation".utf8).write(to: remoteOnly)
        try Data("old-local".utf8).write(to: localManifest)
        try Data("new-remote".utf8).write(to: remoteManifest)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(10)],
            ofItemAtPath: localManifest.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(20)],
            ofItemAtPath: remoteManifest.path
        )

        try PremiumICloudBridgeFileMirror.synchronize(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )

        XCTAssertEqual(try Data(contentsOf: remotePackage.appendingPathComponent("ops/mac/local.json")), Data("local-operation".utf8))
        XCTAssertEqual(try Data(contentsOf: localPackage.appendingPathComponent("ops/ios/remote.json")), Data("remote-operation".utf8))
        XCTAssertEqual(try Data(contentsOf: localManifest), Data("new-remote".utf8))
        XCTAssertEqual(try Data(contentsOf: remoteManifest), Data("new-remote".utf8))

        try Data("newest-local".utf8).write(to: localManifest)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.date(30)],
            ofItemAtPath: localManifest.path
        )
        try PremiumICloudBridgeFileMirror.synchronize(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )

        XCTAssertEqual(try Data(contentsOf: remoteManifest), Data("newest-local".utf8))
    }

    func testICloudBridgeUsesConfiguredContainerIdentifier() {
        XCTAssertEqual(
            PremiumICloudBridgeConstants.containerIdentifier(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        "iCloud.com.typewhisper.sync.dev"
                ]
            ),
            "iCloud.com.typewhisper.sync.dev"
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.containerIdentifier(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        "$(ICLOUD_CONTAINER_ID)"
                ]
            ),
            PremiumICloudBridgeConstants.productionContainerIdentifier
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.containerIdentifier(
                infoDictionary: nil
            ),
            PremiumICloudBridgeConstants.productionContainerIdentifier
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.serviceBundleIdentifier(
                infoDictionary: [
                    PremiumICloudBridgeConstants
                        .serviceBundleIdentifierInfoKey:
                        "com.typewhisper.mac.dev.icloudbridge"
                ]
            ),
            "com.typewhisper.mac.dev.icloudbridge"
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.serviceBundleIdentifier(
                infoDictionary: nil
            ),
            PremiumICloudBridgeConstants.productionServiceBundleIdentifier
        )
    }

    func testICloudBridgeSeparatesNonProductionLocalMirror() {
        XCTAssertNil(
            PremiumICloudBridgeConstants.localMirrorNamespace(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        PremiumICloudBridgeConstants.productionContainerIdentifier,
                ]
            )
        )
        XCTAssertEqual(
            PremiumICloudBridgeConstants.localMirrorNamespace(
                infoDictionary: [
                    PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                        "iCloud.com.typewhisper.sync.dev",
                ]
            ),
            "iCloud.com.typewhisper.sync.dev"
        )
        for invalidIdentifier in [".", "..", "nested/container", "nested\\container"] {
            XCTAssertNil(
                PremiumICloudBridgeConstants.localMirrorNamespace(
                    infoDictionary: [
                        PremiumICloudBridgeConstants.containerIdentifierInfoKey:
                            invalidIdentifier,
                    ]
                )
            )
        }
    }

    func testICloudBridgeDeletionRemovesOnlySyncPackages() throws {
        let localRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeDeleteLocal")
        let remoteRoot = try TestSupport.makeTemporaryDirectory(prefix: "ICloudBridgeDeleteRemote")
        defer {
            TestSupport.remove(localRoot)
            TestSupport.remove(remoteRoot)
        }
        let unrelated = remoteRoot.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        for root in [localRoot, remoteRoot] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("typewhisper-sync", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try PremiumICloudBridgeFileMirror.deletePackages(
            localRoot: localRoot,
            remoteRoot: remoteRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: localRoot.appendingPathComponent("typewhisper-sync").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: remoteRoot.appendingPathComponent("typewhisper-sync").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCrossPlatformGoldenFixturesDecode() throws {
        let upsert: CloudFolderSyncOperation = try Self.decodeFixture("upsert-dictionary-v1")
        XCTAssertEqual(upsert.dictionary?.source, .autoLearned)

        let deletion: CloudFolderSyncOperation = try Self.decodeFixture("delete-snippet-v1")
        XCTAssertEqual(deletion.kind, .delete)
        XCTAssertEqual(deletion.deviceId, "fixture-iphone")

        let device: CloudFolderSyncDeviceRecord = try Self.decodeFixture("device-v1")
        XCTAssertEqual(device.platform, "macOS")
        XCTAssertNil(device.historyOriginDeviceID)

        let legacy: CloudFolderSyncOperation = try Self.decodeFixture("upsert-snippet-legacy-v1")
        XCTAssertEqual(legacy.snippet?.tags, [])

        let ctc: CloudFolderSyncOperation = try Self.decodeFixture(
            "upsert-dictionary-ctc-v1"
        )
        XCTAssertEqual(ctc.dictionary?.ctcMinSimilarity, 0.65)
        XCTAssertEqual(
            ctc.dictionary?.ctcMinSimilarityFieldPresent,
            true
        )

        let unknown: CloudFolderSyncOperation = try Self.decodeFixture("unknown-schema")
        XCTAssertEqual(unknown.schemaVersion, 2)
        XCTAssertTrue(CloudFolderSyncEngine.winningOperations(from: [unknown]).isEmpty)
    }

    @MainActor
    func testDeviceMetadataKeepsTransportAndHistoryOriginIDsSeparate() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDeviceIdentity")
        defer { TestSupport.remove(folder) }
        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-transport")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            historyOriginDeviceID: "mac-history-origin",
            now: Self.date(20)
        )

        let device = try XCTUnwrap(result.devices.first)
        XCTAssertEqual(device.deviceId, "mac-transport")
        XCTAssertEqual(device.historyOriginDeviceID, "mac-history-origin")
        XCTAssertEqual(device.platform, "macOS")
    }

    func testDeviceCatalogDeduplicatesHistoryIdentityAndSkipsMalformedFiles() throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDeviceCatalog")
        defer { TestSupport.remove(folder) }
        let devicesURL = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("devices", isDirectory: true)
        try FileManager.default.createDirectory(at: devicesURL, withIntermediateDirectories: true)
        let older = CloudFolderSyncDeviceRecord(
            deviceId: "transport-old",
            historyOriginDeviceID: "history-device",
            platform: "iOS",
            appVersion: "1",
            updatedAt: Self.date(10),
            name: "Old Name"
        )
        let newer = CloudFolderSyncDeviceRecord(
            deviceId: "transport-new",
            historyOriginDeviceID: "history-device",
            platform: "iOS",
            appVersion: "2",
            updatedAt: Self.date(20),
            name: "Marco's iPhone"
        )
        try Self.entitlementEncoder.encode(older).write(
            to: devicesURL.appendingPathComponent("old.json")
        )
        try Self.entitlementEncoder.encode(newer).write(
            to: devicesURL.appendingPathComponent("new.json")
        )
        try Data("not-json".utf8).write(
            to: devicesURL.appendingPathComponent("broken.json")
        )

        let result = try CloudFolderSyncEngine.readDevices(from: devicesURL)

        XCTAssertEqual(result.devices, [newer])
        XCTAssertEqual(result.diagnostics, [
            .init(kind: .malformedDevice, fileName: "broken.json"),
        ])
    }

    @MainActor
    func testDeterministicItemIDsUseNaturalKeys() {
        XCTAssertEqual(
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: " TypeWhisper "),
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "typewhisper")
        )
        XCTAssertEqual(
            UserDataSyncIdentity.snippetItemID(trigger: "Résumé"),
            UserDataSyncIdentity.snippetItemID(trigger: "resume")
        )
        XCTAssertNotEqual(
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "same"),
            UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.correction, original: "same")
        )
    }

    @MainActor
    func testProviderDetectionFromFolderPath() {
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Users/marco/Library/Mobile Documents/com~apple~CloudDocs")),
            .iCloudDrive
        )
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Users/marco/OneDrive - Example")),
            .oneDrive
        )
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Users/marco/Dropbox/TypeWhisper")),
            .dropbox
        )
        XCTAssertEqual(
            CloudFolderSyncProvider.detect(folderURL: URL(fileURLWithPath: "/Volumes/Sync")),
            .custom
        )
    }

    @MainActor
    func testSnippetPlaceholderCompatibilityKeepsBothDialects() {
        let currentYear = Calendar.current.component(.year, from: Date()).description
        let snippet = Snippet(
            trigger: ";date",
            replacement: "{{DATE:yyyy}}|{date:yyyy}|{year}|{day}"
        )

        let output = snippet.processedReplacement()
        let parts = output.split(separator: "|").map(String.init)

        XCTAssertEqual(parts[0], currentYear)
        XCTAssertEqual(parts[1], currentYear)
        XCTAssertEqual(parts[2], currentYear)
        XCTAssertFalse(output.contains("{{DATE"))
        XCTAssertFalse(output.contains("{date"))
        XCTAssertFalse(output.contains("{day}"))
    }

    @MainActor
    func testUnpaidSyncDoesNotCreateFiles() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncUnpaid")
        defer { TestSupport.remove(folder) }

        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        ])
        var state = CloudFolderSyncState(deviceId: "mac-a")

        do {
            _ = try await CloudFolderSyncEngine.sync(
                folderURL: folder,
                store: store,
                state: &state,
                entitlements: PaidEntitlements(canUseCloudFolderSync: false),
                now: Self.date(20)
            )
            XCTFail("Expected unpaid sync to throw")
        } catch CloudFolderSyncError.notEntitled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: CloudFolderSyncEngine.packageURL(for: folder).path))
        }
    }

    @MainActor
    func testExportCollapsesDuplicateNaturalKeysToNewestRecord() {
        let older = Self.snippet(trigger: ";SIG", replacement: "Old", updatedAt: Self.date(10))
        let newer = Self.snippet(trigger: ";sig", replacement: "New", updatedAt: Self.date(20))

        let records = CloudFolderSyncEngine.records(
            from: UserDataSyncSnapshot(snippets: [older, newer])
        )

        let itemID = UserDataSyncIdentity.snippetItemID(trigger: ";sig")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[itemID]?.snippet?.replacement, "New")
    }

    @MainActor
    func testOperationEncodingPreservesFractionalSeconds() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncFractional")
        defer { TestSupport.remove(folder) }

        let updatedAt = Date(timeIntervalSince1970: 1_700_000_010.456)
        let deviceAStore = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: updatedAt)
        ])
        let deviceBStore = InMemoryUserDataSyncStore()
        var deviceAState = CloudFolderSyncState(deviceId: "mac-a")
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        let operationFile = try XCTUnwrap(Self.operationFiles(folder: folder, deviceId: "mac-a").first)
        let operationJSON = try String(contentsOf: operationFile, encoding: .utf8)
        XCTAssertTrue(operationJSON.contains(".456"))

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )

        let syncedUpdatedAt = try XCTUnwrap(deviceBStore.dictionaryEntries.first?.updatedAt)
        XCTAssertEqual(syncedUpdatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    @MainActor
    func testMalformedOperationFileIsSkipped() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncMalformed")
        defer { TestSupport.remove(folder) }

        let remoteDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: remoteDirectory.appendingPathComponent("bad.json"))

        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        XCTAssertEqual(result.mutationsApplied, 0)
        XCTAssertEqual(result.diagnostics.map(\.kind), [.malformedOperation])
    }

    @MainActor
    func testFutureSchemaIsDiagnosedBeforeFullOperationDecoding() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncFutureSchema")
        defer { TestSupport.remove(folder) }

        let remoteDirectory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops/remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":2}"#.utf8)
            .write(to: remoteDirectory.appendingPathComponent("future.json"))

        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        XCTAssertEqual(result.diagnostics.map(\.kind), [.unsupportedSchema])
    }

    func testMissingOperationsDirectoryThrowsInsteadOfReportingEmptySync() throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncMissingOperations")
        defer { TestSupport.remove(folder) }

        XCTAssertThrowsError(
            try CloudFolderSyncEngine.readOperations(
                from: folder.appendingPathComponent("missing", isDirectory: true)
            )
        )
    }

    func testUnreadableDeviceDirectoryProducesDiagnostic() throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncUnreadableDevice")
        defer { TestSupport.remove(folder) }
        let deviceDirectory = folder.appendingPathComponent("remote-device", isDirectory: true)
        try FileManager.default.createDirectory(at: deviceDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0)],
            ofItemAtPath: deviceDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: deviceDirectory.path
            )
        }

        let result = try CloudFolderSyncEngine.readOperations(from: folder)

        XCTAssertEqual(
            result.diagnostics,
            [.init(kind: .unreadableFile, fileName: "remote-device")]
        )
    }

    @MainActor
    func testConcurrentLocalEditRemainsPendingForNextSync() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncConcurrentEdit")
        defer { TestSupport.remove(folder) }

        let original = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        let edited = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(30))
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [original])
        let editDuringFileIO: @Sendable () async -> Void = {
            await MainActor.run {
                store.dictionaryEntries = [edited]
            }
        }
        var state = CloudFolderSyncState(deviceId: "mac-a")

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20),
            afterFileIO: editDuringFileIO
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(40)
        )

        XCTAssertEqual(firstResult.operationsWritten, 1)
        XCTAssertEqual(secondResult.operationsWritten, 1)
        XCTAssertEqual(
            state.exportedItemVersions[
                UserDataSyncIdentity.dictionaryItemID(
                    entryType: UserDataSyncDictionaryEntryType.term,
                    original: "TypeWhisper"
                )
            ],
            CloudFolderSyncEngine.records(from: store.snapshot()).values.first?.version
        )
    }

    @MainActor
    func testTwoSimulatedDevicesShareAppendOnlyOperations() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncTwoDevices")
        defer { TestSupport.remove(folder) }

        let firstEntry = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        let deviceAStore = InMemoryUserDataSyncStore(dictionaryEntries: [firstEntry])
        let deviceBStore = InMemoryUserDataSyncStore()
        var deviceAState = CloudFolderSyncState(deviceId: "mac-a")
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )

        XCTAssertEqual(firstResult.operationsWritten, 1)
        XCTAssertEqual(secondResult.mutationsApplied, 1)
        XCTAssertEqual(deviceBStore.dictionaryEntries.map(\.original), ["TypeWhisper"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: CloudFolderSyncEngine.packageURL(for: folder)
                    .appendingPathComponent("ops/mac-a", isDirectory: true)
                    .path
            )
        )
    }

    @MainActor
    func testHistoryContentAndInboxSyncAsIndependentComponents() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryComponents")
        defer { TestSupport.remove(folder) }

        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000001")!
        let initial = Self.historyRecord(
            recordID: recordID,
            finalText: "Watch capture",
            contentUpdatedAt: Self.date(10),
            inboxState: "open",
            inboxUpdatedAt: Self.date(10)
        )
        let watch = InMemoryUserDataSyncStore(historyRecords: [initial])
        let mac = InMemoryUserDataSyncStore()
        var watchState = CloudFolderSyncState(deviceId: "ios-watch")
        var macState = CloudFolderSyncState(deviceId: "mac-main")

        let exported = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: watch,
            state: &watchState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        let imported = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: mac,
            state: &macState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )

        XCTAssertEqual(exported.operationsWritten, 2)
        XCTAssertEqual(imported.mutationsApplied, 2)
        XCTAssertEqual(mac.historyRecords.first?.content.finalText, "Watch capture")
        XCTAssertEqual(mac.historyRecords.first?.inbox.state, "open")

        let importedRecord = try XCTUnwrap(mac.historyRecords.first)
        mac.historyRecords = [UserDataSyncHistoryRecord(
            content: importedRecord.content,
            inbox: UserDataSyncHistoryInboxV1(
                recordID: recordID,
                updatedAt: Self.date(40),
                state: "completed",
                kind: "watchRecording",
                completionPolicy: .onOpen,
                completedAt: Self.date(40),
                safeAction: nil
            ),
            audio: importedRecord.audio,
            localAudioFileURL: nil,
            audioEligible: false
        )]

        let completionExport = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: mac,
            state: &macState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(50)
        )
        let completionImport = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: watch,
            state: &watchState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(60)
        )

        XCTAssertEqual(completionExport.operationsWritten, 1)
        XCTAssertEqual(completionImport.mutationsApplied, 1)
        XCTAssertEqual(watch.historyRecords.first?.content.finalText, "Watch capture")
        XCTAssertEqual(watch.historyRecords.first?.inbox.state, "completed")
    }

    @MainActor
    func testHistoryRetentionAbsenceDoesNotDeleteButExplicitJournalDoes() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryDeletion")
        defer { TestSupport.remove(folder) }

        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000002")!
        let record = Self.historyRecord(
            recordID: recordID,
            finalText: "Keep on the other device",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let first = InMemoryUserDataSyncStore(historyRecords: [record])
        let second = InMemoryUserDataSyncStore()
        var firstState = CloudFolderSyncState(deviceId: "ios-a")
        var secondState = CloudFolderSyncState(deviceId: "mac-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )
        XCTAssertEqual(second.historyRecords.count, 1)

        first.historyRecords = []
        let retentionPass = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(35)
        )
        XCTAssertEqual(retentionPass.operationsWritten, 0)

        first.deletedHistoryRecords = [
            UserDataSyncHistoryDeletion(recordID: recordID, deletedAt: Self.date(40))
        ]
        let deletionPass = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(45)
        )
        let deletionImport = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(50)
        )

        XCTAssertEqual(deletionPass.operationsWritten, 1)
        XCTAssertEqual(deletionImport.mutationsApplied, 1)
        XCTAssertTrue(second.historyRecords.isEmpty)
    }

    func testHistoryAudioAssetsUseContentAddressingAndVerifyIntegrity() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHistoryAudio")
        defer { TestSupport.remove(folder) }
        let packageURL = CloudFolderSyncEngine.packageURL(for: folder)
        let sourceURL = folder.appendingPathComponent("capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03]).write(to: sourceURL)
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000003")!

        let descriptor = try HistorySyncAssetStore.publish(
            sourceURL: sourceURL,
            packageURL: packageURL,
            generation: "history-v1",
            recordID: recordID,
            updatedAt: Self.date(10),
            durationSeconds: 1.25
        )
        let verified = try await HistorySyncAssetStore.verifiedAssetURL(
            packageURL: packageURL,
            descriptor: descriptor
        )

        XCTAssertTrue(descriptor.isValid)
        XCTAssertEqual(descriptor.byteCount, 7)
        XCTAssertTrue(descriptor.relativeAssetPath.hasSuffix("/\(descriptor.sha256).wav"))
        XCTAssertEqual(try Data(contentsOf: verified), try Data(contentsOf: sourceURL))

        let unsafe = UserDataSyncHistoryAudioV1(
            recordID: recordID,
            updatedAt: Self.date(10),
            relativeAssetPath: "../capture.wav",
            mediaType: "audio/wav",
            byteCount: 7,
            sha256: descriptor.sha256,
            createdAt: Self.date(10),
            durationSeconds: 1.25
        )
        do {
            _ = try await HistorySyncAssetStore.verifiedAssetURL(
                packageURL: packageURL,
                descriptor: unsafe
            )
            XCTFail("Expected an unsafe asset path to be rejected")
        } catch HistorySyncAssetStoreError.invalidDescriptor {
            // Expected.
        }

        let outsideURL = folder.appendingPathComponent("outside.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: outsideURL)
        let symlinkURL = packageURL
            .appendingPathComponent("assets/history", isDirectory: true)
            .appendingPathComponent("escaped.wav")
        try FileManager.default.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideURL
        )
        let outsideDigest = try HistorySyncAssetStore.sha256AndSize(of: outsideURL)
        let symlinkDescriptor = UserDataSyncHistoryAudioV1(
            recordID: recordID,
            updatedAt: Self.date(10),
            relativeAssetPath: "assets/history/escaped.wav",
            mediaType: "audio/wav",
            byteCount: outsideDigest.byteCount,
            sha256: outsideDigest.sha256,
            createdAt: Self.date(10),
            durationSeconds: 1.25
        )
        do {
            _ = try await HistorySyncAssetStore.verifiedAssetURL(
                packageURL: packageURL,
                descriptor: symlinkDescriptor
            )
            XCTFail("Expected a symlink outside the sync package to be rejected")
        } catch HistorySyncAssetStoreError.invalidDescriptor {
            // Expected.
        }
    }

    @MainActor
    func testHistoryAudioPublishFailureDoesNotAbortTextSync() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAudioFailure")
        defer { TestSupport.remove(folder) }
        let record = Self.historyRecord(
            recordID: UUID(),
            finalText: "Text survives missing audio",
            contentUpdatedAt: Self.date(10),
            inboxState: "none",
            inboxUpdatedAt: Self.date(10)
        )
        let missingAudio = folder.appendingPathComponent("missing.wav")
        let store = InMemoryUserDataSyncStore(historyRecords: [
            UserDataSyncHistoryRecord(
                content: record.content,
                inbox: record.inbox,
                audio: nil,
                localAudioFileURL: missingAudio,
                audioEligible: true
            ),
        ])
        var state = CloudFolderSyncState(deviceId: "mac-audio-failure")

        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        XCTAssertEqual(result.operationsWritten, 2)
        XCTAssertEqual(
            result.diagnostics,
            [CloudFolderSyncDiagnostic(kind: .audioTransferFailed, fileName: "missing.wav")]
        )
    }

    @MainActor
    func testControllerAutomaticallyInstallsVerifiedSynchronizedAudio() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAutomaticAudio")
        defer { TestSupport.remove(folder) }
        let historyDirectory = folder.appendingPathComponent("history", isDirectory: true)
        let suiteName = "CloudFolderSyncAutomaticAudio-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.isAudioEnabled = true
        let historyService = HistoryService(
            appSupportDirectory: historyDirectory,
            historySyncPreferences: preferences
        )
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000030")!
        let sourceURL = folder.appendingPathComponent("capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x09, 0x08, 0x07]).write(to: sourceURL)
        let descriptor = try HistorySyncAssetStore.publish(
            sourceURL: sourceURL,
            packageURL: CloudFolderSyncEngine.packageURL(for: folder),
            generation: "history-v1",
            recordID: recordID,
            updatedAt: Date(),
            durationSeconds: 1.5
        )
        try historyService.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: Self.date(1),
                updatedAt: Self.date(10),
                originDeviceID: "ios-history-origin",
                originPlatform: "iOS",
                source: RecordingSource.iPhone.rawValue,
                processingState: RecordingProcessingState.ready.rawValue,
                rawTranscript: "Audio note",
                finalText: "Audio note",
                durationSeconds: 1.5,
                detectedLanguage: "en",
                engineDisplayName: "Apple Speech"
            )),
            .upsertHistoryAudio(descriptor),
        ])
        let account = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        let controller = CloudFolderSyncController(
            premiumAccountService: account,
            syncStore: InMemoryUserDataSyncStore(),
            historyService: historyService,
            historySyncPreferences: preferences,
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }

        let diagnostics = await controller.installPendingSynchronizedAudio(in: folder)

        XCTAssertTrue(diagnostics.isEmpty)
        let record = try XCTUnwrap(historyService.records.first { $0.id == recordID })
        let installedURL = try XCTUnwrap(historyService.audioFileURL(for: record))
        XCTAssertEqual(try Data(contentsOf: installedURL), try Data(contentsOf: sourceURL))
    }

    @MainActor
    func testControllerDoesNotBackfillAudioFromBeforeAudioSyncWasEnabled() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncNoAudioBackfill")
        defer { TestSupport.remove(folder) }
        let historyDirectory = folder.appendingPathComponent("history", isDirectory: true)
        let suiteName = "CloudFolderSyncNoAudioBackfill-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        preferences.isAudioEnabled = false
        let historyService = HistoryService(
            appSupportDirectory: historyDirectory,
            historySyncPreferences: preferences
        )
        let recordID = UUID(uuidString: "83600000-0000-4000-8000-000000000031")!
        let sourceURL = folder.appendingPathComponent("old-capture.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x01]).write(to: sourceURL)
        let oldDate = Date().addingTimeInterval(-24 * 60 * 60)
        let descriptor = try HistorySyncAssetStore.publish(
            sourceURL: sourceURL,
            packageURL: CloudFolderSyncEngine.packageURL(for: folder),
            generation: "history-v1",
            recordID: recordID,
            updatedAt: oldDate,
            durationSeconds: 1
        )
        try historyService.applyUserDataSyncMutations([
            .upsertHistoryContent(UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: oldDate,
                updatedAt: oldDate,
                originDeviceID: "ios-history-origin",
                originPlatform: "iOS",
                source: RecordingSource.iPhone.rawValue,
                processingState: RecordingProcessingState.ready.rawValue,
                rawTranscript: "Old audio note",
                finalText: "Old audio note",
                durationSeconds: 1,
                engineDisplayName: "Apple Speech"
            )),
            .upsertHistoryAudio(descriptor),
        ])
        preferences.isAudioEnabled = true
        let account = PremiumAccountService(
            defaults: defaults,
            keychainService: suiteName,
            isSignedInOverride: false,
            automaticallyRefresh: false
        )
        let controller = CloudFolderSyncController(
            premiumAccountService: account,
            syncStore: InMemoryUserDataSyncStore(),
            historyService: historyService,
            historySyncPreferences: preferences,
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }

        let diagnostics = await controller.installPendingSynchronizedAudio(in: folder)

        XCTAssertTrue(diagnostics.isEmpty)
        let record = try XCTUnwrap(historyService.records.first { $0.id == recordID })
        XCTAssertNil(historyService.audioFileURL(for: record))
    }

    @MainActor
    func testDeleteTombstoneWinsOverOlderLocalItem() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDelete")
        defer { TestSupport.remove(folder) }

        let snippet = Self.snippet(trigger: ";sig", replacement: "Regards", updatedAt: Self.date(10))
        let deviceAStore = InMemoryUserDataSyncStore(snippets: [snippet])
        var deviceAState = CloudFolderSyncState(deviceId: "mac-a")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        deviceAStore.snippets = []
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )

        let deviceBStore = InMemoryUserDataSyncStore(snippets: [snippet])
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")
        let result = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(40)
        )

        XCTAssertEqual(result.mutationsApplied, 1)
        XCTAssertTrue(deviceBStore.snippets.isEmpty)
    }

    @MainActor
    func testAlreadyAppliedRemoteOperationIsNotAppliedAgain() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncApplied")
        defer { TestSupport.remove(folder) }

        let entry = Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10))
        let deviceAStore = InMemoryUserDataSyncStore(dictionaryEntries: [entry])
        let deviceBStore = InMemoryUserDataSyncStore()
        var deviceAState = CloudFolderSyncState(deviceId: "mac-z")
        var deviceBState = CloudFolderSyncState(deviceId: "mac-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceAStore,
            state: &deviceAState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )

        let firstResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )
        let secondResult = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: deviceBStore,
            state: &deviceBState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(40)
        )

        XCTAssertEqual(firstResult.mutationsApplied, 1)
        XCTAssertEqual(secondResult.mutationsApplied, 0)
        XCTAssertEqual(deviceBStore.appliedMutations.count, 1)
    }

    @MainActor
    func testExpiredLocalTombstonesArePrunedAfterRetentionWindow() async throws {
        let folder = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncTombstoneRetention")
        defer { TestSupport.remove(folder) }

        let itemID = UserDataSyncIdentity.snippetItemID(trigger: ";sig")
        let store = InMemoryUserDataSyncStore()
        var state = CloudFolderSyncState(deviceId: "mac-a", knownLocalItemIDs: [itemID])

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(10)
        )
        XCTAssertEqual(Self.operationFiles(folder: folder, deviceId: "mac-a").count, 1)

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(10 + 91 * 24 * 60 * 60)
        )

        XCTAssertTrue(Self.operationFiles(folder: folder, deviceId: "mac-a").isEmpty)
    }

    @MainActor
    func testConflictTieBreakerUsesUpdatedAtThenDeviceId() {
        let older = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(10)),
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "TypeWhisper"),
            deviceId: "mac-z",
            operationId: "older"
        )
        let newer = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(20)),
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "TypeWhisper"),
            deviceId: "mac-a",
            operationId: "newer"
        )
        let sameTimeHigherDevice = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(original: "TypeWhisper", updatedAt: Self.date(20)),
            itemID: UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "TypeWhisper"),
            deviceId: "mac-z",
            operationId: "tie"
        )

        let winner = CloudFolderSyncEngine.winningOperations(from: [older, newer, sameTimeHigherDevice]).values.first
        XCTAssertEqual(winner?.operationId, "tie")
    }

    func testTermEncodingUsesExplicitNullAndLegacyDecodingTracksAbsence()
        throws
    {
        let automatic = Self.dictionaryEntry(
            original: "Automatic",
            updatedAt: Self.date(10)
        )
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Self.entitlementEncoder.encode(automatic)
            ) as? [String: Any]
        )
        XCTAssertTrue(encoded["ctcMinSimilarity"] is NSNull)

        let legacyData = Data(
            """
            {
              "entryType": "term",
              "original": "Legacy",
              "caseSensitive": false,
              "isEnabled": true,
              "createdAt": "2023-11-14T22:13:21.000Z",
              "updatedAt": "2023-11-14T22:13:30.000Z"
            }
            """.utf8
        )
        let legacy = try Self.fixtureDecoder.decode(
            UserDataSyncDictionaryEntry.self,
            from: legacyData
        )
        XCTAssertNil(legacy.ctcMinSimilarity)
        XCTAssertFalse(legacy.ctcMinSimilarityFieldPresent)
    }

    @MainActor
    func testExplicitCTCFieldWinsEqualTimestampBeforeDeviceID() {
        let itemID = UserDataSyncIdentity.dictionaryItemID(
            entryType: UserDataSyncDictionaryEntryType.term,
            original: "TypeWhisper"
        )
        let explicit = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(20),
                ctcMinSimilarity: 0.65
            ),
            itemID: itemID,
            deviceId: "mac-a",
            operationId: "explicit"
        )
        let legacy = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(20),
                ctcMinSimilarityFieldPresent: false
            ),
            itemID: itemID,
            deviceId: "mac-z",
            operationId: "legacy"
        )

        XCTAssertEqual(
            CloudFolderSyncEngine.winningOperations(
                from: [legacy, explicit]
            )[itemID]?.operationId,
            "explicit"
        )
    }

    @MainActor
    func testCTCValueAndExplicitNullRoundTripAcrossTwoDevices()
        async throws
    {
        let folder = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncCTCRoundTrip"
        )
        defer { TestSupport.remove(folder) }
        let first = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(10),
                ctcMinSimilarity: 0.65
            )
        ])
        let second = InMemoryUserDataSyncStore()
        var firstState = CloudFolderSyncState(deviceId: "mac-a")
        var secondState = CloudFolderSyncState(deviceId: "ios-b")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(20)
        )
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )
        XCTAssertEqual(
            second.dictionaryEntries.first?.ctcMinSimilarity,
            0.65
        )

        second.dictionaryEntries = [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(40)
            )
        ]
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: second,
            state: &secondState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(50)
        )
        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: first,
            state: &firstState,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(60)
        )

        XCTAssertNil(first.dictionaryEntries.first?.ctcMinSimilarity)
        XCTAssertEqual(
            first.dictionaryEntries.first?.ctcMinSimilarityFieldPresent,
            true
        )
    }

    @MainActor
    func testLegacyCTCFieldPreservesValueAndRepublishesOnce()
        async throws
    {
        let folder = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncLegacyCTC"
        )
        defer { TestSupport.remove(folder) }
        let store = InMemoryUserDataSyncStore(dictionaryEntries: [
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(10),
                ctcMinSimilarity: 0.8
            )
        ])
        let legacy = CloudFolderSyncOperation.upsertDictionary(
            Self.dictionaryEntry(
                original: "TypeWhisper",
                updatedAt: Self.date(20),
                ctcMinSimilarityFieldPresent: false
            ),
            itemID: UserDataSyncIdentity.dictionaryItemID(
                entryType: UserDataSyncDictionaryEntryType.term,
                original: "TypeWhisper"
            ),
            deviceId: "legacy-ios",
            operationId: "legacy"
        )
        try Self.writeLegacyOperation(legacy, to: folder)
        var state = CloudFolderSyncState(deviceId: "mac-a")

        _ = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(25)
        )
        XCTAssertEqual(
            store.dictionaryEntries.first?.ctcMinSimilarity,
            0.8
        )
        let itemID = UserDataSyncIdentity.dictionaryItemID(
            entryType: UserDataSyncDictionaryEntryType.term,
            original: "TypeWhisper"
        )
        XCTAssertNil(state.exportedItemVersions[itemID])

        let republish = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(30)
        )
        let repeated = try await CloudFolderSyncEngine.sync(
            folderURL: folder,
            store: store,
            state: &state,
            entitlements: PaidEntitlements(canUseCloudFolderSync: true),
            now: Self.date(35)
        )
        XCTAssertEqual(republish.operationsWritten, 1)
        XCTAssertEqual(repeated.operationsWritten, 0)
    }

    @MainActor
    func testLegacyMutationDoesNotOverwriteStoredCTC() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncStoredCTC"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let service = DictionaryService(
            appSupportDirectory: appSupportDirectory
        )
        service.addEntry(
            type: .term,
            original: "TypeWhisper",
            ctcMinSimilarity: 0.8
        )
        try service.applyUserDataSyncMutations([
            .upsertDictionary(
                Self.dictionaryEntry(
                    original: "TypeWhisper",
                    updatedAt: Self.date(20),
                    ctcMinSimilarityFieldPresent: false
                )
            )
        ])

        XCTAssertEqual(service.entries.first?.ctcMinSimilarity, 0.8)
        XCTAssertTrue(
            service.userDataSyncEntries().first?
                .ctcMinSimilarityFieldPresent == true
        )
    }

    @MainActor
    func testHostStoreSnapshotsObserversBeforeNotifying() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncObservers")
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )

        var firstObserverID: UUID?
        var firstCalls = 0
        var secondCalls = 0

        firstObserverID = store.observeLocalChanges {
            firstCalls += 1
            if let firstObserverID {
                store.removeLocalChangeObserver(firstObserverID)
            }
        }
        store.observeLocalChanges {
            secondCalls += 1
        }

        dictionaryService.addEntry(type: .term, original: "First")
        dictionaryService.addEntry(type: .term, original: "Second")

        XCTAssertEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, 2)
    }

    @MainActor
    func testHistoryJournalObserverSeesPostChangeSnapshot() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(
            prefix: "CloudFolderSyncHistoryJournalObserver"
        )
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "CloudFolderSyncHistoryJournalObserver-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let historyService = HistoryService(
            appSupportDirectory: appSupportDirectory,
            historySyncPreferences: preferences
        )
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            snippetService: SnippetService(appSupportDirectory: appSupportDirectory),
            historyService: historyService,
            historySyncPreferences: preferences,
            defaults: defaults
        )
        let recordID = UUID()
        let notified = expectation(description: "Journal change notification")
        var observedDeletion = false
        let observerID = store.observeLocalChanges {
            observedDeletion = store.snapshot().deletedHistoryRecords.contains {
                $0.recordID == recordID
            }
            notified.fulfill()
        }
        defer { store.removeLocalChangeObserver(observerID) }

        preferences.recordExplicitDeletion(recordID)
        await fulfillment(of: [notified], timeout: 1)

        XCTAssertTrue(observedDeletion)
    }

    @MainActor
    func testHistorySyncPreferencesDefaultAudioOffAndPruneExpiredSuppressions() throws {
        let suiteName = "CloudFolderSyncHistoryPreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expiredID = UUID()
        let expiredSuppressions = [
            expiredID.uuidString.lowercased(): Date().addingTimeInterval(-91 * 24 * 60 * 60),
        ]
        defaults.set(
            try JSONEncoder().encode(expiredSuppressions),
            forKey: "premiumSync.historySuppressedRecordIDs"
        )

        let preferences = HistorySyncPreferences(defaults: defaults)

        XCTAssertFalse(preferences.isAudioEnabled)
        XCTAssertFalse(preferences.isSuppressed(expiredID))
    }

    func testHistoryPayloadDecodingSanitizesForwardCompatibleValues() throws {
        let recordID = UUID()
        let content = UserDataSyncHistoryContentV1(
            recordID: recordID,
            createdAt: Self.date(1),
            updatedAt: Self.date(2),
            originDeviceID: "ios-origin",
            originPlatform: "iOS",
            source: "iPhone",
            processingState: "ready",
            rawTranscript: "Test",
            finalText: "Test",
            durationSeconds: 5,
            engineDisplayName: "test"
        )
        var contentJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as? [String: Any]
        )
        contentJSON["durationSeconds"] = -5
        let decodedContent = try JSONDecoder().decode(
            UserDataSyncHistoryContentV1.self,
            from: JSONSerialization.data(withJSONObject: contentJSON)
        )

        let inbox = UserDataSyncHistoryInboxV1(
            recordID: recordID,
            updatedAt: Self.date(2),
            state: "open",
            kind: nil,
            completionPolicy: .explicit,
            completedAt: nil,
            safeAction: nil
        )
        var inboxJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(inbox)) as? [String: Any]
        )
        inboxJSON["completionPolicy"] = "futurePolicy"
        let decodedInbox = try JSONDecoder().decode(
            UserDataSyncHistoryInboxV1.self,
            from: JSONSerialization.data(withJSONObject: inboxJSON)
        )
        let localRecord = UserDataSyncHistoryRecord(
            content: content,
            inbox: inbox,
            audio: nil,
            localAudioFileURL: URL(fileURLWithPath: "/private/local.wav"),
            audioEligible: true
        )
        let encodedRecord = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(localRecord)) as? [String: Any]
        )

        XCTAssertEqual(decodedContent.durationSeconds, 0)
        XCTAssertEqual(decodedInbox.completionPolicy, .explicit)
        XCTAssertNil(encodedRecord["localAudioFileURL"])
        XCTAssertNil(encodedRecord["audioEligible"])
    }

    @MainActor
    func testHostStoreExcludesManagedEntriesAndPreservesUserAuthoredData() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncHostStore")
        defer { TestSupport.remove(appSupportDirectory) }

        let suiteName = "CloudFolderSyncHostStore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .term, original: "ManualTerm")
        dictionaryService.addEntry(type: .term, original: "ManagedTerm")
        dictionaryService.addEntry(type: .correction, original: "filler", replacement: "")
        snippetService.addSnippet(trigger: ";sig", replacement: "{date:yyyy}")
        _ = dictionaryService.applyCorrections(to: "filler")
        _ = snippetService.applySnippets(to: ";sig")

        let state = ActivatedTermPackState(
            packID: "managed-pack",
            source: "test",
            installedVersion: "1",
            installedTerms: ["ManagedTerm"],
            installedCorrections: [],
            requiresCommercialLicense: false
        )
        defaults.set(try JSONEncoder().encode([state]), forKey: UserDefaultsKeys.activatedTermPackStates)

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            defaults: defaults
        )
        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.dictionaryEntries.filter { $0.original == "ManualTerm" }.count, 1)
        XCTAssertFalse(snapshot.dictionaryEntries.contains { $0.original == "ManagedTerm" })
        XCTAssertEqual(snapshot.dictionaryEntries.first { $0.original == "filler" }?.replacement, "")
        XCTAssertEqual(snapshot.snippets.first?.replacement, "{date:yyyy}")
    }

    @MainActor
    func testHostStorePreservesAutoLearnedDictionarySource() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncAutoLearnedSource")
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.learnCorrection(original: "recieve", replacement: "receive")

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )

        XCTAssertEqual(store.snapshot().dictionaryEntries.first?.source, .autoLearned)

        try store.apply([
            .upsertDictionary(Self.dictionaryEntry(
                entryType: .correction,
                original: "langauge",
                replacement: "language",
                source: .autoLearned,
                updatedAt: Self.date(30)
            ))
        ])

        XCTAssertEqual(
            dictionaryService.entries.first { $0.original == "langauge" }?.source,
            .autoLearned
        )
    }

    @MainActor
    func testDictionaryResetActionsKeepHostSnapshotConsistent() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncDictionaryReset")
        defer { TestSupport.remove(appSupportDirectory) }

        let suiteName = "CloudFolderSyncDictionaryReset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .term, original: "ManualBeforeReset")
        dictionaryService.learnCorrection(original: "recieve", replacement: "receive")

        let viewModel = DictionaryViewModel(dictionaryService: dictionaryService, defaults: defaults)
        let pack = TermPack(
            id: "sync-reset-pack",
            name: "Sync Reset Pack",
            description: "Sync reset test pack",
            icon: "shippingbox",
            terms: ["ManagedPackTerm"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        viewModel.activatePack(pack)

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            defaults: defaults
        )

        viewModel.requestReset(.resetCustomDictionary)
        viewModel.confirmReset()
        XCTAssertTrue(store.snapshot().dictionaryEntries.isEmpty)
        XCTAssertEqual(dictionaryService.entries.map(\.original), ["ManagedPackTerm"])

        dictionaryService.addEntry(type: .term, original: "ManualAfterReset")
        dictionaryService.learnCorrection(original: "langauge", replacement: "language")
        viewModel.requestReset(.deactivateAllTermPacks)
        viewModel.confirmReset()

        let snapshot = store.snapshot()
        XCTAssertEqual(Set(snapshot.dictionaryEntries.map(\.original)), ["ManualAfterReset", "langauge"])
        XCTAssertFalse(dictionaryService.entries.contains { $0.original == "ManagedPackTerm" })
        XCTAssertTrue(viewModel.activatedPackStates.isEmpty)
    }

    @MainActor
    func testHostApplyMergesDuplicateNaturalKeys() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory(prefix: "CloudFolderSyncMerge")
        defer { TestSupport.remove(appSupportDirectory) }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .term, original: "TypeWhisper")
        snippetService.addSnippet(trigger: ";sig", replacement: "Old")

        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionaryService,
            snippetService: snippetService
        )

        try store.apply([
            .upsertDictionary(Self.dictionaryEntry(original: " typewhisper ", updatedAt: Self.date(30))),
            .upsertSnippet(Self.snippet(trigger: ";SIG", replacement: "New", updatedAt: Self.date(30)))
        ])

        let dictionaryMatches = dictionaryService.entries.filter {
            UserDataSyncIdentity.dictionaryItemID(entryType: $0.type, original: $0.original)
                == UserDataSyncIdentity.dictionaryItemID(entryType: UserDataSyncDictionaryEntryType.term, original: "typewhisper")
        }
        let snippetMatches = snippetService.snippets.filter {
            UserDataSyncIdentity.snippetItemID(trigger: $0.trigger)
                == UserDataSyncIdentity.snippetItemID(trigger: ";sig")
        }

        XCTAssertEqual(dictionaryMatches.count, 1)
        XCTAssertEqual(dictionaryMatches.first?.original, " typewhisper ")
        XCTAssertEqual(snippetMatches.count, 1)
        XCTAssertEqual(snippetMatches.first?.replacement, "New")
    }

    private static func dictionaryEntry(
        entryType: UserDataSyncDictionaryEntryType = .term,
        original: String,
        replacement: String? = nil,
        source: DictionaryEntrySource? = nil,
        updatedAt: Date,
        ctcMinSimilarity: Float? = nil,
        ctcMinSimilarityFieldPresent: Bool? = nil
    ) -> UserDataSyncDictionaryEntry {
        UserDataSyncDictionaryEntry(
            entryType: entryType,
            original: original,
            replacement: replacement,
            caseSensitive: false,
            isEnabled: true,
            source: source,
            ctcMinSimilarity: ctcMinSimilarity,
            ctcMinSimilarityFieldPresent:
                ctcMinSimilarityFieldPresent,
            createdAt: date(1),
            updatedAt: updatedAt
        )
    }

    private static func writeLegacyOperation(
        _ operation: CloudFolderSyncOperation,
        to folder: URL
    ) throws {
        let directory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent(
                "ops/\(operation.deviceId)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoded = try entitlementEncoder.encode(operation)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var dictionary = try XCTUnwrap(
            object["dictionary"] as? [String: Any]
        )
        dictionary.removeValue(forKey: "ctcMinSimilarity")
        object["dictionary"] = dictionary
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: directory.appendingPathComponent("legacy.json"),
            options: [.atomic]
        )
    }

    private static func snippet(
        trigger: String,
        replacement: String,
        updatedAt: Date
    ) -> UserDataSyncSnippet {
        UserDataSyncSnippet(
            trigger: trigger,
            replacement: replacement,
            caseSensitive: false,
            isEnabled: true,
            createdAt: date(1),
            updatedAt: updatedAt
        )
    }

    private static func historyRecord(
        recordID: UUID,
        finalText: String,
        contentUpdatedAt: Date,
        inboxState: String,
        inboxUpdatedAt: Date
    ) -> UserDataSyncHistoryRecord {
        UserDataSyncHistoryRecord(
            content: UserDataSyncHistoryContentV1(
                recordID: recordID,
                createdAt: date(1),
                updatedAt: contentUpdatedAt,
                originDeviceID: "watch-origin",
                originPlatform: "watchOS",
                source: "appleWatch",
                processingState: "ready",
                rawTranscript: finalText,
                finalText: finalText,
                durationSeconds: 4,
                detectedLanguage: "en",
                engineDisplayName: "Apple Speech"
            ),
            inbox: UserDataSyncHistoryInboxV1(
                recordID: recordID,
                updatedAt: inboxUpdatedAt,
                state: inboxState,
                kind: "watchRecording",
                completionPolicy: .onOpen,
                completedAt: nil,
                safeAction: nil
            ),
            audio: nil,
            localAudioFileURL: nil,
            audioEligible: false
        )
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private static func signedEntitlement(
        privateKey: P256.Signing.PrivateKey
    ) throws -> CrossDevicePremiumEntitlement {
        let entitlement = CrossDevicePremiumEntitlement(
            status: "active",
            tier: "individual",
            source: "polar",
            isLifetime: true,
            expiresAt: nil,
            deviceLimit: 3,
            verifiedAt: date(10),
            signature: nil
        )
        let payload = try entitlementEncoder.encode(entitlement.signedClaims)
        let signature = try privateKey.signature(for: payload)
        return CrossDevicePremiumEntitlement(
            status: entitlement.status,
            tier: entitlement.tier,
            source: entitlement.source,
            isLifetime: entitlement.isLifetime,
            expiresAt: entitlement.expiresAt,
            deviceLimit: entitlement.deviceLimit,
            verifiedAt: entitlement.verifiedAt,
            signature: "\(base64URL(payload)).\(base64URL(signature.rawRepresentation))"
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func operationFiles(folder: URL, deviceId: String) -> [URL] {
        let directory = CloudFolderSyncEngine.packageURL(for: folder)
            .appendingPathComponent("ops", isDirectory: true)
            .appendingPathComponent(deviceId, isDirectory: true)

        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func decodeFixture<T: Decodable>(_ name: String) throws -> T {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PremiumSync/\(name).json")
        return try fixtureDecoder.decode(T.self, from: Data(contentsOf: fixtureURL))
    }

    private static let fixtureDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: value))
            }
            return date
        }
        return decoder
    }()

    private static let entitlementEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()

    private static let stateEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let stateDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
