import XCTest
@testable import TypeWhisper

/// Issue #1335: the setup wizard must distinguish selected, installed, loaded,
/// and tested models instead of treating a selected model ID as readiness.
final class SetupWizardTrialSignalTests: XCTestCase {
    // MARK: - evaluate

    func testRealInsertionCycleGrantsTestedState() {
        let armed = SetupWizardTrialSignal.evaluate(
            oldState: .processing, newState: .inserting,
            enteredInsertingFromProcessing: false)
        XCTAssertFalse(armed.granted)
        XCTAssertTrue(armed.enteredInsertingFromProcessing)

        let granted = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .idle,
            enteredInsertingFromProcessing: armed.enteredInsertingFromProcessing)
        XCTAssertTrue(granted.granted)
        XCTAssertFalse(granted.enteredInsertingFromProcessing)
    }

    func testToastFeedbackCycleDoesNotGrantTestedState() {
        // Notch/toast feedback passes through .inserting without a
        // transcription having run.
        let armed = SetupWizardTrialSignal.evaluate(
            oldState: .idle, newState: .inserting,
            enteredInsertingFromProcessing: false)
        XCTAssertFalse(armed.granted)
        XCTAssertFalse(armed.enteredInsertingFromProcessing)

        let done = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .idle,
            enteredInsertingFromProcessing: armed.enteredInsertingFromProcessing)
        XCTAssertFalse(done.granted)
    }

    func testToastDuringRecordingDoesNotGrantTestedState() {
        let armed = SetupWizardTrialSignal.evaluate(
            oldState: .recording, newState: .inserting,
            enteredInsertingFromProcessing: false)
        XCTAssertFalse(armed.granted)

        let done = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .idle,
            enteredInsertingFromProcessing: armed.enteredInsertingFromProcessing)
        XCTAssertFalse(done.granted)
    }

    func testInsertionFailureDoesNotGrantTestedState() {
        let armed = SetupWizardTrialSignal.evaluate(
            oldState: .processing, newState: .inserting,
            enteredInsertingFromProcessing: false)
        XCTAssertFalse(armed.granted)

        let failed = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .error("boom"),
            enteredInsertingFromProcessing: armed.enteredInsertingFromProcessing)
        XCTAssertFalse(failed.granted)
        // The flag resets so a later toast cycle cannot piggyback on it.
        XCTAssertFalse(failed.enteredInsertingFromProcessing)

        let done = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .idle,
            enteredInsertingFromProcessing: failed.enteredInsertingFromProcessing)
        XCTAssertFalse(done.granted)
    }

    func testReentrantInsertingSetKeepsFlagAndGrantsOnIdle() {
        // The real insertion path can set .inserting twice (post-processing
        // fallback toast); the second set must not clear the flag.
        let armed = SetupWizardTrialSignal.evaluate(
            oldState: .processing, newState: .inserting,
            enteredInsertingFromProcessing: false)
        let reentrant = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .inserting,
            enteredInsertingFromProcessing: armed.enteredInsertingFromProcessing)
        XCTAssertFalse(reentrant.granted)
        XCTAssertTrue(reentrant.enteredInsertingFromProcessing)

        let granted = SetupWizardTrialSignal.evaluate(
            oldState: .inserting, newState: .idle,
            enteredInsertingFromProcessing: reentrant.enteredInsertingFromProcessing)
        XCTAssertTrue(granted.granted)
    }

    // MARK: - engineIsReadyOrRestorable (#1335 invariants)

    func testSelectedModelIdAloneIsNotAnInputToReadiness() {
        // A selected or persisted model ID alone must never produce a
        // loaded/ready claim: without configured, restorable, or fallback
        // state there is no readiness, regardless of selection.
        XCTAssertFalse(TranscriptionEngineReadiness.engineIsReadyOrRestorable(
            authAvailable: true,
            isConfigured: false,
            hasPersistedRestorableModel: false,
            hasPreparationFallback: false))
    }

    func testRestorableInstalledModelCountsAsReady() {
        // Auto-unloaded model with persisted installed assets: restorable on
        // demand, so the setup test may run (the test itself is the proof).
        XCTAssertTrue(TranscriptionEngineReadiness.engineIsReadyOrRestorable(
            authAvailable: true,
            isConfigured: false,
            hasPersistedRestorableModel: true,
            hasPreparationFallback: false))
    }

    func testConfiguredEngineCountsAsReady() {
        XCTAssertTrue(TranscriptionEngineReadiness.engineIsReadyOrRestorable(
            authAvailable: true,
            isConfigured: true,
            hasPersistedRestorableModel: false,
            hasPreparationFallback: false))
    }

    func testPreparationFallbackCountsAsReady() {
        XCTAssertTrue(TranscriptionEngineReadiness.engineIsReadyOrRestorable(
            authAvailable: true,
            isConfigured: false,
            hasPersistedRestorableModel: false,
            hasPreparationFallback: true))
    }

    func testUnavailableAuthNeverCountsAsReady() {
        XCTAssertFalse(TranscriptionEngineReadiness.engineIsReadyOrRestorable(
            authAvailable: false,
            isConfigured: true,
            hasPersistedRestorableModel: true,
            hasPreparationFallback: true))
    }
}
