import XCTest
@testable import TypeWhisper

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
