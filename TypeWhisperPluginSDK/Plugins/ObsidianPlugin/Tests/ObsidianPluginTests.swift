import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import ObsidianPlugin

final class ObsidianPluginTests: XCTestCase {
    private struct HistorySyncPayload: Encodable {
        let id: UUID
        let rawText: String
        let finalText: String
        let language: String?
        let engineUsed: String
        let modelUsed: String?
        let durationSeconds: Double
        let appName: String?
        let bundleIdentifier: String?
        let url: String?
        let pipelineSteps: [String]
    }

    private struct StoredNoteContext: Codable {
        let timestamp: Date
        let rawText: String
        let finalText: String
        let appName: String?
        let bundleIdentifier: String?
        let url: String?
        let language: String?
        let engineUsed: String?
        let modelUsed: String?
        let durationSeconds: Double?
        let pipelineSteps: [String]
    }

    private struct StoredLiveSyncEntry: Codable {
        let path: String
        let context: StoredNoteContext
        let awaitingCompletion: Bool
    }

    private static let historySyncActionID = "com.typewhisper.history.transcription-updated"
    private static let workflowInstructionTitle = "Workflow Instruction"
    private static let workflowInstructionHelp = "Create a Custom Workflow, paste this into Instruction, and set Action Target to \"Save to Obsidian\"."
    private static let copyInstructionTitle = "Copy Instruction"

    func testManifestDeclaresVersionAndHostBoundary() throws {
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(contentsOf: Self.pluginRoot.appendingPathComponent("manifest.json"))
        )

