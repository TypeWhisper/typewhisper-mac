import AudioToolbox
import AVFoundation
import XCTest
@testable import TypeWhisper

private final class TestClock: @unchecked Sendable {
    var now: TimeInterval = 0
}

private func makeMonoBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    ))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channel = buffer.floatChannelData?[0] else {
        throw NSError(domain: "AudioEngineRecoverySupportTests", code: 0)
    }
    for (index, sample) in samples.enumerated() {
        channel[index] = sample
    }
    return buffer
}

final class AudioEngineRecoverySupportTests: XCTestCase {
    func testAudioLevelMeterKeepsSilenceAtZero() {
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: 0), 0)
        XCTAssertEqual(AudioLevelMeter.normalizedLevel(rms: -0.1), 0)
    }

    func testAudioLevelMeterMapsLowBluetoothLikeSpeechToVisibleRange() {
        let level = AudioLevelMeter.normalizedLevel(rms: 0.05)

        XCTAssertGreaterThan(level, 0.65)
        XCTAssertLessThan(level, 0.9)
    }

    func testAudioInputSignalRejectsZeroFilledBluetoothTapBuffer() throws {
        let buffer = try makeMonoBuffer(samples: [0, 0, 0, 0])

        XCTAssertFalse(AudioInputSignal.containsSignal(buffer))
    }

    func testAudioInputSignalAcceptsNonSilentBluetoothTapBuffer() throws {
        let buffer = try makeMonoBuffer(samples: [0, 0.002, 0, -0.001])

        XCTAssertTrue(AudioInputSignal.containsSignal(buffer))
    }

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

    func testEngineInputRouteUsesDefaultAggregateForBluetoothSelection() {
        XCTAssertNil(AudioEngineInputRoute.preferredDeviceIDForEngine(
            selectedDeviceID: AudioDeviceID(112),
            usesBluetoothTransport: true
        ))
    }

    func testEngineInputRouteKeepsExplicitDeviceForNonBluetoothSelection() {
        XCTAssertEqual(
            AudioEngineInputRoute.preferredDeviceIDForEngine(
                selectedDeviceID: AudioDeviceID(410),
                usesBluetoothTransport: false
            ),
            AudioDeviceID(410)
        )
    }

    func testInputFormatStabilizerRejectsStaleDefaultFormatAfterBluetoothDeviceSwitch() {
        let staleDefaultFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let bluetoothHardwareFormat = AudioInputHardwareFormat(sampleRate: 24_000, channelCount: 1)

        XCTAssertFalse(AudioInputFormatStabilizer.isSettled(
            staleDefaultFormat,
            expectedHardwareFormat: bluetoothHardwareFormat
        ))
    }

    func testInputFormatStabilizerWaitsUntilFormatMatchesSelectedDeviceHardware() throws {
        let staleDefaultFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let bluetoothFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let bluetoothHardwareFormat = AudioInputHardwareFormat(sampleRate: 24_000, channelCount: 1)
        var formats = [staleDefaultFormat, staleDefaultFormat, bluetoothFormat]
        var now: TimeInterval = 0

        let settled = try AudioInputFormatStabilizer.waitForSettledFormat(
            label: "test",
            expectedHardwareFormat: bluetoothHardwareFormat,
            timeout: 0.1,
            pollInterval: 0.01,
            now: { now },
            readFormat: { formats.removeFirst() },
            sleep: { now += $0 }
        )

        XCTAssertEqual(settled.sampleRate, 24_000)
        XCTAssertEqual(settled.channelCount, 1)
        XCTAssertEqual(formats.count, 0)
    }

    func testInputFormatStabilizerThrowsRetryableMismatchWhenFormatDoesNotSettle() {
        let staleDefaultFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let bluetoothHardwareFormat = AudioInputHardwareFormat(sampleRate: 24_000, channelCount: 1)
        var now: TimeInterval = 0

        XCTAssertThrowsError(try AudioInputFormatStabilizer.waitForSettledFormat(
            label: "test",
            expectedHardwareFormat: bluetoothHardwareFormat,
            timeout: 0.02,
            pollInterval: 0.01,
            now: { now },
            readFormat: { staleDefaultFormat },
            sleep: { now += $0 }
        )) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, AudioEngineRecoveryErrorDomains.transientFormatMismatch)
            XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: error))
        }
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

    func testSelectingBluetoothDeviceValidatesThroughInputOnlyAggregateRoute() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let bluetoothDeviceID = AudioDeviceID(710)
        var events: [String] = []
        let inputActivationGuard = FakeAudioInputDeviceActivator { call in
            events.append("input:\(call.reason):\(call.deviceID)")
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: bluetoothDeviceID, name: "AirPods Max", uid: "airpods-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            inputActivationGuard: inputActivationGuard
        )

        service.audioDeviceIDResolverOverride = { uid in
            uid == "airpods-input" ? bluetoothDeviceID : nil
        }
        service.transportTypeResolverOverride = { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
            return kAudioDeviceTransportTypeBluetooth
        }
        service.bluetoothRouteStabilizationOverride = { inputDeviceID, outputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, bluetoothDeviceID)
            XCTAssertNil(outputDeviceID)
            XCTAssertEqual(reason, "selection-validation")
            events.append("stabilize:selection-validation")
        }
        service.selectionEngineValidationOverride = { preferredDeviceID in
            XCTAssertNil(preferredDeviceID)
            events.append("validate:aggregate")
        }

        service.selectedDeviceUID = "airpods-input"

        XCTAssertEqual(service.selectedDeviceUID, "airpods-input")
        XCTAssertNil(service.previewError)
        XCTAssertEqual(events, [
            "input:selection-validation:\(bluetoothDeviceID)",
            "stabilize:selection-validation",
            "validate:aggregate"
        ])
        XCTAssertEqual(inputActivationGuard.restoreCalls, ["selection-validation"])
        XCTAssertEqual(service.selectedDeviceCompatibility, .compatible)
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

    func testBluetoothPreviewConfigurationChangesAreSuppressedDuringRouteSettleWindow() {
        let service = AudioDeviceService(
            initialInputDevices: [],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )

        service.testingSetPreviewEngine(
            nil,
            activeDeviceID: AudioDeviceID(42),
            usesBluetoothTransport: true
        )
        service.testingBeginBluetoothPreviewConfigurationChangeIgnoreWindow(now: 10)

        XCTAssertTrue(service.testingShouldSuppressBluetoothPreviewConfigurationChange(now: 12.9))
        XCTAssertFalse(service.testingShouldSuppressBluetoothPreviewConfigurationChange(now: 13.1))
    }

    func testNonBluetoothPreviewConfigurationChangesAreNotSuppressed() {
        let service = AudioDeviceService(
            initialInputDevices: [],
            monitorDeviceChanges: false,
            probeCompatibilities: false
        )

        service.testingSetPreviewEngine(
            nil,
            activeDeviceID: AudioDeviceID(43),
            usesBluetoothTransport: false
        )
        service.testingBeginBluetoothPreviewConfigurationChangeIgnoreWindow(now: 10)

        XCTAssertFalse(service.testingShouldSuppressBluetoothPreviewConfigurationChange(now: 11))
    }

    @MainActor
    func testStartPreviewPinsBluetoothInputAsDefaultWithoutChangingOutputAndUsesAggregateEngineRouteUntilPreviewStops() {
        let bluetoothDeviceID = AudioDeviceID(710)
        let inputActivationGuard = FakeAudioInputDeviceActivator()
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: bluetoothDeviceID, name: "AirPods Max", uid: "airpods-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            inputActivationGuard: inputActivationGuard
        )

        service.hasMicrophonePermissionOverride = true
        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "airpods-input" ? bluetoothDeviceID : nil
        }
        service.transportTypeResolverOverride = { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
            return kAudioDeviceTransportTypeBluetooth
        }
        service.selectedDeviceUID = "airpods-input"
        service.bluetoothRouteStabilizationOverride = { inputDeviceID, outputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, bluetoothDeviceID)
            XCTAssertNil(outputDeviceID)
            XCTAssertEqual(reason, "preview-start")
        }
        service.startPreviewOverride = { preferredDeviceID in
            XCTAssertNil(preferredDeviceID)
        }

        service.startPreview()

        XCTAssertEqual(inputActivationGuard.activateCalls, [
            .init(deviceID: bluetoothDeviceID, reason: "preview-start")
        ])
        XCTAssertTrue(inputActivationGuard.restoreCalls.isEmpty)
        XCTAssertTrue(service.isPreviewActive)

        service.stopPreview()

        XCTAssertEqual(inputActivationGuard.restoreCalls, ["preview-stop"])
    }

    @MainActor
    func testStartPreviewKeepsExplicitEngineRouteForUSBInput() {
        let usbDeviceID = AudioDeviceID(711)
        let inputActivationGuard = FakeAudioInputDeviceActivator()
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            inputActivationGuard: inputActivationGuard
        )

        service.hasMicrophonePermissionOverride = true
        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }
        service.transportTypeResolverOverride = { deviceID in
            XCTAssertEqual(deviceID, usbDeviceID)
            return kAudioDeviceTransportTypeUSB
        }
        service.selectedDeviceUID = "usb-input"
        service.startPreviewOverride = { preferredDeviceID in
            XCTAssertEqual(preferredDeviceID, usbDeviceID)
        }

        service.startPreview()

        XCTAssertTrue(inputActivationGuard.activateCalls.isEmpty)
        XCTAssertTrue(service.isPreviewActive)

        service.stopPreview()
    }
}

