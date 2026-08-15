import Foundation
import os
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ElevenLabsPlugin

final class ElevenLabsPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testAPIKeyValidationAcceptsSuccessfulUserResponse() {
        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 200, data: Data()),
            .valid
        )
    }

    func testAPIKeyValidationAcceptsKeyWithoutUserReadPermission() {
        let data = Data(#"""
        {
            "detail": {
                "type": "authentication_error",
                "code": "unauthorized",
                "message": "The API key you used is missing the permission user_read to execute this operation.",
                "status": "missing_permissions"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .valid
        )
    }

    func testAPIKeyValidationRejectsInvalidKeyWithProviderMessage() {
        let data = Data(#"""
        {
            "detail": {
                "type": "authentication_error",
                "code": "invalid_api_key",
                "message": "Invalid API key",
                "status": "invalid_api_key"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .invalid(message: "Invalid API key")
        )
    }

    func testAPIKeyValidationRejectsUnrelatedMissingPermission() {
        let data = Data(#"""
        {
            "detail": {
                "message": "The API key is missing the permission speech_to_text.",
                "status": "missing_permissions"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .invalid(message: "The API key is missing the permission speech_to_text.")
        )
    }

    func testAPIKeyValidationRejectsMultipleMissingPermissions() {
        let message = "The API key you used is missing the permissions user_read and speech_to_text."
        let data = Data(#"""
        {
            "detail": {
                "message": "\#(message)",
                "status": "missing_permissions"
            }
        }
        """#.utf8)

        XCTAssertEqual(
            ElevenLabsPlugin.apiKeyValidationResult(statusCode: 401, data: data),
            .invalid(message: message)
        )
    }

    func testTranscriptionModeDefaultsToAutomaticForMissingOrUnknownValue() throws {
        let defaultHost = try PluginTestHostServices()
        let defaultPlugin = ElevenLabsPlugin()
        defaultPlugin.activate(host: defaultHost)

        XCTAssertEqual(defaultPlugin.transcriptionMode, .automatic)
        XCTAssertTrue(defaultPlugin.supportsStreaming)

        let unknownHost = try PluginTestHostServices(
            defaults: [ElevenLabsPlugin.transcriptionModeKey: "realtimeOnly"]
        )
        let unknownPlugin = ElevenLabsPlugin()
        unknownPlugin.activate(host: unknownHost)

        XCTAssertEqual(unknownPlugin.transcriptionMode, .automatic)
        XCTAssertTrue(unknownPlugin.supportsStreaming)
    }

    func testTranscriptionModePersistsAndUpdatesStreamingCapability() throws {
        let host = try PluginTestHostServices()
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        plugin.setTranscriptionMode(.restOnly)

        XCTAssertEqual(plugin.transcriptionMode, .restOnly)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(
            host.userDefault(forKey: ElevenLabsPlugin.transcriptionModeKey) as? String,
            ElevenLabsTranscriptionMode.restOnly.rawValue
        )
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setTranscriptionMode(.restOnly)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        let reloadedPlugin = ElevenLabsPlugin()
        reloadedPlugin.activate(host: host)
        XCTAssertEqual(reloadedPlugin.transcriptionMode, .restOnly)
        XCTAssertFalse(reloadedPlugin.supportsStreaming)
    }

    func testRESTOnlyProgressTranscriptionUsesBatchEndpointAndReportsFinalText() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "selectedModel": "scribe_v2",
                ElevenLabsPlugin.transcriptionModeKey: ElevenLabsTranscriptionMode.restOnly.rawValue,
            ],
            secrets: ["api-key": "elevenlabs-key"]
        )
        let plugin = ElevenLabsPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"REST transcript","language_code":"de"}"#.utf8),
                    Self.httpResponse(url: "https://api.elevenlabs.io/v1/speech-to-text", statusCode: 200)
                )
            ])
        }

        let progressRecorder = StringRecorder()
        let samples = [Float](repeating: 0.1, count: 16_000)
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: 1),
            language: "de",
            translate: false,
            prompt: "TypeWhisper, Scribe",
            onProgress: { text in
                progressRecorder.append(text)
                return true
            }
        )

        XCTAssertEqual(result.text, "REST transcript")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(progressRecorder.values, ["REST transcript"])

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.elevenlabs.io")
        XCTAssertEqual(request.url?.path, "/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "elevenlabs-key")

        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nde\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterms\"\r\n\r\nTypeWhisper\r\n"))
        XCTAssertTrue(body.contains("name=\"keyterms\"\r\n\r\nScribe\r\n"))
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let valuesLock = OSAllocatedUnfairLock(initialState: [String]())

    var values: [String] {
        valuesLock.withLock { $0 }
    }

    func append(_ value: String) {
        valuesLock.withLock { $0.append(value) }
    }
}
