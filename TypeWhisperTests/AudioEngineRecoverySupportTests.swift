import AudioToolbox
import AVFoundation
import XCTest
@testable import TypeWhisper

private final class TestClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

final class AudioEngineRecoverySupportTests: XCTestCase {
    func testRetryableErrorClassification_matchesKnownAudioUnitCodes() {
        let formatError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        let invalidElementError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement))
        let permissionError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Unauthorized))

        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: formatError))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: invalidElementError))
        XCTAssertFalse(AudioEngineRecoveryPolicy.isRetryable(error: permissionError))
    }

    func testRetryableErrorClassification_matchesObjCExceptionAndFormatMismatchDomains() {
        let avfException = NSError(
            domain: AudioEngineRecoveryErrorDomains.avfException,
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "required condition is false"]
        )
        let transientFormatMismatch = NSError(
            domain: AudioEngineRecoveryErrorDomains.transientFormatMismatch,
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Format mismatch before installTap"]
        )

        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: avfException))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: transientFormatMismatch))
    }

    func testRetryableErrorClassification_matchesKnownLogMessages() {
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "Failed to create tap, config change pending!", osStatus: nil))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "Format mismatch: input hw 24000 Hz, client format 48000 Hz", osStatus: nil))
        XCTAssertFalse(AudioEngineRecoveryPolicy.isRetryable(detail: "Microphone permission denied", osStatus: nil))
    }

    func testObjCExceptionCatcher_convertsNSExceptionIntoNSError() {
        XCTAssertThrowsError(try ObjCExceptionCatcher.catching {
            _ = NSArray().object(at: 1)
        }) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, AudioEngineRecoveryErrorDomains.avfException)
            XCTAssertEqual(nsError.userInfo[AudioEngineRecoveryErrorUserInfoKeys.exceptionName] as? String, NSExceptionName.rangeException.rawValue)
            XCTAssertFalse(nsError.localizedDescription.isEmpty)
        }
    }

    func testConfigurationChangeDuringStart_triggersImmediateRecoveryOnceStartSucceeds() {
        let coordinator = AudioEngineRecoveryCoordinator()

        coordinator.beginStarting()
        XCTAssertEqual(coordinator.noteConfigurationChange(), .none)
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .performImmediateRecovery)
        XCTAssertEqual(coordinator.finishRecovery(), .none)
    }

    func testConfigurationChangeWithinQuiescenceWindow_preservesStartupRecoveryPath() {
        let clock = TestClock()
        let coordinator = AudioEngineRecoveryCoordinator(now: { clock.now })

        coordinator.beginStarting()
        coordinator.noteEngineStarted()
        clock.now += 0.1

        XCTAssertEqual(coordinator.noteConfigurationChange(), .none)
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .performImmediateRecovery)
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

    func testSelfTriggeredConfigurationChangeWithinQuiescenceWindow_isDeferredWhileRunning() {
        let clock = TestClock()
        let coordinator = AudioEngineRecoveryCoordinator(now: { clock.now })

        coordinator.beginStarting()
        coordinator.noteEngineStarted()
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .none)

        clock.now += 0.1
        guard case .schedule(_, let delay) = coordinator.noteConfigurationChange() else {
            return XCTFail("Expected deferred recovery schedule")
        }

        XCTAssertEqual(delay, AudioEngineRecoveryPolicy.configurationChangeQuiescence - 0.1, accuracy: 0.0001)
    }

    func testSelfTriggeredConfigurationChangeWithinQuiescenceWindow_isDeferredDuringScheduledRecovery() {
        let clock = TestClock()
        let coordinator = AudioEngineRecoveryCoordinator(now: { clock.now })

        coordinator.beginStarting()
        coordinator.noteEngineStarted()
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .none)

        clock.now = 1
        guard case .schedule(let generation, _) = coordinator.noteConfigurationChange() else {
            return XCTFail("Expected scheduled recovery")
        }

        XCTAssertTrue(coordinator.beginScheduledRecovery(generation: generation))

        coordinator.noteEngineStarted()
        clock.now += 0.1
        XCTAssertEqual(coordinator.noteConfigurationChange(), .none)
        guard case .schedule(_, let delay) = coordinator.finishRecovery() else {
            return XCTFail("Expected deferred follow-up recovery")
        }
        XCTAssertEqual(delay, AudioEngineRecoveryPolicy.configurationChangeQuiescence - 0.1, accuracy: 0.0001)
    }

    func testRecoveryCoordinator_stopsAfterRestartLoopThreshold() {
        let clock = TestClock()
        let coordinator = AudioEngineRecoveryCoordinator(now: { clock.now })

        coordinator.beginStarting()
        coordinator.noteEngineStarted()
        XCTAssertEqual(coordinator.finishStartingSuccessfully(), .none)
        clock.now += AudioEngineRecoveryPolicy.configurationChangeQuiescence + 0.1

        for attempt in 0..<(AudioEngineRecoveryPolicy.configurationChangeBurstLimit - 1) {
            guard case .schedule(let generation, let delay) = coordinator.noteConfigurationChange() else {
                return XCTFail("Expected scheduled recovery for attempt \(attempt + 1)")
            }
            XCTAssertEqual(delay, AudioEngineRecoveryPolicy.configurationDebounce)
            XCTAssertTrue(coordinator.beginScheduledRecovery(generation: generation))
            XCTAssertEqual(coordinator.finishRecovery(), .none)

            clock.now += 0.2
        }

        XCTAssertEqual(coordinator.noteConfigurationChange(), .fail(.configurationChangeBurstLimitExceeded))
    }

    func testTransientFormatMismatchError_describesMismatch() throws {
        let expected = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let current = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 0, interleaved: false))

        let error = AudioRecordingService.makeTransientFormatMismatchError(expected: expected, current: current)

        XCTAssertEqual(error.domain, AudioEngineRecoveryErrorDomains.transientFormatMismatch)
        XCTAssertTrue(error.localizedDescription.contains("expected 48000.0 Hz/1 ch"))
        XCTAssertTrue(error.localizedDescription.contains("got 0.0 Hz/0 ch"))
    }
}

