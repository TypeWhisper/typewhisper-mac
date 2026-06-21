import XCTest
@testable import TypeWhisper

final class HistoryServiceTests: XCTestCase {
    @MainActor
    func testAddSearchUniqueDomainsAndPurgeHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = HistoryService(appSupportDirectory: appSupportDirectory)
        service.clearAll()

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

        service.purgeOldRecords(retentionDays: 30)

        XCTAssertEqual(service.records.count, 1)
        XCTAssertEqual(service.totalRecords, 1)
        XCTAssertEqual(service.totalWords, 3)
    }
}
