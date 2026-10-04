import Foundation
import XCTest
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
@testable import ScriptPlugin

@MainActor
final class ScriptPluginTests: XCTestCase {
    func testLegacyScriptDoesNotOptIntoRecordings() throws {
        let legacy = Data("""
        {"id":"11111111-1111-4111-8111-111111111111","name":"Legacy","command":"cat","isEnabled":true,"profileFilter":[]}
        """.utf8)
        let config = try JSONDecoder().decode(ScriptConfig.self, from: legacy)
        XCTAssertFalse(config.includesRecordings)
        XCTAssertFalse(ScriptConfig().includesRecordings)
    }

    func testRecorderEventExportsOriginalAndFileContextOnlyForOptedInScripts() async throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let audioURL = host.pluginDataDirectory.appendingPathComponent("Meeting with spaces.wav")
        let payload = RecorderTranscriptReadyPayload(
            recordingID: UUID(), text: String(repeating: "Notes — Grüße 中文\n", count: 10_000),
            audioFilePath: audioURL.path,
            transcriptFilePath: audioURL.deletingPathExtension().appendingPathExtension("txt").path
        )
        try payload.text.write(toFile: payload.transcriptFilePath, atomically: true, encoding: .utf8)
        let export = ScriptConfig(
            name: "Export", command: """
            cat > "$TYPEWHISPER_AUDIO_FILE.export"
            printf '%s\\n' "$TYPEWHISPER_SOURCE" "$TYPEWHISPER_RECORDING_ID" "$TYPEWHISPER_COMPLETION_ID" "$TYPEWHISPER_TRANSCRIPT_FILE" "$TYPEWHISPER_COMPLETED_AT" "${TYPEWHISPER_MARKDOWN_FILE-unset}" > "$TYPEWHISPER_AUDIO_FILE.context"
            """, profileFilter: ["Unrelated dictation rule"], includesRecordings: true
        )
        let disabled = ScriptConfig(
            command: "touch \"$TYPEWHISPER_AUDIO_FILE.disabled\"", isEnabled: false, includesRecordings: true
        )
        let notOptedIn = ScriptConfig(command: "touch \"$TYPEWHISPER_AUDIO_FILE.unwanted\"")
        let configs = [export, disabled, notOptedIn]
        try JSONEncoder().encode(configs).write(to: host.pluginDataDirectory.appendingPathComponent("scripts.json"))
        let plugin = ScriptPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        XCTAssertEqual(eventBus.subscriberCount, 1)

        await eventBus.emit(.recorderTranscriptReady(payload))

        XCTAssertEqual(try String(contentsOf: audioURL.appendingPathExtension("export"), encoding: .utf8), payload.text)
        let context = try String(contentsOf: audioURL.appendingPathExtension("context"), encoding: .utf8)
        XCTAssertEqual(context, ["recorder", payload.recordingID.uuidString, payload.completionID.uuidString,
                                  payload.transcriptFilePath, String(payload.completedAt.timeIntervalSince1970), "unset", ""].joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.appendingPathExtension("disabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.appendingPathExtension("unwanted").path))
        XCTAssertEqual(try String(contentsOfFile: payload.transcriptFilePath, encoding: .utf8), payload.text)
        plugin.deactivate()
        XCTAssertEqual(eventBus.subscriberCount, 0)
    }

    func testRecorderExportAcceptsNoStdoutAndLogsFailure() async throws {
        let host = try PluginTestHostServices()
        let service = ScriptService(dataDirectory: host.pluginDataDirectory, host: host)
        let payload = RecorderTranscriptReadyPayload(
            recordingID: UUID(), text: "original", audioFilePath: "/tmp/meeting.wav", transcriptFilePath: "/tmp/meeting.txt"
        )
        _ = await service.executeScript(ScriptConfig(name: "Export", command: "cat > /dev/null"),
                                        input: payload.text, context: PostProcessingContext(), recorder: payload)
        _ = await service.executeScript(ScriptConfig(name: "Ignores stdin", command: "exit 0"),
                                        input: String(repeating: "long meeting\n", count: 100_000),
                                        context: PostProcessingContext(), recorder: payload)
        _ = await service.executeScript(ScriptConfig(name: "Failure", command: "cat > /dev/null; exit 7"),
                                        input: payload.text, context: PostProcessingContext(), recorder: payload)
        // Execution log publication is queued on the main queue.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(service.executionLog.first(where: { $0.scriptName == "Export" })?.success, true)
        XCTAssertEqual(service.executionLog.first(where: { $0.scriptName == "Ignores stdin" })?.success, true)
        XCTAssertEqual(service.executionLog.first(where: { $0.scriptName == "Failure" })?.success, false)
    }

    func testDictationStillChainsScriptOutputAndHonorsRules() async throws {
        let host = try PluginTestHostServices()
        let configs = [
            ScriptConfig(command: "tr '[:lower:]' '[:upper:]'", includesRecordings: true),
            ScriptConfig(command: "cat; printf '!'", profileFilter: ["Notes"])
        ]
        try JSONEncoder().encode(configs).write(to: host.pluginDataDirectory.appendingPathComponent("scripts.json"))
        let plugin = ScriptPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        let matching = try await plugin.process(text: "hello", context: PostProcessingContext(ruleName: "Notes"))
        let other = try await plugin.process(text: "hello", context: PostProcessingContext(ruleName: "Other"))
        XCTAssertEqual(matching, "HELLO!")
        XCTAssertEqual(other, "HELLO")
    }
}
