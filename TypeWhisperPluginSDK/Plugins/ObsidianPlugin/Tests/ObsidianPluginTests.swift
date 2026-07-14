import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import ObsidianPlugin

final class ObsidianPluginTests: XCTestCase {
    private static let workflowInstructionTitle = "Workflow Instruction"
    private static let workflowInstructionHelp = "Create a Custom Workflow, paste this into Instruction, and set Action Target to \"Save to Obsidian\"."
    private static let copyInstructionTitle = "Copy Instruction"

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

    func testAutoExportDailyNoteOmitsAppMetadataWhenFormatDoesNotContainApp() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultDailyNoApp")
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: [
                "vaultPath": vaultURL.path,
                "dailyNoteEnabled": true,
                "dailyNoteFormat": "{{DATE}}", // No {{APP}}
                "frontmatterEnabled": true,
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
                    language: "it",
                    engineUsed: "test",
                    durationSeconds: 1,
                    appName: "Brave Browser",
                    bundleIdentifier: "com.brave.Browser",
                    url: "https://example.com",
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
        XCTAssertTrue(content.contains("---"))
        XCTAssertFalse(content.contains("app: Brave Browser"))
        XCTAssertFalse(content.contains("bundleId: com.brave.Browser"))
        XCTAssertFalse(content.contains("url: https://example.com"))
        XCTAssertTrue(content.contains("language: it"))
        XCTAssertTrue(content.contains("First entry"))
    }

    func testActionNameMatchesWorkflowInstructionTarget() {
        let plugin = ObsidianPlugin()

        XCTAssertEqual(plugin.actionName, "Save to Obsidian")
        XCTAssertTrue(Self.workflowInstructionHelp.contains("\"\(plugin.actionName)\""))
    }

    func testSettingsCopyDescribesWorkflowActionTarget() throws {
        let source = try String(contentsOf: Self.pluginRoot.appendingPathComponent("ObsidianPlugin.swift"), encoding: .utf8)
        let catalog = try Self.loadStringCatalog()

        XCTAssertTrue(source.contains(Self.workflowInstructionTitle))
        XCTAssertTrue(source.contains("Create a Custom Workflow"))
        XCTAssertTrue(source.contains("Action Target"))
        XCTAssertTrue(source.contains("Save to Obsidian"))
        XCTAssertTrue(source.contains(Self.copyInstructionTitle))
        XCTAssertEqual(catalog.localizedValue(for: Self.workflowInstructionTitle), "Workflow-Anweisung")
        XCTAssertEqual(
            catalog.localizedValue(for: Self.workflowInstructionHelp),
            "Erstelle einen eigenen Workflow, füge dies in Anweisung ein und setze das Action-Ziel auf \"Save to Obsidian\"."
        )
        XCTAssertEqual(catalog.localizedValue(for: Self.copyInstructionTitle), "Anweisung kopieren")
    }

    func testSettingsCopyDoesNotReferenceLegacyPromptActionFlow() throws {
        let source = try String(contentsOf: Self.pluginRoot.appendingPathComponent("ObsidianPlugin.swift"), encoding: .utf8)
        let catalog = try String(contentsOf: Self.pluginRoot.appendingPathComponent("Localizable.xcstrings"), encoding: .utf8)
        let combinedCopy = source + "\n" + catalog

        for staleTerm in ["PromptAction", "Recommended Prompt", "Copy Prompt", "Create a new PromptAction"] {
            XCTAssertFalse(combinedCopy.contains(staleTerm), "\(staleTerm) should not appear in Obsidian settings copy")
        }
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static var pluginRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadStringCatalog() throws -> StringCatalog {
        try JSONDecoder().decode(
            StringCatalog.self,
            from: Data(contentsOf: pluginRoot.appendingPathComponent("Localizable.xcstrings"))
        )
    }
}

private struct StringCatalog: Decodable {
    struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    struct StringUnit: Decodable {
        let value: String
    }

    let strings: [String: Entry]

    func localizedValue(for key: String, language: String = "de") -> String? {
        strings[key]?.localizations?[language]?.stringUnit?.value
    }
}
