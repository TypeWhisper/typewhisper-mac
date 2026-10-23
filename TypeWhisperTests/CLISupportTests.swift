import Foundation
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

        let importJSON = Data(#"{"workflowsImported":2,"dictionaryImported":1,"dictionarySkipped":3,"snippetsImported":0,"snippetsSkipped":0,"promptActionsImported":0,"profilesImported":0,"hotkeysApplied":1,"hotkeysSkipped":0,"pluginsConfigured":0,"pluginsSkipped":0,"historyImported":0,"historySkippedByRetention":0,"preferencesApplied":4}"#.utf8)
        let importSummary = OutputFormatter.formatSettingsImport(importJSON, json: false)
        XCTAssertTrue(importSummary.contains("Workflows: 2 imported"))
        XCTAssertTrue(importSummary.contains("Dictionary: 1 imported, 3 skipped"))
        XCTAssertTrue(importSummary.contains("Preferences: 4 applied"))
        XCTAssertTrue(OutputFormatter.formatSettingsImport(importJSON, json: true).contains("\"workflowsImported\" : 2"))
    }

    func testPortDiscoveryUsesConfiguredPortFileAndFallback() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("dictum", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "9911".write(to: appDirectory.appendingPathComponent("api-port"), atomically: true, encoding: .utf8)

        XCTAssertEqual(PortDiscovery.discoverPort(dev: false, applicationSupportDirectory: applicationSupportRoot), 9911)
        XCTAssertEqual(PortDiscovery.discoverPort(dev: true, applicationSupportDirectory: applicationSupportRoot), PortDiscovery.defaultPort)
    }

    func testPortDiscoveryUsesTokenizedDiscoveryFileBeforeLegacyPortFile() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("dictum", isDirectory: true)
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

    private static func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