final class AudioDeviceServiceCompatibilityTests: XCTestCase {
    private var originalSelectedDeviceUID: Any?

    override func setUp() {
        super.setUp()
        originalSelectedDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
    }

    override func tearDown() {
        if let originalSelectedDeviceUID {
            UserDefaults.standard.set(originalSelectedDeviceUID, forKey: UserDefaultsKeys.selectedInputDeviceUID)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        }
        super.tearDown()
    }

    func testStartPreview_selectedIncompatibleDeviceDoesNotActivatePreview() {
        UserDefaults.standard.set("display-mic", forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let device = AudioInputDevice(
            deviceID: AudioDeviceID(42),
            name: "LG Ultrafine",
            uid: "display-mic",
            compatibility: .incompatible(.cannotSetDevice)
        )
        let service = AudioDeviceService(
            initialInputDevices: [device],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        service.hasMicrophonePermissionOverride = true
        service.audioDeviceIDResolverOverride = { uid in
            XCTAssertEqual(uid, "display-mic")
            return AudioDeviceID(42)
        }

        service.startPreview()

        XCTAssertFalse(service.isPreviewActive)
        XCTAssertEqual(service.previewError, .incompatible(.cannotSetDevice))
    }

    func testSelectingIncompatibleDeviceRevertsToPreviousSelection() {
        UserDefaults.standard.set("built-in", forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let devices = [
            AudioInputDevice(deviceID: AudioDeviceID(1), name: "MacBook Pro Mic", uid: "built-in"),
            AudioInputDevice(deviceID: AudioDeviceID(42), name: "LG Ultrafine", uid: "display-mic")
        ]
        let service = AudioDeviceService(
            initialInputDevices: devices,
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        service.audioDeviceIDResolverOverride = { uid in
            switch uid {
            case "built-in": return AudioDeviceID(1)
            case "display-mic": return AudioDeviceID(42)
            default: return nil
            }
        }
        service.selectionValidationOverride = { deviceID in
            XCTAssertEqual(deviceID, AudioDeviceID(42))
            throw SelectedInputDeviceError.incompatible(.cannotSetDevice)
        }

        service.selectedDeviceUID = "display-mic"

        XCTAssertEqual(service.selectedDeviceUID, "built-in")
        XCTAssertEqual(service.previewError, .incompatible(.cannotSetDevice))
        let attemptedDevice = service.inputDevices.first(where: { $0.uid == "display-mic" })
        XCTAssertEqual(attemptedDevice?.compatibility, .incompatible(.cannotSetDevice))
    }

    func testDisplayName_marksIncompatibleDevicesWithoutRemovingThem() {
        let device = AudioInputDevice(
            deviceID: AudioDeviceID(42),
            name: "LG Ultrafine",
            uid: "display-mic",
            compatibility: .incompatible(.engineStartFailed)
        )
        let service = AudioDeviceService(
            initialInputDevices: [device],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )

        XCTAssertEqual(service.inputDevices.count, 1)
        XCTAssertEqual(
            service.displayName(for: device),
            "LG Ultrafine (\(AudioInputDeviceCompatibilityIssue.engineStartFailed.badgeText))"
        )
    }

    func testSavedSelectedIncompatibleDeviceRemainsSelected() {
        UserDefaults.standard.set("display-mic", forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let device = AudioInputDevice(
            deviceID: AudioDeviceID(42),
            name: "LG Ultrafine",
            uid: "display-mic",
            compatibility: .incompatible(.invalidInputFormat)
        )
        let service = AudioDeviceService(
            initialInputDevices: [device],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )

        XCTAssertEqual(service.selectedDeviceUID, "display-mic")
        XCTAssertEqual(service.selectedDevice?.uid, "display-mic")
        XCTAssertNotNil(service.selectedDeviceStatusMessage)
    }

    func testPreviewRecoveryEngineSwap_replacesStoredEngineInstance() {
        let service = AudioDeviceService(
            initialInputDevices: [],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        let originalEngine = AVAudioEngine()

        service.testingSetPreviewEngine(originalEngine, activeDeviceID: AudioDeviceID(42))
        let replacementEngine = service.testingReplacePreviewEngineForRecoveryIfNeeded(originalEngine)

        XCTAssertNotNil(replacementEngine)
        XCTAssertTrue(service.testingCurrentPreviewEngine() === replacementEngine)
        XCTAssertFalse(service.testingCurrentPreviewEngine() === originalEngine)
        XCTAssertEqual(service.testingCurrentPreviewDeviceID(), AudioDeviceID(42))
    }

    func testPreviewTapPreconditions_throwRetryableMismatchWhenFormatChangesImmediately() throws {
        let service = AudioDeviceService(
            initialInputDevices: [],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )
        let expected = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let current = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))

        XCTAssertThrowsError(try service.testingValidatePreviewTapInstallationPreconditions(expected: expected, current: current)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, AudioEngineRecoveryErrorDomains.transientFormatMismatch)
            XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: nsError))
        }
    }
}

final class AudioRecordingServiceSelectedDeviceTests: XCTestCase {
    func testStartRecording_selectedUnavailableDeviceThrowsTypedError() {
        let service = AudioRecordingService()
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = nil

        XCTAssertThrowsError(try service.startRecording()) { error in
            guard case AudioRecordingService.AudioRecordingError.selectedInputDeviceUnavailable = error else {
                return XCTFail("Expected selectedInputDeviceUnavailable, got \(error)")
            }
        }
    }

