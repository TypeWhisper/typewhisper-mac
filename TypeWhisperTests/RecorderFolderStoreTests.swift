import Foundation
import os
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Path bookmarks whose folders can be made unreachable, like a disconnected disk, or whose
/// security scope can be refused, like a sandbox that lost access.
private final class FakeRecorderFolderBookmarks: RecorderFolderBookmarking, @unchecked Sendable {
    private struct State {
        var unreachablePaths: Set<String> = []
        var refusesAccess = false
        var startedPaths: [String] = []
        var stoppedPaths: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var refusesAccess: Bool {
        get { state.withLock { $0.refusesAccess } }
        set { state.withLock { $0.refusesAccess = newValue } }
    }

    var startedPaths: [String] { state.withLock { $0.startedPaths } }
    var stoppedPaths: [String] { state.withLock { $0.stoppedPaths } }

    func setReachable(_ reachable: Bool, _ url: URL) {
        state.withLock { state in
            if reachable {
                state.unreachablePaths.remove(url.standardizedFileURL.path)
            } else {
                state.unreachablePaths.insert(url.standardizedFileURL.path)
            }
        }
    }

    func makeBookmark(for url: URL) throws -> Data {
        Data(url.standardizedFileURL.path.utf8)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        let path = String(decoding: data, as: UTF8.self)
        guard !state.withLock({ $0.unreachablePaths.contains(path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return (URL(fileURLWithPath: path, isDirectory: true), false)
    }

    func startAccessing(_ url: URL) -> Bool {
        state.withLock { state in
            state.startedPaths.append(url.path)
            return !state.refusesAccess
        }
    }

    func stopAccessing(_ url: URL) {
        state.withLock { $0.stoppedPaths.append(url.path) }
    }
}

@MainActor
final class RecorderFolderStoreTests: XCTestCase {
    private var root: URL!
    private var defaultFolder: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderFolderStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaultFolder = root.appendingPathComponent("TypeWhisper Recordings", isDirectory: true)
        let root = root!
        addTeardownBlock {
            // Read-only test folders must become writable again before they can be removed.
            let enumerator = FileManager.default.enumerator(atPath: root.path)
            while let path = enumerator?.nextObject() as? String {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: root.appendingPathComponent(path).path
                )
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Folder choice

    func testNewRecordingsGoToTheDefaultFolderUntilAFolderIsChosen() throws {
        let store = makeStore()

        XCTAssertTrue(store.usesDefaultFolder)
        XCTAssertEqual(store.destinationForNewRecordings(), defaultFolder)
        XCTAssertEqual(store.listedFolders(), [defaultFolder])
        XCTAssertTrue(store.earlierFolders.isEmpty)
        XCTAssertNil(store.notice)
    }

    func testChosenFolderTakesNewRecordingsAndTheDefaultFolderStaysListed() throws {
        let defaults = try makeDefaults()
        try writeFile("Old.wav", in: defaultFolder)
        let chosen = try makeFolder("Archive")
        let store = makeStore(defaults: defaults)

        try store.chooseFolder(chosen)

        XCTAssertFalse(store.usesDefaultFolder)
        assertSameFolders([store.destinationForNewRecordings()], [chosen])
        assertSameFolders(store.listedFolders(), [chosen, defaultFolder])
        XCTAssertEqual(store.earlierFolders.map(\.isDefault), [true])

        // The bookmark survives a relaunch.
        let relaunched = makeStore(defaults: defaults)
        assertSameFolders([relaunched.destinationForNewRecordings()], [chosen])
        assertSameFolders(relaunched.listedFolders(), [chosen, defaultFolder])
        XCTAssertNil(relaunched.notice)
    }

    func testDefaultFolderWithoutRecordingsIsNotKeptAsAnEarlierFolder() throws {
        let store = makeStore()

        try store.chooseFolder(try makeFolder("Archive"))

        XCTAssertTrue(store.earlierFolders.isEmpty)
    }

    func testChangingFoldersListsEveryEarlierFolderOnce() throws {
        try writeFile("Old.wav", in: defaultFolder)
        let first = try makeFolder("First")
        let second = try makeFolder("Second")
        let store = makeStore()

        try store.chooseFolder(first)
        try store.chooseFolder(second)
        try store.chooseFolder(first)

        assertSameFolders([store.destinationForNewRecordings()], [first])
        assertSameFolders(store.listedFolders(), [first, second, defaultFolder])

        store.useDefaultFolder()

        XCTAssertTrue(store.usesDefaultFolder)
        XCTAssertEqual(store.destinationForNewRecordings(), defaultFolder)
        assertSameFolders(store.listedFolders(), [defaultFolder, first, second])
    }

    func testChoosingTheDefaultFolderPathUsesTheDefaultFolder() throws {
        try FileManager.default.createDirectory(at: defaultFolder, withIntermediateDirectories: true)
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)

        try store.chooseFolder(defaultFolder)

        XCTAssertTrue(store.usesDefaultFolder)
        assertSameFolders(store.listedFolders(), [defaultFolder, chosen])
    }

    func testChoosingAReadOnlyFolderIsRefused() throws {
        let readOnly = try makeFolder("Read Only")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        let store = makeStore()

        XCTAssertThrowsError(try store.chooseFolder(readOnly)) { error in
            guard case RecorderFolderStore.ChoiceError.notWritable = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertTrue(store.usesDefaultFolder)
    }

    func testChoosingTheWatchFolderIsRefused() throws {
        let watched = try makeFolder("Watched")
        let previous = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(previous)

        // The panel may return the same folder through another spelling of its path.
        let samePath = watched.appendingPathComponent("..").appendingPathComponent("Watched")
        XCTAssertThrowsError(try store.chooseFolder(samePath, watchFolderPath: watched.path)) { error in
            XCTAssertEqual(error as? RecorderFolderStore.ChoiceError, .watchFolder(path: watched.standardizedFileURL.path))
        }
        assertSameFolders([store.destinationForNewRecordings()], [previous])
        XCTAssertTrue(store.earlierFolders.isEmpty)

        try store.chooseFolder(try makeFolder("Other"), watchFolderPath: watched.path)
        XCTAssertFalse(store.listedFolders().contains { RecorderFolderStore.isSameFolder($0, watched) })
    }

    func testForgettingAnEarlierFolderStopsListingItAndKeepsItsFiles() throws {
        let first = try makeFolder("First")
        let recording = try writeFile("Meeting.wav", in: first)
        let second = try makeFolder("Second")
        let store = makeStore()
        try store.chooseFolder(first)
        try store.chooseFolder(second)
        let earlier = try XCTUnwrap(store.earlierFolders.first)

        store.forgetEarlierFolder(earlier)

        assertSameFolders(store.listedFolders(), [second])
        XCTAssertTrue(store.earlierFolders.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path))
    }

    func testForgettingAnEarlierFolderWhoseBookmarkChangedSinceItWasShown() throws {
        let first = try makeFolder("First")
        let store = makeStore()
        try store.chooseFolder(first)
        try store.chooseFolder(try makeFolder("Second"))
        let shown = try XCTUnwrap(store.earlierFolders.first)

        // A stale bookmark is renewed while the folder's row is still on screen.
        store.forgetEarlierFolder(RecorderFolder(bookmark: Data("renewed".utf8), path: shown.path))

        XCTAssertTrue(store.earlierFolders.isEmpty)
    }

    // MARK: - Unavailable folders

    func testDeletedChosenFolderFallsBackToTheDefaultFolderAndSaysSo() throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)
        try FileManager.default.removeItem(at: chosen)

        XCTAssertEqual(store.destinationForNewRecordings(), defaultFolder)
        XCTAssertEqual(store.notice, .unavailable(path: store.chosenFolderPath))
        XCTAssertTrue(store.listedFolders().isEmpty, "Neither the missing folder nor an empty default folder is listed")

        let replacement = try makeFolder("Archive 2")
        try store.chooseFolder(replacement)
        XCTAssertNil(store.notice)
        assertSameFolders([store.destinationForNewRecordings()], [replacement])
    }

    func testDisconnectedFolderIsUsedAgainOnceItIsBack() throws {
        let bookmarks = FakeRecorderFolderBookmarks()
        let chosen = try makeFolder("External")
        let store = makeStore(bookmarks: bookmarks)
        try store.chooseFolder(chosen)

        bookmarks.setReachable(false, chosen)
        XCTAssertEqual(store.destinationForNewRecordings(), defaultFolder)
        XCTAssertEqual(store.notice, .unavailable(path: chosen.standardizedFileURL.path))

        bookmarks.setReachable(true, chosen)
        store.refreshAvailability()
        XCTAssertNil(store.notice)
        assertSameFolders([store.destinationForNewRecordings()], [chosen])
    }

    func testMovedChosenFolderIsFollowedAndItsBookmarkRenewed() throws {
        let defaults = try makeDefaults()
        let chosen = try makeFolder("Archive")
        let store = makeStore(defaults: defaults)
        try store.chooseFolder(chosen)
        let originalBookmark = try XCTUnwrap(defaults.data(forKey: UserDefaultsKeys.recorderFolderBookmark))
        let moved = root.appendingPathComponent("Renamed Archive", isDirectory: true)
        try FileManager.default.moveItem(at: chosen, to: moved)

        assertSameFolders([store.destinationForNewRecordings()], [moved])
        XCTAssertTrue(RecorderFolderStore.isSameFolder(store.chosenFolderPath, moved.path))
        XCTAssertNotEqual(defaults.data(forKey: UserDefaultsKeys.recorderFolderBookmark), originalBookmark)
        XCTAssertNil(store.notice)
    }

    func testChosenFolderMovedToTheTrashIsNotUsed() throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)
        let trash = try makeFolder(".Trash")
        try FileManager.default.moveItem(at: chosen, to: trash.appendingPathComponent("Archive", isDirectory: true))

