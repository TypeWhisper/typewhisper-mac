import Foundation
import XCTest
@testable import TypeWhisper

final class DictationRecoveryAudioStoreTests: XCTestCase {
    func testPreserveWritesWavWithExpectedHeaderAndSamples() throws {
        let directory = makeTemporaryDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)
        let samples: [Float] = [0, 0.5, -0.5]

        store.startNewRecording()
        store.append(samples)
        let url = try XCTUnwrap(store.preserveActiveRecording())

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(readUInt32(data, at: 4), UInt32(36 + samples.count * 2))
        XCTAssertEqual(readUInt32(data, at: 40), UInt32(samples.count * 2))
        XCTAssertEqual(readInt16(data, at: 44), 0)
        XCTAssertEqual(readInt16(data, at: 46), 16_383)
        XCTAssertEqual(readInt16(data, at: 48), -16_383)
        XCTAssertEqual(store.latestRecoveryURL, url)
        XCTAssertEqual(store.recoveryURLs, [url])
    }

    func testPreserveKeepsMultipleTimestampedRecoveries() throws {
        let directory = makeTemporaryDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)

        store.startNewRecording()
        store.append([0.1])
        let first = try XCTUnwrap(store.preserveActiveRecording())

        store.startNewRecording()
        store.append([0.2])
        let second = try XCTUnwrap(store.preserveActiveRecording())

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("dictation-recovery-"))
        XCTAssertTrue(second.lastPathComponent.hasPrefix("dictation-recovery-"))
        XCTAssertEqual(Set(store.recoveryURLs), Set([first, second]))
        XCTAssertEqual(store.latestRecoveryURL, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testPreserveDeletesEmptyRecordingWithoutDeletingExistingRecoveries() throws {
        let directory = makeTemporaryDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)

        store.startNewRecording()
        store.append([0.1])
        let existingRecovery = try XCTUnwrap(store.preserveActiveRecording())

        store.startNewRecording()

        XCTAssertEqual(store.preserveActiveRecording(), existingRecovery)
        XCTAssertEqual(store.latestRecoveryURL, existingRecovery)
        XCTAssertEqual(store.recoveryURLs, [existingRecovery])
        XCTAssertTrue(try fileNames(in: directory).contains(existingRecovery.lastPathComponent))
    }

    func testDiscardActiveKeepsStoredRecoveriesAndDiscardRecoveryDeletesSelectedFile() throws {
        let directory = makeTemporaryDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)

        store.startNewRecording()
        store.append([0.1])
        let first = try XCTUnwrap(store.preserveActiveRecording())

        store.startNewRecording()
        store.append([0.2])
        store.discardActiveRecording()

        XCTAssertEqual(store.recoveryURLs, [first])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        store.startNewRecording()
        store.append([0.3])
        let second = try XCTUnwrap(store.preserveActiveRecording())
        XCTAssertEqual(Set(store.recoveryURLs), Set([first, second]))

        store.discardRecovery(at: second)

        XCTAssertEqual(store.recoveryURLs, [first])
        XCTAssertEqual(store.latestRecoveryURL, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testDiscardAllRecoveriesDeletesStoredFiles() throws {
        let directory = makeTemporaryDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)

        store.startNewRecording()
        store.append([0.1])
        _ = try XCTUnwrap(store.preserveActiveRecording())
        store.startNewRecording()
        store.append([0.2])
        _ = try XCTUnwrap(store.preserveActiveRecording())

        store.discardAllRecoveries()

        XCTAssertNil(store.latestRecoveryURL)
        XCTAssertTrue(store.recoveryURLs.isEmpty)
        XCTAssertTrue(try fileNames(in: directory).isEmpty)
    }

    func testDiscardRecoveryIgnoresMatchingFileOutsideRecoveryDirectory() throws {
        let directory = makeTemporaryDirectory()
        let outsideDirectory = makeTemporaryDirectory()
        let outsideURL = outsideDirectory
            .appendingPathComponent("dictation-recovery-outside")
            .appendingPathExtension("wav")
        FileManager.default.createFile(atPath: outsideURL.path, contents: Data([1, 2, 3]))

        let store = DictationRecoveryAudioStore(directory: directory)

        store.discardRecovery(at: outsideURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    @MainActor
    func testRecoverLastRecordingNavigatesToRecoveryWithoutQueueOrPicker() throws {
        let appSupportDirectory = makeTemporaryDirectory()
        let recoveryDirectory = appSupportDirectory.appendingPathComponent("dictation-recovery", isDirectory: true)
        let store = DictationRecoveryAudioStore(directory: recoveryDirectory)
        store.startNewRecording()
        store.append([0.1, -0.1])
        _ = try XCTUnwrap(store.preserveActiveRecording())

        let previousFileTranscriptionViewModel = FileTranscriptionViewModel._shared
        let previousSettingsNavigationCoordinator = SettingsNavigationCoordinator.shared
        addTeardownBlock {
            FileTranscriptionViewModel._shared = previousFileTranscriptionViewModel
            SettingsNavigationCoordinator.shared = previousSettingsNavigationCoordinator
        }

        let modelManager = ModelManagerService()
        let fileTranscriptionViewModel = FileTranscriptionViewModel(
            modelManager: modelManager,
            audioFileService: AudioFileService()
        )
        FileTranscriptionViewModel._shared = fileTranscriptionViewModel
        let navigationCoordinator = SettingsNavigationCoordinator()
        SettingsNavigationCoordinator.shared = navigationCoordinator

        let dictationViewModel = makeDictationViewModel(
            appSupportDirectory: appSupportDirectory,
            modelManager: modelManager,
            audioRecordingService: AudioRecordingService(recoveryAudioStore: store)
        )

        dictationViewModel.recoverLastRecording(openSettingsWindow: false)

        XCTAssertTrue(fileTranscriptionViewModel.files.isEmpty)
        XCTAssertEqual(navigationCoordinator.request?.tab, .dictationRecovery)
        XCTAssertFalse(fileTranscriptionViewModel.showFilePickerFromMenu)
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationRecoveryAudioStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func fileNames(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func readInt16(_ data: Data, at offset: Int) -> Int16 {
        let value = data[offset..<(offset + 2)].reversed().reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        return Int16(bitPattern: value)
    }

    @MainActor
    private func makeDictationViewModel(
        appSupportDirectory: URL,
        modelManager: ModelManagerService,
        audioRecordingService: AudioRecordingService
    ) -> DictationViewModel {
        let textInsertionService = TextInsertionService()
        let hotkeyService = HotkeyService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()

        return DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: SettingsViewModel(modelManager: modelManager),
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: AudioDuckingService(),
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: SoundService(),
            audioDeviceService: AudioDeviceService(
                initialInputDevices: [],
                monitorDeviceChanges: false,
                probeCompatibilities: false
            ),
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: AppFormatterService(),
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: punctuationProfileStore),
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            speechFeedbackService: SpeechFeedbackService(),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(),
            errorLogService: ErrorLogService(appSupportDirectory: appSupportDirectory),
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )
    }
}
