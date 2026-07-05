import ApplicationServices
import XCTest
@testable import TypeWhisper

@MainActor
final class TargetAppCorrectionLearningServiceTests: XCTestCase {
    func testLearnsSingleConfidentReplacementAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use the word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let learned = await task.value

        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.original, "teh")
        XCTAssertEqual(learned.first?.replacement, "the")
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testSkipsSentenceRewriteAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Rewrite every token now"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: baseline.value, baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let learned = await task.value

        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsInsertedTextRemovalAfterCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(5)],
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        for _ in 0..<1000 where !commitEmitter.isReady {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(commitEmitter.isReady)
        commitEmitter.emit(.returnKey)
        let learned = await task.value

        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testTimeoutDoesNotLearnWithoutCommitSignal() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use the word",
            "Please use the word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testLearnsLatestConfidentReplacementWhenFocusLeavesSameElement() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        let otherElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var focusLeft = false
        textInsertionService.focusedTextElementOverride = {
            focusLeft ? otherElement : element
        }

        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            if captureCount == 1 {
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }
            focusLeft = true
            return nil
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.first?.original, "teh")
        XCTAssertEqual(learned.first?.replacement, "the")
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testSkipsMissingTextStateWithoutFocusChangeAfterCandidate() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            if captureCount == 1 {
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }
            return nil
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsUnavailableFocusComparisonAfterCandidate() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        var focusAvailable = true
        textInsertionService.focusedTextElementOverride = {
            focusAvailable ? element : nil
        }

        var captureCount = 0
        textInsertionService.focusedTextStateOverride = { _ in
            captureCount += 1
            if captureCount == 1 {
                let value = "Please use the word"
                return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
            }
            focusAvailable = false
            return nil
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsFocusElementChangesAndMissingTextState() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let baselineElement = AXUIElementCreateSystemWide()
        let otherElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let baseline = TextInsertionService.FocusedTextObservation(
            element: baselineElement,
            value: "teh",
            selectedText: nil,
            selectedRange: NSRange(location: 3, length: 0)
        )

        let changedFocusInsertionService = TextInsertionService()
        changedFocusInsertionService.focusedTextElementOverride = { otherElement }
        changedFocusInsertionService.focusedTextStateOverride = { _ in
            (value: "the", selectedText: nil, selectedRange: NSRange(location: 3, length: 0))
        }
        let changedFocusDictionary = DictionaryService(appSupportDirectory: appSupportDirectory.appendingPathComponent("changed-focus"))
        let changedFocusService = TargetAppCorrectionLearningService(
            textInsertionService: changedFocusInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: changedFocusDictionary,
            pollSchedule: [.milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )

        let changedFocusLearned = await changedFocusService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertTrue(changedFocusLearned.isEmpty)

        let missingStateInsertionService = TextInsertionService()
        missingStateInsertionService.focusedTextElementOverride = { baselineElement }
        missingStateInsertionService.focusedTextStateOverride = { _ in nil }
        let missingStateDictionary = DictionaryService(appSupportDirectory: appSupportDirectory.appendingPathComponent("missing-state"))
        let missingStateService = TargetAppCorrectionLearningService(
            textInsertionService: missingStateInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: missingStateDictionary,
            pollSchedule: [.milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )

        let missingStateLearned = await missingStateService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertTrue(missingStateLearned.isEmpty)
    }

    func testClearsStaleSuggestionsWhenEditIsUndoneBeforeCommit() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use the word",
            "Please use teh word",
            "Please use teh word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        let commitEmitter = CommitEmitterBox()
        var sleepCount = 0
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0), .milliseconds(0)],
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 3 {
                    commitEmitter.emit(.returnKey)
                }
            },
            makeCommitObserver: commitObserver(capturing: commitEmitter)
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testSkipsUnmappableLargeDuplicateCaseAndPunctuationOnlyEdits() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        dictionaryService.addEntry(type: .correction, original: "teh", replacement: "the")

        let service = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: "not present",
            baselineText: baseline.value,
            editedText: "Please use the word"
        ).isEmpty)

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: baseline.value,
            baselineText: baseline.value,
            editedText: "Completely different rewrite with many words"
        ).isEmpty)

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: "teh",
            baselineText: baseline.value,
            editedText: "Please use Teh word"
        ).isEmpty)

        XCTAssertTrue(service.highConfidenceCorrectionSuggestions(
            insertedText: "teh.",
            baselineText: "Please use teh. word",
            editedText: "Please use teh word"
        ).isEmpty)

        let duplicateInsertionService = TextInsertionService()
        duplicateInsertionService.focusedTextElementOverride = { element }
        duplicateInsertionService.focusedTextStateOverride = { _ in
            (value: "Please use the word", selectedText: nil, selectedRange: NSRange(location: 19, length: 0))
        }
        let duplicateCommitEmitter = CommitEmitterBox()
        var duplicateSleepCount = 0
        let duplicateService = TargetAppCorrectionLearningService(
            textInsertionService: duplicateInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0), .milliseconds(0)],
            sleep: { _ in
                duplicateSleepCount += 1
                if duplicateSleepCount == 2 {
                    duplicateCommitEmitter.emit(.returnKey)
                }
            },
            makeCommitObserver: commitObserver(capturing: duplicateCommitEmitter)
        )

        let duplicateLearned = await duplicateService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertTrue(duplicateLearned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testCancelsStaleTrackingBeforeLearning() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }
        textInsertionService.focusedTextStateOverride = { _ in
            (value: "Please use the word", selectedText: nil, selectedRange: NSRange(location: 19, length: 0))
        }

        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.seconds(60)],
            makeCommitObserver: noopCommitObserver
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let task = Task { @MainActor in
            await service.trackInsertion(insertedText: "teh", baseline: baseline)
        }
        await Task.yield()
        task.cancel()

        let learned = await task.value
        XCTAssertTrue(learned.isEmpty)
        XCTAssertEqual(dictionaryService.correctionsCount, 0)
    }

    func testCommitObserverMapsReturnEnterAndTabKeys() {
        XCTAssertEqual(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x24), .returnKey)
        XCTAssertEqual(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x4C), .returnKey)
        XCTAssertEqual(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x30), .tabKey)
        XCTAssertNil(TargetAppCorrectionCommitObserver.commitSignal(forKeyCode: 0x31))
    }

    private func noopCommitObserver(
        onCommit _: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void
    ) -> TargetAppCorrectionCommitObserving {
        TestTargetAppCorrectionCommitObserver()
    }

    private func commitObserver(
        capturing box: CommitEmitterBox
    ) -> (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving {
        { onCommit in
            box.emit = { signal in
                onCommit(signal)
            }
            box.isReady = true
            return TestTargetAppCorrectionCommitObserver()
        }
    }
}

@MainActor
private final class CommitEmitterBox {
    var emit: (TargetAppCorrectionCommitSignal) -> Void = { _ in }
    var isReady = false
}

@MainActor
private final class TestTargetAppCorrectionCommitObserver: TargetAppCorrectionCommitObserving {
    func start() {}
    func stop() {}
}
