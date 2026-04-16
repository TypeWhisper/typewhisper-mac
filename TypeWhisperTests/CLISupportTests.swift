import Foundation
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
}