final class AudioRecordingServiceSelectedDeviceTests: XCTestCase {
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

    func testStartRecordingActivatesBluetoothInputWithoutChangingOutputAndRestoresInputOnStop() async {
        var routeEvents: [String] = []
        let inputActivationGuard = FakeAudioInputDeviceActivator { call in
            routeEvents.append("input:\(call.reason)")
        }
        let service = AudioRecordingService(
            inputActivationGuard: inputActivationGuard
        )
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = AudioDeviceID(42)
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, AudioDeviceID(42))
            return true
        }
        service.bluetoothRouteStabilizationOverride = { inputDeviceID, outputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, AudioDeviceID(42))
            XCTAssertNil(outputDeviceID)
            XCTAssertEqual(reason, "recording-start")
            routeEvents.append("stabilize:\(reason)")
        }
        service.startRecordingOverride = {}
        service.stopRecordingOverride = { _ in [] }

        XCTAssertNoThrow(try service.startRecording())
        _ = await service.stopRecording(policy: .immediate)

        XCTAssertEqual(routeEvents, [
            "input:recording-start",
            "stabilize:recording-start"
        ])
        XCTAssertEqual(inputActivationGuard.activateCalls, [
            .init(deviceID: AudioDeviceID(42), reason: "recording-start")
        ])
        XCTAssertEqual(inputActivationGuard.restoreCalls, ["recording-stop-override"])
    }

    func testSelectedDeviceUsesBluetoothTransport_resolvesTransportFromSelectedUID() {
        let bluetoothDeviceID = AudioDeviceID(700)
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: bluetoothDeviceID, name: "Jabra PRO 930", uid: "jabra-pro-930")
            ],
            monitorDeviceChanges: false
        )

        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "jabra-pro-930" ? bluetoothDeviceID : nil
        }
        service.transportTypeResolverOverride = { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
            return kAudioDeviceTransportTypeBluetoothLE
        }

        service.selectedDeviceUID = "jabra-pro-930"

        XCTAssertTrue(service.selectedDeviceUsesBluetoothTransport)
    }

    func testSelectedDeviceUsesBluetoothTransport_returnsFalseForUSBAndDefaultInput() {
        let usbDeviceID = AudioDeviceID(701)
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-mic")
            ],
            monitorDeviceChanges: false
        )

        XCTAssertFalse(service.selectedDeviceUsesBluetoothTransport)

        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "usb-mic" ? usbDeviceID : nil
        }
        service.transportTypeResolverOverride = { deviceID in
            XCTAssertEqual(deviceID, usbDeviceID)
            return kAudioDeviceTransportTypeUSB
        }

        service.selectedDeviceUID = "usb-mic"

        XCTAssertFalse(service.selectedDeviceUsesBluetoothTransport)
    }

    func testBluetoothInputReadinessProbeTimesOutWithNoInitialInput() {
        let service = AudioRecordingService()
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputReadinessTimeoutOverride = 0.002
        service.inputReadinessPollIntervalOverride = 0.001
        service.inputReadinessProbeOverride = { false }

        XCTAssertThrowsError(try service.testingWaitForInitialInputReadinessIfNeeded()) { error in
            guard case AudioRecordingService.AudioRecordingError.noAudioData = error else {
                return XCTFail("Expected noAudioData, got \(error)")
            }
        }
    }

    func testBluetoothInputReadinessThrowsRetryableErrorWhenEngineStopsBeforeInitialInput() {
        let service = AudioRecordingService()
        var engineRunningProbeCalls = 0
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputReadinessTimeoutOverride = 0.05
        service.inputReadinessPollIntervalOverride = 0.001
        service.inputReadinessProbeOverride = { false }

        XCTAssertThrowsError(try service.testingWaitForInitialInputReadinessIfNeeded {
            engineRunningProbeCalls += 1
            return engineRunningProbeCalls == 1
        }) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, AudioEngineRecoveryErrorDomains.transientFormatMismatch)
            XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: error))
        }
        XCTAssertGreaterThanOrEqual(engineRunningProbeCalls, 2)
    }

    func testBluetoothInputReadinessProbeSucceedsWhenInitialInputArrives() {
        let service = AudioRecordingService()
        var probeCalls = 0
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputReadinessTimeoutOverride = 0.05
        service.inputReadinessPollIntervalOverride = 0.001
        service.inputReadinessProbeOverride = {
            probeCalls += 1
            return probeCalls >= 2
        }

        XCTAssertNoThrow(try service.testingWaitForInitialInputReadinessIfNeeded())
        XCTAssertGreaterThanOrEqual(probeCalls, 2)
    }

    func testBluetoothInputReadinessDoesNotAcceptZeroFilledTapCallback() throws {
        let service = AudioRecordingService()
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputReadinessTimeoutOverride = 0.002
        service.inputReadinessPollIntervalOverride = 0.001

        try service.testingMarkInitialInputTapSeen(makeMonoBuffer(samples: [0, 0, 0, 0]))

        XCTAssertThrowsError(try service.testingWaitForInitialInputReadinessIfNeeded()) { error in
            guard case AudioRecordingService.AudioRecordingError.noAudioData = error else {
                return XCTFail("Expected noAudioData, got \(error)")
            }
        }
    }

    func testBluetoothInputReadinessSucceedsWhenTapCallbackContainsSignalBeforeConvertedSamples() throws {
        let service = AudioRecordingService()
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputReadinessTimeoutOverride = 0.01
        service.inputReadinessPollIntervalOverride = 0.001

        try service.testingMarkInitialInputTapSeen(makeMonoBuffer(samples: [0, 0.002, 0, -0.001]))

        XCTAssertNoThrow(try service.testingWaitForInitialInputReadinessIfNeeded())
    }

    func testBluetoothInputReadinessProbeIsSkippedForNonBluetoothInput() {
        let service = AudioRecordingService()
        var probeCalls = 0
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = false
        service.inputReadinessProbeOverride = {
            probeCalls += 1
            return false
        }

        XCTAssertNoThrow(try service.testingWaitForInitialInputReadinessIfNeeded())
        XCTAssertEqual(probeCalls, 0)
    }

    func testInputActivatorActivateIfNeededPinsBluetoothInput() {
        let inputActivationGuard = FakeAudioInputDeviceActivator()

        XCTAssertTrue(inputActivationGuard.activateIfNeeded(
            deviceID: AudioDeviceID(720),
            usesBluetoothTransport: true,
            reason: "recording-start"
        ))

        XCTAssertEqual(inputActivationGuard.activateCalls, [
            .init(deviceID: AudioDeviceID(720), reason: "recording-start")
        ])
    }

    func testInputActivatorActivateIfNeededSkipsNonBluetoothInput() {
        let inputActivationGuard = FakeAudioInputDeviceActivator()

        XCTAssertTrue(inputActivationGuard.activateIfNeeded(
            deviceID: AudioDeviceID(721),
            usesBluetoothTransport: false,
            reason: "recording-start"
        ))

        XCTAssertTrue(inputActivationGuard.activateCalls.isEmpty)
    }

    func testInputActivatorActivateIfNeededFailsWhenBluetoothDeviceIsMissing() {
        let inputActivationGuard = FakeAudioInputDeviceActivator()

        XCTAssertFalse(inputActivationGuard.activateIfNeeded(
            deviceID: nil,
            usesBluetoothTransport: true,
            reason: "recording-start"
        ))

        XCTAssertTrue(inputActivationGuard.activateCalls.isEmpty)
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
    func testInputActivationGuardRestoresPreviousDefaultInput() {
        let controller = FakeAudioInputDeviceDefaultController(defaultInputDeviceID: AudioDeviceID(1))
        let guardService = AudioInputDeviceActivationGuard(controller: controller)

        XCTAssertTrue(guardService.activate(deviceID: AudioDeviceID(2), reason: "test"))
        guardService.restore(reason: "test")

        XCTAssertEqual(controller.setCalls, [AudioDeviceID(2), AudioDeviceID(1)])
        XCTAssertEqual(controller.defaultInputDeviceID(), AudioDeviceID(1))
    }

    func testInputActivationGuardReferenceCountsSharedActivation() {
        let controller = FakeAudioInputDeviceDefaultController(defaultInputDeviceID: AudioDeviceID(1))
        let guardService = AudioInputDeviceActivationGuard(controller: controller)

        XCTAssertTrue(guardService.activate(deviceID: AudioDeviceID(2), reason: "preview-start"))
        XCTAssertTrue(guardService.activate(deviceID: AudioDeviceID(2), reason: "recording-start"))
        guardService.restore(reason: "preview-stop")

        XCTAssertEqual(controller.setCalls, [AudioDeviceID(2)])
        XCTAssertEqual(controller.defaultInputDeviceID(), AudioDeviceID(2))

        guardService.restore(reason: "recording-stop")

        XCTAssertEqual(controller.setCalls, [AudioDeviceID(2), AudioDeviceID(1)])
        XCTAssertEqual(controller.defaultInputDeviceID(), AudioDeviceID(1))
    }

    func testInputActivationGuardDoesNotRestoreAfterExternalInputChange() {
        let controller = FakeAudioInputDeviceDefaultController(defaultInputDeviceID: AudioDeviceID(1))
        let guardService = AudioInputDeviceActivationGuard(controller: controller)

        XCTAssertTrue(guardService.activate(deviceID: AudioDeviceID(2), reason: "recording-start"))
        controller.defaultInputDevice = AudioDeviceID(3)
        guardService.restore(reason: "recording-stop")

        XCTAssertEqual(controller.setCalls, [AudioDeviceID(2)])
        XCTAssertEqual(controller.defaultInputDeviceID(), AudioDeviceID(3))
    }

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
        let guardService = AudioOutputVolumeGuard(volumeController: controller, allowsVolumeRestoration: true)

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
        let guardService = AudioOutputVolumeGuard(volumeController: controller, allowsVolumeRestoration: true)

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
        let guardService = AudioOutputVolumeGuard(volumeController: controller, allowsVolumeRestoration: true)

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
        let guardService = AudioOutputVolumeGuard(volumeController: controller, allowsVolumeRestoration: true)

        guardService.captureBaseline()
        guardService.clear()
        controller.updateVolume(0.40, for: AudioDeviceID(1))
        guardService.restoreIfRaised(reason: "test")

        XCTAssertTrue(controller.setCalls.isEmpty)
    }

    func testDefaultGuardDoesNotWriteOutputVolume() {
        let controller = FakeAudioOutputVolumeController.airPods(volume: 0.10)
        let guardService = AudioOutputVolumeGuard(volumeController: controller)

        guardService.captureBaseline()
        controller.updateVolume(0.40, for: AudioDeviceID(1))
        guardService.restoreIfRaised(reason: "test")

        XCTAssertTrue(controller.setCalls.isEmpty)
    }
}

