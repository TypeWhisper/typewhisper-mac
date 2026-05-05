import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import ObsidianPlugin

final class ObsidianPluginTests: XCTestCase {
    func testExecuteFailsForInvalidVaultPath() async throws {
        let invalidVaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("obsidian-invalid-\(UUID().uuidString)", isDirectory: false)
        try Data("not-a-directory".utf8).write(to: invalidVaultURL)
        defer { try? FileManager.default.removeItem(at: invalidVaultURL) }

        let host = try PluginTestHostServices(defaults: [
            "vaultPath": invalidVaultURL.path,
            "subfolder": "",
        ])
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        let result = try await plugin.execute(
            input: "Hello",
            context: ActionContext(appName: "Notes", originalText: "Hello")
        )

        XCTAssertFalse(result.success)
        XCTAssertFalse(result.message.isEmpty)
    }

    func testExecuteWritesNoteWithFrontmatter() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVault")
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let host = try PluginTestHostServices(defaults: [
            "vaultPath": vaultURL.path,
            "subfolder": "Captured",
            "frontmatterEnabled": true,
        ])
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        let result = try await plugin.execute(
            input: "Captured text",
            context: ActionContext(
                appName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                url: "https://example.com",
                language: "en",
                originalText: "Captured text"
            )
        )

        XCTAssertTrue(result.success)

        let files = try FileManager.default.contentsOfDirectory(
            at: vaultURL.appendingPathComponent("Captured", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)

        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("---"))
        XCTAssertTrue(content.contains("app: Notes"))
        XCTAssertTrue(content.contains("language: en"))
        XCTAssertTrue(content.contains("Captured text"))
    }

    func testAutoExportDailyNoteAppendsTranscriptions() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultDaily")
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: [
                "vaultPath": vaultURL.path,
                "dailyNoteEnabled": true,
                "autoExportEnabled": true,
            ],
            eventBus: eventBus
        )
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        await eventBus.emit(
            .transcriptionCompleted(
                TranscriptionCompletedPayload(
                    rawText: "First",
                    finalText: "First entry",
                    engineUsed: "test",
                    durationSeconds: 1,
                    appName: "Notes",
                    ruleName: nil
                )
            )
        )
        await eventBus.emit(
            .transcriptionCompleted(
                TranscriptionCompletedPayload(
                    rawText: "Second",
                    finalText: "Second entry",
                    engineUsed: "test",
                    durationSeconds: 1,
                    appName: "Notes",
                    ruleName: nil
                )
            )
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: vaultURL.appendingPathComponent("TypeWhisper", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)

        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertTrue(content.contains("First entry"))
        XCTAssertTrue(content.contains("Second entry"))
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
