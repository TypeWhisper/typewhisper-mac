import XCTest
import AppKit
@testable import TypeWhisper

@MainActor
final class VoiceTransformCoordinatorTests: XCTestCase {
    @MainActor
    private final class Fixture {
        var starts = 0
        var stops = 0
        var writes: [String] = []
        var requests: [(String, String)] = []
        var resolutions = 0
        var limits = VoiceTransformLimits()
        var recordingTimeouts: [Int] = []
        var expireRecordingImmediately = false
        var canStart = true
        var source = "Original 🐱 text"
        var spoken = "my rewrite, keep the dates"
        var resolvedInstruction = "Be concise, keep the dates"
        var output = "Rewritten text"
        var startOverride: (() async throws -> Void)?
        var generationOverride: (() async throws -> String)?
        var writeError = false
        var presentations = 0
        var captureOverride: (() async throws -> VoiceTransformTarget)?
        lazy var coordinator = makeCoordinator()

        private func makeCoordinator() -> VoiceTransformCoordinator {
            VoiceTransformCoordinator(dependencies: .init(
            canStart: { [unowned self] in canStart },
            capture: { [unowned self] in
                if let captureOverride { return try await captureOverride() }
                return VoiceTransformTarget(text: source) { [unowned self] text in
                    writes.append(text)
                    if writeError { throw VoiceTransformError.message("Target changed") }
                }
            },
            start: { [unowned self] in starts += 1; try await startOverride?() },
            stop: { [unowned self] in stops += 1; return [0.1, 0.2] },
            transcribe: { [unowned self] _ in spoken },
            resolve: { [unowned self] text in
                resolutions += 1
                return .init(original: text, resolved: resolvedInstruction, matchedTriggers: ["my rewrite"])
            },
            generate: { [unowned self] instruction, source in
                requests.append((instruction, source))
                if let generationOverride { return try await generationOverride() }
                return output
            },
            present: { [unowned self] in presentations += 1 },
            cancellationAvailability: { _ in },
            limits: { [unowned self] in limits },
            waitForRecordingLimit: { [unowned self] seconds in
                recordingTimeouts.append(seconds)
                if !expireRecordingImmediately { try await Task.sleep(for: .seconds(seconds)) }
            }
            ))
        }
    }

    private func waitFor(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected state was not reached", file: file, line: line)
    }