    func testStartRecording_explicitIncompatibleDeviceDoesNotFallbackToDefault() {
        let service = AudioRecordingService()
        var didReachStartOverride = false

        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = AudioDeviceID(42)
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, AudioDeviceID(42))
            return true
        }
        service.startRecordingOverride = {
            didReachStartOverride = true
            throw AudioRecordingService.AudioRecordingError.selectedInputDeviceIncompatible(.cannotSetDevice)
        }

        XCTAssertThrowsError(try service.startRecording()) { error in
            guard case AudioRecordingService.AudioRecordingError.selectedInputDeviceIncompatible(.cannotSetDevice) = error else {
                return XCTFail("Expected selectedInputDeviceIncompatible(.cannotSetDevice), got \(error)")
            }
        }
        XCTAssertTrue(didReachStartOverride)
        XCTAssertFalse(service.isRecording)
    }

    func testStartRecording_withoutExplicitSelectionStillAllowsDefaultInput() {
        let service = AudioRecordingService()
        var didReachStartOverride = false

        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = false
        service.selectedDeviceID = nil
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertNil(selectedDeviceID)
            return true
        }
        service.startRecordingOverride = {
            didReachStartOverride = true
        }

        XCTAssertNoThrow(try service.startRecording())
        XCTAssertTrue(didReachStartOverride)
        XCTAssertTrue(service.isRecording)
    }

    func testRecoveryEngineSwap_replacesStoredEngineInstance() {
        let service = AudioRecordingService()
        let originalEngine = AVAudioEngine()

        service.testingSetAudioEngine(originalEngine)
        let replacementEngine = service.testingReplaceAudioEngineForRecoveryIfNeeded(originalEngine)

        XCTAssertNotNil(replacementEngine)
        XCTAssertTrue(service.testingCurrentAudioEngine() === replacementEngine)
        XCTAssertFalse(service.testingCurrentAudioEngine() === originalEngine)
    }

    func testTapPreconditions_throwRetryableMismatchWhenFormatChangesImmediately() throws {
        let service = AudioRecordingService()
        let expected = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let current = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))

        XCTAssertThrowsError(try service.testingValidateTapInstallationPreconditions(expected: expected, current: current)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, AudioEngineRecoveryErrorDomains.transientFormatMismatch)
            XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: nsError))
        }
    }

    func testStartupConfigurationChangeGuard_ignoresOnlyFirstMatchingChangeForSameEngine() throws {
        let service = AudioRecordingService()
        let engine = AVAudioEngine()
        let matchingFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))

        service.testingArmStartupConfigurationChangeGuard(for: engine, expectedTapFormat: matchingFormat)

        XCTAssertTrue(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: matchingFormat))
        XCTAssertFalse(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: matchingFormat))
    }

    func testStartupConfigurationChangeGuard_doesNotIgnoreMatchingFormatOnDifferentEngine() throws {
        let service = AudioRecordingService()
        let expectedEngine = AVAudioEngine()
        let otherEngine = AVAudioEngine()
        let matchingFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))

        service.testingArmStartupConfigurationChangeGuard(for: expectedEngine, expectedTapFormat: matchingFormat)

        XCTAssertFalse(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: otherEngine, liveFormat: matchingFormat))
        XCTAssertTrue(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: expectedEngine, liveFormat: matchingFormat))
    }

    func testStartupConfigurationChangeGuard_doesNotIgnoreMatchingFormatWithoutPendingState() throws {
        let service = AudioRecordingService()
        let engine = AVAudioEngine()
        let matchingFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))

        XCTAssertFalse(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: matchingFormat))
    }

    func testStartupConfigurationChangeGuard_mismatchDoesNotIgnoreAndConsumesSingleUseState() throws {
        let service = AudioRecordingService()
        let engine = AVAudioEngine()
        let expectedFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let mismatchedFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))

        service.testingArmStartupConfigurationChangeGuard(for: engine, expectedTapFormat: expectedFormat)

        XCTAssertFalse(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: mismatchedFormat))
        XCTAssertFalse(service.testingConsumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: expectedFormat))
    }
}

