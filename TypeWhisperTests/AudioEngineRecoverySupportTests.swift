import AudioToolbox
import XCTest
@testable import TypeWhisper

final class AudioEngineRecoverySupportTests: XCTestCase {
    func testRetryableErrorClassification_matchesKnownAudioUnitCodes() {
        let formatError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        let invalidElementError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement))
        let temporarilyUnavailableError = NSError(domain: NSOSStatusErrorDomain, code: 35)
        let permissionError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Unauthorized))

        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: formatError))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: invalidElementError))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: temporarilyUnavailableError))
        XCTAssertFalse(AudioEngineRecoveryPolicy.isRetryable(error: permissionError))
    }

    func testRetryableErrorClassification_matchesKnownLogMessages() {
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "Failed to create tap, config change pending!", osStatus: nil))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "Format mismatch: input hw 24000 Hz, client format 48000 Hz", osStatus: nil))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "StartIO failed with error 35", osStatus: nil))
        XCTAssertFalse(AudioEngineRecoveryPolicy.isRetryable(detail: "Microphone permission denied", osStatus: nil))
    }

    func testConfigurationChangeDuringStart_triggersImmediateRecoveryOnceStartSucceeds() {
        let coordinator = AudioEngineRecoveryCoordinator()

        coordinator.beginStarting()
        XCTAssertEqual(coordinator.noteConfigurationChange(), .none)
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .performImmediateRecovery)
        XCTAssertEqual(coordinator.finishRecovery(), .none)
    }

    func testMultipleConfigurationChanges_coalesceToLatestScheduledGeneration() {
        let coordinator = AudioEngineRecoveryCoordinator()

        coordinator.beginStarting()
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .none)

        guard case .schedule(let firstGeneration, let firstDelay) = coordinator.noteConfigurationChange() else {
            return XCTFail("Expected first configuration change to schedule recovery")
        }
        guard case .schedule(let secondGeneration, let secondDelay) = coordinator.noteConfigurationChange() else {
            return XCTFail("Expected second configuration change to reschedule recovery")
        }

        XCTAssertEqual(firstDelay, AudioEngineRecoveryPolicy.configurationDebounce)
        XCTAssertEqual(secondDelay, AudioEngineRecoveryPolicy.configurationDebounce)
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertFalse(coordinator.beginScheduledRecovery(generation: firstGeneration))
        XCTAssertTrue(coordinator.beginScheduledRecovery(generation: secondGeneration))
        XCTAssertEqual(coordinator.finishRecovery(), .none)
    }

    func testConfigurationChangeDuringRecovery_schedulesOneFollowUpPass() {
        let coordinator = AudioEngineRecoveryCoordinator()

        coordinator.beginStarting()
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .none)

        guard case .schedule(let generation, _) = coordinator.noteConfigurationChange() else {
            return XCTFail("Expected scheduled recovery")
        }
        XCTAssertTrue(coordinator.beginScheduledRecovery(generation: generation))
        XCTAssertEqual(coordinator.noteConfigurationChange(), .none)

        guard case .schedule(let followUpGeneration, let delay) = coordinator.finishRecovery() else {
            return XCTFail("Expected follow-up recovery after a new pending change")
        }

        XCTAssertNotEqual(generation, followUpGeneration)
        XCTAssertEqual(delay, AudioEngineRecoveryPolicy.configurationDebounce)
    }
}
