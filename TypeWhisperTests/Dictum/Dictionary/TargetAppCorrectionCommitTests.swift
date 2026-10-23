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
        let service = TargetAppCorrectionLearningService(
            textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
            makeCommitObserver: { callback in
                let value = DeferredCommitObserver(onCommit: callback)
                observer = value
                return value
            }, defaults: defaults)
        let baseline = TextInsertionService.FocusedTextObservation(
            element: element, value: "Please use teh word", selectedText: nil,
            selectedRange: NSRange(location: 19, length: 0))
        let task = Task { await service.trackInsertion(insertedText: "Please use teh word", baseline: baseline) }
        try await Task.sleep(for: .seconds(35))
        edited = true
        observer?.onCommit(.returnKey)
        let result = await task.value
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