final class AudioOutputVolumeGuardTests: XCTestCase {
    func testRestoreIfRaisedRestoresCurrentOutputToCapturedUserVolume() {
        let controller = FakeAudioOutputVolumeController(
            defaultDeviceID: AudioDeviceID(1),
            snapshots: [
                AudioDeviceID(1): AudioOutputVolumeSnapshot(
                    deviceID: AudioDeviceID(1),
                    deviceUID: "airpods-output",
                    deviceName: "AirPods Pro",
                    volume: 0.10
                )
            ]
        )
        let guardService = AudioOutputVolumeGuard(volumeController: controller)

        guardService.captureBaseline()
        controller.updateVolume(0.42, for: AudioDeviceID(1))
        guardService.restoreIfRaised(reason: "test")

        XCTAssertEqual(controller.setCalls, [
            .init(deviceID: AudioDeviceID(1), volume: 0.10)
        ])
    }

    func testRestoreIfRaisedDoesNotIncreaseLowerCurrentVolume() {
        let controller = FakeAudioOutputVolumeController(
            defaultDeviceID: AudioDeviceID(1),
            snapshots: [
                AudioDeviceID(1): AudioOutputVolumeSnapshot(
                    deviceID: AudioDeviceID(1),
                    deviceUID: "speakers",
                    deviceName: "Speakers",
                    volume: 0.50
                )
            ]
        )
        let guardService = AudioOutputVolumeGuard(volumeController: controller)

        guardService.captureBaseline()
        controller.updateVolume(0.20, for: AudioDeviceID(1))
        guardService.restoreIfRaised(reason: "test")

        XCTAssertTrue(controller.setCalls.isEmpty)
    }

