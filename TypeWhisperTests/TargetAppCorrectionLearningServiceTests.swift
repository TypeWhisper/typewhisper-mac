import ApplicationServices
import XCTest
@testable import TypeWhisper

@MainActor
final class TargetAppCorrectionLearningServiceTests: XCTestCase {
    func testLearnsSingleConfidentReplacementFromSameElementFinalEdit() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use teh word",
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
            pollSchedule: [.milliseconds(0), .milliseconds(0)]
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.original, "teh")
        XCTAssertEqual(learned.first?.replacement, "the")
        XCTAssertEqual(dictionaryService.correctionsCount, 1)
    }

    func testDefaultPollScheduleSleepsWithinTenSecondWindow() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let element = AXUIElementCreateSystemWide()
        let textInsertionService = TextInsertionService()
        textInsertionService.focusedTextElementOverride = { element }

        var observations = [
            "Please use teh word",
            "Please use teh word",
            "Please use the word"
        ]
        textInsertionService.focusedTextStateOverride = { _ in
            let value = observations.removeFirst()
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.count, length: 0))
        }

        var sleeps: [Duration] = []
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: textInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            sleep: { duration in
                sleeps.append(duration)
            }
        )
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element,
            value: "Please use teh word",
            selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0)
        )

        let learned = await service.trackInsertion(insertedText: "teh", baseline: baseline)

        XCTAssertEqual(sleeps, [.seconds(2), .seconds(3), .seconds(5)])
        XCTAssertEqual(learned.first?.original, "teh")
        XCTAssertEqual(learned.first?.replacement, "the")
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
            pollSchedule: [.milliseconds(0)]
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
            pollSchedule: [.milliseconds(0)]
        )

        let missingStateLearned = await missingStateService.trackInsertion(insertedText: "teh", baseline: baseline)
        XCTAssertTrue(missingStateLearned.isEmpty)
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
            pollSchedule: [.milliseconds(0)]
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
        let duplicateService = TargetAppCorrectionLearningService(
            textInsertionService: duplicateInsertionService,
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            pollSchedule: [.milliseconds(0)]
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
            pollSchedule: [.seconds(60)]
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
}