final class AudioOutputVolumeIntegrationTests: XCTestCase {
    func testStartRecordingDoesNotWriteOutputVolumeDuringAudioStart() {
        let controller = FakeAudioOutputVolumeController.airPods(volume: 0.10)
        let guardService = AudioOutputVolumeGuard(volumeController: controller)
        let service = AudioRecordingService(outputVolumeGuard: guardService)
        service.hasMicrophonePermissionOverride = true
        service.inputAvailabilityOverride = { _ in true }
        service.startRecordingOverride = {
            controller.updateVolume(0.40, for: AudioDeviceID(1))
        }

        XCTAssertNoThrow(try service.startRecording())

        XCTAssertTrue(controller.setCalls.isEmpty)
    }

    func testStopRecordingDoesNotWriteOutputVolume() async {
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

        XCTAssertTrue(controller.setCalls.isEmpty)
    }

    @MainActor
    func testStartPreviewDoesNotWriteOutputVolume() {
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

        XCTAssertTrue(controller.setCalls.isEmpty)
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

private final class FakeAudioInputDeviceActivator: AudioInputDeviceActivating {
    struct ActivateCall: Equatable {
        let deviceID: AudioDeviceID
        let reason: String
    }

    var shouldActivate = true
    private let onActivate: ((ActivateCall) -> Void)?
    private(set) var activateCalls: [ActivateCall] = []
    private(set) var restoreCalls: [String] = []

    init(onActivate: ((ActivateCall) -> Void)? = nil) {
        self.onActivate = onActivate
    }

    func activate(deviceID: AudioDeviceID, reason: String) -> Bool {
        let call = ActivateCall(deviceID: deviceID, reason: reason)
        activateCalls.append(call)
        onActivate?(call)
        return shouldActivate
    }

    func restore(reason: String) {
        restoreCalls.append(reason)
    }
}

private final class FakeAudioInputDeviceDefaultController: AudioInputDeviceDefaultControlling {
    var defaultInputDevice: AudioDeviceID?
    private(set) var setCalls: [AudioDeviceID] = []

    init(defaultInputDeviceID: AudioDeviceID?) {
        defaultInputDevice = defaultInputDeviceID
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        defaultInputDevice
    }

    func setDefaultInputDeviceID(_ deviceID: AudioDeviceID) -> Bool {
        setCalls.append(deviceID)
        defaultInputDevice = deviceID
        return true
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
