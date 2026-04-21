import XCTest
@testable import TypeWhisper

final class RecentTranscriptionStoreTests: XCTestCase {
    @MainActor
    func testMergedEntriesDedupesSessionAndHistoryAndSortsNewestFirst() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let store = RecentTranscriptionStore()
        let now = Date()

        let duplicatedID = UUID()
        historyService.addRecord(
            id: duplicatedID,
            rawText: "history newer",
            finalText: "History newer",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            durationSeconds: 1,
            language: "en",
            engineUsed: "mock"
        )
        historyService.addRecord(
            id: UUID(),
            rawText: "history oldest",
            finalText: "History oldest",
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 1,
            language: "en",
            engineUsed: "mock"
        )

        let newerHistory = try XCTUnwrap(historyService.records.first(where: { $0.id == duplicatedID }))
        newerHistory.timestamp = now.addingTimeInterval(-60)
        historyService.updateRecord(newerHistory, finalText: newerHistory.finalText)

        let olderHistory = try XCTUnwrap(historyService.records.first(where: { $0.id != duplicatedID }))
        olderHistory.timestamp = now.addingTimeInterval(-180)
        historyService.updateRecord(olderHistory, finalText: olderHistory.finalText)

        store.recordTranscription(
            id: duplicatedID,
            finalText: "Session duplicate",
            timestamp: now.addingTimeInterval(-120),
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari"
        )
        store.recordTranscription(
            id: UUID(),
            finalText: "Session newest",
            timestamp: now.addingTimeInterval(-30),
            appName: "Mail",
            appBundleIdentifier: "com.apple.mail"
        )

        let merged = store.mergedEntries(historyRecords: historyService.records)

        XCTAssertEqual(merged.map(\.finalText), ["Session newest", "History newer", "History oldest"])
        XCTAssertEqual(merged.count, 3)
    }

    @MainActor
    func testMergedEntriesFallsBackToSessionEntriesWhenHistoryIsEmpty() {
        let store = RecentTranscriptionStore()
        let id = UUID()

        store.recordTranscription(
            id: id,
            finalText: "Fallback session entry",
            timestamp: Date(),
            appName: "Slack",
            appBundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        let merged = store.mergedEntries(historyRecords: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, id)
        XCTAssertEqual(merged.first?.source, .session)
    }

    @MainActor
    func testSessionBufferIsLimitedToTwentyEntries() {
        let store = RecentTranscriptionStore()

        for index in 0..<25 {
            store.recordTranscription(
                id: UUID(),
                finalText: "Entry \(index)",
                timestamp: Date().addingTimeInterval(Double(index)),
                appName: nil,
                appBundleIdentifier: nil
            )
        }

        XCTAssertEqual(store.sessionEntries.count, 20)
        XCTAssertEqual(store.sessionEntries.first?.finalText, "Entry 24")
        XCTAssertEqual(store.sessionEntries.last?.finalText, "Entry 5")
    }
}