    func testRestoreIfRaisedTargetsCurrentDefaultOutputAfterDeviceSwitch() {
        let controller = FakeAudioOutputVolumeController(
            defaultDeviceID: AudioDeviceID(1),
            snapshots: [
                AudioDeviceID(1): AudioOutputVolumeSnapshot(
                    deviceID: AudioDeviceID(1),
                    deviceUID: "airpods-output",
                    deviceName: "AirPods Pro",
                    volume: 0.12
                ),
                AudioDeviceID(2): AudioOutputVolumeSnapshot(
                    deviceID: AudioDeviceID(2),
                    deviceUID: "built-in-output",
                    deviceName: "MacBook Pro Speakers",
                    volume: 0.46
                )
            ]
        )
        let guardService = AudioOutputVolumeGuard(volumeController: controller)

        guardService.captureBaseline()
        controller.defaultDeviceID = AudioDeviceID(2)
        guardService.restoreIfRaised(reason: "test")

        XCTAssertEqual(controller.setCalls, [
            .init(deviceID: AudioDeviceID(2), volume: 0.12)
        ])
    }

    func testClearPreventsLaterVolumeWrites() {
        let controller = FakeAudioOutputVolumeController(
            defaultDeviceID: AudioDeviceID(1),
            snapshots: [
                AudioDeviceID(1): AudioOutputVolumeSnapshot(
                    deviceID: AudioDeviceID(1),
                    deviceUID: "airpods-output",
                    deviceName: "AirPods Pro",
                    volume: 0.10
                )
            ]
        )
        let guardService = AudioOutputVolumeGuard(volumeController: controller)

        guardService.captureBaseline()
        guardService.clear()
        controller.updateVolume(0.40, for: AudioDeviceID(1))
        guardService.restoreIfRaised(reason: "test")

        XCTAssertTrue(controller.setCalls.isEmpty)
    }
}

final class AudioOutputVolumeIntegrationTests: XCTestCase {
    func testStartRecordingRestoresOutputVolumeRaisedDuringAudioStart() {
        let controller = FakeAudioOutputVolumeController.airPods(volume: 0.10)
        let guardService = AudioOutputVolumeGuard(volumeController: controller)
        let service = AudioRecordingService(outputVolumeGuard: guardService)
        service.hasMicrophonePermissionOverride = true
        service.inputAvailabilityOverride = { _ in true }
        service.startRecordingOverride = {
            controller.updateVolume(0.40, for: AudioDeviceID(1))
        }

        XCTAssertNoThrow(try service.startRecording())

        XCTAssertEqual(controller.setCalls, [
            .init(deviceID: AudioDeviceID(1), volume: 0.10)
        ])
    }