        XCTAssertEqual(store.destinationForNewRecordings(), defaultFolder)
        XCTAssertNotNil(store.notice)
        XCTAssertTrue(store.listedFolders().isEmpty)
    }

    func testReadOnlyChosenFolderStaysListedButTakesNoNewRecordings() throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: chosen.path)

        XCTAssertEqual(store.destinationForNewRecordings(), defaultFolder)
        XCTAssertNotNil(store.notice)
        assertSameFolders(store.listedFolders(), [chosen])
    }

    func testRefusedSecurityScopeMakesTheFolderUnavailableInTheSandbox() throws {
        let bookmarks = FakeRecorderFolderBookmarks()
        bookmarks.refusesAccess = true
        let chosen = try makeFolder("Archive")
        let sandboxed = makeStore(bookmarks: bookmarks, requiresSecurityScope: true)
        try sandboxed.chooseFolder(chosen)

        XCTAssertEqual(sandboxed.destinationForNewRecordings(), defaultFolder)
        XCTAssertNotNil(sandboxed.notice)

        // Outside the sandbox the folder is used without a security scope.
        let direct = makeStore(bookmarks: bookmarks, requiresSecurityScope: false)
        try direct.chooseFolder(chosen)
        assertSameFolders([direct.destinationForNewRecordings()], [chosen])
    }

    func testSecurityScopeIsEnteredOnceAndLeftWhenTheFolderIsForgotten() throws {
        let bookmarks = FakeRecorderFolderBookmarks()
        let first = try makeFolder("First")
        let second = try makeFolder("Second")
        let store = makeStore(bookmarks: bookmarks)
        try store.chooseFolder(first)
        try store.chooseFolder(second)

        _ = store.listedFolders()
        _ = store.listedFolders()
        _ = store.destinationForNewRecordings()

        let firstPath = first.standardizedFileURL.path
        XCTAssertEqual(bookmarks.startedPaths.filter { $0 == firstPath }.count, 1)
        store.forgetEarlierFolder(try XCTUnwrap(store.earlierFolders.first))
        XCTAssertEqual(bookmarks.stoppedPaths, [firstPath])
    }

    func testFailedSaveFallsBackToTheDefaultFolderAndKeepsItListed() throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)

        XCTAssertEqual(store.fallbackDirectory(afterFailureIn: chosen), defaultFolder)
        XCTAssertEqual(store.notice, .saveFailed(path: chosen.path))
        XCTAssertNil(store.fallbackDirectory(afterFailureIn: defaultFolder), "The default folder has no fallback")

        store.noteRecordingSaved(at: defaultFolder.appendingPathComponent("Meeting.wav"))
        XCTAssertEqual(store.earlierFolders.map(\.isDefault), [true])
        assertSameFolders(store.listedFolders(), [chosen, defaultFolder])

        store.noteRecordingSaved(at: chosen.appendingPathComponent("Next.wav"))
        XCTAssertNil(store.notice)
    }

    // MARK: - Recorder service

    func testRecordingIsSavedToTheChosenFolder() async throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)
        let service = makeService(store: store)

        let startURL = try await service.startRecording(micEnabled: true, systemAudioEnabled: false, format: .wav)
        let stoppedURL = await service.stopRecording()
        let savedURL = try XCTUnwrap(stoppedURL)

        assertSameFolders([startURL.deletingLastPathComponent()], [chosen])
        XCTAssertEqual(savedURL, startURL)
        XCTAssertEqual(try String(contentsOf: savedURL, encoding: .utf8), "recorded")
        assertSameFolders(service.recordingsDirectories, [chosen])
    }

    func testRecordingStartsInTheDefaultFolderWhenTheChosenFolderIsGone() async throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)
        try FileManager.default.removeItem(at: chosen)
        let service = makeService(store: store)

        let startURL = try await service.startRecording(micEnabled: true, systemAudioEnabled: false, format: .wav)
        let stoppedURL = await service.stopRecording()
        let savedURL = try XCTUnwrap(stoppedURL)

        assertSameFolders([startURL.deletingLastPathComponent()], [defaultFolder])
        XCTAssertEqual(savedURL, startURL)
        XCTAssertEqual(store.notice, .unavailable(path: store.chosenFolderPath))
        assertSameFolders(service.recordingsDirectories, [defaultFolder], "The fallback recording stays listed")
    }

    func testRecordingWhoseFolderFailsWhileRecordingIsSavedToTheDefaultFolder() async throws {
        let chosen = try makeFolder("Archive")
        let store = makeStore()
        try store.chooseFolder(chosen)
        let service = makeService(store: store, failsToSaveIn: chosen)

        let startURL = try await service.startRecording(micEnabled: true, systemAudioEnabled: false, format: .wav)
        let stoppedURL = await service.stopRecording()
        let savedURL = try XCTUnwrap(stoppedURL, "The recording must not be lost")

        assertSameFolders([savedURL.deletingLastPathComponent()], [defaultFolder])
        XCTAssertEqual(savedURL.lastPathComponent, startURL.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: savedURL, encoding: .utf8), "recorded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: startURL.path), "No partial file is left behind")
        XCTAssertEqual(store.notice, .saveFailed(path: startURL.deletingLastPathComponent().path))
        assertSameFolders(service.recordingsDirectories, [chosen, defaultFolder])
    }

    func testRecordingThatFailsInTheDefaultFolderIsNotRetried() async throws {
        let store = makeStore()
        let service = makeService(store: store, failsToSaveIn: defaultFolder)

        _ = try await service.startRecording(micEnabled: true, systemAudioEnabled: false, format: .wav)
        let savedURL = await service.stopRecording()

        XCTAssertNil(savedURL)
        XCTAssertNil(store.notice)
    }

    // MARK: - Recorder list and API

    func testRecorderListsAndDeletesRecordingsFromChosenAndEarlierFolders() async throws {
        let older = try writeFile("Older.wav", in: defaultFolder, created: Date(timeIntervalSince1970: 1_700_000_000))
        let chosen = try makeFolder("Archive")
        let newer = try writeFile("Newer.wav", in: chosen, created: Date(timeIntervalSince1970: 1_800_000_000))
        try Data("Older transcript".utf8).write(to: defaultFolder.appendingPathComponent("Older.txt"))
        let store = makeStore()
        try store.chooseFolder(chosen)
        let viewModel = try makeViewModel(service: makeService(store: store))

        try await waitForRecordings(viewModel, count: 2)
        assertSameFolders(viewModel.recordings.map(\.url), [newer, older])
        XCTAssertEqual(viewModel.recordings.last?.transcript, "Older transcript")

        viewModel.deleteRecording(try XCTUnwrap(viewModel.recordings.last))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultFolder.appendingPathComponent("Older.txt").path))
        viewModel.loadRecordings()
        try await waitForRecordings(viewModel, count: 1)
        assertSameFolders(viewModel.recordings.map(\.url), [newer])
    }

    func testRecorderRecordingsAPIIncludesEarlierFolders() async throws {
        let older = try writeCompletion("Older", in: defaultFolder, completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let chosen = try makeFolder("Archive")
        let newer = try writeCompletion("Newer", in: chosen, completedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let store = makeStore()
        try store.chooseFolder(chosen)
        let viewModel = try makeViewModel(service: makeService(store: store))

        let completions = try await viewModel.apiRecorderRecordings()
        XCTAssertEqual(completions.map(\.recordingID), [older.recordingID, newer.recordingID], "Oldest completion first")
        XCTAssertEqual(completions.map(\.text), ["Older", "Newer"])

        let router = APIRouter(authenticationProvider: { .required(token: "test-token") })
        router.register("GET", "/v1/recorder/recordings") { request in
            await APIHandlers.recorderRecordingsResponse(for: request, recorder: viewModel)
        }
        let response = await router.route(HTTPRequest(
            method: "GET",
            path: "/v1/recorder/recordings",
            queryParams: ["since": "1750000000"],
            headers: ["authorization": "Bearer test-token"],
            body: Data()
        ))
        struct Response: Decodable { let recordings: [RecorderTranscriptReadyPayload] }
        XCTAssertEqual(response.status, 200)
        let recordings = try JSONDecoder().decode(Response.self, from: response.body).recordings
        XCTAssertEqual(recordings.map(\.recordingID), [newer.recordingID])
        XCTAssertEqual(
            recordings.first?.audioFilePath,
            chosen.appendingPathComponent("Newer.wav").resolvingSymlinksInPath().path
        )
    }

    // MARK: - Helpers

    private func makeStore(
        defaults: UserDefaults? = nil,
        bookmarks: any RecorderFolderBookmarking = SecurityScopedRecorderFolderBookmarks(),
        requiresSecurityScope: Bool = false
    ) -> RecorderFolderStore {
        RecorderFolderStore(
            defaults: defaults ?? (try? makeDefaults()) ?? UserDefaults(),
            defaultDirectory: defaultFolder,
            bookmarks: bookmarks,
            requiresSecurityScope: requiresSecurityScope
        )
    }

    /// A recorder whose capture is simulated: each recording is a small file named after the
    /// proposed output URL. Saving into `failingFolder` fails, as on a disconnected disk.
    private func makeService(store: RecorderFolderStore, failsToSaveIn failingFolder: URL? = nil) -> AudioRecorderService {
        let service = AudioRecorderService(folderStore: store)
        service.startRecordingOverride = { _, _, _, outputURL, _ in
            try Data("placeholder".utf8).write(to: outputURL)
            return outputURL
        }
        service.stopRecordingOverride = { outputURL in
            if let failingFolder,
               RecorderFolderStore.isSameFolder(outputURL.deletingLastPathComponent(), failingFolder) {
                throw CocoaError(.fileWriteVolumeReadOnly)
            }
            try Data("recorded".utf8).write(to: outputURL)
            return outputURL
        }
        service.currentBufferOverride = { [] }
        return service
    }

    private func makeViewModel(service: AudioRecorderService) throws -> AudioRecorderViewModel {
        let previousEventBus: EventBus? = EventBus.shared
        EventBus.shared = EventBus()
        addTeardownBlock { EventBus.shared = previousEventBus }
        return AudioRecorderViewModel(
            recorderService: service,
            modelManager: ModelManagerService(),
            dictionaryService: DictionaryService(appSupportDirectory: try makeFolder("App Support")),
            defaults: try makeDefaults(),
            speechRegionDetector: WholeRecordingSpeechDetector()
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "RecorderFolderStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    private func writeFile(_ name: String, in folder: URL, created: Date? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        if let created {
            try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        }
        return url
    }

    /// A saved Recorder transcript with its completion receipt, as the Recorder writes it.
    private func writeCompletion(
        _ name: String,
        in folder: URL,
        completedAt: Date
    ) throws -> RecorderTranscriptReadyPayload {
        let audioURL = try writeFile("\(name).wav", in: folder)
        let transcriptURL = folder.appendingPathComponent("\(name).txt")
        try Data(name.utf8).write(to: transcriptURL)
        let payload = RecorderTranscriptReadyPayload(
            recordingID: UUID(),
            completedAt: completedAt,
            text: name,
            audioFilePath: audioURL.path,
            transcriptFilePath: transcriptURL.path
        )
        try JSONEncoder().encode(payload).write(to: audioURL.appendingPathExtension("transcript-ready.json"))
        return payload
    }

    private func waitForRecordings(
        _ viewModel: AudioRecorderViewModel,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if viewModel.recordings.count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected \(count) recordings, found \(viewModel.recordings.count)", file: file, line: line)
    }

    private func assertSameFolders(
        _ actual: [URL],
        _ expected: [URL],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolve = { (urls: [URL]) in urls.map { $0.standardizedFileURL.resolvingSymlinksInPath().path } }
        XCTAssertEqual(resolve(actual), resolve(expected), message, file: file, line: line)
    }
}
