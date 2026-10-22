import CoreData
import Foundation
import SwiftData
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

@MainActor
final class HistoryLLMUsageTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        directories.forEach(TestSupport.remove)
        directories = []
        try await super.tearDown()
    }

    // MARK: - Summing requests

    func testRequestsToTheSameProviderAndModelAreSummed() {
        var usage = HistoryLLMUsage(entries: [])
        usage.addRequest(
            providerId: "Claude", providerName: "Claude", requestedModel: "claude-haiku-4-5",
            reports: [PluginLLMUsage(inputTokens: 100, outputTokens: 20)]
        )
        usage.addRequest(
            providerId: "Claude", providerName: "Claude", requestedModel: "claude-haiku-4-5",
            reports: [PluginLLMUsage(inputTokens: 50, outputTokens: 5)]
        )
        // The model the provider names wins over the requested alias.
        usage.addRequest(
            providerId: "OpenRouter", providerName: "OpenRouter", requestedModel: "openrouter/auto",
            reports: [PluginLLMUsage(inputTokens: 7, outputTokens: 3, model: "meta-llama/llama-3.3-70b")]
        )

        XCTAssertEqual(usage.entries, [
            HistoryLLMUsage.Entry(
                providerId: "Claude", providerName: "Claude", model: "claude-haiku-4-5",
                requestCount: 2, inputTokens: 150, outputTokens: 25
            ),
            HistoryLLMUsage.Entry(
                providerId: "OpenRouter", providerName: "OpenRouter", model: "meta-llama/llama-3.3-70b",
                requestCount: 1, inputTokens: 7, outputTokens: 3
            ),
        ])
        XCTAssertEqual(usage.inputTokens, 157)
        XCTAssertEqual(usage.outputTokens, 28)
        XCTAssertEqual(usage.requestCount, 3)
    }

    func testRequestWithoutReportCountsWithUnknownTokens() {
        var usage = HistoryLLMUsage(entries: [])
        usage.addRequest(providerId: "appleIntelligence", providerName: "Apple Intelligence", requestedModel: nil, reports: [])

        XCTAssertEqual(usage.entries, [
            HistoryLLMUsage.Entry(providerId: "appleIntelligence", providerName: "Apple Intelligence", requestCount: 1),
        ])
        XCTAssertNil(usage.inputTokens)
        XCTAssertNil(usage.outputTokens)
        XCTAssertFalse(usage.hasTokenCounts)
    }

    func testTotalsSumOnlyReportedCounts() {
        var usage = HistoryLLMUsage(entries: [])
        usage.addRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [
            PluginLLMUsage(inputTokens: 10, outputTokens: nil),
        ])
        usage.addRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [])
        usage.addRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [
            PluginLLMUsage(inputTokens: 5, outputTokens: 2),
        ])

        XCTAssertEqual(usage.entries.count, 1)
        XCTAssertEqual(usage.entries[0].requestCount, 3)
        XCTAssertEqual(usage.inputTokens, 15)
        XCTAssertEqual(usage.outputTokens, 2)
    }

    func testDecodingDropsWhatThisBuildCannotRead() throws {
        let json = #"""
        {"entries":[
          {"providerId":"Claude","providerName":"Claude","model":"claude-haiku-4-5","requestCount":0,"inputTokens":-4,"outputTokens":12,"futureField":true},
          {"providerName":"No ID"},
          {"providerId":"  "},
          "not an entry"
        ],"futureTotals":{"costUSD":0.1}}
        """#

        let usage = try JSONDecoder().decode(HistoryLLMUsage.self, from: Data(json.utf8))

        XCTAssertEqual(usage.entries, [
            HistoryLLMUsage.Entry(
                providerId: "Claude", providerName: "Claude", model: "claude-haiku-4-5",
                requestCount: 1, inputTokens: nil, outputTokens: 12
            ),
        ])
    }

    func testEqualUsageEncodesToEqualBytes() throws {
        let usage = Self.claudeUsage(input: 1_284, output: 18)
        let decoded = try XCTUnwrap(HistoryLLMUsage.decode(usage.encodedData()))

        XCTAssertEqual(decoded, usage)
        XCTAssertEqual(decoded.encodedData(), usage.encodedData())
    }

    // MARK: - Ledger

    func testLedgerCollectsRequestsFromChildAndUnstructuredTasks() async {
        let ledger = LLMUsageLedger()

        await LLMUsageLedger.$current.withValue(ledger) {
            LLMUsageLedger.current?.recordRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [
                PluginLLMUsage(inputTokens: 1, outputTokens: 1),
            ])
            // Workflow segments run in unstructured tasks, which inherit the ledger.
            await Task { @MainActor in
                LLMUsageLedger.current?.recordRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [
                    PluginLLMUsage(inputTokens: 2, outputTokens: 2),
                ])
            }.value
            await Task.detached {
                LLMUsageLedger.current?.recordRequest(providerId: "detached", providerName: nil, requestedModel: nil, reports: [])
            }.value
        }

        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(providerId: "p", model: "m", requestCount: 2, inputTokens: 3, outputTokens: 3),
        ])
    }

    func testLedgerMergeAddsTheOtherLedgerOnce() {
        let ledger = LLMUsageLedger()
        let incremental = LLMUsageLedger()
        ledger.recordRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [
            PluginLLMUsage(inputTokens: 10, outputTokens: 1),
        ])
        incremental.recordRequest(providerId: "p", providerName: nil, requestedModel: "m", reports: [
            PluginLLMUsage(inputTokens: 5, outputTokens: 1),
        ])

        ledger.merge(incremental)
        ledger.merge(ledger)
        ledger.merge(nil)
        ledger.merge(LLMUsageLedger())

        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(providerId: "p", model: "m", requestCount: 2, inputTokens: 15, outputTokens: 2),
        ])
        XCTAssertNil(LLMUsageLedger().usage)
    }

    // MARK: - Storage

    func testRecordKeepsUsageAcrossRelaunchAndOtherRecordsHaveNone() throws {
        let directory = try makeDirectory()
        let withUsage = UUID()
        let withoutUsage = UUID()
        do {
            let history = HistoryService(appSupportDirectory: directory)
            XCTAssertTrue(history.addRecord(
                id: withUsage, rawText: "raw", finalText: "final", appName: nil, appBundleIdentifier: nil,
                durationSeconds: 2, language: "en", engineUsed: "parakeet", audioFileName: nil,
                llmUsage: Self.claudeUsage(input: 120, output: 30)
            ))
            XCTAssertTrue(history.addRecord(
                id: withoutUsage, rawText: "raw", finalText: "raw", appName: nil, appBundleIdentifier: nil,
                durationSeconds: 2, language: "en", engineUsed: "parakeet", audioFileName: nil
            ))
        }

        let reopened = HistoryService(appSupportDirectory: directory)

        XCTAssertEqual(reopened.record(withID: withUsage)?.llmUsage, Self.claudeUsage(input: 120, output: 30))
        XCTAssertNil(reopened.record(withID: withoutUsage)?.llmUsage)
        XCTAssertNil(reopened.record(withID: withoutUsage)?.llmUsageData)
    }

    func testExplicitlyEmptyUsageReadsAsNoUsage() {
        let record = TranscriptionRecord(rawText: "a", finalText: "a", durationSeconds: 1, engineUsed: "e")
        record.llmUsageData = HistoryLLMUsage(entries: []).encodedData()

        XCTAssertNil(record.llmUsage)
        XCTAssertEqual(HistoryLLMUsage.decode(record.llmUsageData), HistoryLLMUsage(entries: []))
    }

    /// A store written before `llmUsageData` existed must open by lightweight
    /// migration. A failed migration makes `SwiftDataStoreFactory` delete the store.
    func testHistoryStoreFromBeforeUsageOpensWithoutReset() throws {
        let directory = try makeDirectory()
        let storeURL = directory.appendingPathComponent("history.store")
        let recordID = UUID()

        let currentModel = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: [TranscriptionRecord.self]))
        let earlierModel = try XCTUnwrap(currentModel.copy() as? NSManagedObjectModel)
        let entity = try XCTUnwrap(earlierModel.entitiesByName["TranscriptionRecord"])
        entity.properties = entity.properties.filter { $0.name != "llmUsageData" }
        XCTAssertNotNil(currentModel.entitiesByName["TranscriptionRecord"]?.attributesByName["llmUsageData"])
        XCTAssertNil(entity.attributesByName["llmUsageData"])

        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: earlierModel)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let object = NSManagedObject(entity: entity, insertInto: context)
            for (name, attribute) in entity.attributesByName where !attribute.isOptional && attribute.defaultValue == nil {
                object.setValue(Self.placeholder(for: attribute.attributeType), forKey: name)
            }
            object.setValue(recordID, forKey: "id")
            object.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "timestamp")
            object.setValue("written before usage", forKey: "rawText")
            object.setValue("Written before usage.", forKey: "finalText")
            object.setValue("parakeet", forKey: "engineUsed")
            object.setValue(3.5, forKey: "durationSeconds")
            try context.save()
            try coordinator.remove(store)
        }

        let history = HistoryService(appSupportDirectory: directory)

        let record = try XCTUnwrap(history.record(withID: recordID), "The store was reset instead of migrated")
        XCTAssertEqual(record.finalText, "Written before usage.")
        XCTAssertEqual(record.durationSeconds, 3.5)
        XCTAssertNil(record.llmUsageData)
        XCTAssertNil(record.llmUsage)
    }

    func testEditingTheTextKeepsTheUsage() throws {
        let directory = try makeDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        let id = UUID()
        XCTAssertTrue(history.addRecord(
            id: id, timestamp: Date(timeIntervalSinceNow: -60), rawText: "raw", finalText: "Processed.",
            appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "en", engineUsed: "parakeet",
            audioFileName: nil, llmUsage: Self.claudeUsage(input: 100, output: 10)
        ))
        let record = try XCTUnwrap(history.record(withID: id))

        // The tokens were used for the processed text; a manual edit does not undo that.
        history.updateRecord(record, finalText: "Edited by hand.")

        XCTAssertEqual(record.finalText, "Edited by hand.")
        XCTAssertEqual(record.llmUsage, Self.claudeUsage(input: 100, output: 10))
    }

    // MARK: - Versions

    func testVersionsFromBeforeUsageDecodeWithoutIt() throws {
        let version = HistoryTranscriptionVersion(rawText: "r", finalText: "f", engineID: "parakeet")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([version])) as? [[String: Any]])
        json[0].removeValue(forKey: "llmUsageData")
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode([HistoryTranscriptionVersion].self, from: data)

        XCTAssertEqual(decoded.first?.finalText, "f")
        XCTAssertNil(decoded.first?.llmUsageData)
    }

    func testPromotingAVersionMakesItsUsageTheEntrysUsage() throws {
        let directory = try makeDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        let id = UUID()
        XCTAssertTrue(history.addRecord(
            id: id, rawText: "original raw", finalText: "Original final.", appName: nil, appBundleIdentifier: nil,
            durationSeconds: 2, language: "en", engineUsed: "parakeet", audioFileName: nil,
            llmUsage: Self.claudeUsage(input: 100, output: 10)
        ))
        let record = try XCTUnwrap(history.record(withID: id))
        let original = HistoryTranscriptionVersion.capture(record)
        var rerun = HistoryTranscriptionVersion(rawText: "new raw", finalText: "New final.", engineID: "parakeet")
        rerun.llmUsageData = HistoryLLMUsage(entries: []).encodedData()
        var workflowRun = HistoryTranscriptionVersion(rawText: "new raw", finalText: "Rewritten final.", engineID: "parakeet")
        workflowRun.llmUsageData = Self.claudeUsage(input: 300, output: 40).encodedData()

        try history.appendTranscriptionVersion(rerun, to: record, expected: original)
        try history.appendTranscriptionVersion(workflowRun, to: record, expected: original)
        XCTAssertEqual(record.llmUsage, Self.claudeUsage(input: 100, output: 10), "Saving a run does not change the entry")

        try history.promoteTranscriptionVersion(rerun.id, in: record)
        XCTAssertNil(record.llmUsage)
        XCTAssertEqual(HistoryLLMUsage.decode(record.llmUsageData), HistoryLLMUsage(entries: []))

        try history.promoteTranscriptionVersion(workflowRun.id, in: record)
        XCTAssertEqual(record.llmUsage, Self.claudeUsage(input: 300, output: 40))
        XCTAssertTrue(try XCTUnwrap(record.savedTranscriptionVersions().first { $0.id == workflowRun.id }).isActive(in: record))

        try history.promoteTranscriptionVersion(record.id, in: record)
        XCTAssertEqual(record.llmUsage, Self.claudeUsage(input: 100, output: 10))
        XCTAssertTrue(try XCTUnwrap(record.savedTranscriptionVersions().first { $0.id == record.id }).isActive(in: record))
    }

    // MARK: - Sync

    func testSyncContentCarriesUsageOnlyWhenTheEntryHasIt() throws {
        let withUsage = Self.content(llmUsage: Self.claudeUsage(input: 9, output: 2))
        let withoutUsage = Self.content(llmUsage: nil)

        let encodedWith = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withUsage)) as? [String: Any]
        let encodedWithout = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withoutUsage)) as? [String: Any]

        XCTAssertNotNil(encodedWith?["llmUsage"])
        XCTAssertNil(encodedWithout?["llmUsage"])
        XCTAssertEqual(
            try JSONDecoder().decode(UserDataSyncHistoryContentV1.self, from: JSONEncoder().encode(withUsage)),
            withUsage
        )
    }

    func testSyncContentFromOlderClientsAndUnreadableUsageStillDecodes() throws {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.content(llmUsage: nil))) as? [String: Any]
        )
        let older = try JSONDecoder().decode(
            UserDataSyncHistoryContentV1.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(older.llmUsage)

        json["llmUsage"] = "a shape from a future build"
        let unreadable = try JSONDecoder().decode(
            UserDataSyncHistoryContentV1.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(unreadable.finalText, "Synced final.")
        XCTAssertNil(unreadable.llmUsage)
    }

    func testRemoteContentWithoutUsageKeepsTheUsageThisMacKnows() throws {
        let suite = "HistoryLLMUsageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let directory = try makeDirectory()
        let history = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences)
        let id = UUID()
        XCTAssertTrue(history.addRecord(
            id: id, timestamp: Date(timeIntervalSinceNow: -60), rawText: "raw", finalText: "Local final.",
            appName: nil, appBundleIdentifier: nil, durationSeconds: 2, language: "en", engineUsed: "parakeet",
            audioFileName: nil, llmUsage: Self.claudeUsage(input: 100, output: 10)
        ))
        let record = try XCTUnwrap(history.record(withID: id))
        XCTAssertEqual(
            history.userDataSyncHistoryRecords().first { $0.content.recordID == id }?.content.llmUsage,
            Self.claudeUsage(input: 100, output: 10)
        )

        // An older client edited the text and sent content without the key.
        try history.applyUserDataSyncMutations([
            .upsertHistoryContent(Self.content(recordID: id, finalText: "Edited elsewhere.", updatedAt: Date(), llmUsage: nil)),
        ])
        XCTAssertEqual(record.finalText, "Edited elsewhere.")
        XCTAssertEqual(record.llmUsage, Self.claudeUsage(input: 100, output: 10))

        // A newer client replaced the text with a workflow run of its own.
        try history.applyUserDataSyncMutations([
            .upsertHistoryContent(Self.content(
                recordID: id, finalText: "Rewritten elsewhere.", updatedAt: Date().addingTimeInterval(1),
                llmUsage: Self.claudeUsage(input: 400, output: 50)
            )),
        ])
        XCTAssertEqual(record.llmUsage, Self.claudeUsage(input: 400, output: 50))

        // A text made without an LLM clears it.
        try history.applyUserDataSyncMutations([
            .upsertHistoryContent(Self.content(
                recordID: id, finalText: "Transcribed again.", updatedAt: Date().addingTimeInterval(2),
                llmUsage: HistoryLLMUsage(entries: [])
            )),
        ])
        XCTAssertNil(record.llmUsage)
        XCTAssertEqual(
            history.userDataSyncHistoryRecords().first { $0.content.recordID == id }?.content.llmUsage,
            HistoryLLMUsage(entries: []),
            "The cleared state is sent on, so other Macs clear it too"
        )
    }

    func testRemoteRecordWithUsageIsCreatedWithIt() throws {
        let directory = try makeDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        let id = UUID()

        try history.applyUserDataSyncMutations([
            .upsertHistoryContent(Self.content(recordID: id, finalText: "From another Mac.",
                                               llmUsage: Self.claudeUsage(input: 64, output: 8))),
        ])

        XCTAssertEqual(history.record(withID: id)?.finalText, "From another Mac.")
        XCTAssertEqual(history.record(withID: id)?.llmUsage, Self.claudeUsage(input: 64, output: 8))
    }

    // MARK: - Local API

    func testHistoryAPIReturnsUsageOnlyForEntriesThatHaveIt() throws {
        let directory = try makeDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        var usage = Self.claudeUsage(input: 1_284, output: 18)
        usage.addRequest(providerId: "appleIntelligence", providerName: "Apple Intelligence", requestedModel: nil, reports: [])
        XCTAssertTrue(history.addRecord(
            rawText: "with usage", finalText: "With usage.", appName: nil, appBundleIdentifier: nil,
            durationSeconds: 1, language: "en", engineUsed: "parakeet", llmUsage: usage
        ))
        XCTAssertTrue(history.addRecord(
            rawText: "without usage", finalText: "without usage", appName: nil, appBundleIdentifier: nil,
            durationSeconds: 1, language: "en", engineUsed: "parakeet"
        ))

        let response = APIHandlers.historyResponse(
            HTTPRequest(method: "GET", path: "/v1/history", queryParams: [:], headers: [:], body: Data()),
            historyService: history,
            speakerVoices: nil
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let entries = try XCTUnwrap(body["entries"] as? [[String: Any]])
        let withUsage = try XCTUnwrap(entries.first { $0["text"] as? String == "With usage." })
        let withoutUsage = try XCTUnwrap(entries.first { $0["text"] as? String == "without usage" })

        XCTAssertNil(withoutUsage["llm_usage"])
        let llmUsage = try XCTUnwrap(withUsage["llm_usage"] as? [String: Any])
        XCTAssertEqual(llmUsage["input_tokens"] as? Int, 1_284)
        XCTAssertEqual(llmUsage["output_tokens"] as? Int, 18)
        XCTAssertEqual(llmUsage["requests"] as? Int, 2)
        let providers = try XCTUnwrap(llmUsage["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0]["provider"] as? String, "Claude")
        XCTAssertEqual(providers[0]["provider_name"] as? String, "Claude")
        XCTAssertEqual(providers[0]["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(providers[0]["requests"] as? Int, 1)
        XCTAssertEqual(providers[0]["input_tokens"] as? Int, 1_284)
        XCTAssertEqual(providers[0]["output_tokens"] as? Int, 18)
        // Apple Intelligence reports no counts: the keys are absent, not zero.
        XCTAssertEqual(providers[1]["provider"] as? String, "appleIntelligence")
        XCTAssertNil(providers[1]["model"])
        XCTAssertNil(providers[1]["input_tokens"])
        XCTAssertNil(providers[1]["output_tokens"])
    }

    func testHistoryAPIOmitsTotalsNoRequestReported() throws {
        let directory = try makeDirectory()
        let history = HistoryService(appSupportDirectory: directory)
        var usage = HistoryLLMUsage(entries: [])
        usage.addRequest(providerId: "appleIntelligence", providerName: "Apple Intelligence", requestedModel: nil, reports: [])
        XCTAssertTrue(history.addRecord(
            rawText: "raw", finalText: "On device.", appName: nil, appBundleIdentifier: nil,
            durationSeconds: 1, language: "en", engineUsed: "parakeet", llmUsage: usage
        ))

        let response = APIHandlers.historyResponse(
            HTTPRequest(method: "GET", path: "/v1/history", queryParams: [:], headers: [:], body: Data()),
            historyService: history,
            speakerVoices: nil
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let entry = try XCTUnwrap((body["entries"] as? [[String: Any]])?.first)
        let llmUsage = try XCTUnwrap(entry["llm_usage"] as? [String: Any])

        XCTAssertNil(llmUsage["input_tokens"])
        XCTAssertNil(llmUsage["output_tokens"])
        XCTAssertEqual(llmUsage["requests"] as? Int, 1)
    }

    // MARK: - Exports

    func testMarkdownAndJSONExportsIncludeUsageWhenPresent() throws {
        let record = TranscriptionRecord(rawText: "raw", finalText: "Final.", durationSeconds: 1, engineUsed: "parakeet")
        XCTAssertFalse(HistoryExporter.exportMarkdown(record).contains("**LLM:**"))
        XCTAssertFalse(HistoryExporter.exportJSON(record).contains("llmUsage"))

        var usage = Self.claudeUsage(input: 1_284, output: 18)
        usage.addRequest(providerId: "Claude", providerName: "Claude", requestedModel: "claude-haiku-4-5", reports: [
            PluginLLMUsage(inputTokens: 16, outputTokens: 2),
        ])
        record.llmUsage = usage

        let markdown = HistoryExporter.exportMarkdown(record)
        XCTAssertTrue(markdown.contains("- **LLM:** Claude · claude-haiku-4-5"), markdown)
        XCTAssertTrue(markdown.contains("- **Tokens:** 1300 input, 20 output, 2 requests"), markdown)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(HistoryExporter.exportJSON(record).utf8)) as? [String: Any]
        )
        let llmUsage = try XCTUnwrap(json["llmUsage"] as? [String: Any])
        XCTAssertEqual(llmUsage["inputTokens"] as? Int, 1_300)
        XCTAssertEqual(llmUsage["outputTokens"] as? Int, 20)
        XCTAssertEqual(llmUsage["requests"] as? Int, 2)
        let provider = try XCTUnwrap((llmUsage["providers"] as? [[String: Any]])?.first)
        XCTAssertEqual(provider["provider"] as? String, "Claude")
        XCTAssertEqual(provider["model"] as? String, "claude-haiku-4-5")
    }

    func testSettingsBackupRestoresUsageAndReadsOlderBackups() throws {
        let entry = SettingsBackupExporter.HistoryEntryDTO(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), rawText: "raw", finalText: "Final.",
            appName: nil, appBundleIdentifier: nil, appURL: nil, durationSeconds: 2, language: "en",
            engineUsed: "parakeet", modelUsed: nil, pipelineSteps: ["Workflow"],
            llmUsage: Self.claudeUsage(input: 50, output: 5)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let roundTripped = try decoder.decode(SettingsBackupExporter.HistoryEntryDTO.self, from: encoder.encode(entry))
        XCTAssertEqual(roundTripped.llmUsage, Self.claudeUsage(input: 50, output: 5))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(entry)) as? [String: Any])
        json.removeValue(forKey: "llmUsage")
        let older = try decoder.decode(
            SettingsBackupExporter.HistoryEntryDTO.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(older.llmUsage)
        XCTAssertEqual(older.pipelineSteps, ["Workflow"])

        json["llmUsage"] = 42
        let unreadable = try decoder.decode(
            SettingsBackupExporter.HistoryEntryDTO.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(unreadable.llmUsage)
        XCTAssertEqual(unreadable.finalText, "Final.")
    }

    // MARK: - Details text

    func testDetailsTextNamesProvidersAndTotals() {
        var usage = Self.claudeUsage(input: 1_284, output: 18)
        XCTAssertEqual(HistoryLLMUsageText.providers(usage), "Claude · claude-haiku-4-5")
        XCTAssertEqual(
            HistoryLLMUsageText.tokens(usage, locale: Locale(identifier: "en_US")),
            "1,284 input · 18 output"
        )

        usage.addRequest(providerId: "appleIntelligence", providerName: "Apple Intelligence", requestedModel: nil, reports: [])
        XCTAssertEqual(HistoryLLMUsageText.providers(usage), "Claude · claude-haiku-4-5\nApple Intelligence")
        XCTAssertEqual(
            HistoryLLMUsageText.tokens(usage, locale: Locale(identifier: "en_US")),
            "1,284 input · 18 output · 2 requests"
        )

        var onDevice = HistoryLLMUsage(entries: [])
        onDevice.addRequest(providerId: "appleIntelligence", providerName: nil, requestedModel: nil, reports: [])
        XCTAssertEqual(HistoryLLMUsageText.providers(onDevice), "appleIntelligence")
        XCTAssertNil(HistoryLLMUsageText.tokens(onDevice, locale: Locale(identifier: "en_US")))
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let directory = try TestSupport.makeTemporaryDirectory()
        directories.append(directory)
        return directory
    }

    private static func claudeUsage(input: Int, output: Int) -> HistoryLLMUsage {
        HistoryLLMUsage(entries: [
            HistoryLLMUsage.Entry(
                providerId: "Claude",
                providerName: "Claude",
                model: "claude-haiku-4-5",
                inputTokens: input,
                outputTokens: output
            ),
        ])
    }

    private static func content(
        recordID: UUID = UUID(),
        finalText: String = "Synced final.",
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        llmUsage: HistoryLLMUsage?
    ) -> UserDataSyncHistoryContentV1 {
        UserDataSyncHistoryContentV1(
            recordID: recordID,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: updatedAt,
            originDeviceID: "other-mac",
            originPlatform: "macOS",
            source: RecordingSource.mac.rawValue,
            processingState: RecordingProcessingState.ready.rawValue,
            rawTranscript: "synced raw",
            finalText: finalText,
            durationSeconds: 2,
            engineDisplayName: "parakeet",
            llmUsage: llmUsage
        )
    }

    private static func placeholder(for type: NSAttributeType) -> Any? {
        switch type {
        case .stringAttributeType: ""
        case .dateAttributeType: Date(timeIntervalSince1970: 0)
        case .doubleAttributeType, .floatAttributeType: 0.0
        case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: 0
        case .booleanAttributeType: false
        case .UUIDAttributeType: UUID()
        case .binaryDataAttributeType: Data()
        default: nil
        }
    }
}
