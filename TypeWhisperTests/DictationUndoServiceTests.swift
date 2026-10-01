import ApplicationServices
import AppKit
import XCTest
@testable import TypeWhisper

/// Tests for the session-only safe undo / raw-transcript restore
/// (issue #999). All Accessibility access is injected through fakes; the
/// tests run headless.
@MainActor
final class DictationUndoServiceTests: XCTestCase {
    @MainActor
    private final class Harness {
        var value: String
        var selectedRange: NSRange?
        var element: AXUIElement
        var bundleId: String?
        var busy = false
        var pendingPersistenceIDs = Set<UUID>()
        var focusedElementAvailable = true
        var observationAvailable = true
        var replaceSucceeds = true
        var verifiesReplacement = true
        var now = Date()
        var maximumSnapshotAge: TimeInterval = DictationUndoService.defaultMaximumSnapshotAge
        var replacements: [(range: NSRange, text: String)] = []
        var restoredCallbacks: [(id: UUID, rawText: String)] = []

        init(value: String, caret: Int, bundleId: String? = "com.test.app") {
            self.value = value
            self.selectedRange = NSRange(location: caret, length: 0)
            self.element = AXUIElementCreateApplication(1234)
            self.bundleId = bundleId
        }

        func makeService() -> DictationUndoService {
            DictationUndoService(
                captureActiveApp: { [weak self] in
                    (name: nil, bundleId: self?.bundleId ?? nil, url: nil)
                },
                focusedObservation: { [weak self] in
                    guard let self,
                          self.focusedElementAvailable,
                          self.observationAvailable else { return nil }
                    return TextInsertionService.FocusedTextObservation(
                        element: self.element,
                        value: self.value,
                        selectedText: nil,
                        selectedRange: self.selectedRange
                    )
                },
                replaceRange: { [weak self] range, _, text in
                    guard let self, self.replaceSucceeds else { return .notApplied }
                    let nsValue = self.value as NSString
                    guard NSMaxRange(range) <= nsValue.length else { return .notApplied }
                    self.replacements.append((range, text))
                    self.value = nsValue.replacingCharacters(in: range, with: text)
                    self.selectedRange = NSRange(
                        location: range.location + (text as NSString).length,
                        length: 0
                    )
                    return self.verifiesReplacement ? .verified : .unverified
                },
                isDictationBusy: { [weak self] in self?.busy ?? true },
                didRestoreRawTranscript: { [weak self] id, rawText in
                    self?.restoredCallbacks.append((id, rawText))
                },
                isPersistencePending: { [weak self] id in self?.pendingPersistenceIDs.contains(id) ?? true },
                now: { [weak self] in self?.now ?? Date() },
                maximumSnapshotAge: maximumSnapshotAge
            )
        }

        /// Records a snapshot as if `insertedText` had just been inserted at
        /// the end of the document.
        func record(
            service: DictationUndoService,
            raw: String,
            inserted: String,
            id: UUID = UUID()
        ) -> UUID {
            value += inserted
            selectedRange = NSRange(location: (value as NSString).length, length: 0)
            service.recordSnapshot(rawTranscript: raw, insertedText: inserted, transcriptionID: id)
            return id
        }
    }

    // MARK: - Happy paths

    func testUndoDeletesInsertedTextAndInvalidatesSnapshot() {
        let harness = Harness(value: "Say ", caret: 4)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello world", inserted: "Hello world.")

        XCTAssertTrue(service.canUndo)
        XCTAssertEqual(service.perform(.undo), .success)
        XCTAssertEqual(harness.value, "Say ")
        XCTAssertEqual(harness.replacements.count, 1)
        XCTAssertEqual(harness.replacements[0].text, "")
        // "Hello world." is 12 UTF-16 units; document was "Say Hello world." (16).
        XCTAssertEqual(harness.replacements[0].range, NSRange(location: 4, length: 12))

        // A second invocation is a safe no-op: the snapshot is consumed.
        XCTAssertFalse(service.canUndo)
        XCTAssertEqual(service.perform(.undo), .failed(.noSnapshot))
        XCTAssertEqual(harness.replacements.count, 1)
    }

    func testRestoreReplacesInsertedTextWithRawTranscript() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        let id = harness.record(service: service, raw: "hello world", inserted: "Hello world.")

        XCTAssertTrue(service.canRestoreRaw)
        XCTAssertEqual(service.perform(.restore), .success)
        XCTAssertEqual(harness.value, "hello world")
        XCTAssertEqual(harness.replacements.count, 1)
        XCTAssertEqual(harness.replacements[0].text, "hello world")

