import AudioToolbox
import XCTest
@testable import TypeWhisper

final class AudioEngineRecoverySupportTests: XCTestCase {
    func testRetryableErrorClassification_matchesKnownAudioUnitCodes() {
        let formatError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        let invalidElementError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidElement))
        let permissionError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_Unauthorized))

        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: formatError))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: invalidElementError))
        XCTAssertFalse(AudioEngineRecoveryPolicy.isRetryable(error: permissionError))
    }

    func testRetryableErrorClassification_matchesKnownLogMessages() {
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "Failed to create tap, config change pending!", osStatus: nil))
        XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(detail: "Format mismatch: input hw 24000 Hz, client format 48000 Hz", osStatus: nil))
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
}
