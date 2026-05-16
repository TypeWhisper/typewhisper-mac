import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import LinearPlugin

final class LinearPluginTests: XCTestCase {
    private static let workflowInstructionTitle = "Workflow Instruction"
    private static let workflowInstructionHelp = "Create a Custom Workflow, paste this into Instruction, and set Action Target to \"Create Linear Issue\"."
    private static let copyInstructionTitle = "Copy Instruction"

    func testExecuteFailsWhenApiKeyIsMissing() async throws {
        let host = try PluginTestHostServices()
        let plugin = LinearPlugin()
        plugin.activate(host: host)

        let result = try await plugin.execute(
            input: "Fix the onboarding copy",
            context: ActionContext(appName: "Notes", originalText: "Fix the onboarding copy")
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "Linear API key not configured")
    }

    func testSettingsPersistToHostServices() throws {
        let host = try PluginTestHostServices()
        let plugin = LinearPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)

        plugin.setApiKey("lin_api_test")
        plugin.setDefaultTeam("team-1")
        plugin.setDefaultProject("project-1")
        plugin.setDefaultLabels(["label-a", "label-b"])

        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(host.loadSecret(key: "api-key"), "lin_api_test")
        XCTAssertEqual(host.userDefault(forKey: "defaultTeamId") as? String, "team-1")
        XCTAssertEqual(host.userDefault(forKey: "defaultProjectId") as? String, "project-1")
        XCTAssertEqual(host.userDefault(forKey: "defaultLabels") as? [String], ["label-a", "label-b"])
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testActionNameMatchesWorkflowInstructionTarget() {
        let plugin = LinearPlugin()

        XCTAssertEqual(plugin.actionName, "Create Linear Issue")
        XCTAssertTrue(Self.workflowInstructionHelp.contains("\"\(plugin.actionName)\""))
    }

    func testSettingsCopyDescribesWorkflowActionTarget() throws {
        let source = try String(contentsOf: Self.pluginRoot.appendingPathComponent("LinearPlugin.swift"), encoding: .utf8)
        let catalog = try Self.loadStringCatalog()

        XCTAssertTrue(source.contains(Self.workflowInstructionTitle))
        XCTAssertTrue(source.contains("Create a Custom Workflow"))
        XCTAssertTrue(source.contains("Action Target"))
        XCTAssertTrue(source.contains("Create Linear Issue"))
        XCTAssertTrue(source.contains(Self.copyInstructionTitle))
        XCTAssertEqual(catalog.localizedValue(for: Self.workflowInstructionTitle), "Workflow-Anweisung")
        XCTAssertEqual(
            catalog.localizedValue(for: Self.workflowInstructionHelp),
            "Erstelle einen eigenen Workflow, füge dies in Anweisung ein und setze das Action-Ziel auf \"Create Linear Issue\"."
        )
        XCTAssertEqual(catalog.localizedValue(for: Self.copyInstructionTitle), "Anweisung kopieren")
    }

    func testSettingsCopyDoesNotReferenceLegacyPromptActionFlow() throws {
        let source = try String(contentsOf: Self.pluginRoot.appendingPathComponent("LinearPlugin.swift"), encoding: .utf8)
        let catalog = try String(contentsOf: Self.pluginRoot.appendingPathComponent("Localizable.xcstrings"), encoding: .utf8)
        let combinedCopy = source + "\n" + catalog

        for staleTerm in ["PromptAction", "Recommended Prompt", "Copy Prompt", "Create a new PromptAction"] {
            XCTAssertFalse(combinedCopy.contains(staleTerm), "\(staleTerm) should not appear in Linear settings copy")
        }
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