    func testStopRecordingRestoresRaisedOutputVolumeAndClearsGuard() async {
        let controller = FakeAudioOutputVolumeController.airPods(volume: 0.10)
        let guardService = AudioOutputVolumeGuard(volumeController: controller)
        let service = AudioRecordingService(outputVolumeGuard: guardService)
        service.hasMicrophonePermissionOverride = true
        service.inputAvailabilityOverride = { _ in true }
        service.startRecordingOverride = {}
        service.stopRecordingOverride = { _ in
            controller.updateVolume(0.70, for: AudioDeviceID(1))
            return []
        }

        XCTAssertNoThrow(try service.startRecording())
        controller.updateVolume(0.45, for: AudioDeviceID(1))
        _ = await service.stopRecording(policy: .immediate)

        XCTAssertEqual(controller.setCalls, [
            .init(deviceID: AudioDeviceID(1), volume: 0.45)
        ])
    }

    @MainActor
    func testStartPreviewRestoresOutputVolumeRaisedDuringPreviewStart() {
        let controller = FakeAudioOutputVolumeController.airPods(volume: 0.10)
        let guardService = AudioOutputVolumeGuard(volumeController: controller)
        let service = AudioDeviceService(
            initialInputDevices: [],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            outputVolumeGuard: guardService
        )
        service.hasMicrophonePermissionOverride = true
        service.startPreviewOverride = { _ in
            controller.updateVolume(0.40, for: AudioDeviceID(1))
        }

        service.startPreview()

        XCTAssertEqual(controller.setCalls, [
            .init(deviceID: AudioDeviceID(1), volume: 0.10)
        ])
    }

    @MainActor
    func testAudioDuckingUsesCurrentOutputVolumeAsBaseline() {
        let controller = FakeAudioOutputVolumeController.airPods(volume: 0.10)
        let service = AudioDuckingService(volumeController: controller)

        service.duckAudio(to: 0.20)
        service.restoreAudio()

        XCTAssertEqual(controller.setCalls.count, 2)
        XCTAssertEqual(controller.setCalls[0].deviceID, AudioDeviceID(1))
        XCTAssertEqual(controller.setCalls[0].volume, 0.02, accuracy: 0.0001)
        XCTAssertEqual(controller.setCalls[1], .init(deviceID: AudioDeviceID(1), volume: 0.10))
    }
}

private final class FakeAudioOutputVolumeController: AudioOutputVolumeControlling {
    struct SetCall: Equatable {
        let deviceID: AudioDeviceID
        let volume: Float
    }

    var defaultDeviceID: AudioDeviceID?
    private var snapshots: [AudioDeviceID: AudioOutputVolumeSnapshot]
    private(set) var setCalls: [SetCall] = []

    init(defaultDeviceID: AudioDeviceID?, snapshots: [AudioDeviceID: AudioOutputVolumeSnapshot]) {
        self.defaultDeviceID = defaultDeviceID
        self.snapshots = snapshots
    }

    static func airPods(volume: Float) -> FakeAudioOutputVolumeController {
        FakeAudioOutputVolumeController(
            defaultDeviceID: AudioDeviceID(1),
            snapshots: [
                AudioDeviceID(1): AudioOutputVolumeSnapshot(
                    deviceID: AudioDeviceID(1),
                    deviceUID: "airpods-output",
                    deviceName: "AirPods Pro",
                    volume: volume
                )
            ]
        )
    }

    func defaultOutputSnapshot() -> AudioOutputVolumeSnapshot? {
        guard let defaultDeviceID else { return nil }
        return snapshots[defaultDeviceID]
    }

    func setVolume(_ volume: Float, for deviceID: AudioDeviceID) -> Bool {
        setCalls.append(.init(deviceID: deviceID, volume: volume))
        updateVolume(volume, for: deviceID)
        return true
    }

    func updateVolume(_ volume: Float, for deviceID: AudioDeviceID) {
        guard let snapshot = snapshots[deviceID] else { return }
        snapshots[deviceID] = AudioOutputVolumeSnapshot(
            deviceID: snapshot.deviceID,
            deviceUID: snapshot.deviceUID,
            deviceName: snapshot.deviceName,
            volume: volume
        )
    }
}
