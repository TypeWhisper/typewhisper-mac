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

final class WatchFolderServiceTests: XCTestCase {
    @MainActor
    func testFileFingerprintDifferentiatesFilesWithSamePrefixButDifferentTail() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }

        // Generate 8192 bytes of identical prefix
        let prefixData = Data(repeating: 0x41, count: 8192)

        // File 1: Prefix + "A"
        let file1URL = directory.appendingPathComponent("file1.txt")
        var file1Data = prefixData
        file1Data.append(Data("A".utf8))
        try file1Data.write(to: file1URL)

        // File 2: Prefix + "B" (same size as File 1, same prefix)
        let file2URL = directory.appendingPathComponent("file2.txt")
        var file2Data = prefixData
        file2Data.append(Data("B".utf8))
        try file2Data.write(to: file2URL)

        // Force both files to have the exact same modification date
        let date = Date(timeIntervalSince1970: 1000000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file1URL.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file2URL.path)

        let service = WatchFolderService(
            audioFileService: AudioFileService(),
            modelManagerService: ModelManagerService()
        )
        
        let fingerprint1 = try XCTUnwrap(service.fileFingerprint(for: file1URL))
        let fingerprint2 = try XCTUnwrap(service.fileFingerprint(for: file2URL))
        
        // Assert that they are different now that we hash the whole file
        XCTAssertNotEqual(fingerprint1, fingerprint2)
    }
}
