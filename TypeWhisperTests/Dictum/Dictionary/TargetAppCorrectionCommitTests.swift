import AppKit
import XCTest
@testable import TypeWhisper

@MainActor
final class TargetAppCorrectionCommitTests: XCTestCase {
    func testCorrectionCommittedAfterReadingForThirtySecondsIsLearned() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-delayed-commit")
        defer { TestSupport.remove(root) }
        let suite = "dictum-delayed-commit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let element = AXUIElementCreateSystemWide()
        let insertion = TextInsertionService()
        insertion.focusedTextElementOverride = { element }
        var edited = false
        insertion.focusedTextStateOverride = { _ in
            let value = edited ? "Please use the word" : "Please use teh word"
            return (value: value, selectedText: nil, selectedRange: NSRange(location: value.utf16.count, length: 0))
        }
        let dictionary = DictionaryService(appSupportDirectory: root)
        var observer: DeferredCommitObserver?
        var slept: [Duration] = []
        var waitCount = 0
        let service = TargetAppCorrectionLearningService(
            textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: (1...36).map { .seconds($0) },
            sleep: { duration in
                slept.append(duration)
                waitCount += 1
                // 用户读完插入的文字，第 35 秒改正并按回车。
                if waitCount == 35 {
                    edited = true
                    observer?.onCommit(.returnKey)
                }
            },
            makeCommitObserver: { callback in
                let value = DeferredCommitObserver(onCommit: callback)
                observer = value
                return value
            }, defaults: defaults)
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element, value: "Please use teh word", selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0))
        let task = Task { await service.trackInsertion(insertedText: "Please use teh word", baseline: baseline) }
        let result = await task.value
        XCTAssertEqual(slept.count, 35)
        XCTAssertEqual(result.snapshot.outcome, .learned)
        XCTAssertEqual(dictionary.entries.first?.original, "teh")
        XCTAssertEqual(dictionary.entries.first?.replacement, "the")
    }

    func testChineseCorrectionWithReturnNewlineIsLearned() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-commit")
        defer { TestSupport.remove(root) }
        let element = AXUIElementCreateSystemWide()
        let insertion = TextInsertionService()
        insertion.focusedTextElementOverride = { element }
        let original = "周四下午三点，讨论新河项目，请准备会议记录。"
        let edited = "周四下午三点，讨论星河项目，请准备会议记录。\n"
        insertion.focusedTextStateOverride = { _ in
            (value: edited, selectedText: nil, selectedRange: NSRange(location: edited.utf16.count, length: 0))
        }
        let dictionary = DictionaryService(appSupportDirectory: root)
        let suite = "dictum-commit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = TargetAppCorrectionLearningService(
            textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: [.zero], makeCommitObserver: { ReturnCommitObserver(onCommit: $0) }, defaults: defaults)
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element, value: original, selectedText: nil,
            selectedRange: NSRange(location: original.utf16.count, length: 0))
        let result = await service.trackInsertion(insertedText: original, baseline: baseline)
        XCTAssertEqual(result.snapshot.outcome, .learned)
        XCTAssertFalse(dictionary.entries.isEmpty)
    }

    func testEditMadeBetweenPollsSurvivesAFocusChange() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-late-edit")
        defer { TestSupport.remove(root) }
        let suite = "dictum-late-edit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let element = AXUIElementCreateSystemWide()
        let insertion = TextInsertionService()
        insertion.focusedTextElementOverride = { element }
        var text = "Please use teh word"
        insertion.focusedTextStateOverride = { _ in
            (value: text, selectedText: nil, selectedRange: NSRange(location: text.utf16.count, length: 0))
        }
        let dictionary = DictionaryService(appSupportDirectory: root)
        let otherApplication = AXUIElementCreateApplication(getpid())
        var pollCount = 0
        let service = TargetAppCorrectionLearningService(
            textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            pollSchedule: [.zero, .seconds(1), .seconds(2)],
            sleep: { _ in
                pollCount += 1
                if pollCount == 2 {
                    // 用户在两次轮询之间改正了词，随后切换了应用。
                    text = "Please use the word"
                    insertion.focusedTextElementOverride = { otherApplication }
                }
            },
            makeCommitObserver: { _ in SilentCommitObserver() }, defaults: defaults)
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element, value: "Please use teh word", selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0))
        let result = await service.trackInsertion(insertedText: "Please use teh word", baseline: baseline)
        XCTAssertEqual(result.snapshot.commitSignal, .focusChanged)
        XCTAssertEqual(result.snapshot.outcome, .learned)
        XCTAssertEqual(dictionary.entries.first?.original, "teh")
        XCTAssertEqual(dictionary.entries.first?.replacement, "the")
    }
}

@MainActor
private final class DeferredCommitObserver: TargetAppCorrectionCommitObserving {
    let onCommit: @MainActor (TargetAppCorrectionCommitSignal) -> Void
    init(onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) { self.onCommit = onCommit }
    func start() {}
    func stop() {}
}

@MainActor
private final class ReturnCommitObserver: TargetAppCorrectionCommitObserving {
    let onCommit: @MainActor (TargetAppCorrectionCommitSignal) -> Void
    init(onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) { self.onCommit = onCommit }
    func start() { onCommit(.returnKey) }
    func stop() {}
}

@MainActor
private final class SilentCommitObserver: TargetAppCorrectionCommitObserving {
    func start() {}
    func stop() {}
}
