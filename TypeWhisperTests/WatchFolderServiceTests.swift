import XCTest
@testable import TypeWhisper

final class WatchFolderServiceTests: XCTestCase {
    @MainActor
    private final class LoadState {
        var started = false
        var continuation: CheckedContinuation<[Float], Never>?
    }

    @MainActor
    func testAudioPreparationBlocksComparisonBeforeTheEngineLeaseIsAcquired() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let manager = ModelManagerService()
        let state = LoadState()
        let service = WatchFolderService(
            audioFileService: AudioFileService(), modelManagerService: manager,
            appSupportDirectory: directory, audioSamplesLoader: { _ in
                state.started = true
                return await withCheckedContinuation { state.continuation = $0 }
            }
        )
        XCTAssertFalse(HistoryRetranscriptionEnvironment.isBackgroundTranscriptionBusy(manager: manager, watchFolder: service))
        let task = runFile(service, directory: directory)
        for _ in 0..<100 where state.continuation == nil { await Task.yield() }
        XCTAssertTrue(state.started)
        XCTAssertEqual(service.currentlyProcessing, "test.wav")
        XCTAssertFalse(manager.hasProtectedEngineUse, "Loading audio precedes ModelManager's engine lease")
        XCTAssertTrue(HistoryRetranscriptionEnvironment.isBackgroundTranscriptionBusy(manager: manager, watchFolder: service))
        task.cancel()
        state.continuation?.resume(returning: [0.1])
        await task.value
        XCTAssertNil(service.currentlyProcessing)
        XCTAssertTrue(service.processedFiles.isEmpty)
        XCTAssertFalse(HistoryRetranscriptionEnvironment.isBackgroundTranscriptionBusy(manager: manager, watchFolder: service))
    }

    @MainActor
    func testNewFolderJobWaitsForComparisonBeforeLoadingAudio() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let previousActivity = HistoryRetranscriptionActivity.recordID
        defer {
            HistoryRetranscriptionActivity.recordID = previousActivity
            TestSupport.remove(directory)
        }
        let state = LoadState()
        let service = WatchFolderService(
            audioFileService: AudioFileService(), modelManagerService: ModelManagerService(),
            appSupportDirectory: directory, audioSamplesLoader: { _ in
                state.started = true
                throw CancellationError()
            }
        )
        HistoryRetranscriptionActivity.recordID = UUID()
        let task = runFile(service, directory: directory)
        for _ in 0..<100 where service.currentlyProcessing == nil { await Task.yield() }
        XCTAssertNotNil(service.currentlyProcessing)
        XCTAssertFalse(state.started)
        XCTAssertTrue(service.processedFiles.isEmpty)
        HistoryRetranscriptionActivity.recordID = nil
        await task.value
        XCTAssertTrue(state.started)
        XCTAssertNil(service.currentlyProcessing)
        XCTAssertTrue(service.processedFiles.isEmpty)
    }

    @MainActor
    func testCancellingFolderJobWaitingForComparisonDoesNotLoadOrRecordFailure() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let previousActivity = HistoryRetranscriptionActivity.recordID
        defer {
            HistoryRetranscriptionActivity.recordID = previousActivity
            TestSupport.remove(directory)
        }
        let state = LoadState()
        let service = WatchFolderService(
            audioFileService: AudioFileService(), modelManagerService: ModelManagerService(),
            appSupportDirectory: directory, audioSamplesLoader: { _ in
                state.started = true
                throw CancellationError()
            }
        )
        let comparisonID = UUID()
        HistoryRetranscriptionActivity.recordID = comparisonID
        let task = runFile(service, directory: directory)
        for _ in 0..<100 where service.currentlyProcessing == nil { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertFalse(state.started)
        XCTAssertNil(service.currentlyProcessing)
        XCTAssertTrue(service.processedFiles.isEmpty)
        XCTAssertEqual(HistoryRetranscriptionActivity.recordID, comparisonID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("watch-folder-history.json").path))
    }

    @MainActor
    private func runFile(_ service: WatchFolderService, directory: URL) -> Task<Void, Never> {
        Task {
            await service.transcribeFile(
                url: directory.appendingPathComponent("test.wav"), fingerprint: "test",
                outputFolder: directory, format: .markdown,
                overrides: .init(engineId: nil, modelId: nil, languageSelection: .auto), deleteSource: false
            )
        }
    }

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

        func checksum(from fingerprint: String) throws -> String {
            try XCTUnwrap(fingerprint.split(separator: "|").last.map(String.init))
        }

        // Assert checksum differs for files that only differ after the shared prefix
        XCTAssertNotEqual(try checksum(from: fingerprint1), try checksum(from: fingerprint2))
    }
}