    private func preview(_ fixture: Fixture) async throws {
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .preview || fixture.coordinator.state == .failed }
    }

    func testInstructionExpansionPreviewAndExplicitReplacement() async throws {
        let fixture = Fixture()
        try await preview(fixture)
        XCTAssertEqual(fixture.requests.first?.0, "Be concise, keep the dates")
        XCTAssertEqual(fixture.requests.first?.1, "Original 🐱 text")
        XCTAssertEqual(fixture.coordinator.matchedTriggers, ["my rewrite"])
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.coordinator.apply()
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.writes, ["Rewritten text"])
        XCTAssertEqual(fixture.coordinator.original, "")
        XCTAssertEqual(fixture.coordinator.generatedInstruction, "")
    }

    func testPreviewWindowResizesOnlyAfterCoordinatorCommitsPreviewState() async throws {
        let fixture = Fixture()
        let suite = "VoiceTransformWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = VoiceTransformWindowController(coordinator: fixture.coordinator, defaults: defaults)
        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Voice Transform" && $0.isVisible })
        defer { panel.orderOut(nil) }
        var statesDuringReviewLayout: [VoiceTransformCoordinator.State] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                if !fixture.coordinator.result.isEmpty {
                    statesDuringReviewLayout.append(fixture.coordinator.state)
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await preview(fixture)
        try await waitFor { !statesDuringReviewLayout.isEmpty }
        XCTAssertTrue(statesDuringReviewLayout.allSatisfy { $0 == .preview },
                      "Window layout rendered stale coordinator states: \(statesDuringReviewLayout)")
        XCTAssertEqual(fixture.coordinator.result, fixture.output)
        XCTAssertTrue(panel.isVisible)
        withExtendedLifetime(controller) {}
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
        try await waitFor { !panel.isVisible }
    }

    func testQueuedIdleDoesNotHideNewRecordingPanel() async throws {
        let fixture = Fixture()
        let controller = VoiceTransformWindowController(coordinator: fixture.coordinator)
        // The controller has queued its initial idle event. Opening a new
        // session before that event is delivered must not hide its panel.
        fixture.coordinator.toggleRecording()
        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Voice Transform" && $0.isVisible })
        defer { panel.orderOut(nil) }
        try await waitFor { fixture.coordinator.state == .recording }
        await Task.yield()
        XCTAssertTrue(panel.isVisible)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle && !panel.isVisible }
        withExtendedLifetime(controller) {}
    }

    func testRetryUsesOriginalAndEditedInstructionWithoutExpandingAgain() async throws {
        let fixture = Fixture()
        try await preview(fixture)
        fixture.coordinator.instruction = "Translate to French"
        XCTAssertFalse(fixture.coordinator.canApply)
        fixture.coordinator.retry()
        try await waitFor { fixture.requests.count == 2 && fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.resolutions, 1)
        XCTAssertEqual(fixture.requests.last?.0, "Translate to French")
        XCTAssertEqual(fixture.requests.last?.1, fixture.source)
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testBusyAndMissingSelectionDoNotStartRecording() async throws {
        let fixture = Fixture()
        fixture.canStart = false
        fixture.coordinator.toggleRecording()
        XCTAssertEqual(fixture.starts, 0)
        fixture.canStart = true
        fixture.source = ""
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .failed }
        XCTAssertEqual(fixture.starts, 0)
        XCTAssertEqual(fixture.coordinator.state, .failed)
    }

    func testCaptureCompletesBeforePanelCanStealFocus() async throws {
        let fixture = Fixture()
        var continuation: CheckedContinuation<VoiceTransformTarget, Never>?
        var released = false
        fixture.captureOverride = { await withCheckedContinuation { continuation = $0 } }
        fixture.coordinator.toggleRecording()
        try await waitFor { continuation != nil }
        XCTAssertEqual(fixture.presentations, 0)
        XCTAssertEqual(fixture.starts, 0)
        fixture.coordinator.cancel()
        continuation?.resume(returning: VoiceTransformTarget(text: "Selected", release: { released = true }, replace: { _ in }))
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertTrue(released)
        XCTAssertEqual(fixture.presentations, 0)
        XCTAssertEqual(fixture.starts, 0)
    }

    func testCopyFallbackCapturesFreshSelectionAndRestoresClipboard() async throws {
        let service = TextInsertionService()
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("Previous clipboard", forType: .string)
        service.pasteboardProvider = { clipboard }
        service.accessibilityGrantedOverride = true
        service.textSelectionOverride = { nil }
        service.chromiumAccessibilityObservationOverride = { _, _ in nil }
        service.copySimulatorOverride = {
            clipboard.clearContents()
            clipboard.setString("Firefox selection", forType: .string)
        }
        let target = try await service.captureVoiceTransformTarget()
        XCTAssertEqual(target.text, "Firefox selection")
        XCTAssertFalse(target.supportsReplacement)
        XCTAssertEqual(clipboard.string(forType: .string), "Previous clipboard")
        do {
            try await target.replace("New text")
            XCTFail("Copy-only target must reject replacement")
        } catch { }
    }

    func testCancelDuringPendingCopyRestoresClipboard() async throws {
        let service = TextInsertionService()
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("Original clipboard", forType: .string)
        service.pasteboardProvider = { clipboard }
        service.accessibilityGrantedOverride = true
        service.textSelectionOverride = { nil }
        service.chromiumAccessibilityObservationOverride = { _, _ in nil }
        var pendingCopy: Task<Void, Never>?
        service.copySimulatorOverride = {
            pendingCopy = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                clipboard.clearContents()
                clipboard.setString("Delayed selection", forType: .string)
            }
        }
        let capture = Task { try await service.captureVoiceTransformTarget() }
        try await waitFor { pendingCopy != nil }
        capture.cancel()
        do {
            _ = try await capture.value
            XCTFail("Cancelled copy must not return a target")
        } catch is CancellationError { }
        await pendingCopy?.value
        XCTAssertEqual(clipboard.string(forType: .string), "Original clipboard")
    }

    func testCaptureDoesNotUseStaleClipboardAndDistinguishesMissingPermission() async throws {
        let service = TextInsertionService()
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("Unrelated clipboard text", forType: .string)
        service.pasteboardProvider = { clipboard }
        service.textSelectionOverride = { nil }
        service.chromiumAccessibilityObservationOverride = { _, _ in nil }
        service.copySimulatorOverride = {}
        service.accessibilityGrantedOverride = true
        do {
            _ = try await service.captureVoiceTransformTarget()
            XCTFail("Stale clipboard must not be interpreted as a selection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No selection"))
        }
        XCTAssertEqual(clipboard.string(forType: .string), "Unrelated clipboard text")
        service.accessibilityGrantedOverride = false
        do {
            _ = try await service.captureVoiceTransformTarget()
            XCTFail("Permission failure must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Accessibility permission"))
        }
    }

    func testGenerationFailureAndEmptyOutputNeverWrite() async throws {
        let fixture = Fixture()
        fixture.generationOverride = { throw VoiceTransformError.message("Signed out") }
        try await preview(fixture)
        XCTAssertEqual(fixture.coordinator.state, .failed)
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertEqual(fixture.coordinator.original, fixture.source)
        fixture.generationOverride = nil
        fixture.output = "   "
        fixture.coordinator.retry()
        try await waitFor { fixture.requests.count == 2 && fixture.coordinator.state == .failed }
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testCancellationDiscardsLateGenerationAndHoldsOwnershipUntilCleanup() async throws {
        let fixture = Fixture()
        var continuation: CheckedContinuation<String, Never>?
        fixture.generationOverride = { await withCheckedContinuation { continuation = $0 } }
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.coordinator.finishRecording()
        try await waitFor { continuation != nil }
        fixture.coordinator.cancel()
        XCTAssertTrue(fixture.coordinator.isBusy)
        continuation?.resume(returning: "Late output")
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.coordinator.result, "")
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testCancelDuringMicrophoneStartStopsAfterStartReturns() async throws {
        let fixture = Fixture()
        var continuation: CheckedContinuation<Void, Never>?
        fixture.startOverride = { await withCheckedContinuation { continuation = $0 } }
        fixture.coordinator.toggleRecording()
        try await waitFor { continuation != nil }
        fixture.coordinator.cancel()
        XCTAssertTrue(fixture.coordinator.isBusy)
        continuation?.resume()
        try await waitFor { fixture.coordinator.state == .idle }
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testUnverifiedWriteCannotBeRetriedAutomaticallyOrByRepeatedApply() async throws {
        let fixture = Fixture()
        fixture.writeError = true
        try await preview(fixture)
        fixture.coordinator.apply()
        try await waitFor { fixture.coordinator.state == .preview }
        fixture.coordinator.apply()
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertFalse(fixture.coordinator.replacementAvailable)
        XCTAssertEqual(fixture.coordinator.result, fixture.output)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testLimitsRejectRatherThanTruncate() throws {
        XCTAssertThrowsError(try VoiceTransformCoordinator.validateSource(String(repeating: "a", count: 12_001)))
        XCTAssertThrowsError(try VoiceTransformCoordinator.validateInstruction(String(repeating: "a", count: 2_001)))
        XCTAssertThrowsError(try VoiceTransformCoordinator.validateInstruction(" \n"))
        XCTAssertNoThrow(try VoiceTransformCoordinator.validateSource("Hello 🐱"))
    }

    func testConfiguredSourceLimitRejectsBeforeMicrophoneStarts() async throws {
        let fixture = Fixture()
        fixture.limits = VoiceTransformLimits(sourceCharacters: 100)
        fixture.source = String(repeating: "x", count: 101)
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .failed }
        XCTAssertEqual(fixture.starts, 0)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testExpandedPromptIsCheckedAgainstConfiguredInstructionLimit() async throws {
        let fixture = Fixture()
        fixture.limits = VoiceTransformLimits(instructionCharacters: 100)
        fixture.resolvedInstruction = String(repeating: "x", count: 101)
        try await preview(fixture)
        XCTAssertEqual(fixture.coordinator.state, .failed)
        XCTAssertEqual(fixture.coordinator.instruction.count, 101)
        XCTAssertTrue(fixture.requests.isEmpty)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testInstructionLimitCanBeRaisedForRetry() async throws {
        let fixture = Fixture()
        fixture.limits = VoiceTransformLimits(instructionCharacters: 100)
        try await preview(fixture)
        fixture.coordinator.instruction = String(repeating: "x", count: 101)
        fixture.coordinator.retry()
        try await waitFor { fixture.coordinator.state == .failed }
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.limits = VoiceTransformLimits(instructionCharacters: 200)
        fixture.coordinator.retry()
        try await waitFor { fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.requests.last?.0.count, 101)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testRecordingKeepsStartingLimitsAndRetryLoadsNewLimits() async throws {
        let fixture = Fixture()
        fixture.output = String(repeating: "x", count: 101)
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .recording }
        fixture.limits = VoiceTransformLimits(resultCharacters: 100)
        fixture.coordinator.finishRecording()
        try await waitFor { fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.coordinator.result.count, 101)
        fixture.coordinator.retry()
        try await waitFor { fixture.coordinator.state == .failed }
        XCTAssertTrue(fixture.coordinator.result.isEmpty)
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testConfiguredRecordingTimeoutStopsAndGeneratesPreview() async throws {
        let fixture = Fixture()
        fixture.limits = VoiceTransformLimits(recordingSeconds: 20)
        fixture.expireRecordingImmediately = true
        fixture.coordinator.toggleRecording()
        try await waitFor { fixture.coordinator.state == .preview }
        XCTAssertEqual(fixture.recordingTimeouts, [20])
        XCTAssertEqual(fixture.stops, 1)
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.coordinator.cancel()
        try await waitFor { fixture.coordinator.state == .idle }
    }

    func testTransformPreferencesDefaultsPersistenceAndBounds() throws {
        let suite = "VoiceTransformPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(VoiceTransformLimits.load(from: defaults), VoiceTransformLimits())
        defaults.set(4_000, forKey: UserDefaultsKeys.transformInstructionLimit)
        defaults.set(-1, forKey: UserDefaultsKeys.transformSourceLimit)
        defaults.set(Int.max, forKey: UserDefaultsKeys.transformResultLimit)
        defaults.set(0, forKey: UserDefaultsKeys.transformRecordingLimit)
        let reloaded = VoiceTransformLimits.load(from: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reloaded.instructionCharacters, 4_000)
        XCTAssertEqual(reloaded.sourceCharacters, 100)
        XCTAssertEqual(reloaded.resultCharacters, 100_000)
        XCTAssertEqual(reloaded.recordingSeconds, 10)
    }

    func testReviewSizeRememberResetAndCompactPolicy() throws {
        let suite = "VoiceTransformWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = NSSize(width: 800, height: 600)
        XCTAssertEqual(VoiceTransformWindowPreferences.size(for: .recording, defaults: defaults), NSSize(width: 420, height: 180))
        VoiceTransformWindowPreferences.saveReviewSize(saved, to: defaults)
        XCTAssertEqual(VoiceTransformWindowPreferences.size(for: .preview, defaults: defaults), saved)
        XCTAssertEqual(VoiceTransformWindowPreferences.size(for: .recording, defaults: defaults), NSSize(width: 420, height: 180))
        defaults.set(false, forKey: UserDefaultsKeys.transformStartCompact)
        XCTAssertEqual(VoiceTransformWindowPreferences.size(for: .recording, defaults: defaults), saved)
        XCTAssertEqual(VoiceTransformWindowPreferences.size(for: .failed, defaults: defaults), NSSize(width: 460, height: 300))
        defaults.set(false, forKey: UserDefaultsKeys.transformRememberReviewSize)
        VoiceTransformWindowPreferences.saveReviewSize(NSSize(width: 900, height: 700), to: defaults)
        XCTAssertEqual(VoiceTransformWindowPreferences.reviewSize(defaults), NSSize(width: 560, height: 400))
        defaults.set(true, forKey: UserDefaultsKeys.transformRememberReviewSize)
        XCTAssertEqual(VoiceTransformWindowPreferences.reviewSize(defaults), saved)
        VoiceTransformWindowPreferences.resetSize(in: defaults)
        XCTAssertEqual(VoiceTransformWindowPreferences.reviewSize(defaults), NSSize(width: 560, height: 400))
    }

    func testSelectionSnapshotRejectsDocumentRangeAndSelectionChanges() throws {
        let initial = VoiceTransformSelectionSnapshot(value: "A 🐱 B", range: NSRange(location: 2, length: 2), selectedText: "🐱")
        XCTAssertEqual(try initial.replacementDocument(original: "🐱", replacement: "cat", current: initial), "A cat B")
        let changed = [
            VoiceTransformSelectionSnapshot(value: "C 🐱 B", range: initial.range, selectedText: "🐱"),
            VoiceTransformSelectionSnapshot(value: initial.value, range: NSRange(location: 0, length: 1), selectedText: "A"),
            VoiceTransformSelectionSnapshot(value: initial.value, range: initial.range, selectedText: nil)
        ]
        for current in changed {
            XCTAssertThrowsError(try initial.replacementDocument(original: "🐱", replacement: "cat", current: current))
        }
        XCTAssertThrowsError(try initial.replacementDocument(original: "wrong", replacement: "cat", current: initial))
    }

    func testDedicatedShortcutDoesNotStartDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        let hotkey = UnifiedHotkey(keyCode: 17, modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue, isFn: false)
        service.setHotkeyForTesting(hotkey, for: .voiceTransform)
        var transforms = 0
        var dictations = 0
        service.onVoiceTransformToggle = { transforms += 1 }
        service.onDictationStart = { _ in dictations += 1 }
        service.processCarbonHotkeyForTesting(slotType: .voiceTransform, hotkey: hotkey, isPressed: true)
        service.processCarbonHotkeyForTesting(slotType: .voiceTransform, hotkey: hotkey, isPressed: false)
        XCTAssertEqual(transforms, 1)
        XCTAssertEqual(dictations, 0)
        XCTAssertNil(service.currentMode)
    }
}
