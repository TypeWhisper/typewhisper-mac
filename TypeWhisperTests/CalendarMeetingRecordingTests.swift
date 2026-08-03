import Foundation
import XCTest
@testable import TypeWhisper

@MainActor
final class CalendarMeetingRecordingTests: XCTestCase {
    func testPreferredNameSanitizesUnicodeControlsAndInvalidPathCharacters() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let value = CalendarMeetingRecordingFilename.preferredBaseName(
            title: "  ...Café\u{0000} / Team:   Weekly\nSync  ",
            date: date
        )

        XCTAssertTrue(value.hasPrefix("Café Team Weekly Sync — "))
        XCTAssertFalse(value.contains("/"))
        XCTAssertFalse(value.contains(":"))
        XCTAssertFalse(value.contains("\n"))
    }

    func testEmptyTitleFallsBackAndTitleIsLimitedToOneHundredTwentyGraphemes() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(CalendarMeetingRecordingFilename.preferredBaseName(
            title: " .  \n ",
            date: date
        ).hasPrefix("Recording "))

        let longTitle = String(repeating: "A", count: 140)
        let result = CalendarMeetingRecordingFilename.preferredBaseName(title: longTitle, date: date)
        let title = result.components(separatedBy: " — ").first ?? ""
        XCTAssertEqual(title.count, 120)
    }

    func testMultibyteTitleAndFinalFilenameStayWithinFilesystemByteLimit() {
        let date = Date(timeIntervalSince1970: 2_000_000_000)
        let preferredBaseName = CalendarMeetingRecordingFilename.preferredBaseName(
            title: String(repeating: "会", count: 140),
            date: date
        )
        let title = preferredBaseName.components(separatedBy: " — ").first ?? ""
        XCTAssertLessThanOrEqual(title.utf8.count, 200)

        let result = CalendarMeetingRecordingFilename.availableURL(
            in: URL(fileURLWithPath: "/tmp/calendar-recordings", isDirectory: true),
            preferredBaseName: String(repeating: "会", count: 200),
            fileExtension: "m4a",
            fileExists: { _ in false }
        )
        XCTAssertLessThanOrEqual(result.lastPathComponent.utf8.count, 255)
    }

    func testCollisionSuffixAppearsBeforeExtension() {
        let directory = URL(fileURLWithPath: "/tmp/calendar-recordings", isDirectory: true)
        let occupied: Set<String> = [
            directory.appendingPathComponent("Planning.wav").path,
            directory.appendingPathComponent("Planning 2.wav").path,
        ]

        let result = CalendarMeetingRecordingFilename.availableURL(
            in: directory,
            preferredBaseName: "Planning",
            fileExtension: "wav",
            fileExists: { occupied.contains($0) }
        )

        XCTAssertEqual(result.lastPathComponent, "Planning 3.wav")
    }

    func testRecorderBridgeOnlyAcceptsCurrentCalendarHandleAndManualStopInvalidatesIt() async throws {
        let suiteName = "CalendarMeetingRecordingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let previousEventBus: EventBus? = EventBus.shared
        EventBus.shared = EventBus()
        defer { EventBus.shared = previousEventBus }

        let recorderService = AudioRecorderService()
        recorderService.recordingsDirectoryOverride = directory
        recorderService.startRecordingOverride = { _, _, _, proposedURL, _ in
            try Data("recording".utf8).write(to: proposedURL)
            return proposedURL
        }
        recorderService.stopRecordingOverride = { outputURL in outputURL }
        let viewModel = AudioRecorderViewModel(
            recorderService: recorderService,
            modelManager: ModelManagerService(),
            dictionaryService: DictionaryService(appSupportDirectory: directory),
            audioDeviceService: AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false),
            defaults: defaults,
            recordingsLoader: { _, _ in [] }
        )
        viewModel.transcriptionEnabled = false
        viewModel.micEnabled = true

        let handle = try await viewModel.startCalendarMeetingRecording(preferredBaseName: "Planning")
        XCTAssertEqual(viewModel.state, .recording)
        XCTAssertEqual(handle.outputURL.lastPathComponent, "Planning.wav")

        let wrongHandle = CalendarMeetingRecordingHandle(id: UUID(), outputURL: handle.outputURL)
        XCTAssertThrowsError(try viewModel.stopCalendarMeetingRecording(handle: wrongHandle))
        XCTAssertEqual(viewModel.state, .recording)

        viewModel.stopRecording()
        XCTAssertEqual(viewModel.state, .finalizing)
        XCTAssertThrowsError(try viewModel.stopCalendarMeetingRecording(handle: handle))
        for _ in 0..<100 where viewModel.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.state, .idle)
    }
}