        // The restore callback carries the transcription id and raw text so
        // recent-transcription state and history stay consistent.
        XCTAssertEqual(harness.restoredCallbacks.count, 1)
        XCTAssertEqual(harness.restoredCallbacks[0].id, id)
        XCTAssertEqual(harness.restoredCallbacks[0].rawText, "hello world")

        XCTAssertFalse(service.canUndo)
        XCTAssertEqual(service.perform(.restore), .failed(.noSnapshot))
    }

    func testRestoreUnavailableWhenRawIdenticalToInserted() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "Hello world.", inserted: "Hello world.")

        XCTAssertTrue(service.canUndo)
        XCTAssertFalse(service.canRestoreRaw)
        XCTAssertEqual(service.perform(.restore), .failed(.nothingToRestore))
        XCTAssertTrue(harness.replacements.isEmpty)
        // Undo is still available: only restore is gated on identical text.
        XCTAssertEqual(service.perform(.undo), .success)
    }

    func testContextualCapitalizationAndWhitespaceTrackedExactly() {
        // Contextual insertion added a leading space and capitalization.
        let harness = Harness(value: "Say", caret: 3)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: " Hello")

        XCTAssertEqual(service.perform(.undo), .success)
        XCTAssertEqual(harness.value, "Say")
        XCTAssertEqual(harness.replacements[0].range, NSRange(location: 3, length: 6))
    }

    func testUnicodeInsertedTextUsesUTF16Offsets() {
        // "👍" is one Character but two UTF-16 code units; AX ranges are UTF-16.
        let harness = Harness(value: "Hi", caret: 2)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "thumbs up", inserted: " 👍")

        XCTAssertEqual(service.perform(.restore), .success)
        XCTAssertEqual(harness.value, "Hithumbs up")
        XCTAssertEqual(harness.replacements[0].range, NSRange(location: 2, length: 3))
    }

    // MARK: - Eligibility

    func testPerformWithoutSnapshotFails() {
        let harness = Harness(value: "text", caret: 4)
        let service = harness.makeService()
        XCTAssertFalse(service.canUndo)
        XCTAssertFalse(service.canRestoreRaw)
        XCTAssertEqual(service.perform(.undo), .failed(.noSnapshot))
        XCTAssertEqual(service.perform(.restore), .failed(.noSnapshot))
    }

    func testEmptyInsertedTextRecordsNothing() {
        let harness = Harness(value: "text", caret: 4)
        let service = harness.makeService()
        service.recordSnapshot(rawTranscript: "raw", insertedText: "", transcriptionID: UUID())
        XCTAssertFalse(service.canUndo)
    }

    func testMissingFocusedElementRecordsNothing() {
        let harness = Harness(value: "text", caret: 4)
        harness.focusedElementAvailable = false
        let service = harness.makeService()
        service.recordSnapshot(rawTranscript: "raw", insertedText: "text", transcriptionID: UUID())
        XCTAssertFalse(service.canUndo)
    }

    func testRecordRequiresInsertedTextImmediatelyBeforeCaret() {
        // The field does not end with the claimed inserted text at the caret:
        // an unverified paste must not create a snapshot.
        let harness = Harness(value: "Say Hello.", caret: 6)
        let service = harness.makeService()
        service.recordSnapshot(rawTranscript: "hello", insertedText: "Hello.", transcriptionID: UUID())
        XCTAssertFalse(service.canUndo)

        // Same when the caret is a selection rather than an insertion point.
        let selecting = Harness(value: "", caret: 0)
        let selectingService = selecting.makeService()
        selecting.value = "Hello."
        selecting.selectedRange = NSRange(location: 0, length: 6)
        selectingService.recordSnapshot(rawTranscript: "hello", insertedText: "Hello.", transcriptionID: UUID())
        XCTAssertFalse(selectingService.canUndo)
    }

    func testNewerInsertionReplacesOlderSnapshot() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "first", inserted: "First.")
        _ = harness.record(service: service, raw: "second", inserted: " Second.")

        XCTAssertEqual(service.perform(.undo), .success)
        // Only the most recent insertion (" Second.") was removed.
        XCTAssertEqual(harness.value, "First.")
    }

    func testStaleSnapshotIsInvalidated() {
        let harness = Harness(value: "", caret: 0)
        harness.maximumSnapshotAge = 60
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.now = harness.now.addingTimeInterval(61)

        XCTAssertEqual(service.perform(.undo), .failed(.staleSnapshot))
        XCTAssertTrue(harness.replacements.isEmpty)
        XCTAssertEqual(harness.value, "Hello.")
        // A stale snapshot is consumed, not kept.
        XCTAssertFalse(service.canUndo)
        XCTAssertEqual(service.perform(.undo), .failed(.noSnapshot))
    }

    func testFreshSnapshotWithinMaxAgeSucceeds() {
        let harness = Harness(value: "", caret: 0)
        harness.maximumSnapshotAge = 60
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.now = harness.now.addingTimeInterval(59)

        XCTAssertEqual(service.perform(.undo), .success)
        XCTAssertEqual(harness.value, "")
    }

    // MARK: - Safe no-ops

    func testBusyDictationIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.busy = true

        XCTAssertEqual(service.perform(.undo), .failed(.dictationBusy))
        XCTAssertEqual(service.perform(.restore), .failed(.dictationBusy))
        XCTAssertTrue(harness.replacements.isEmpty)
        XCTAssertEqual(harness.value, "Hello.")
        // Snapshot survives a busy rejection.
        XCTAssertTrue(service.canUndo)
    }

    func testApplicationSwitchIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.bundleId = "com.other.app"

        XCTAssertEqual(service.perform(.undo), .failed(.targetChanged))
        XCTAssertTrue(harness.replacements.isEmpty)
    }

    func testFieldSwitchIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.element = AXUIElementCreateApplication(5678)

        XCTAssertEqual(service.perform(.undo), .failed(.targetChanged))
        XCTAssertTrue(harness.replacements.isEmpty)
    }

    func testMissingFocusedElementIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.focusedElementAvailable = false

        XCTAssertEqual(service.perform(.undo), .failed(.accessibilityUnavailable))
        XCTAssertTrue(harness.replacements.isEmpty)
    }

    func testMissingObservationIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.observationAvailable = false

        XCTAssertEqual(service.perform(.undo), .failed(.accessibilityUnavailable))
        XCTAssertTrue(harness.replacements.isEmpty)
    }

    func testSelectionInsteadOfCaretIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        // The user selected text instead of leaving the caret after the insertion.
        harness.selectedRange = NSRange(location: 0, length: 6)

        XCTAssertEqual(service.perform(.undo), .failed(.caretMoved))
        XCTAssertTrue(harness.replacements.isEmpty)
    }

    func testCaretMovedElsewhereIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        // Caret moved back to the start; the document itself is untouched.
        harness.selectedRange = NSRange(location: 0, length: 0)

        XCTAssertEqual(service.perform(.undo), .failed(.caretMoved))
        XCTAssertTrue(harness.replacements.isEmpty)
        XCTAssertEqual(harness.value, "Hello.")
    }

    func testMovedCaretAfterIdenticalTextIsSafeNoOp() {
        // The exact post-insertion caret location is required: moving the
        // caret after an identical earlier occurrence must not delete it.
        let harness = Harness(value: "ab ", caret: 3)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "ab", inserted: "ab")
        XCTAssertEqual(harness.value, "ab ab")

        // Caret moved to the end of the first "ab".
        harness.selectedRange = NSRange(location: 2, length: 0)

        XCTAssertEqual(service.perform(.undo), .failed(.caretMoved))
        XCTAssertTrue(harness.replacements.isEmpty)
        XCTAssertEqual(harness.value, "ab ab")
    }

    func testEditedTextIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        // The user edited the inserted text in place.
        harness.value = "Hello!"
        harness.selectedRange = NSRange(location: 6, length: 0)

        XCTAssertEqual(service.perform(.undo), .failed(.textChanged))
        XCTAssertEqual(harness.value, "Hello!")
    }

    func testEditedPrefixWithUnchangedCaretAndInsertedTextIsSafeNoOp() {
        let harness = Harness(value: "old ", caret: 4)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.value = "new Hello."
        XCTAssertEqual(service.perform(.undo), .failed(.textChanged))
        XCTAssertEqual(service.perform(.restore), .failed(.textChanged))
        XCTAssertTrue(harness.replacements.isEmpty)
    }

    func testTextTypedAfterInsertionIsSafeNoOp() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        // The user kept typing after the insertion.
        harness.value = "Hello. More text"
        harness.selectedRange = NSRange(location: 16, length: 0)

        XCTAssertEqual(service.perform(.undo), .failed(.textChanged))
        XCTAssertEqual(harness.value, "Hello. More text")
    }

    func testMutationFailureKeepsSnapshot() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.replaceSucceeds = false

        XCTAssertEqual(service.perform(.undo), .failed(.mutationFailed))
        // The snapshot is only invalidated on success, so a retry is possible.
        XCTAssertTrue(service.canUndo)
    }

    func testAppliedButUnverifiedRestoreConsumesSnapshotWithoutClaimingSuccess() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        _ = harness.record(service: service, raw: "hello", inserted: "Hello.")
        harness.verifiesReplacement = false

        XCTAssertNotEqual(service.perform(.restore), .success)
        XCTAssertEqual(harness.value, "hello")
        XCTAssertFalse(service.canUndo, "An uncertain write must not leave the old snapshot retryable")
        XCTAssertTrue(harness.restoredCallbacks.isEmpty)
    }

    func testRestoreGatesOnlyItsOwnPendingPersistenceAndDoesNotBlockUndo() {
        let harness = Harness(value: "", caret: 0)
        let service = harness.makeService()
        let id = harness.record(service: service, raw: "raw", inserted: "Processed.")
        harness.pendingPersistenceIDs = [id]
        XCTAssertEqual(service.perform(.restore), .failed(.persistencePending))
        XCTAssertEqual(harness.value, "Processed.")
        XCTAssertTrue(harness.replacements.isEmpty)
        XCTAssertTrue(service.canUndo)
        XCTAssertEqual(service.perform(.undo), .success)

        _ = harness.record(service: service, raw: "new raw", inserted: "New processed.")
        // An older pending record cannot hold up this already-persisted snapshot.
        XCTAssertEqual(service.perform(.restore), .success)
        XCTAssertEqual(harness.value, "new raw")
    }

    @MainActor
    private final class AXReplacementHarness {
        let insertion = TextInsertionService()
        let element = AXUIElementCreateApplication(1234)
        var value = "Processed."
        var selection = NSRange(location: 10, length: 0)
        var writeCount = 0
        var readbackAvailable = true
        var appliesWrite = true
        var acknowledgesWrite = true
        var honorsSelection = true
        var transformedText: String?
        var callbacks: [String] = []

        init() {
            insertion.accessibilityGrantedOverride = true
            insertion.captureActiveAppOverride = { (nil, "com.test.app", nil) }
            insertion.focusedTextElementOverride = { [unowned self] in element }
            insertion.focusedTextStateOverride = { [unowned self] _ in
                guard writeCount == 0 || readbackAvailable else { return nil }
                return TextInsertionService.FocusedTextSnapshot(
                    value: value, selectedText: nil, selectedRange: selection
                )
            }
            insertion.setSelectedRangeOverride = { [unowned self] _, range in
                if honorsSelection { selection = range }
                return true
            }
            insertion.insertTextAtOverride = { [unowned self] _, text in
                writeCount += 1
                if appliesWrite {
                    let replacement = transformedText ?? text
                    value = (value as NSString).replacingCharacters(in: selection, with: replacement)
                    selection = NSRange(location: selection.location + (replacement as NSString).length, length: 0)
                }
                return acknowledgesWrite
            }
        }

        func makeService() -> DictationUndoService {
            let service = DictationUndoService(
                textInsertionService: insertion,
                isPersistencePending: { _ in false },
                isDictationBusy: { false },
                didRestoreRawTranscript: { [unowned self] _, raw in callbacks.append(raw) }
            )
            service.recordSnapshot(rawTranscript: " raw \n", insertedText: value, transcriptionID: UUID())
            return service
        }
    }

    func testActualRangeWriterConsumesSnapshotWhenPostWriteReadFails() {
        let harness = AXReplacementHarness()
        let service = harness.makeService()
        harness.readbackAvailable = false
        XCTAssertEqual(service.perform(.restore), .failed(.mutationUnverified))
        XCTAssertEqual(harness.writeCount, 1)
        XCTAssertEqual(harness.value, " raw \n")
        XCTAssertNil(service.snapshot)
        XCTAssertTrue(harness.callbacks.isEmpty)
        XCTAssertEqual(service.perform(.restore), .failed(.noSnapshot))
        XCTAssertEqual(harness.writeCount, 1)
    }

    func testActualRangeWriterKeepsSnapshotWhenApplicationIgnoresWrite() {
        let harness = AXReplacementHarness()
        let service = harness.makeService()
        harness.appliesWrite = false
        XCTAssertEqual(service.perform(.restore), .failed(.mutationFailed))
        XCTAssertEqual(harness.value, "Processed.")
        XCTAssertEqual(harness.writeCount, 1)
        XCTAssertNotNil(service.snapshot)
        XCTAssertTrue(harness.callbacks.isEmpty)
    }

    func testActualRangeWriterRejectsIgnoredSelectionBeforeWriting() {
        let harness = AXReplacementHarness()
        let service = harness.makeService()
        harness.honorsSelection = false
        XCTAssertEqual(service.perform(.undo), .failed(.mutationFailed))
        XCTAssertEqual(harness.value, "Processed.")
        XCTAssertEqual(harness.writeCount, 0)
        XCTAssertNotNil(service.snapshot)
    }

    func testActualRangeWriterDoesNotClaimTransformedResultAsRestored() {
        let harness = AXReplacementHarness()
        let service = harness.makeService()
        harness.transformedText = "RAW"
        XCTAssertEqual(service.perform(.restore), .failed(.mutationUnverified))
        XCTAssertEqual(harness.value, "RAW")
        XCTAssertNil(service.snapshot)
        XCTAssertTrue(harness.callbacks.isEmpty)
    }

    func testActualRangeWriterTrustsVerifiedValueEvenWhenSetterReportsFailure() {
        let harness = AXReplacementHarness()
        let service = harness.makeService()
        harness.acknowledgesWrite = false
        XCTAssertEqual(service.perform(.restore), .success)
        XCTAssertEqual(harness.callbacks, [" raw \n"])
        XCTAssertEqual(harness.value, " raw \n")
        XCTAssertNil(service.snapshot)
    }

    // MARK: - Feedback and hotkeys

    func testAllFailuresHaveFeedbackMessages() {
        let failures: [DictationUndoService.Failure] = [
            .noSnapshot, .nothingToRestore, .staleSnapshot, .dictationBusy,
            .accessibilityUnavailable, .targetChanged, .caretMoved,
            .textChanged, .mutationFailed, .mutationUnverified, .persistencePending,
        ]
        for failure in failures {
            XCTAssertFalse(
                failure.feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Missing feedback message for \(failure)"
            )
        }
    }

    func testHotkeySlotDefaultsKeysAreUnique() {
        // The shared hotkey path persists each slot under its defaults keys;
        // collisions would silently merge two slots' bindings.
        let slots = HotkeySlotType.allCases
        let singleKeys = slots.map { $0.defaultsKey }
        XCTAssertEqual(Set(singleKeys).count, singleKeys.count, "Duplicate hotkey defaults key")
        let multiKeys = slots.map { $0.hotkeysDefaultsKey }
        XCTAssertEqual(Set(multiKeys).count, multiKeys.count, "Duplicate hotkeys defaults key")
    }

    func testUndoHotkeyConflictsThroughSharedPredicate() {
        // isHotkeyAssigned(_:excluding:) and the settings conflict UI both go
        // through UnifiedHotkey.conflicts(with:).
        let undoHotkey = UnifiedHotkey(keyCode: 6, modifierFlags: 1_048_576, isFn: false)
        let identical = UnifiedHotkey(keyCode: 6, modifierFlags: 1_048_576, isFn: false)
        let differentKey = UnifiedHotkey(keyCode: 7, modifierFlags: 1_048_576, isFn: false)
        let differentModifiers = UnifiedHotkey(keyCode: 6, modifierFlags: 2_097_152, isFn: false)

        XCTAssertTrue(undoHotkey.conflicts(with: identical))
        XCTAssertFalse(undoHotkey.conflicts(with: differentKey))
        XCTAssertFalse(undoHotkey.conflicts(with: differentModifiers))
    }

    func testHotkeyConflictDetectedThroughSharedServicePath() {
        // isHotkeyAssigned(_:excluding:) is the shared path used by hotkey
        // registration and the settings conflict UI.
        let service = HotkeyService()
        let hotkey = UnifiedHotkey(keyCode: 6, modifierFlags: 1_048_576, isFn: false)
        service.setHotkeysForTesting([hotkey], for: .copyLastTranscription)

        XCTAssertEqual(
            service.isHotkeyAssigned(hotkey, excluding: .undoLastDictation),
            .copyLastTranscription
        )
        XCTAssertNil(service.isHotkeyAssigned(hotkey, excluding: .copyLastTranscription))

        let other = UnifiedHotkey(keyCode: 7, modifierFlags: 1_048_576, isFn: false)
        XCTAssertNil(service.isHotkeyAssigned(other, excluding: .undoLastDictation))
    }

    func testNewSlotsDoNotStartDictation() {
        // Undo/restore hotkeys must never start or stop a recording; they are
        // keyDown-only actions like copy/paste last transcription.
        XCTAssertFalse(HotkeySlotType.undoLastDictation.startsDictation)
        XCTAssertFalse(HotkeySlotType.restoreRawTranscript.startsDictation)
        XCTAssertTrue(HotkeySlotType.toggle.startsDictation)
    }
}