        XCTAssertEqual(manifest.id, "com.typewhisper.obsidian")
        XCTAssertEqual(manifest.version, "1.1.0")
        XCTAssertEqual(manifest.minHostVersion, "1.6.0")
        XCTAssertEqual(manifest.sdkCompatibilityVersion, "v1")
    }

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
            "frontmatterTags": ["team: voice", "#capture"],
        ])
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        let result = try await plugin.execute(
            input: "Captured text",
            context: ActionContext(
                appName: "Research: Notes #1",
                bundleIdentifier: "com.apple.Notes",
                url: "https://example.com/search?q=voice#result",
                language: "en: US",
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
        XCTAssertTrue(content.contains("app: \"Research: Notes #1\""))
        XCTAssertTrue(content.contains("bundleId: \"com.apple.Notes\""))
        XCTAssertTrue(content.contains("url: \"https://example.com/search?q=voice#result\""))
        XCTAssertTrue(content.contains("language: \"en: US\""))
        XCTAssertTrue(content.contains("  - \"team: voice\""))
        XCTAssertTrue(content.contains("  - \"#capture\""))
        XCTAssertTrue(content.contains("Captured text"))
    }

    func testIndividualNoteTemplateResolvesAvailableMetadataAndSanitizesFilename() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultTemplate")
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let host = try PluginTestHostServices(defaults: [
            "vaultPath": vaultURL.path,
            "subfolder": "",
            "filenameTemplate": "[{{APP}}]: report?",
            "noteTemplate": "# {{app}}\n\n{{transcript}}\n\nOriginal: {{raw_transcript}}\nWords: {{words}}",
            "frontmatterEnabled": false,
        ])
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        let result = try await plugin.execute(
            input: "Clean final text",
            context: ActionContext(appName: "Notes", originalText: "Raw text")
        )

        XCTAssertTrue(result.success)
        let files = try FileManager.default.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), ["Notes report.md"])
        let content = try String(contentsOf: try XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertEqual(content, "# Notes\n\nClean final text\n\nOriginal: Raw text\nWords: 3")
    }

    func testAutoExportLiveSyncUpdatesSameFileAfterPluginReactivation() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultLiveSync")
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let id = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let timestamp = Date()
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: [
                "vaultPath": vaultURL.path,
                "subfolder": "Captured",
                "filenameTemplate": "{{DATE}} {{TIME}}",
                "noteTemplate": "## Transcript\n\n{{TRANSCRIPT}}",
                "frontmatterEnabled": true,
                "autoExportEnabled": true,
                "liveSyncEnabled": true,
            ],
            eventBus: eventBus
        )
        var plugin: ObsidianPlugin? = ObsidianPlugin()
        plugin?.activate(host: host)

        await eventBus.emit(.transcriptionCompleted(TranscriptionCompletedPayload(
            timestamp: timestamp,
            rawText: "Initial raw text",
            finalText: "Initial final text",
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "TDT",
            durationSeconds: 4,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            ruleName: nil
        )))

        let folderURL = vaultURL.appendingPathComponent("Captured", isDirectory: true)
        let initialFiles = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        let noteURL = try XCTUnwrap(initialFiles.first)
        XCTAssertEqual(initialFiles.count, 1)
        XCTAssertTrue(try String(contentsOf: noteURL, encoding: .utf8).contains("Initial final text"))

        plugin?.deactivate()
        plugin = ObsidianPlugin()
        plugin?.activate(host: host)

        await eventBus.emit(try Self.historyUpdateEvent(
            id: id,
            timestamp: timestamp,
            rawText: "Initial raw text",
            finalText: "Corrected final text",
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "TDT",
            durationSeconds: 4,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            pipelineSteps: []
        ))

        let updatedFiles = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(updatedFiles, initialFiles)
        let updatedContent = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("Corrected final text"))
        XCTAssertFalse(updatedContent.contains("Initial final text"))
        plugin?.deactivate()
    }

    func testWorkflowActionLiveSyncPersistsMappingWithoutDuplicateAutoExport() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultWorkflowLiveSync")
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let id = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let timestamp = Date()
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: [
                "vaultPath": vaultURL.path,
                "subfolder": "Captured",
                "filenameTemplate": "{{DATE}} {{TIME}}",
                "noteTemplate": "{{TRANSCRIPT}}\n\nEngine: {{ENGINE}}\nProcessing: {{PROCESSING}}",
                "frontmatterEnabled": true,
                "autoExportEnabled": true,
                "liveSyncEnabled": true,
            ],
            eventBus: eventBus
        )
        var plugin: ObsidianPlugin? = ObsidianPlugin()
        plugin?.activate(host: host)

        let result = try await plugin?.execute(
            input: "Workflow result",
            context: ActionContext(
                appName: "Notes",
                language: "en",
                originalText: "Raw workflow text"
            )
        )
        XCTAssertEqual(result?.success, true)

        await eventBus.emit(.transcriptionCompleted(TranscriptionCompletedPayload(
            timestamp: timestamp,
            rawText: "Raw workflow text",
            finalText: "Workflow result",
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "TDT",
            durationSeconds: 4,
            appName: "Notes",
            ruleName: nil
        )))

        let folderURL = vaultURL.appendingPathComponent("Captured", isDirectory: true)
        let initialFiles = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        let noteURL = try XCTUnwrap(initialFiles.first)
        XCTAssertEqual(initialFiles.count, 1)
        let initialContent = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(initialContent.contains("Engine: parakeet"))

        plugin?.deactivate()
        plugin = ObsidianPlugin()
        plugin?.activate(host: host)
        await eventBus.emit(try Self.historyUpdateEvent(
            id: id,
            timestamp: timestamp,
            rawText: "Raw workflow text",
            finalText: "Corrected workflow result",
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "TDT",
            durationSeconds: 4,
            appName: "Notes",
            bundleIdentifier: nil,
            pipelineSteps: ["Cleanup"]
        ))

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil),
            initialFiles
        )
        let updatedContent = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(updatedContent.contains("Corrected workflow result"))
        XCTAssertTrue(updatedContent.contains("Processing: Cleanup"))
        plugin?.deactivate()
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
        XCTAssertTrue(content.contains("---\n\n## "), "The default timestamp-section format should remain unchanged.")
        XCTAssertNotNil(
            content.range(of: #"## \d{2}:\d{2}"#, options: .regularExpression),
            "The default timestamp should retain the legacy HH:mm format."
        )
    }

    func testDailyNoteUsesCustomAppendTemplate() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultCustomAppend")
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let host = try PluginTestHostServices(defaults: [
            "vaultPath": vaultURL.path,
            "dailyNoteEnabled": true,
            "dailyNoteAppendTemplate": "- {{TEXT}} ({{APP}} / {{LANGUAGE}} / {{URL}})",
            "frontmatterEnabled": false,
        ])
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        for text in ["First note", "Second note"] {
            let result = try await plugin.execute(
                input: text,
                context: ActionContext(
                    appName: "Notes",
                    url: "https://example.com",
                    language: "en",
                    originalText: text
                )
            )
            XCTAssertTrue(result.success)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: vaultURL.appendingPathComponent("TypeWhisper", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)

        let content = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertEqual(content, "- First note (Notes / en / https://example.com)\n\n- Second note (Notes / en / https://example.com)")
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
        XCTAssertFalse(content.contains("app: \"Brave Browser\""))
        XCTAssertFalse(content.contains("bundleId: \"com.brave.Browser\""))
        XCTAssertFalse(content.contains("url: \"https://example.com\""))
        XCTAssertTrue(content.contains("language: \"it\""))
        XCTAssertTrue(content.contains("First entry"))
    }

    func testActivationPrunesExpiredEntriesAndCapsPersistentLiveSyncStore() throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultPruning")
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let now = Date()
        let context: (Date) -> StoredNoteContext = { timestamp in
            StoredNoteContext(
                timestamp: timestamp,
                rawText: "Raw text",
                finalText: "Final text",
                appName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                url: nil,
                language: "en",
                engineUsed: "test",
                modelUsed: nil,
                durationSeconds: 1,
                pipelineSteps: []
            )
        }
        var storedEntries: [String: StoredLiveSyncEntry] = [
            "expired": StoredLiveSyncEntry(
                path: vaultURL.appendingPathComponent("expired.md").path,
                context: context(now.addingTimeInterval(-31 * 24 * 60 * 60)),
                awaitingCompletion: false
            ),
        ]
        for index in 0...500 {
            let key = String(format: "recent-%03d", index)
            storedEntries[key] = StoredLiveSyncEntry(
                path: vaultURL.appendingPathComponent("\(key).md").path,
                context: context(now.addingTimeInterval(-TimeInterval(index))),
                awaitingCompletion: false
            )
        }

        let host = try PluginTestHostServices(defaults: [
            "vaultPath": vaultURL.path,
            "liveSyncEntries": try JSONEncoder().encode(storedEntries),
        ])
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        let persistedData = try XCTUnwrap(host.userDefault(forKey: "liveSyncEntries") as? Data)
        let persistedEntries = try JSONDecoder().decode([String: StoredLiveSyncEntry].self, from: persistedData)
        XCTAssertEqual(persistedEntries.count, 500)
        XCTAssertNil(persistedEntries["expired"])
        XCTAssertNotNil(persistedEntries["recent-000"])
        XCTAssertNil(persistedEntries["recent-500"])
        plugin.deactivate()
    }

    func testLiveSyncRejectsPersistedEntryThroughSymlinkOutsideConfiguredVault() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultContainment")
        let outsideURL = try Self.makeTemporaryDirectory(prefix: "ObsidianOutsideVault")
        defer {
            try? FileManager.default.removeItem(at: vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let outsideNoteURL = outsideURL.appendingPathComponent("outside.md")
        try "Original outside content".write(to: outsideNoteURL, atomically: true, encoding: .utf8)
        let symlinkURL = vaultURL.appendingPathComponent("linked-outside", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)
        let persistedNoteURL = symlinkURL.appendingPathComponent("outside.md")
        let timestamp = Date()
        let storedEntry = StoredLiveSyncEntry(
            path: persistedNoteURL.path,
            context: Self.storedNoteContext(timestamp: timestamp),
            awaitingCompletion: false
        )
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: [
                "vaultPath": vaultURL.path,
                "liveSyncEnabled": true,
                "liveSyncEntries": try JSONEncoder().encode([
                    Self.liveSyncKey(for: timestamp): storedEntry,
                ]),
            ],
            eventBus: eventBus
        )
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        await eventBus.emit(try Self.historyUpdateEvent(
            id: UUID(),
            timestamp: timestamp,
            rawText: "Raw text",
            finalText: "Changed content",
            language: "en",
            engineUsed: "test",
            modelUsed: nil,
            durationSeconds: 1,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            pipelineSteps: []
        ))

        XCTAssertEqual(try String(contentsOf: outsideNoteURL, encoding: .utf8), "Original outside content")
        let persistedData = try XCTUnwrap(host.userDefault(forKey: "liveSyncEntries") as? Data)
        XCTAssertTrue(try JSONDecoder().decode([String: StoredLiveSyncEntry].self, from: persistedData).isEmpty)
        plugin.deactivate()
    }

    func testDailyNoteModeIgnoresHistoryLiveSyncEvents() async throws {
        let vaultURL = try Self.makeTemporaryDirectory(prefix: "ObsidianVaultDailyGuard")
        defer { try? FileManager.default.removeItem(at: vaultURL) }
        let noteURL = vaultURL.appendingPathComponent("tracked.md")
        try "Original daily content".write(to: noteURL, atomically: true, encoding: .utf8)
        let timestamp = Date()
        let storedEntry = StoredLiveSyncEntry(
            path: noteURL.path,
            context: Self.storedNoteContext(timestamp: timestamp),
            awaitingCompletion: false
        )
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(
            defaults: [
                "vaultPath": vaultURL.path,
                "dailyNoteEnabled": true,
                "liveSyncEnabled": true,
                "liveSyncEntries": try JSONEncoder().encode([
                    Self.liveSyncKey(for: timestamp): storedEntry,
                ]),
            ],
            eventBus: eventBus
        )
        let plugin = ObsidianPlugin()
        plugin.activate(host: host)

        await eventBus.emit(try Self.historyUpdateEvent(
            id: UUID(),
            timestamp: timestamp,
            rawText: "Raw text",
            finalText: "Changed content",
            language: "en",
            engineUsed: "test",
            modelUsed: nil,
            durationSeconds: 1,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            pipelineSteps: []
        ))

        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "Original daily content")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path), ["tracked.md"])
        plugin.deactivate()
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

    private static func historyUpdateEvent(
        id: UUID,
        timestamp: Date,
        rawText: String,
        finalText: String,
        language: String?,
        engineUsed: String,
        modelUsed: String?,
        durationSeconds: Double,
        appName: String?,
        bundleIdentifier: String?,
        url: String? = nil,
        pipelineSteps: [String]
    ) throws -> TypeWhisperEvent {
        let payload = HistorySyncPayload(
            id: id,
            rawText: rawText,
            finalText: finalText,
            language: language,
            engineUsed: engineUsed,
            modelUsed: modelUsed,
            durationSeconds: durationSeconds,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            url: url,
            pipelineSteps: pipelineSteps
        )
        let message = try XCTUnwrap(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        return .actionCompleted(ActionCompletedPayload(
            timestamp: timestamp,
            actionId: historySyncActionID,
            success: true,
            message: message,
            url: url,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ))
    }

    private static func storedNoteContext(timestamp: Date) -> StoredNoteContext {
        StoredNoteContext(
            timestamp: timestamp,
            rawText: "Raw text",
            finalText: "Final text",
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            url: nil,
            language: "en",
            engineUsed: "test",
            modelUsed: nil,
            durationSeconds: 1,
            pipelineSteps: []
        )
    }

    private static func liveSyncKey(for timestamp: Date) -> String {
        String(timestamp.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
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
