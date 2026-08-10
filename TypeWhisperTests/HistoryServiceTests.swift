import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class HistoryServiceTests: XCTestCase {
    @MainActor
    func testUpdateRecordEmitsCompletePluginSyncPayloadWithoutChangingSDKABI() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let id = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let timestamp = Date(timeIntervalSince1970: 1_754_668_800)
        var emittedEvents: [TypeWhisperEvent] = []
        let service = HistoryService(appSupportDirectory: appSupportDirectory) { event in
            emittedEvents.append(event)
        }

        service.addRecord(
            id: id,
            timestamp: timestamp,
            rawText: "Original text",
            finalText: "Original text",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            appURL: "https://example.com",
            durationSeconds: 7.5,
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "TDT",
            pipelineSteps: ["Cleanup"]
        )

        let record = try XCTUnwrap(service.records.first)
        service.updateRecord(record, finalText: "Corrected text")

        XCTAssertEqual(emittedEvents.count, 1)
        guard case .actionCompleted(let event) = try XCTUnwrap(emittedEvents.first) else {
            return XCTFail("Expected an actionCompleted plugin sync envelope")
        }
        XCTAssertEqual(event.actionId, HistoryService.pluginSyncActionID)
        XCTAssertEqual(event.timestamp, timestamp)
        XCTAssertEqual(event.appName, "Notes")
        XCTAssertEqual(event.url, "https://example.com")

        let data = try XCTUnwrap(event.message.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, id.uuidString)
        XCTAssertEqual(payload["rawText"] as? String, "Original text")
        XCTAssertEqual(payload["finalText"] as? String, "Corrected text")
        XCTAssertEqual(payload["pipelineSteps"] as? [String], ["Cleanup"])
    }

    @MainActor
    func testAddSearchUniqueDomainsAndPurgeHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        service.clearAll()
        let usageStatisticsService = UsageStatisticsService(appSupportDirectory: appSupportDirectory)

        service.addRecord(
            rawText: "Weekly planning meeting",
            finalText: "Weekly planning meeting",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            appURL: "https://www.github.com/TypeWhisper/typewhisper-mac",
            durationSeconds: 12,
            language: "en",
            engineUsed: "parakeet",
            audioSamples: Array(repeating: 0.25, count: 1600)
        )
        service.addRecord(
            rawText: "Older note",
            finalText: "Older note",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 8,
            language: "en",
            engineUsed: "parakeet"
        )

        XCTAssertEqual(service.records.count, 2)
        XCTAssertEqual(service.searchRecords(query: "planning").count, 1)
        XCTAssertEqual(service.uniqueDomains(), ["github.com"])
        XCTAssertNotNil(service.audioFileURL(for: service.records.first { $0.audioFileName != nil }!))

        let staleRecord = try XCTUnwrap(service.records.first(where: { $0.finalText == "Older note" }))
        staleRecord.timestamp = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
        service.updateRecord(staleRecord, finalText: staleRecord.finalText)
        usageStatisticsService.backfillFromHistoryIfNeeded(service.records)

        service.purgeOldRecords(retentionDays: 30)

        XCTAssertEqual(service.records.count, 1)
        XCTAssertEqual(service.totalRecords, 1)
        XCTAssertEqual(service.totalWords, 3)

        let allTimeUsage = usageStatisticsService.summary(from: nil)
        XCTAssertEqual(allTimeUsage.transcriptionCount, 2)
        XCTAssertEqual(allTimeUsage.words, 5)
        XCTAssertEqual(allTimeUsage.appCount, 2)
    }
}
