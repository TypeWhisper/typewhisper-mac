import Foundation
import Security
import XCTest
@testable import TypeWhisper

final class CLISupportTests: XCTestCase {
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var request: URLRequest?

        func record(_ request: URLRequest) {
            lock.withLock {
                self.request = request
            }
        }

        var recordedRequest: URLRequest? {
            lock.withLock { request }
        }
    }

    func testShellCompletionsCoverCommandsAndOptionsForEveryShell() {
        let words = [
            "transcribe", "status", "models", "list", "load", "unload", "delete", "export", "import", "audio", "set", "completions",
            "port", "api-token", "dev", "json", "help", "version", "language", "language-hint", "task", "translate-to",
            "engine", "model", "await-download", "no-corrections", "replace", "__complete", "engines",
        ]
        for shell in CompletionShell.allCases {
            let script = ShellCompletions.script(for: shell)
            for word in words {
                XCTAssertTrue(script.contains(word), "\(shell.rawValue) completion is missing \(word)")
            }
        }
    }

    func testShellCompletionIDsComeFromModelsResponse() {
        let modelsJSON = Data(#"{"models":[{"id":"v3","engine":"parakeet"},{"id":"v2","engine":"parakeet"},{"id":"turbo","engine":"groq"},{"id":"v3","engine":"parakeet"}]}"#.utf8)

        XCTAssertEqual(ShellCompletions.engineIDs(fromModelsJSON: modelsJSON), ["parakeet", "groq"])
        XCTAssertEqual(ShellCompletions.modelIDs(fromModelsJSON: modelsJSON, engine: "parakeet"), ["v3", "v2"])
        XCTAssertEqual(ShellCompletions.modelIDs(fromModelsJSON: modelsJSON, engine: nil), ["v3", "v2", "turbo"])
        XCTAssertEqual(ShellCompletions.engineIDs(fromModelsJSON: Data("not json".utf8)), [])
    }

    func testOutputFormatterRendersHumanReadableStatusAndModels() {
        let statusJSON = Data(#"{"status":"ready","engine":"parakeet","model":"tiny"}"#.utf8)
        let modelsJSON = Data(#"{"models":[{"id":"tiny","engine":"parakeet","name":"Tiny","status":"ready","selected":true}]}"#.utf8)

        XCTAssertEqual(OutputFormatter.formatStatus(statusJSON, json: false), "Ready - parakeet (tiny)")
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("tiny"))
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("*"))
        XCTAssertEqual(
            OutputFormatter.formatSettingsExport(path: "/tmp/settings.json", bytes: 123, json: false),
            "Exported settings to /tmp/settings.json"
        )

        let importJSON = Data(#"{"workflowsImported":2,"dictionaryImported":1,"dictionarySkipped":3,"snippetsImported":0,"snippetsSkipped":0,"promptActionsImported":0,"profilesImported":0,"hotkeysApplied":1,"hotkeysSkipped":0,"pluginsInstalled":0,"pluginsSkipped":0,"pluginsRegistryFetchFailed":false,"historyImported":0,"historySkippedByRetention":0,"updateChannelApplied":false,"preferencesApplied":4}"#.utf8)
        let importSummary = OutputFormatter.formatSettingsImport(importJSON, json: false)
        XCTAssertTrue(importSummary.contains("Workflows: 2 imported"))
        XCTAssertTrue(importSummary.contains("Dictionary: 1 imported, 3 skipped"))
        XCTAssertTrue(importSummary.contains("Preferences: 4 applied"))
        XCTAssertTrue(OutputFormatter.formatSettingsImport(importJSON, json: true).contains("\"workflowsImported\" : 2"))
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

    func testPortDiscoveryUsesTokenizedDiscoveryFileBeforeLegacyPortFile() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("TypeWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "9911".write(to: appDirectory.appendingPathComponent("api-port"), atomically: true, encoding: .utf8)
        try """
        {
          "version": 1,
          "port": 9922,
          "token": "token-from-discovery"
        }
        """.write(to: appDirectory.appendingPathComponent("api-discovery.json"), atomically: true, encoding: .utf8)

        let discovery = PortDiscovery.discover(dev: false, applicationSupportDirectory: applicationSupportRoot)

        XCTAssertEqual(discovery, APIDiscovery(port: 9922, token: "token-from-discovery"))
        XCTAssertEqual(PortDiscovery.discoverPort(dev: false, applicationSupportDirectory: applicationSupportRoot), 9922)
    }

    func testCLITranscribeLanguageOptionsRejectMixedExactAndHintFlags() {
        let options = CLITranscribeLanguageOptions(language: "de", languageHints: ["en", "nl"])
        XCTAssertEqual(
            options.validationError(),
            "Error: --language and --language-hint cannot be used together."
        )
    }

    func testCLIClientTranscribeLocalFileUsesLocalFileEndpointWithoutUploadingBytes() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let fileURL = directory.appendingPathComponent("large.mp4")
        try Data("distinctive-video-bytes".utf8).write(to: fileURL)

        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.transcribe(
            fileURL: fileURL,
            language: nil,
            languageHints: ["de", "en"],
            task: "transcribe",
            targetLanguage: nil,
            engine: "mock",
            model: "tiny"
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe/local-file")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, fileURL.path)
        XCTAssertEqual(body["language_hints"] as? [String], ["de", "en"])
        XCTAssertEqual(body["task"] as? String, "transcribe")
        XCTAssertEqual(body["engine"] as? String, "mock")
        XCTAssertEqual(body["model"] as? String, "tiny")
        XCTAssertNil(body["apply_corrections"])
        XCTAssertFalse(String(data: bodyData, encoding: .utf8)?.contains("distinctive-video-bytes") == true)
    }

    func testCLIClientTranscribeLocalFileSendsApplyCorrectionsFalseWhenRequested() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let fileURL = directory.appendingPathComponent("raw.wav")
        try Data("audio-bytes".utf8).write(to: fileURL)

        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.transcribe(
            fileURL: fileURL,
            language: nil,
            languageHints: [],
            task: "transcribe",
            targetLanguage: nil,
            applyCorrections: false
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe/local-file")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, fileURL.path)
        XCTAssertEqual(body["apply_corrections"] as? Bool, false)
    }

    func testCLIClientSendsBearerTokenWhenConfigured() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            apiToken: "cli-token",
            transport: { request in
                recorder.record(request)
                let body = #"{"models":[]}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.models()

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
    }

    func testCLIClientExportsSettingsFromAuthenticatedEndpoint() async throws {
        let recorder = RequestRecorder()
        let exportedBackup = Data(#"{"schemaVersion":1}"#.utf8)
        let client = CLIClient(
            port: 9876,
            apiToken: "cli-token",
            transport: { request in
                recorder.record(request)
                return (exportedBackup, Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        let result = try await client.exportSettings()

        XCTAssertEqual(result, exportedBackup)
        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/settings/export")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 300)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
    }

    func testCLIClientImportsSettingsBackupAsJSON() async throws {
        let recorder = RequestRecorder()
        let backup = Data(#"{"schemaVersion":1,"workflows":[]}"#.utf8)
        let responseBody = Data(#"{"workflowsImported":0}"#.utf8)
        let client = CLIClient(
            port: 9876,
            apiToken: "cli-token",
            transport: { request in
                recorder.record(request)
                return (responseBody, Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        let result = try await client.importSettings(backup)

        XCTAssertEqual(result, responseBody)
        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/settings/import")
        XCTAssertEqual(request.url?.query, "mode=merge")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 300)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
        XCTAssertEqual(request.httpBody, backup)

        _ = try await client.importSettings(backup, replaceExisting: true)
        XCTAssertEqual(recorder.recordedRequest?.url?.query, "mode=replace")
    }

    func testCLIClientReadsAndPatchesAudioSettings() async throws {
        let recorder = RequestRecorder()
        let state = Data(#"{"input_priority":[]}"#.utf8)
        let client = CLIClient(
            port: 9876,
            apiToken: "cli-token",
            transport: { request in
                recorder.record(request)
                return (state, Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        let current = try await client.audioSettings()
        XCTAssertEqual(current, state)
        XCTAssertEqual(recorder.recordedRequest?.url?.path, "/v1/settings/audio")
        XCTAssertEqual(recorder.recordedRequest?.httpMethod, "GET")

        let changes = Data(#"{"audio_ducking_enabled":false}"#.utf8)
        let updated = try await client.updateAudioSettings(changes)
        XCTAssertEqual(updated, state)
        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/settings/audio")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
        XCTAssertEqual(request.httpBody, changes)
    }

    func testCLIClientLoadsUnloadsAndDeletesModels() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            apiToken: "cli-token",
            transport: { request in
                recorder.record(request)
                return (Data(#"{"engine":"parakeet","status":"ready"}"#.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )
        func body(_ request: URLRequest) throws -> [String: String]? {
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        }

        _ = try await client.loadModel(engine: "parakeet", model: "parakeet-tdt-0.6b-v3")
        var request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/models/load")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 660)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
        XCTAssertEqual(try body(request), ["engine": "parakeet", "model": "parakeet-tdt-0.6b-v3"])

        _ = try await client.unloadModel(engine: "parakeet")
        request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/models/unload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertEqual(try body(request), ["engine": "parakeet"])

        _ = try await client.deleteModel(engine: "parakeet", model: "parakeet tdt&v2")
        request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertEqual(request.url?.query, "engine=parakeet&model=parakeet%20tdt%26v2")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
    }

    func testCLIClientSurfacesUnsupportedUnloadAsServerError() async {
        let client = CLIClient(
            port: 9876,
            transport: { request in
                let body = Data(#"{"error":{"message":"Engine 'groq' does not support unloading"}}"#.utf8)
                return (body, Self.httpResponse(url: request.url!, statusCode: 409))
            }
        )

        do {
            _ = try await client.unloadModel(engine: "groq")
            XCTFail("Expected a server error")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, 3)
            XCTAssertEqual(error.message, "Error: Server returned 409 - Engine 'groq' does not support unloading")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOutputFormatterRendersModelActions() {
        let loaded = Data(#"{"engine":"parakeet","model":"parakeet-tdt-0.6b-v3","status":"ready"}"#.utf8)
        let unloadedWithoutModel = Data(#"{"engine":"parakeet","model":null,"status":"unloaded"}"#.utf8)

        XCTAssertEqual(OutputFormatter.formatModelAction(loaded, json: false), "ready: parakeet parakeet-tdt-0.6b-v3")
        XCTAssertEqual(OutputFormatter.formatModelAction(unloadedWithoutModel, json: false), "unloaded: parakeet")
        XCTAssertTrue(OutputFormatter.formatModelAction(loaded, json: true).contains("\"status\" : \"ready\""))
    }

    func testOutputFormatterRendersAudioSettings() {
        let state = Data("""
            {"input_devices":[{"id":"bh","name":"BlackHole 2ch","is_system_default":false},
                              {"id":"mic","name":"MacBook Pro Microphone","is_system_default":true}],
             "input_priority":[{"id":"quadcast","name":"HyperX QuadCast 2"},{"id":"bh","name":"BlackHole 2ch"}],
             "active_input":{"id":"bh","name":"BlackHole 2ch"},
             "audio_ducking_enabled":true,"audio_ducking_level":0.2,
             "pause_media_during_recording":false,"sound_feedback_enabled":true}
            """.utf8)

        XCTAssertEqual(OutputFormatter.formatAudioSettings(state, json: false), """
            Active input: BlackHole 2ch [bh]
            Input priority:
              1. HyperX QuadCast 2 [quadcast] (not connected)
              2. BlackHole 2ch [bh]
            Available inputs:
              BlackHole 2ch [bh]
              MacBook Pro Microphone [mic] (system default)
            Audio ducking: on (20% volume)
            Pause media during recording: off
            Sound feedback: on
            """)

        let systemDefault = Data(#"{"input_devices":[],"input_priority":[],"active_input":null,"audio_ducking_enabled":false,"audio_ducking_level":0,"pause_media_during_recording":true,"sound_feedback_enabled":false}"#.utf8)
        XCTAssertEqual(OutputFormatter.formatAudioSettings(systemDefault, json: false), """
            Active input: none
            Input priority: system default
            Available inputs:
            Audio ducking: off
            Pause media during recording: on
            Sound feedback: off
            """)
    }

    func testCLIClientTranscribeStdinKeepsMultipartUploadPath() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            stdinReader: {
                Data("stdin-audio-bytes".utf8)
            }
        )

        _ = try await client.transcribe(
            fileURL: nil,
            language: "de",
            languageHints: [],
            task: "transcribe",
            targetLanguage: nil,
            engine: nil,
            model: nil
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertTrue(bodyText?.contains("stdin-audio-bytes") == true)
        XCTAssertTrue(bodyText?.contains("name=\"language\"") == true)
        XCTAssertFalse(bodyText?.contains("name=\"apply_corrections\"") == true)
    }

    func testCLIClientTranscribeStdinSendsApplyCorrectionsFalseWhenRequested() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            stdinReader: {
                Data("stdin-audio-bytes".utf8)
            }
        )

        _ = try await client.transcribe(
            fileURL: nil,
            language: nil,
            languageHints: [],
            task: "transcribe",
            targetLanguage: nil,
            applyCorrections: false
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe")
        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertTrue(bodyText?.contains("name=\"apply_corrections\"") == true)
        XCTAssertTrue(bodyText?.contains("\r\nfalse\r\n") == true)
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
                benefitDescription: "Freelancer single-seat license for 3 devices"
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
                price: "199 EUR",
                billingLabel: localizedAppText("per month", de: "pro Monat"),
                detail: localizedAppText("Recurring billing", de: "Wiederkehrende Abrechnung")
            )
        )

        XCTAssertEqual(
            commercialPurchaseOptionCopy(for: .enterprise, cadence: .yearly),
            CommercialPurchaseOptionCopy(
                price: localizedAppText("1,990 EUR", de: "1.990 EUR"),
                billingLabel: localizedAppText("per year", de: "pro Jahr"),
                detail: localizedAppText("Two months free", de: "Zwei Monate gratis")
            )
        )
        XCTAssertNil(commercialPurchaseOptionCopy(for: .enterprise, cadence: .lifetime))
        XCTAssertNil(commercialPurchaseOptionCopy(for: .individual, cadence: .yearly))
        XCTAssertNil(commercialPurchaseOptionCopy(for: .team, cadence: .yearly))
    }

    func testOnlyEnterpriseIsSoldYearlyAndOnlyAsSubscription() {
        XCTAssertEqual(commercialPurchaseCadences(for: .individual), [.monthly, .lifetime])
        XCTAssertEqual(commercialPurchaseCadences(for: .team), [.monthly, .lifetime])
        XCTAssertEqual(commercialPurchaseCadences(for: .enterprise), [.monthly, .yearly])

        for tier in [LicenseTier.individual, .team, .enterprise] {
            for cadence in commercialPurchaseCadences(for: tier) {
                XCTAssertNotNil(
                    commercialPurchaseOptionCopy(for: tier, cadence: cadence),
                    "\(tier) \(cadence) is offered without a price"
                )
            }
        }
    }

    func testSwitchingPlansKeepsTheSecondBillingOption() {
        XCTAssertEqual(commercialPurchaseCadence(for: .enterprise, preferring: .lifetime), .yearly)
        XCTAssertEqual(commercialPurchaseCadence(for: .individual, preferring: .yearly), .lifetime)
        XCTAssertEqual(commercialPurchaseCadence(for: .team, preferring: .yearly), .lifetime)

        for tier in [LicenseTier.individual, .team, .enterprise] {
            XCTAssertEqual(commercialPurchaseCadence(for: tier, preferring: .monthly), .monthly)
            for cadence in CommercialPurchaseCadence.allCases {
                XCTAssertTrue(
                    commercialPurchaseCadences(for: tier).contains(
                        commercialPurchaseCadence(for: tier, preferring: cadence)
                    ),
                    "\(tier) shows a billing option it does not offer for \(cadence)"
                )
            }
        }
    }

    func testMacCheckoutURLAddsPolarAttribution() throws {
        let url = try XCTUnwrap(
            AppConstants.Polar.appCheckoutURL(
                baseURL: AppConstants.Polar.checkoutURLIndividual,
                content: "settings_individual_monthly"
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertEqual(query["utm_source"], "typewhisper_mac")
        XCTAssertEqual(query["utm_medium"], "app")
        XCTAssertEqual(query["utm_content"], "mac_settings_individual_monthly")
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
                    let bodyData = try XCTUnwrap(request.httpBody)
                    let requestBody = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
                    )
                    let metadata = try XCTUnwrap(requestBody["meta"] as? [String: String])
                    XCTAssertEqual(metadata["platform"], "macos")
                    XCTAssertEqual(metadata["app_version"], AppConstants.appVersion)
                    XCTAssertNotNil(requestBody["label"] as? String)
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
        let keychainValue = Self.loadKeychainValue(service: keychainServiceName, account: "polar-license") ?? ""
        XCTAssertTrue(keychainValue.contains("\"key\":\"TYPEWHISPER-ENT-123\""))
        XCTAssertTrue(keychainValue.contains("\"activationId\":\"activation-123\""))
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
        let keychainValue = Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter") ?? ""
        XCTAssertTrue(keychainValue.contains("\"key\":\"TYPEWHISPER-SUP-999\""))
        XCTAssertTrue(keychainValue.contains("\"activationId\":\"activation-999\""))
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

    private actor PolarRequestLog {
        private(set) var entries: [(path: String, version: String?)] = []

        func record(_ request: URLRequest) {
            entries.append((request.url?.lastPathComponent ?? "", request.value(forHTTPHeaderField: "Polar-Version")))
        }
    }

    /// Bodies Polar can return with HTTP 404 that do not confirm a missing activation.
    /// `{"detail":"Not Found"}` is what Polar's API-version middleware sends for unknown or removed versions.
    private static let unconfirmedPolar404Bodies = [
        #"{"detail":"Not Found"}"#,
        "",
        #"{"error":"UnexpectedError","detail":"Not Found"}"#,
    ]

    @MainActor
    func testPolarLicenseRequestsPinApiVersionHeader() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.PolarVersion.\(UUID().uuidString)"
        defer {
            Self.deleteKeychainValue(service: keychainServiceName, account: "polar-license")
            Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter")
        }

        let log = PolarRequestLog()
        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                await log.record(request)
                switch request.url?.lastPathComponent {
                case "activate":
                    return (Data(#"{"id":"activation-123"}"#.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
                case "validate":
                    let body = #"{"id":"activation-123","status":"granted","expires_at":null,"benefit_id":"40b82917-f74e-4cc3-8165-937f1f47b294"}"#
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
                default:
                    return (Data(), Self.httpResponse(url: request.url!, statusCode: 204))
                }
            }
        )

        _ = await service.activateAnyKey("TYPEWHISPER-ENT-123")
        await service.validateLicense()
        await service.deactivateLicense()

        XCTAssertFalse(service.hasCommercialLicense)
        let entries = await log.entries
        XCTAssertEqual(entries.map(\.path), ["activate", "validate", "validate", "deactivate"])
        XCTAssertEqual(entries.map(\.version), Array(repeating: "2026-04", count: 4))
    }

    @MainActor
    func testCommercialValidationClearsLicenseWhenPolarActivationIsMissing() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.Commercial.\(UUID().uuidString)"
        defer { Self.deleteKeychainValue(service: keychainServiceName, account: "polar-license") }
        Self.storeKeychainValue("license-key|activation-123", service: keychainServiceName, account: "polar-license")

        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                let body = #"{"error":"ResourceNotFound","detail":"Not found"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 404))
            }
        )
        service.licenseStatus = .active
        service.licenseTier = .team

        await service.validateLicense()

        XCTAssertEqual(service.licenseStatus, .unlicensed)
        XCTAssertNil(service.licenseTier)
        XCTAssertNil(Self.loadKeychainValue(service: keychainServiceName, account: "polar-license"))
    }

    @MainActor
    func testUnconfirmedPolar404KeepsCommercialAndSupporterCredentials() async throws {
        for body in Self.unconfirmedPolar404Bodies {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let keychainServiceName = "TypeWhisperTests.Unconfirmed404.\(UUID().uuidString)"
            defer {
                Self.deleteKeychainValue(service: keychainServiceName, account: "polar-license")
                Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter")
            }
            let licenseSecret = "license-key|license-activation"
            let supporterSecret = "supporter-key|supporter-activation"
            Self.storeKeychainValue(licenseSecret, service: keychainServiceName, account: "polar-license")
            Self.storeKeychainValue(supporterSecret, service: keychainServiceName, account: "polar-supporter")

            let log = PolarRequestLog()
            let service = LicenseService(
                defaults: defaults,
                keychainServiceName: keychainServiceName,
                dataTransport: { request in
                    await log.record(request)
                    return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 404))
                }
            )
            service.licenseStatus = .active
            service.licenseTier = .team
            service.supporterStatus = .active
            service.supporterTier = .gold
            defaults.set(Date.distantPast, forKey: UserDefaultsKeys.lastSupporterValidation)

            await service.validateLicense()
            await service.validateSupporterIfNeeded()
            await service.deactivateLicense()
            await service.deactivateSupporterLicense()

            let paths = await log.entries.map(\.path)
            XCTAssertEqual(paths, ["validate", "validate", "deactivate", "deactivate"], "body: \(body)")
            XCTAssertEqual(service.licenseStatus, .active, "body: \(body)")
            XCTAssertEqual(service.licenseTier, .team, "body: \(body)")
            XCTAssertEqual(service.supporterStatus, .active, "body: \(body)")
            XCTAssertEqual(service.supporterTier, .gold, "body: \(body)")
            XCTAssertNotNil(service.deactivationError, "body: \(body)")
            XCTAssertNotNil(service.supporterDeactivationError, "body: \(body)")
            XCTAssertEqual(Self.loadKeychainValue(service: keychainServiceName, account: "polar-license"), licenseSecret, "body: \(body)")
            XCTAssertEqual(Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter"), supporterSecret, "body: \(body)")
        }
    }

    @MainActor
    func testSupporterKeychainReadFailureKeepsCachedStateAndDiscordSession() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("session-123", forKey: UserDefaultsKeys.supporterDiscordSessionId)

        let previousDiscordService = SupporterDiscordService.shared
        defer { SupporterDiscordService.shared = previousDiscordService }

        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable] {
            let service = LicenseService(
                defaults: defaults,
                keychainServiceName: "TypeWhisperTests.UnavailableKeychain.\(UUID().uuidString)",
                keychainCopyMatching: { _, _ in status },
                dataTransport: { request in
                    XCTFail("Validation must be skipped while Keychain is unavailable")
                    return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
                }
            )
            SupporterDiscordService.shared = SupporterDiscordService(licenseService: service, defaults: defaults)
            service.supporterStatus = .active
            service.supporterTier = .silver
            defaults.set(Date.distantPast, forKey: UserDefaultsKeys.lastSupporterValidation)

            await service.validateSupporterIfNeeded()

            XCTAssertEqual(service.supporterStatus, .active, "status: \(status)")
            XCTAssertEqual(service.supporterTier, .silver, "status: \(status)")
            XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId), "session-123", "status: \(status)")
        }

        // Only a confirmed missing item still resets supporter and Discord state.
        let missingService = LicenseService(
            defaults: defaults,
            keychainServiceName: "TypeWhisperTests.MissingKeychain.\(UUID().uuidString)",
            keychainCopyMatching: { _, _ in errSecItemNotFound },
            dataTransport: { request in
                XCTFail("A missing supporter record must not be validated")
                return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
            }
        )
        SupporterDiscordService.shared = SupporterDiscordService(licenseService: missingService, defaults: defaults)

        await missingService.validateSupporterIfNeeded()

        XCTAssertEqual(missingService.supporterStatus, .unlicensed)
        XCTAssertNil(missingService.supporterTier)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId))
    }

    @MainActor
    func testSupporterKeychainReadFailureKeepsDiscordClaimThroughStartupRefresh() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("session-123", forKey: UserDefaultsKeys.supporterDiscordSessionId)
        let linked = SupporterDiscordClaimStatus(
            state: .linked,
            discordUsername: "marco#1234",
            linkedRoles: ["Supporter Gold"],
            errorMessage: nil,
            sessionId: "session-123",
            updatedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(linked), forKey: UserDefaultsKeys.supporterDiscordClaimStatus)

        let licenseService = LicenseService(
            defaults: defaults,
            keychainServiceName: "TypeWhisperTests.UnavailableKeychain.\(UUID().uuidString)",
            keychainCopyMatching: { _, _ in errSecInteractionNotAllowed },
            dataTransport: { request in
                XCTFail("Validation must be skipped while Keychain is unavailable")
                return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
            }
        )
        licenseService.supporterStatus = .active
        licenseService.supporterTier = .gold
        defaults.set(Date.distantPast, forKey: UserDefaultsKeys.lastSupporterValidation)

        // Uses the production claim-proof provider backed by the failing Keychain read.
        let discordService = SupporterDiscordService(
            licenseService: licenseService,
            defaults: defaults,
            transport: { request in
                XCTFail("Discord claim status must not be requested without a readable proof")
                return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
            }
        )
        let previousDiscordService = SupporterDiscordService.shared
        SupporterDiscordService.shared = discordService
        defer { SupporterDiscordService.shared = previousDiscordService }

        // Same order as ServiceContainer startup, plus the callback-driven refresh.
        await licenseService.validateSupporterIfNeeded()
        await discordService.refreshStatusIfNeeded()
        await discordService.refreshClaimStatus()

        XCTAssertThrowsError(try licenseService.readSupporterClaimProof())
        XCTAssertEqual(licenseService.supporterStatus, .active)
        XCTAssertEqual(licenseService.supporterTier, .gold)
        XCTAssertEqual(discordService.claimStatus.state, .linked)
        XCTAssertEqual(discordService.claimStatus.sessionId, "session-123")
        XCTAssertEqual(discordService.claimStatus.discordUsername, "marco#1234")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId), "session-123")

        // A user-started claim fails visibly but still keeps the linked session.
        let persistedStatus = defaults.data(forKey: UserDefaultsKeys.supporterDiscordClaimStatus)
        let claimURL = await discordService.createClaimSession()
        XCTAssertNil(claimURL)
        XCTAssertEqual(discordService.claimStatus.state, .linked)
        XCTAssertNotNil(discordService.claimStatus.errorMessage)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsKeys.supporterDiscordClaimStatus), persistedStatus)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId), "session-123")
    }

    @MainActor
    func testSupporterDiscordReconnectKeepsClaimWhenKeychainReadFails() async throws {
        for state in [SupporterDiscordClaimStatus.State.linked, .pending] {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let existing = SupporterDiscordClaimStatus(
                state: state,
                discordUsername: state == .linked ? "marco#1234" : nil,
                linkedRoles: state == .linked ? ["Supporter Gold"] : [],
                errorMessage: nil,
                sessionId: "session-123",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let persistedStatus = try JSONEncoder().encode(existing)
            defaults.set(persistedStatus, forKey: UserDefaultsKeys.supporterDiscordClaimStatus)
            defaults.set("session-123", forKey: UserDefaultsKeys.supporterDiscordSessionId)

            let licenseService = LicenseService(
                defaults: defaults,
                keychainServiceName: "TypeWhisperTests.UnavailableKeychain.\(UUID().uuidString)",
                keychainCopyMatching: { _, _ in errSecInteractionNotAllowed },
                dataTransport: { request in
                    XCTFail("No Polar request expected")
                    return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
                }
            )
            licenseService.supporterStatus = .active
            licenseService.supporterTier = .gold
            let discordService = SupporterDiscordService(
                licenseService: licenseService,
                defaults: defaults,
                transport: { request in
                    XCTFail("A claim session must not start without a readable proof")
                    return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
                }
            )

            let claimURL = await discordService.reconnect()

            XCTAssertNil(claimURL, "state: \(state)")
            XCTAssertNotNil(discordService.claimStatus.errorMessage, "state: \(state)")
            XCTAssertEqual(discordService.claimStatus.state, state, "state: \(state)")
            XCTAssertEqual(discordService.claimStatus.sessionId, "session-123", "state: \(state)")
            XCTAssertEqual(discordService.claimStatus.discordUsername, existing.discordUsername, "state: \(state)")
            XCTAssertEqual(discordService.claimStatus.linkedRoles, existing.linkedRoles, "state: \(state)")
            XCTAssertEqual(defaults.data(forKey: UserDefaultsKeys.supporterDiscordClaimStatus), persistedStatus, "state: \(state)")
            XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId), "session-123", "state: \(state)")
            XCTAssertEqual(licenseService.supporterStatus, .active, "state: \(state)")
            XCTAssertEqual(licenseService.supporterTier, .gold, "state: \(state)")
        }
    }

    @MainActor
    func testSupporterDiscordReconnectReplacesClaimWhenProofIsReadable() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let linked = SupporterDiscordClaimStatus(
            state: .linked,
            discordUsername: "marco#1234",
            linkedRoles: ["Supporter Gold"],
            errorMessage: nil,
            sessionId: "session-123",
            updatedAt: Date()
        )
        defaults.set(try JSONEncoder().encode(linked), forKey: UserDefaultsKeys.supporterDiscordClaimStatus)
        defaults.set("session-123", forKey: UserDefaultsKeys.supporterDiscordSessionId)

        let service = SupporterDiscordService(
            licenseService: LicenseService(defaults: defaults),
            defaults: defaults,
            transport: { request in
                XCTAssertEqual(request.url?.path, "/claims/polar/start")
                let body = #"{"session_id":"session-456","claim_url":"https://claims.example.test/claims/polar/discord?session_id=session-456"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            claimProofProvider: {
                SupporterClaimProof(key: "supporter-key", activationId: "activation-123", tier: .gold)
            },
            baseURLProvider: {
                URL(string: "https://claims.example.test")!
            }
        )

        let claimURL = await service.reconnect()

        XCTAssertEqual(claimURL?.absoluteString, "https://claims.example.test/claims/polar/discord?session_id=session-456")
        XCTAssertEqual(service.claimStatus.state, .pending)
        XCTAssertNil(service.claimStatus.discordUsername)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId), "session-456")
    }

    @MainActor
    func testSupporterDiscordReconnectWithoutSupporterRecordClearsClaim() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("session-123", forKey: UserDefaultsKeys.supporterDiscordSessionId)

        let service = SupporterDiscordService(
            licenseService: LicenseService(defaults: defaults),
            defaults: defaults,
            transport: { request in
                XCTFail("A claim session must not start without a supporter record")
                return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
            },
            claimProofProvider: { nil }
        )

        let claimURL = await service.reconnect()

        XCTAssertNil(claimURL)
        XCTAssertEqual(service.claimStatus.state, .failed)
        XCTAssertNil(service.claimStatus.sessionId)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.supporterDiscordSessionId))
    }

    @MainActor
    func testSupporterUnreadablePayloadKeepsCachedStateWithoutValidation() async throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let keychainServiceName = "TypeWhisperTests.SupporterPayload.\(UUID().uuidString)"
        defer { Self.deleteKeychainValue(service: keychainServiceName, account: "polar-supporter") }
        Self.storeKeychainValue("invalid payload", service: keychainServiceName, account: "polar-supporter")

        let service = LicenseService(
            defaults: defaults,
            keychainServiceName: keychainServiceName,
            dataTransport: { request in
                XCTFail("An unreadable supporter record must not be validated")
                return (Data(), Self.httpResponse(url: request.url!, statusCode: 500))
            }
        )
        service.supporterStatus = .active
        service.supporterTier = .bronze
        defaults.set(Date.distantPast, forKey: UserDefaultsKeys.lastSupporterValidation)

        await service.validateSupporterIfNeeded()

        XCTAssertEqual(service.supporterStatus, .active)
        XCTAssertEqual(service.supporterTier, .bronze)
        XCTAssertEqual(Self.loadKeychainValue(service: keychainServiceName, account: "polar-supporter"), "invalid payload")
    }

    private actor ManagedLicenseServer {
        var paths: [String] = []
        var activationCount = 0
        var failActivation = false
        var revoked = false
        var failValidation = false
        var missingActivation = false
        var unsupportedAPIVersion = false
        var supporter = false
        var deactivation: ManagedDeactivationResponse = .success
        var deactivatedActivationIDs: [String] = []
        var deactivationAttempts: [String] = []

        func configureDeactivation(_ response: ManagedDeactivationResponse) {
            deactivation = response
        }

        func configure(failValidation: Bool = false, failActivation: Bool = false, revoked: Bool = false, missingActivation: Bool = false, unsupportedAPIVersion: Bool = false, supporter: Bool = false) {
            self.failActivation = failActivation
            self.failValidation = failValidation
            self.revoked = revoked
            self.missingActivation = missingActivation
            self.unsupportedAPIVersion = unsupportedAPIVersion
            self.supporter = supporter
        }

        func respond(to request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            paths.append(url.lastPathComponent)
            var status = 200
            let body: String
            switch url.lastPathComponent {
            case "activate":
                if failActivation { throw URLError(.notConnectedToInternet) }
                activationCount += 1
                body = "{\"id\":\"activation-\(activationCount)\"}"
                // Exercise MainActor reentrancy while another startup/retry request arrives.
                try await Task.sleep(for: .milliseconds(20))
            case "validate":
                if failValidation { throw URLError(.notConnectedToInternet) }
                if missingActivation {
                    missingActivation = false
                    status = 404
                    body = #"{"error":"ResourceNotFound","detail":"Not found"}"#
                } else if unsupportedAPIVersion {
                    status = 404
                    body = #"{"detail":"Not Found"}"#
                } else {
                    let benefit = supporter ? "0c695b7a-2f3a-4797-81c7-1410dbb76cc2" : "40b82917-f74e-4cc3-8165-937f1f47b294"
                    body = "{\"id\":\"license\",\"status\":\"\(revoked ? "revoked" : "granted")\",\"benefit_id\":\"\(benefit)\"}"
                }
            case "deactivate":
                let requestBody = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let activationID = requestBody?["activation_id"] as? String ?? ""
                deactivationAttempts.append(activationID)
                switch deactivation {
                case .success:
                    deactivatedActivationIDs.append(activationID)
                    status = 204
                    body = ""
                case .offline:
                    throw URLError(.notConnectedToInternet)
                case .http(let statusCode, let errorBody):
                    status = statusCode
                    body = errorBody
                }
            default:
                XCTFail("Unexpected managed license request")
                body = "{}"
                status = 500
            }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private enum ManagedDeactivationResponse: Sendable {
        case success
        case offline
        case http(Int, String)
    }

    @MainActor
    private final class ManagedLicenseClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        func advance(by interval: TimeInterval) {
            now = now.addingTimeInterval(interval)
        }
    }

    @MainActor
    private struct ManagedLicenseFixture {
        nonisolated static let retirementsAccount = "polar-license-retirements"

        let suite = "TypeWhisperTests.Managed.\(UUID().uuidString)"
        let defaults: UserDefaults
        let server = ManagedLicenseServer()
        let clock = ManagedLicenseClock()
        let service: LicenseService

        init(key: String? = "managed-key") throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            if let key { defaults.set(key, forKey: UserDefaultsKeys.managedLicenseKey) }
            let server = server
            let clock = clock
            service = LicenseService(defaults: defaults, keychainServiceName: suite, now: { clock.now }, dataTransport: { request in
                try await server.respond(to: request)
            })
        }

        /// A new service on the same defaults and Keychain, as after an app restart.
        func restartedService(
            keychainUpdate: @escaping (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
            keychainAdd: @escaping (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) },
            keychainCopyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
                SecItemCopyMatching($0, $1)
            },
            keychainDelete: @escaping (CFDictionary) -> OSStatus = { SecItemDelete($0) }
        ) -> LicenseService {
            let server = server
            let clock = clock
            return LicenseService(
                defaults: defaults,
                keychainServiceName: suite,
                keychainUpdate: keychainUpdate,
                keychainAdd: keychainAdd,
                keychainCopyMatching: keychainCopyMatching,
                keychainDelete: keychainDelete,
                now: { clock.now },
                dataTransport: { try await server.respond(to: $0) }
            )
        }

        func rotate(to key: String, using service: LicenseService? = nil) async {
            defaults.set(key, forKey: UserDefaultsKeys.managedLicenseKey)
            await (service ?? self.service).validateIfNeeded()
        }

        var activeActivationID: String? {
            guard let stored = CLISupportTests.loadKeychainValue(service: suite, account: "polar-license"),
                  let object = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any] else {
                return nil
            }
            return object["activationId"] as? String
        }

        var pendingRetirementIDs: [String] {
            guard let stored = CLISupportTests.loadKeychainValue(service: suite, account: Self.retirementsAccount),
                  let object = try? JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any],
                  let entries = object["entries"] as? [[String: Any]] else {
                return []
            }
            return entries.compactMap { $0["activationId"] as? String }
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            CLISupportTests.deleteKeychainValue(service: suite, account: "polar-license")
            CLISupportTests.deleteKeychainValue(service: suite, account: "polar-supporter")
            CLISupportTests.deleteKeychainValue(service: suite, account: Self.retirementsAccount)
        }
    }

    /// Lets tests fail Keychain writes for the retirement queue only.
    private static func isRetirementQueueQuery(_ query: CFDictionary) -> Bool {
        (query as NSDictionary)[kSecAttrAccount as String] as? String == ManagedLicenseFixture.retirementsAccount
    }

    private static func isLicenseQuery(_ query: CFDictionary) -> Bool {
        (query as NSDictionary)[kSecAttrAccount as String] as? String == "polar-license"
    }

    @MainActor
    func testManagedLicenseActivatesAndReusesKeychainAfterRestart() async throws {
        let fixture = try ManagedLicenseFixture(key: "  managed-key\n")
        defer { fixture.cleanup() }
        XCTAssertTrue(fixture.service.isLicenseManaged)
        XCTAssertFalse(fixture.service.needsWelcomeSheet)
        await fixture.service.validateIfNeeded()
        XCTAssertEqual(fixture.service.licenseTier, .enterprise)
        XCTAssertEqual(fixture.service.usageIntent, .enterprise)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertNil(fixture.service.managedLicenseError)
        let stored = try XCTUnwrap(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"))
        XCTAssertTrue(stored.contains("\"key\":\"managed-key\""))
        let server = fixture.server
        let restarted = LicenseService(defaults: fixture.defaults, keychainServiceName: fixture.suite, dataTransport: { request in
            try await server.respond(to: request)
        })
        await restarted.validateIfNeeded()
        let paths = await fixture.server.paths
        XCTAssertEqual(paths, ["activate", "validate"])
        XCTAssertTrue(restarted.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseEmptyConfigurationLeavesManualActivationAvailable() async throws {
        let fixture = try ManagedLicenseFixture(key: " \n")
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        XCTAssertFalse(fixture.service.isLicenseManaged)
        XCTAssertTrue(fixture.service.needsWelcomeSheet)
        let paths = await fixture.server.paths
        XCTAssertTrue(paths.isEmpty)
        await fixture.service.activateLicenseKey("manual-key")
        XCTAssertTrue(fixture.service.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseFailureCanRetryWithoutRevealingKey() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.server.configure(failActivation: true)
        await fixture.service.validateIfNeeded()
        XCTAssertFalse(fixture.service.hasCommercialLicense)
        let error = try XCTUnwrap(fixture.service.managedLicenseError)
        XCTAssertFalse(error.contains("managed-key"))
        XCTAssertNil(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"))
        await fixture.server.configure()
        await fixture.service.validateIfNeeded()
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertNil(fixture.service.managedLicenseError)
    }

    @MainActor
    func testManagedLicenseFailedRotationPreservesExistingLicense() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let original = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        fixture.defaults.set("replacement-key", forKey: UserDefaultsKeys.managedLicenseKey)
        await fixture.server.configure(failActivation: true)
        await fixture.service.validateIfNeeded()
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), original)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertNotNil(fixture.service.managedLicenseError)
        let paths = await fixture.server.paths
        XCTAssertFalse(paths.contains("deactivate"))
    }

    @MainActor
    func testManagedLicenseRotationSavesReplacementBeforeRetiringOldActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        fixture.defaults.set("replacement-key", forKey: UserDefaultsKeys.managedLicenseKey)
        await fixture.service.validateIfNeeded()
        let stored = try XCTUnwrap(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"))
        XCTAssertTrue(stored.contains("replacement-key"))
        XCTAssertTrue(stored.contains("activation-2"))
        let paths = await fixture.server.paths
        XCTAssertEqual(paths, ["activate", "validate", "activate", "validate", "deactivate"])
        let deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["activation-1"])
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        XCTAssertNil(Self.loadKeychainValue(service: fixture.suite, account: ManagedLicenseFixture.retirementsAccount))
    }

    @MainActor
    func testManagedLicenseFailedRetirementSurvivesRestartAndRetriesWithoutNewActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        await fixture.server.configureDeactivation(.offline)
        await fixture.rotate(to: "replacement-key")

        XCTAssertNil(fixture.service.managedLicenseError)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(fixture.activeActivationID, "activation-2")
        XCTAssertEqual(fixture.pendingRetirementIDs, ["activation-1"])

        await fixture.server.configureDeactivation(.success)
        let restarted = fixture.restartedService()
        await restarted.validateIfNeeded()
        var attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts, ["activation-1"], "The retry must wait for its backoff")

        fixture.clock.advance(by: LicenseService.activationRetirementRetryBaseInterval)
        await restarted.validateIfNeeded()
        attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts, ["activation-1", "activation-1"])
        let deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["activation-1"])
        XCTAssertNil(Self.loadKeychainValue(service: fixture.suite, account: ManagedLicenseFixture.retirementsAccount))
        let activations = await fixture.server.activationCount
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(fixture.activeActivationID, "activation-2")
        XCTAssertTrue(restarted.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseRepeatedRotationsKeepEveryPendingRetirement() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        await fixture.server.configureDeactivation(.http(503, #"{"detail":"Service Unavailable"}"#))
        await fixture.rotate(to: "key-b")
        await fixture.rotate(to: "key-c")

        XCTAssertEqual(fixture.activeActivationID, "activation-3")
        XCTAssertEqual(fixture.pendingRetirementIDs, ["activation-1", "activation-2"])

        await fixture.server.configureDeactivation(.success)
        fixture.clock.advance(by: LicenseService.activationRetirementRetryMaxInterval)
        await fixture.service.validateIfNeeded()

        let deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["activation-1", "activation-2"])
        let attempts = await fixture.server.deactivationAttempts
        XCTAssertFalse(attempts.contains("activation-3"))
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        XCTAssertEqual(fixture.activeActivationID, "activation-3")
        XCTAssertTrue(fixture.service.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicensePendingRetirementKeepsEntryUnlessDeactivationIsConfirmed() async throws {
        let notFound = #"{"error":"ResourceNotFound","detail":"Not found"}"#
        let cases: [(name: String, response: ManagedDeactivationResponse, kept: Bool)] = [
            ("offline", .offline, true),
            ("bare 404", .http(404, #"{"detail":"Not Found"}"#), true),
            ("401", .http(401, #"{"detail":"Unauthorized"}"#), true),
            ("403", .http(403, #"{"detail":"Forbidden"}"#), true),
            ("429", .http(429, #"{"detail":"Too Many Requests"}"#), true),
            ("500", .http(500, #"{"detail":"Internal Server Error"}"#), true),
            ("first 422", .http(422, #"{"detail":"Invalid"}"#), true),
            ("ResourceNotFound", .http(404, notFound), false),
            ("success", .success, false),
        ]

        for testCase in cases {
            let fixture = try ManagedLicenseFixture()
            await fixture.service.validateIfNeeded()
            await fixture.server.configureDeactivation(testCase.response)
            await fixture.rotate(to: "replacement-key")

            XCTAssertEqual(fixture.pendingRetirementIDs, testCase.kept ? ["activation-1"] : [], testCase.name)
            XCTAssertEqual(fixture.activeActivationID, "activation-2", testCase.name)
            XCTAssertTrue(fixture.service.hasCommercialLicense, testCase.name)
            XCTAssertNil(fixture.service.managedLicenseError, testCase.name)
            fixture.cleanup()
        }
    }

    @MainActor
    func testManagedLicensePendingRetirementBacksOffAndStopsAfterRepeatedRejections() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        await fixture.server.configureDeactivation(.http(422, #"{"detail":"Invalid"}"#))
        await fixture.rotate(to: "replacement-key")

        let base = LicenseService.activationRetirementRetryBaseInterval
        fixture.clock.advance(by: base - 1)
        await fixture.service.validateIfNeeded()
        var attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts.count, 1)

        fixture.clock.advance(by: 1)
        await fixture.service.validateIfNeeded()
        attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(fixture.pendingRetirementIDs, ["activation-1"])

        fixture.clock.advance(by: 2 * base)
        await fixture.service.validateIfNeeded()
        attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts.count, LicenseService.maxRejectedActivationRetirementAttempts)
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)

        fixture.clock.advance(by: LicenseService.activationRetirementRetryMaxInterval)
        await fixture.service.validateIfNeeded()
        attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts.count, LicenseService.maxRejectedActivationRetirementAttempts)
        XCTAssertEqual(fixture.activeActivationID, "activation-2")
        XCTAssertTrue(fixture.service.hasCommercialLicense)
    }

    func testActivationRetirementRetryDelayDoublesUpToCap() {
        let hour: TimeInterval = 60 * 60
        let delays = (1 ... 7).map { LicenseService.activationRetirementRetryDelay(afterFailures: $0) }
        XCTAssertEqual(delays, [hour, 2 * hour, 4 * hour, 8 * hour, 16 * hour, 24 * hour, 24 * hour])
        XCTAssertEqual(LicenseService.activationRetirementRetryDelay(afterFailures: 10_000), 24 * hour)
    }

    @MainActor
    func testManagedLicenseRetirementServerSuccessWithFailedQueueRemovalRetriesSafely() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        await fixture.server.configureDeactivation(.offline)
        await fixture.rotate(to: "replacement-key")

        await fixture.server.configureDeactivation(.success)
        fixture.clock.advance(by: LicenseService.activationRetirementRetryBaseInterval)
        let failing = fixture.restartedService(keychainDelete: { query in
            Self.isRetirementQueueQuery(query) ? errSecInteractionNotAllowed : SecItemDelete(query)
        })
        await failing.validateIfNeeded()
        let deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["activation-1"])
        XCTAssertEqual(fixture.pendingRetirementIDs, ["activation-1"])

        await fixture.server.configureDeactivation(.http(404, #"{"error":"ResourceNotFound","detail":"Not found"}"#))
        let restarted = fixture.restartedService()
        await restarted.validateIfNeeded()
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        XCTAssertEqual(fixture.activeActivationID, "activation-2")
        XCTAssertTrue(restarted.hasCommercialLicense)
        let activations = await fixture.server.activationCount
        XCTAssertEqual(activations, 2)
    }

    @MainActor
    func testManagedLicenseRotationKeepsOldLicenseWhenRetirementCannotBeQueued() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let original = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        let failing = fixture.restartedService(
            keychainUpdate: { query, attributes in
                Self.isRetirementQueueQuery(query) ? errSecInteractionNotAllowed : SecItemUpdate(query, attributes)
            },
            keychainAdd: { query in
                Self.isRetirementQueueQuery(query) ? errSecInteractionNotAllowed : SecItemAdd(query, nil)
            }
        )

        await fixture.rotate(to: "replacement-key", using: failing)

        XCTAssertNotNil(failing.managedLicenseError)
        XCTAssertTrue(failing.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), original)
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        // Only the unsaved replacement is rolled back; the active activation is untouched.
        let attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts, ["activation-2"])
    }

    @MainActor
    func testManagedLicenseFailedReplacementSaveWithdrawsQueuedRetirement() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let original = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")

        // Saving the replacement fails, and afterwards the active record cannot be read, so the
        // retirement pass cannot drop the entry because it matches the active record.
        final class LicenseReadSwitch { var failing = false }
        let licenseReads = LicenseReadSwitch()
        let failing = fixture.restartedService(
            keychainUpdate: { query, attributes in
                guard Self.isLicenseQuery(query) else { return SecItemUpdate(query, attributes) }
                licenseReads.failing = true
                return errSecInteractionNotAllowed
            },
            keychainCopyMatching: { query, result in
                licenseReads.failing && Self.isLicenseQuery(query)
                    ? errSecInteractionNotAllowed
                    : SecItemCopyMatching(query, result)
            }
        )

        await fixture.rotate(to: "replacement-key", using: failing)

        XCTAssertNotNil(failing.managedLicenseError)
        XCTAssertTrue(failing.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), original)
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        let attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts, ["activation-2"])
    }

    @MainActor
    func testManagedLicensePendingRetirementNeverDeactivatesActiveActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        // State after a crash between queueing the old activation and saving its replacement.
        Self.storeKeychainValue(
            #"{"version":1,"entries":[{"key":"managed-key","activationId":"activation-1","failedAttempts":0,"rejectedAttempts":0}]}"#,
            service: fixture.suite,
            account: ManagedLicenseFixture.retirementsAccount
        )

        let restarted = fixture.restartedService()
        await restarted.validateIfNeeded()

        let attempts = await fixture.server.deactivationAttempts
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        XCTAssertEqual(fixture.activeActivationID, "activation-1")
        XCTAssertTrue(restarted.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseUnreadableRetirementQueueKeepsCredentialsAndCurrentLicense() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let original = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        Self.storeKeychainValue("invalid payload", service: fixture.suite, account: ManagedLicenseFixture.retirementsAccount)

        await fixture.rotate(to: "replacement-key")

        XCTAssertNotNil(fixture.service.managedLicenseError)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), original)
        XCTAssertEqual(
            Self.loadKeychainValue(service: fixture.suite, account: ManagedLicenseFixture.retirementsAccount),
            "invalid payload"
        )
        let attempts = await fixture.server.deactivationAttempts
        XCTAssertEqual(attempts, ["activation-2"])
    }

    @MainActor
    func testManagedLicenseRemovalKeepsRetiringPendingActivations() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        await fixture.server.configureDeactivation(.offline)
        await fixture.rotate(to: "replacement-key")

        fixture.defaults.removeObject(forKey: UserDefaultsKeys.managedLicenseKey)
        await fixture.server.configureDeactivation(.success)
        fixture.clock.advance(by: LicenseService.activationRetirementRetryBaseInterval)
        await fixture.service.validateIfNeeded()

        XCTAssertFalse(fixture.service.isLicenseManaged)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(fixture.activeActivationID, "activation-2")
        XCTAssertTrue(fixture.pendingRetirementIDs.isEmpty)
        let deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["activation-1"])
    }

    @MainActor
    func testManagedLicenseRetirementPassIsBudgeted() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let entries = (1 ... 5).map {
            #"{"key":"old-key-\#($0)","activationId":"old-\#($0)","failedAttempts":0,"rejectedAttempts":0}"#
        }
        Self.storeKeychainValue(
            #"{"version":1,"entries":[\#(entries.joined(separator: ","))]}"#,
            service: fixture.suite,
            account: ManagedLicenseFixture.retirementsAccount
        )

        await fixture.service.validateIfNeeded()
        var deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["old-1", "old-2", "old-3"])
        XCTAssertEqual(fixture.pendingRetirementIDs, ["old-4", "old-5"])

        await fixture.service.validateIfNeeded()
        deactivated = await fixture.server.deactivatedActivationIDs
        XCTAssertEqual(deactivated, ["old-1", "old-2", "old-3", "old-4", "old-5"])
        XCTAssertNil(Self.loadKeychainValue(service: fixture.suite, account: ManagedLicenseFixture.retirementsAccount))
    }

    @MainActor
    func testManagedLicensePreventsManualReplacementAndDeactivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        await fixture.service.activateLicenseKey("other")
        let result = await fixture.service.activateAnyKey("other")
        XCTAssertNil(result)
        await fixture.service.deactivateLicense()
        fixture.service.setUsageIntent(.personalOSS)
        XCTAssertEqual(fixture.service.usageIntent, .enterprise)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        let paths = await fixture.server.paths
        XCTAssertEqual(paths, ["activate", "validate"])
    }

    @MainActor
    func testManagedLicenseRemovalRetainsLicenseAndAllowsManualDeactivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        fixture.defaults.removeObject(forKey: UserDefaultsKeys.managedLicenseKey)
        await fixture.service.validateIfNeeded()
        XCTAssertFalse(fixture.service.isLicenseManaged)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        await fixture.service.deactivateLicense()
        XCTAssertFalse(fixture.service.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseRejectsSupporterKeyAndRollsBackActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.server.configure(supporter: true)
        await fixture.service.validateIfNeeded()
        XCTAssertFalse(fixture.service.hasCommercialLicense)
        XCTAssertFalse(fixture.service.isSupporter)
        XCTAssertNotNil(fixture.service.managedLicenseError)
        let paths = await fixture.server.paths
        XCTAssertEqual(paths, ["activate", "validate", "deactivate"])
    }

    @MainActor
    func testManagedLicenseConcurrentAttemptsCreateOneActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        async let first: Void = fixture.service.validateIfNeeded()
        async let second: Void = fixture.service.validateIfNeeded()
        _ = await (first, second)
        let count = await fixture.server.activationCount
        XCTAssertEqual(count, 1)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseAllowsSeparatePersonalSupporterActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let commercial = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        await fixture.server.configure(supporter: true)
        await fixture.service.activateSupporterKey("personal-supporter-key")
        XCTAssertTrue(fixture.service.isSupporter)
        XCTAssertEqual(fixture.service.supporterTier, .gold)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), commercial)
        XCTAssertNotNil(Self.loadKeychainValue(service: fixture.suite, account: "polar-supporter"))
    }

    @MainActor
    func testManagedSupporterPersistenceFailureRollsBackWithoutLosingExistingLicense() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let commercial = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        await fixture.server.configure(supporter: true)
        await fixture.service.activateSupporterKey("existing-supporter-key")
        let supporter = Self.loadKeychainValue(service: fixture.suite, account: "polar-supporter")
        let lastValidation = fixture.defaults.object(forKey: UserDefaultsKeys.lastSupporterValidation) as? Date
        let server = fixture.server

        let failingService = LicenseService(
            defaults: fixture.defaults,
            keychainServiceName: fixture.suite,
            keychainUpdate: { _, _ in errSecInteractionNotAllowed },
            keychainAdd: { _ in XCTFail("An update failure must not insert another item"); return errSecSuccess },
            dataTransport: { try await server.respond(to: $0) }
        )
        await failingService.activateSupporterKey("replacement-supporter-key")

        XCTAssertNotNil(failingService.supporterActivationError)
        XCTAssertTrue(failingService.isSupporter)
        XCTAssertTrue(failingService.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-supporter"), supporter)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), commercial)
        XCTAssertEqual(fixture.defaults.object(forKey: UserDefaultsKeys.lastSupporterValidation) as? Date, lastValidation)
        let paths = await server.paths
        XCTAssertEqual(Array(paths.suffix(3)), ["activate", "validate", "deactivate"])
    }

    @MainActor
    func testManagedSupporterInsertFailureDoesNotReportActivationSuccess() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.server.configure(supporter: true)
        let server = fixture.server
        let failingService = LicenseService(
            defaults: fixture.defaults,
            keychainServiceName: fixture.suite,
            keychainUpdate: { _, _ in errSecItemNotFound },
            keychainAdd: { _ in errSecInteractionNotAllowed },
            dataTransport: { try await server.respond(to: $0) }
        )

        await failingService.activateSupporterKey("personal-supporter-key")

        XCTAssertNotNil(failingService.supporterActivationError)
        XCTAssertFalse(failingService.isSupporter)
        XCTAssertNil(Self.loadKeychainValue(service: fixture.suite, account: "polar-supporter"))
        XCTAssertNil(fixture.defaults.object(forKey: UserDefaultsKeys.lastSupporterValidation))
        let paths = await server.paths
        XCTAssertEqual(paths, ["activate", "validate", "deactivate"])
    }

    @MainActor
    func testManagedSupporterEntryCannotReplaceCommercialLicense() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let commercial = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        await fixture.service.activateSupporterKey("another-commercial-key")
        XCTAssertFalse(fixture.service.isSupporter)
        XCTAssertNotNil(fixture.service.supporterActivationError)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), commercial)
        let paths = await fixture.server.paths
        XCTAssertEqual(paths, ["activate", "validate", "activate", "validate", "deactivate"])
    }

    @MainActor
    func testManagedLicenseRecoversDeletedActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        fixture.defaults.removeObject(forKey: UserDefaultsKeys.lastLicenseValidation)
        await fixture.server.configure(missingActivation: true)
        await fixture.service.validateIfNeeded()
        let count = await fixture.server.activationCount
        XCTAssertEqual(count, 2)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
    }

    @MainActor
    func testManagedLicenseUnsupportedAPIVersionKeepsActivationWithoutReactivating() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        let stored = Self.loadKeychainValue(service: fixture.suite, account: "polar-license")
        fixture.defaults.removeObject(forKey: UserDefaultsKeys.lastLicenseValidation)
        await fixture.server.configure(unsupportedAPIVersion: true)
        await fixture.service.validateIfNeeded()
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(Self.loadKeychainValue(service: fixture.suite, account: "polar-license"), stored)
        let paths = await fixture.server.paths
        XCTAssertEqual(paths, ["activate", "validate", "validate"])
    }

    @MainActor
    func testManagedLicenseRevocationDoesNotCreateAnotherActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        fixture.defaults.removeObject(forKey: UserDefaultsKeys.lastLicenseValidation)
        await fixture.server.configure(revoked: true)
        await fixture.service.validateIfNeeded()
        await fixture.service.validateIfNeeded()
        let count = await fixture.server.activationCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fixture.service.licenseStatus, .expired)
    }

    @MainActor
    func testManagedLicenseOfflineValidationKeepsExistingActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        await fixture.service.validateIfNeeded()
        fixture.defaults.removeObject(forKey: UserDefaultsKeys.lastLicenseValidation)
        await fixture.server.configure(failValidation: true)
        await fixture.service.validateIfNeeded()
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        let count = await fixture.server.activationCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testManagedLicenseInvalidPreferenceTypeDoesNotActivate() async throws {
        let fixture = try ManagedLicenseFixture(key: nil)
        defer { fixture.cleanup() }
        fixture.defaults.set(123, forKey: UserDefaultsKeys.managedLicenseKey)
        await fixture.service.validateIfNeeded()
        XCTAssertFalse(fixture.service.isLicenseManaged)
        let paths = await fixture.server.paths
        XCTAssertTrue(paths.isEmpty)
    }

    @MainActor
    func testManagedLicenseUnreadablePayloadDoesNotConsumeAnotherActivation() async throws {
        let fixture = try ManagedLicenseFixture()
        defer { fixture.cleanup() }
        Self.storeKeychainValue("invalid payload", service: fixture.suite, account: "polar-license")
        fixture.service.licenseStatus = .active
        fixture.service.licenseTier = .enterprise
        await fixture.service.validateIfNeeded()
        XCTAssertNotNil(fixture.service.managedLicenseError)
        XCTAssertTrue(fixture.service.hasCommercialLicense)
        XCTAssertEqual(fixture.service.licenseTier, .enterprise)
        let paths = await fixture.server.paths
        XCTAssertTrue(paths.isEmpty)
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
