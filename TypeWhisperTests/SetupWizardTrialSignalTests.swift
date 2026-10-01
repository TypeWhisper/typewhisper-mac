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

    // MARK: - Current readiness and persisted model-specific proof

    private let modelA = SetupWizardTestedSelection(providerId: "local", modelId: "model-a")
    private let modelB = SetupWizardTestedSelection(providerId: "local", modelId: "model-b")
    private let ready = SetupWizardReadiness(
        canPrepareEngine: true, microphoneGranted: true, accessibilityGranted: true)

    func testPreviouslyTestedProviderCannotCompleteAfterCredentialsOrAssetsAreRemoved() {
        let unavailable = SetupWizardReadiness(
            canPrepareEngine: false, microphoneGranted: true, accessibilityGranted: true)
        XCTAssertFalse(unavailable.canCompleteSetup)
        XCTAssertFalse(unavailable.hasSuccessfulTest(for: modelA, testedSelections: [modelA]))
    }

    func testSwitchingModelsWithinProviderRequiresThatModelsOwnTest() {
        XCTAssertTrue(ready.hasSuccessfulTest(for: modelA, testedSelections: [modelA]))
        XCTAssertFalse(ready.hasSuccessfulTest(for: modelB, testedSelections: [modelA]))
        XCTAssertTrue(ready.hasSuccessfulTest(for: modelB, testedSelections: [modelA, modelB]))
    }

    func testSameModelNameInDifferentProviderDoesNotInheritSuccess() {
        let otherProvider = SetupWizardTestedSelection(providerId: "cloud", modelId: "model-a")
        XCTAssertFalse(ready.hasSuccessfulTest(for: otherProvider, testedSelections: [modelA]))
    }

    func testSkippedMicrophonePermissionKeepsReadyTestedEngineIncomplete() {
        let missingMic = SetupWizardReadiness(
            canPrepareEngine: true, microphoneGranted: false, accessibilityGranted: true)
        XCTAssertFalse(missingMic.canCompleteSetup)
        XCTAssertFalse(missingMic.hasSuccessfulTest(for: modelA, testedSelections: [modelA]))
    }

    func testSkippedAccessibilityPermissionKeepsReadyTestedEngineIncomplete() {
        let missingAccessibility = SetupWizardReadiness(
            canPrepareEngine: true, microphoneGranted: true, accessibilityGranted: false)
        XCTAssertFalse(missingAccessibility.canCompleteSetup)
        XCTAssertFalse(missingAccessibility.hasSuccessfulTest(for: modelA, testedSelections: [modelA]))
    }

    func testRestorableModelCanFinishSetupWithoutClaimingSuccessfulTest() {
        let canPrepare = TranscriptionEngineReadiness.engineIsReadyOrRestorable(
            authAvailable: true, isConfigured: false,
            hasPersistedRestorableModel: true, hasPreparationFallback: false)
        let restorable = SetupWizardReadiness(
            canPrepareEngine: canPrepare, microphoneGranted: true, accessibilityGranted: true)
        XCTAssertTrue(restorable.canCompleteSetup)
        XCTAssertFalse(restorable.hasSuccessfulTest(for: modelA, testedSelections: []))
    }

    func testReopeningWizardPreservesExactTestedSelection() throws {
        let data = try JSONEncoder().encode([modelA])
        let restored = SetupWizardTestedSelection.decode(data)
        XCTAssertEqual(restored, [modelA])
        XCTAssertTrue(ready.hasSuccessfulTest(for: modelA, testedSelections: restored))
        XCTAssertFalse(ready.hasSuccessfulTest(for: modelB, testedSelections: restored))
    }

    func testLegacyProviderOnlyProofAndInvalidDataDoNotGrantSuccess() throws {
        let legacy = try JSONEncoder().encode(["local"])
        XCTAssertTrue(SetupWizardTestedSelection.decode(legacy).isEmpty)
        XCTAssertTrue(SetupWizardTestedSelection.decode(Data("invalid".utf8)).isEmpty)
        XCTAssertFalse(ready.hasSuccessfulTest(for: nil, testedSelections: [modelA]))
    }

    // MARK: - Associate completion with the recording's original selection

    func testSuccessfulRecordingReturnsOnlyTheSelectionUsedAtStart() {
        var signal = SetupWizardTrialSignal()
        XCTAssertNil(signal.observe(oldState: .idle, newState: .recording, selection: modelA))
        XCTAssertNil(signal.observe(oldState: .recording, newState: .processing, selection: modelA))
        XCTAssertNil(signal.observe(oldState: .processing, newState: .inserting, selection: modelA))
        XCTAssertEqual(signal.observe(oldState: .inserting, newState: .idle, selection: modelA), modelA)
        XCTAssertNil(signal.observe(oldState: .idle, newState: .inserting, selection: modelA))
        XCTAssertNil(signal.observe(oldState: .inserting, newState: .idle, selection: modelA))
    }

    func testModelSwitchDuringRecordingDoesNotCreditEitherModel() {
        var signal = SetupWizardTrialSignal()
        _ = signal.observe(oldState: .idle, newState: .recording, selection: modelA)
        _ = signal.observe(oldState: .recording, newState: .processing, selection: modelB)
        // Switching back must not revive the original attempt.
        _ = signal.observe(oldState: .processing, newState: .inserting, selection: modelA)
        XCTAssertNil(signal.observe(oldState: .inserting, newState: .idle, selection: modelA))
    }

    func testModelSwitchAfterInsertionDoesNotCreditTheNewModel() {
        var signal = SetupWizardTrialSignal()
        _ = signal.observe(oldState: .idle, newState: .recording, selection: modelA)
        _ = signal.observe(oldState: .recording, newState: .processing, selection: modelA)
        _ = signal.observe(oldState: .processing, newState: .inserting, selection: modelA)
        XCTAssertNil(signal.observe(oldState: .inserting, newState: .idle, selection: modelB))
    }

    func testCancelledOrFailedAttemptCannotCreditALaterFeedbackCycle() {
        for terminalState in [DictationViewModel.State.idle, .error("insertion failed")] {
            var signal = SetupWizardTrialSignal()
            _ = signal.observe(oldState: .idle, newState: .recording, selection: modelA)
            _ = signal.observe(oldState: .recording, newState: .processing, selection: modelA)
            XCTAssertNil(signal.observe(oldState: .processing, newState: terminalState, selection: modelA))
            _ = signal.observe(oldState: terminalState, newState: .inserting, selection: modelA)
            XCTAssertNil(signal.observe(oldState: .inserting, newState: .idle, selection: modelA))
        }
    }

    func testLeavingWizardBeforeCompletionDiscardsPendingProof() {
        var signal = SetupWizardTrialSignal()
        _ = signal.observe(oldState: .idle, newState: .recording, selection: modelA)
        _ = signal.observe(oldState: .recording, newState: .processing, selection: modelA)
        _ = signal.observe(oldState: .processing, newState: .inserting, selection: modelA)
        signal.reset()
        XCTAssertNil(signal.observe(oldState: .inserting, newState: .idle, selection: modelA))
    }

    @MainActor
    func testDeferredSetupRemainsIncompleteAtSavedStepAfterReopening() throws {
        try withHomeViewModel { makeViewModel in
            let savedStep = 2
            UserDefaults.standard.set(savedStep, forKey: UserDefaultsKeys.setupWizardCurrentStep)
            let viewModel = makeViewModel()
            viewModel.deferSetupWizard()

            XCTAssertFalse(viewModel.showSetupWizard)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted))
            XCTAssertEqual(UserDefaults.standard.integer(forKey: UserDefaultsKeys.setupWizardCurrentStep), savedStep)
            XCTAssertTrue(makeViewModel().showSetupWizard)
        }
    }

    @MainActor
    func testCompletedSetupClearsSavedStepAndStaysCompletedAfterReopening() throws {
        try withHomeViewModel { makeViewModel in
            UserDefaults.standard.set(4, forKey: UserDefaultsKeys.setupWizardCurrentStep)
            makeViewModel().completeSetupWizard()

            XCTAssertTrue(UserDefaults.standard.bool(forKey: UserDefaultsKeys.setupWizardCompleted))
            XCTAssertNil(UserDefaults.standard.object(forKey: UserDefaultsKeys.setupWizardCurrentStep))
            XCTAssertFalse(makeViewModel().showSetupWizard)
        }
    }

    @MainActor
    private func withHomeViewModel(_ body: (@MainActor () -> HomeViewModel) -> Void) throws {
        let keys = [UserDefaultsKeys.setupWizardCompleted, UserDefaultsKeys.setupWizardCurrentStep]
        let previousValues = keys.map { UserDefaults.standard.object(forKey: $0) }
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "SetupWizardProgress")
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
            TestSupport.remove(directory)
        }
        UserDefaults.standard.set(false, forKey: UserDefaultsKeys.setupWizardCompleted)
        let history = HistoryService(appSupportDirectory: directory)
        let usage = UsageStatisticsService(appSupportDirectory: directory)
        body { HomeViewModel(historyService: history, usageStatisticsService: usage) }
    }
}
