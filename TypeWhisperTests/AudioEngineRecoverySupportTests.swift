import AudioToolbox
import AudioUnit
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

    func testCaptureRouteUsesInputOnlyHALForExplicitNonBluetoothSelection() {
        XCTAssertEqual(
            AudioInputCaptureRoute.selectedRoute(
                selectedDeviceID: AudioDeviceID(410),
                usesBluetoothTransport: false
            ),
            .inputOnlyDevice(AudioDeviceID(410))
        )
    }

    func testCaptureRouteKeepsAVAudioEngineForDefaultAndBluetoothSelection() {
        XCTAssertEqual(
            AudioInputCaptureRoute.selectedRoute(
                selectedDeviceID: nil,
                usesBluetoothTransport: false
            ),
            .avAudioEngine(preferredDeviceID: nil)
        )
        XCTAssertEqual(
            AudioInputCaptureRoute.selectedRoute(
                selectedDeviceID: AudioDeviceID(112),
                usesBluetoothTransport: true
            ),
            .avAudioEngine(preferredDeviceID: nil)
        )
    }

    func testAudioInputBufferNormalizerDownmixesMultiChannelFloatBuffers() throws {
        let stereoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 96_000,
            channels: 2,
            interleaved: false
        ))
        let stereoBuffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: stereoFormat,
            frameCapacity: 3
        ))
        stereoBuffer.frameLength = 3
        stereoBuffer.floatChannelData?[0][0] = 1
        stereoBuffer.floatChannelData?[0][1] = 0.5
        stereoBuffer.floatChannelData?[0][2] = -1
        stereoBuffer.floatChannelData?[1][0] = -1
        stereoBuffer.floatChannelData?[1][1] = 0.5
        stereoBuffer.floatChannelData?[1][2] = 1

        let monoBuffer = try XCTUnwrap(AudioInputBufferNormalizer.monoFloatBuffer(from: stereoBuffer))

        XCTAssertEqual(monoBuffer.format.sampleRate, 96_000)
        XCTAssertEqual(monoBuffer.format.channelCount, 1)
        let monoChannel = try XCTUnwrap(monoBuffer.floatChannelData?[0])
        XCTAssertEqual(monoChannel[0], 0, accuracy: Float(0.0001))
        XCTAssertEqual(monoChannel[1], 0.5, accuracy: Float(0.0001))
        XCTAssertEqual(monoChannel[2], 0, accuracy: Float(0.0001))
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

    func testRecordingSuccessDiscardDeletesRecoveryAudio() async throws {
        let directory = makeRecoveryTestDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)
        let service = AudioRecordingService(recoveryAudioStore: store)
        service.hasMicrophonePermissionOverride = true
        service.startRecordingOverride = {}
        service.stopRecordingOverride = { _ in service.getCurrentBuffer() }

        try service.startRecording()
        service.testingProcessConvertedSamples([0.25, -0.25])
        _ = await service.stopRecording(policy: .immediate)
        service.discardActiveRecoveryRecording()

        XCTAssertNil(service.latestRecoveryRecordingURL)
        XCTAssertTrue(try recoveryFileNames(in: directory).isEmpty)
    }

    func testRecordingSuccessDiscardKeepsPreviousStoredRecoveryAudio() async throws {
        let directory = makeRecoveryTestDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)
        store.startNewRecording()
        store.append([0.5])
        let existingRecovery = try XCTUnwrap(store.preserveActiveRecording())

        let service = AudioRecordingService(recoveryAudioStore: store)
        service.hasMicrophonePermissionOverride = true
        service.startRecordingOverride = {}
        service.stopRecordingOverride = { _ in service.getCurrentBuffer() }

        try service.startRecording()
        service.testingProcessConvertedSamples([0.25, -0.25])
        _ = await service.stopRecording(policy: .immediate)
        service.discardActiveRecoveryRecording()

        XCTAssertEqual(service.recoveryRecordingURLs, [existingRecovery])
        XCTAssertEqual(service.latestRecoveryRecordingURL, existingRecovery)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingRecovery.path))
        XCTAssertEqual(try recoveryFileNames(in: directory), [existingRecovery.lastPathComponent])
    }

    func testTranscriptionFailureCanPreserveStoppedRecoveryAudio() async throws {
        let directory = makeRecoveryTestDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)
        let service = AudioRecordingService(recoveryAudioStore: store)
        service.hasMicrophonePermissionOverride = true
        service.startRecordingOverride = {}
        service.stopRecordingOverride = { _ in service.getCurrentBuffer() }

        try service.startRecording()
        service.testingProcessConvertedSamples([0.25, -0.25, 0.5])
        _ = await service.stopRecording(policy: .immediate)
        let url = try XCTUnwrap(service.preserveActiveRecoveryRecording())

        let data = try Data(contentsOf: url)
        XCTAssertEqual(readRecoveryUInt32(data, at: 40), UInt32(3 * 2))
        XCTAssertEqual(service.latestRecoveryRecordingURL, url)
    }

    func testRecoveryCircuitBreakerPreservesBufferedRecoveryAudio() throws {
        let directory = makeRecoveryTestDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)
        let service = AudioRecordingService(recoveryAudioStore: store)
        service.hasMicrophonePermissionOverride = true
        service.startRecordingOverride = {}

        try service.startRecording()
        service.testingProcessConvertedSamples([0.25, -0.25, 0.5])
        service.testingFailActiveRecordingDueToRecovery(.engineStartFailed("test circuit breaker"))

        let url = try XCTUnwrap(service.latestRecoveryRecordingURL)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(readRecoveryUInt32(data, at: 40), UInt32(3 * 2))
    }

    func testRecordingCancelDiscardDeletesRecoveryAudio() async throws {
        let directory = makeRecoveryTestDirectory()
        let store = DictationRecoveryAudioStore(directory: directory)
        let service = AudioRecordingService(recoveryAudioStore: store)
        service.hasMicrophonePermissionOverride = true
        service.startRecordingOverride = {}
        service.stopRecordingOverride = { _ in service.getCurrentBuffer() }

        try service.startRecording()
        service.testingProcessConvertedSamples([0.1, 0.2])
        _ = await service.stopRecording(policy: .immediate)
        service.discardActiveRecoveryRecording()

        XCTAssertNil(service.latestRecoveryRecordingURL)
        XCTAssertTrue(try recoveryFileNames(in: directory).isEmpty)
    }

    private func makeRecoveryTestDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioEngineRecoverySupportTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func recoveryFileNames(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    private func readRecoveryUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
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
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [bluetoothDeviceID: kAudioDeviceTransportTypeBluetooth]
        ) { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
        }
        let routeStabilizer = FakeBluetoothInputRouteStabilizer { inputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, bluetoothDeviceID)
            XCTAssertEqual(reason, "selection-validation")
            events.append("stabilize:selection-validation")
            return true
        }
        let selectionEngineValidator = FakeAudioInputSelectionEngineValidator { preferredDeviceID in
            XCTAssertNil(preferredDeviceID)
            events.append("validate:aggregate")
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: bluetoothDeviceID, name: "AirPods Max", uid: "airpods-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            bluetoothInputRouteStabilizer: routeStabilizer,
            selectionEngineValidator: selectionEngineValidator,
            inputActivationGuard: inputActivationGuard
        )

        service.audioDeviceIDResolverOverride = { uid in
            uid == "airpods-input" ? bluetoothDeviceID : nil
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

    func testSelectingUSBDeviceSkipsInputOnlyProbeAndAllowsSelection() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let usbDeviceID = AudioDeviceID(712)
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        )
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "Elgato Wave XLR", uid: "wave-xlr")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            selectionEngineValidator: AVAudioInputSelectionEngineValidator(inputCaptureFactory: inputCaptureFactory),
            inputCaptureFactory: inputCaptureFactory
        )

        service.audioDeviceIDResolverOverride = { uid in
            uid == "wave-xlr" ? usbDeviceID : nil
        }

        service.selectedDeviceUID = "wave-xlr"

        XCTAssertEqual(service.selectedDeviceUID, "wave-xlr")
        XCTAssertNil(service.previewError)
        XCTAssertTrue(inputCaptureFactory.validateCalls.isEmpty)
        XCTAssertEqual(service.selectedDeviceCompatibility, .compatible)
    }

    func testSelectingUSBDeviceAllowsSelectionWhenInputOnlyValidationFails() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let usbDeviceID = AudioDeviceID(713)
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        inputCaptureFactory.validateError = SelectedInputDeviceError.incompatible(.engineStartFailed)
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        )
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "Babyface Pro", uid: "babyface-pro")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            selectionEngineValidator: AVAudioInputSelectionEngineValidator(inputCaptureFactory: inputCaptureFactory),
            inputCaptureFactory: inputCaptureFactory
        )

        service.audioDeviceIDResolverOverride = { uid in
            uid == "babyface-pro" ? usbDeviceID : nil
        }

        service.selectedDeviceUID = "babyface-pro"

        XCTAssertEqual(service.selectedDeviceUID, "babyface-pro")
        XCTAssertNil(service.previewError)
        XCTAssertTrue(inputCaptureFactory.validateCalls.isEmpty)
        XCTAssertEqual(service.selectedDeviceCompatibility, .compatible)
    }

    func testEnumerationIncludesVirtualAndAggregateInputDevices() {
        let snapshots: [AudioDeviceService.TestingInputDeviceSnapshot] = [
            .init(
                deviceID: AudioDeviceID(1),
                name: "MacBook Pro Microphone",
                uid: "built-in",
                inputChannels: 1,
                outputChannels: 0,
                transportType: kAudioDeviceTransportTypeBuiltIn
            ),
            .init(
                deviceID: AudioDeviceID(2),
                name: "BlackHole 2ch",
                uid: "blackhole-2ch",
                inputChannels: 2,
                outputChannels: 2,
                transportType: kAudioDeviceTransportTypeVirtual
            ),
            .init(
                deviceID: AudioDeviceID(3),
                name: "Podcast Aggregate Device",
                uid: "podcast-aggregate",
                inputChannels: 4,
                outputChannels: 2,
                transportType: kAudioDeviceTransportTypeAggregate
            ),
            .init(
                deviceID: AudioDeviceID(4),
                name: "CADefaultDevice",
                uid: "ca-default",
                inputChannels: 2,
                outputChannels: 0,
                transportType: kAudioDeviceTransportTypeVirtual
            )
        ]

        let devices = AudioDeviceService.testingAvailableInputDevices(from: snapshots)

        XCTAssertEqual(devices.map(\.uid), [
            "built-in",
            "blackhole-2ch",
            "podcast-aggregate"
        ])

        let diagnostics = AudioDeviceService.testingInputDeviceDiagnostics(
            from: snapshots,
            listedDevices: devices
        )
        let blackHole = diagnostics.first { $0.uid == "blackhole-2ch" }
        let aggregate = diagnostics.first { $0.uid == "podcast-aggregate" }
        let caDefault = diagnostics.first { $0.uid == "ca-default" }

        XCTAssertEqual(blackHole?.transportTypeName, "virtual")
        XCTAssertTrue(blackHole?.isVirtual == true)
        XCTAssertFalse(blackHole?.isAggregate == true)
        XCTAssertNil(blackHole?.exclusionReason)
        XCTAssertEqual(aggregate?.transportTypeName, "aggregate")
        XCTAssertTrue(aggregate?.isAggregate == true)
        XCTAssertFalse(aggregate?.isVirtual == true)
        XCTAssertNil(aggregate?.exclusionReason)
        XCTAssertFalse(caDefault?.listedByTypeWhisper == true)
        XCTAssertEqual(caDefault?.exclusionReason, "nameMatchedCADefault")
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
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [bluetoothDeviceID: kAudioDeviceTransportTypeBluetooth]
        ) { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
        }
        let routeStabilizer = FakeBluetoothInputRouteStabilizer { inputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, bluetoothDeviceID)
            XCTAssertEqual(reason, "preview-start")
            return true
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: bluetoothDeviceID, name: "AirPods Max", uid: "airpods-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            bluetoothInputRouteStabilizer: routeStabilizer,
            inputActivationGuard: inputActivationGuard
        )

        service.hasMicrophonePermissionOverride = true
        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "airpods-input" ? bluetoothDeviceID : nil
        }
        service.selectedDeviceUID = "airpods-input"
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
    func testStartPreviewUsesInputOnlyCaptureForUSBInput() {
        let usbDeviceID = AudioDeviceID(711)
        let inputActivationGuard = FakeAudioInputDeviceActivator()
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        ) { deviceID in
            XCTAssertEqual(deviceID, usbDeviceID)
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            inputCaptureFactory: inputCaptureFactory,
            inputActivationGuard: inputActivationGuard
        )

        service.hasMicrophonePermissionOverride = true
        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }
        service.selectedDeviceUID = "usb-input"

        service.startPreview()

        XCTAssertTrue(inputActivationGuard.activateCalls.isEmpty)
        XCTAssertEqual(inputCaptureFactory.startCalls, [
            .init(deviceID: usbDeviceID, label: "preview", bufferSize: 1024)
        ])
        XCTAssertTrue(service.isPreviewActive)

        service.stopPreview()

        XCTAssertEqual(inputCaptureFactory.createdSessions.first?.stopCalls, 1)
    }

    @MainActor
    func testStartPreviewUsesInputOnlyCaptureForVirtualInput() {
        let virtualDeviceID = AudioDeviceID(714)
        let inputActivationGuard = FakeAudioInputDeviceActivator()
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [virtualDeviceID: kAudioDeviceTransportTypeVirtual]
        ) { deviceID in
            XCTAssertEqual(deviceID, virtualDeviceID)
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: virtualDeviceID, name: "BlackHole 2ch", uid: "blackhole-2ch")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            inputCaptureFactory: inputCaptureFactory,
            inputActivationGuard: inputActivationGuard
        )

        service.hasMicrophonePermissionOverride = true
        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "blackhole-2ch" ? virtualDeviceID : nil
        }
        service.selectedDeviceUID = "blackhole-2ch"

        service.startPreview()

        XCTAssertTrue(inputActivationGuard.activateCalls.isEmpty)
        XCTAssertEqual(inputCaptureFactory.startCalls, [
            .init(deviceID: virtualDeviceID, label: "preview", bufferSize: 1024)
        ])
        XCTAssertTrue(service.isPreviewActive)

        service.stopPreview()

        XCTAssertEqual(inputCaptureFactory.createdSessions.first?.stopCalls, 1)
    }

    @MainActor
    func testDiagnosticsReportIncludesSelectedUSBDeviceAndPreviewFailure() throws {
        UserDefaults.standard.set("usb-input", forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let usbDeviceID = AudioDeviceID(711)
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        inputCaptureFactory.startError = SelectedInputDeviceError.incompatible(.engineStartFailed)
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        )
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
            ],
            monitorDeviceChanges: false,
            probeCompatibilities: false,
            transportResolver: transportResolver,
            inputCaptureFactory: inputCaptureFactory
        )
        service.hasMicrophonePermissionOverride = true
        service.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }

        service.startPreview()
        let report = service.diagnosticsReport()
        let selectedDevice = try XCTUnwrap(report.devices.first { $0.deviceID == UInt32(usbDeviceID) })

        XCTAssertFalse(service.isPreviewActive)
        XCTAssertEqual(report.selectedInputDeviceUID, "usb-input")
        XCTAssertEqual(report.selectedInputDeviceID, UInt32(usbDeviceID))
        XCTAssertEqual(report.selectedInputDeviceName, "USB Mic")
        XCTAssertEqual(report.previewError, "incompatible:engineStartFailed")
        XCTAssertFalse(report.selectedInputUsesBluetoothTransport)
        XCTAssertTrue(selectedDevice.isSelected)
        XCTAssertTrue(selectedDevice.listedByTypeWhisper)
        XCTAssertEqual(selectedDevice.compatibility, "incompatible:engineStartFailed")
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
        let routeStabilizer = FakeBluetoothInputRouteStabilizer { inputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, AudioDeviceID(42))
            XCTAssertEqual(reason, "recording-start")
            routeEvents.append("stabilize:\(reason)")
            return true
        }
        let service = AudioRecordingService(
            inputActivationGuard: inputActivationGuard,
            bluetoothInputRouteStabilizer: routeStabilizer
        )
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = AudioDeviceID(42)
        service.selectedInputDeviceUsesBluetoothTransport = true
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, AudioDeviceID(42))
            return true
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
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [bluetoothDeviceID: kAudioDeviceTransportTypeBluetoothLE]
        ) { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: bluetoothDeviceID, name: "Jabra PRO 930", uid: "jabra-pro-930")
            ],
            monitorDeviceChanges: false,
            transportResolver: transportResolver
        )

        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "jabra-pro-930" ? bluetoothDeviceID : nil
        }

        service.selectedDeviceUID = "jabra-pro-930"

        XCTAssertTrue(service.selectedDeviceUsesBluetoothTransport)
    }

    func testSelectedDeviceUsesBluetoothTransport_returnsFalseForUSBAndDefaultInput() {
        let usbDeviceID = AudioDeviceID(701)
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        ) { deviceID in
            XCTAssertEqual(deviceID, usbDeviceID)
        }
        let service = AudioDeviceService(
            initialInputDevices: [
                AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-mic")
            ],
            monitorDeviceChanges: false,
            transportResolver: transportResolver
        )

        XCTAssertFalse(service.selectedDeviceUsesBluetoothTransport)

        service.selectionValidationOverride = { _ in }
        service.audioDeviceIDResolverOverride = { uid in
            uid == "usb-mic" ? usbDeviceID : nil
        }

        service.selectedDeviceUID = "usb-mic"

        XCTAssertFalse(service.selectedDeviceUsesBluetoothTransport)
    }

    func testBluetoothInputReadinessProbeTimesOutWithNoInitialInput() {
        let clock = FakeReadinessClock()
        let checker = BluetoothInputReadinessChecker(
            timeout: 0.002,
            pollInterval: 0.001,
            now: { clock.now },
            sleep: { clock.now += $0 }
        )

        XCTAssertThrowsError(try checker.waitForInitialInput(
            label: "test",
            hasCapturedInitialInput: { false },
            isEngineRunning: nil
        )) { error in
            guard case AudioRecordingService.AudioRecordingError.noAudioData = error else {
                return XCTFail("Expected noAudioData, got \(error)")
            }
        }
    }

    func testBluetoothInputReadinessThrowsRetryableErrorWhenEngineStopsBeforeInitialInput() {
        let clock = FakeReadinessClock()
        let checker = BluetoothInputReadinessChecker(
            timeout: 0.05,
            pollInterval: 0.001,
            now: { clock.now },
            sleep: { clock.now += $0 }
        )
        var engineRunningProbeCalls = 0

        XCTAssertThrowsError(try checker.waitForInitialInput(
            label: "test",
            hasCapturedInitialInput: { false },
            isEngineRunning: {
                engineRunningProbeCalls += 1
                return engineRunningProbeCalls == 1
            }
        )) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, AudioEngineRecoveryErrorDomains.transientFormatMismatch)
            XCTAssertTrue(AudioEngineRecoveryPolicy.isRetryable(error: error))
        }
        XCTAssertGreaterThanOrEqual(engineRunningProbeCalls, 2)
    }

    func testBluetoothInputReadinessProbeSucceedsWhenInitialInputArrives() {
        let clock = FakeReadinessClock()
        let checker = BluetoothInputReadinessChecker(
            timeout: 0.05,
            pollInterval: 0.001,
            now: { clock.now },
            sleep: { clock.now += $0 }
        )
        var probeCalls = 0
        let probe = {
            probeCalls += 1
            return probeCalls >= 2
        }

        XCTAssertNoThrow(try checker.waitForInitialInput(
            label: "test",
            hasCapturedInitialInput: probe,
            isEngineRunning: nil
        ))
        XCTAssertGreaterThanOrEqual(probeCalls, 2)
    }

    func testBluetoothInputReadinessDoesNotAcceptZeroFilledTapCallback() throws {
        let clock = FakeReadinessClock()
        let service = AudioRecordingService(
            inputReadinessChecker: BluetoothInputReadinessChecker(
                timeout: 0.002,
                pollInterval: 0.001,
                now: { clock.now },
                sleep: { clock.now += $0 }
            )
        )
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true

        try service.testingMarkInitialInputTapSeen(makeMonoBuffer(samples: [0, 0, 0, 0]))

        XCTAssertThrowsError(try service.testingWaitForInitialInputReadinessIfNeeded()) { error in
            guard case AudioRecordingService.AudioRecordingError.noAudioData = error else {
                return XCTFail("Expected noAudioData, got \(error)")
            }
        }
    }

    func testBluetoothInputReadinessSucceedsWhenTapCallbackContainsSignalBeforeConvertedSamples() throws {
        let clock = FakeReadinessClock()
        let service = AudioRecordingService(
            inputReadinessChecker: BluetoothInputReadinessChecker(
                timeout: 0.01,
                pollInterval: 0.001,
                now: { clock.now },
                sleep: { clock.now += $0 }
            )
        )
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = true

        try service.testingMarkInitialInputTapSeen(makeMonoBuffer(samples: [0, 0.002, 0, -0.001]))

        XCTAssertNoThrow(try service.testingWaitForInitialInputReadinessIfNeeded())
    }

    func testBluetoothInputReadinessProbeIsSkippedForNonBluetoothInput() {
        let readinessChecker = FakeAudioInputReadinessChecker()
        let service = AudioRecordingService(inputReadinessChecker: readinessChecker)
        service.hasExplicitDeviceSelection = true
        service.selectedInputDeviceUsesBluetoothTransport = false

        XCTAssertNoThrow(try service.testingWaitForInitialInputReadinessIfNeeded())
        XCTAssertTrue(readinessChecker.waitCalls.isEmpty)
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

    func testStartRecordingUsesInputOnlyCaptureForExplicitUSBInput() async throws {
        let usbDeviceID = AudioDeviceID(730)
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        let service = AudioRecordingService(inputCaptureFactory: inputCaptureFactory)
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = usbDeviceID
        service.selectedInputDeviceUsesBluetoothTransport = false
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, usbDeviceID)
            return true
        }

        try service.startRecording()

        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(inputCaptureFactory.startCalls, [
            .init(deviceID: usbDeviceID, label: "recording", bufferSize: 256)
        ])

        let samples = await service.stopRecording(policy: .immediate)

        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(inputCaptureFactory.createdSessions.first?.stopCalls, 1)
    }

    func testStartRecordingUsesInputOnlyCaptureForExplicitVirtualInput() async throws {
        let virtualDeviceID = AudioDeviceID(731)
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        let service = AudioRecordingService(inputCaptureFactory: inputCaptureFactory)
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = virtualDeviceID
        service.selectedInputDeviceUsesBluetoothTransport = false
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, virtualDeviceID)
            return true
        }

        try service.startRecording()

        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(inputCaptureFactory.startCalls, [
            .init(deviceID: virtualDeviceID, label: "recording", bufferSize: 256)
        ])

        let samples = await service.stopRecording(policy: .immediate)

        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(inputCaptureFactory.createdSessions.first?.stopCalls, 1)
    }

    func testStartRecordingVirtualInputFailureSurfacesAsIncompatibleDevice() {
        let virtualDeviceID = AudioDeviceID(732)
        let inputCaptureFactory = FakeAudioInputCaptureFactory()
        inputCaptureFactory.startError = SelectedInputDeviceError.incompatible(.engineStartFailed)
        let service = AudioRecordingService(inputCaptureFactory: inputCaptureFactory)
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = true
        service.selectedDeviceID = virtualDeviceID
        service.selectedInputDeviceUsesBluetoothTransport = false
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, virtualDeviceID)
            return true
        }

        XCTAssertThrowsError(try service.startRecording()) { error in
            guard case AudioRecordingService.AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed) = error else {
                return XCTFail("Expected selectedInputDeviceIncompatible(.engineStartFailed), got \(error)")
            }
        }

        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(inputCaptureFactory.startCalls, [
            .init(deviceID: virtualDeviceID, label: "recording", bufferSize: 256)
        ])
    }

    func testDefaultInputRecordingSkipsAvailabilityPreflightFastPath() throws {
        let service = AudioRecordingService()
        service.hasMicrophonePermissionOverride = true
        service.hasExplicitDeviceSelection = false
        service.inputAvailabilityOverride = { _ in
            XCTFail("default-input fast path should rely on engine startup instead of input availability preflight")
            return true
        }
        service.startRecordingOverride = {}

        XCTAssertNoThrow(try service.startRecording())
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

final class CoreAudioHALInputCaptureSessionTests: XCTestCase {
    func testInputOnlyCaptureCapsMultichannelHardwareToStereoClientFormat() {
        XCTAssertEqual(CoreAudioHALInputCaptureSession.testingInputOnlyCaptureChannelCount(for: 1), 1)
        XCTAssertEqual(CoreAudioHALInputCaptureSession.testingInputOnlyCaptureChannelCount(for: 2), 2)
        XCTAssertEqual(CoreAudioHALInputCaptureSession.testingInputOnlyCaptureChannelCount(for: 14), 2)
    }

    func testSessionConfiguresInputOnlyHALUnitAndPullsInputFromRenderCallback() throws {
        let operations = FakeCoreAudioHALInputOperations()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 96_000,
            channels: 2,
            interleaved: false
        ))
        var receivedBuffers: [AVAudioPCMBuffer] = []

        let session = try CoreAudioHALInputCaptureSession(
            deviceID: AudioDeviceID(900),
            format: format,
            bufferSize: 256,
            label: "test-hal",
            operations: operations
        ) { buffer in
            receivedBuffers.append(buffer)
        }

        XCTAssertEqual(operations.enableIOCalls, [
            .init(enabled: 0, scope: kAudioUnitScope_Output, element: 0),
            .init(enabled: 1, scope: kAudioUnitScope_Input, element: 1)
        ])
        XCTAssertEqual(operations.currentDeviceCalls, [AudioDeviceID(900)])
        XCTAssertEqual(operations.streamFormatCalls.first?.mSampleRate, 96_000)
        XCTAssertEqual(operations.streamFormatCalls.first?.mChannelsPerFrame, 2)
        XCTAssertEqual(operations.initializeCalls, 1)
        XCTAssertEqual(operations.startCalls, 1)
        XCTAssertNotNil(operations.inputCallback)

        var flags = AudioUnitRenderActionFlags()
        var timestamp = AudioTimeStamp()
        let callback = try XCTUnwrap(operations.inputCallback)
        let callbackStatus = try XCTUnwrap(callback.inputProc)(
            try XCTUnwrap(callback.inputProcRefCon),
            &flags,
            &timestamp,
            1,
            64,
            nil
        )

        XCTAssertEqual(callbackStatus, noErr)
        XCTAssertEqual(operations.renderCalls, [
            .init(busNumber: 1, frameCount: 64)
        ])
        XCTAssertEqual(receivedBuffers.count, 1)
        XCTAssertEqual(receivedBuffers.first?.format.sampleRate, 96_000)
        XCTAssertEqual(receivedBuffers.first?.format.channelCount, 2)

        session.stop()

        XCTAssertEqual(operations.stopCalls, 1)
        XCTAssertEqual(operations.uninitializeCalls, 1)
        XCTAssertEqual(operations.disposeCalls, 1)
    }

    func testSessionMapsCurrentDeviceFailureToSelectedInputCompatibilityError() throws {
        let operations = FakeCoreAudioHALInputOperations()
        operations.currentDeviceError = SelectedInputDeviceError.incompatible(.cannotSetDevice)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        XCTAssertThrowsError(try CoreAudioHALInputCaptureSession(
            deviceID: AudioDeviceID(901),
            format: format,
            bufferSize: 128,
            label: "test-hal",
            operations: operations,
            onBuffer: { _ in }
        )) { error in
            XCTAssertEqual(error as? SelectedInputDeviceError, .incompatible(.cannotSetDevice))
        }
        XCTAssertEqual(operations.disposeCalls, 1)
    }

    func testSessionRecordsInputOnlyCaptureFailureDiagnostics() throws {
        AudioInputCaptureDiagnosticsStore.clear()
        defer { AudioInputCaptureDiagnosticsStore.clear() }

        let operations = FakeCoreAudioHALInputOperations()
        operations.currentDeviceError = CoreAudioHALInputOperationError(
            operation: "test-hal set current input device",
            status: OSStatus(-50)
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        XCTAssertThrowsError(try CoreAudioHALInputCaptureSession(
            deviceID: AudioDeviceID(902),
            format: format,
            bufferSize: 128,
            label: "test-hal",
            operations: operations,
            onBuffer: { _ in }
        )) { error in
            XCTAssertTrue(error is CoreAudioHALInputOperationError)
        }

        let failure = try XCTUnwrap(AudioInputCaptureDiagnosticsStore.lastFailure())
        XCTAssertEqual(failure.label, "test-hal")
        XCTAssertEqual(failure.deviceID, 902)
        XCTAssertEqual(failure.operation, "test-hal set current input device")
        XCTAssertEqual(failure.status, -50)
        XCTAssertEqual(failure.statusString, "-50")
        XCTAssertEqual(failure.errorDescription, "test-hal set current input device failed with status -50 (-50)")
        XCTAssertEqual(failure.formatSampleRate, 48_000)
        XCTAssertEqual(failure.formatChannelCount, 1)
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

private final class FakeAudioDeviceTransportResolver: AudioDeviceTransportResolving {
    private let transports: [AudioDeviceID: UInt32]
    private let onResolve: ((AudioDeviceID) -> Void)?

    init(
        transports: [AudioDeviceID: UInt32],
        onResolve: ((AudioDeviceID) -> Void)? = nil
    ) {
        self.transports = transports
        self.onResolve = onResolve
    }

    func transportType(for deviceID: AudioDeviceID) -> UInt32? {
        onResolve?(deviceID)
        return transports[deviceID]
    }
}

private final class FakeBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing {
    private let handler: (AudioDeviceID?, String) -> Bool

    init(handler: @escaping (AudioDeviceID?, String) -> Bool) {
        self.handler = handler
    }

    func waitForActivatedDefaultInput(deviceID: AudioDeviceID?, reason: String) -> Bool {
        handler(deviceID, reason)
    }
}

private final class FakeAudioInputSelectionEngineValidator: AudioInputSelectionEngineValidating {
    private let handler: (AudioDeviceID?) throws -> Void

    init(handler: @escaping (AudioDeviceID?) throws -> Void) {
        self.handler = handler
    }

    func validate(preferredDeviceID: AudioDeviceID?) throws {
        try handler(preferredDeviceID)
    }
}

private final class FakeAudioInputCaptureSession: AudioInputCaptureSession {
    private(set) var stopCalls = 0

    func stop() {
        stopCalls += 1
    }
}

private final class FakeAudioInputCaptureFactory: AudioInputCaptureFactory {
    struct ValidateCall: Equatable {
        let deviceID: AudioDeviceID
        let label: String
    }

    struct StartCall: Equatable {
        let deviceID: AudioDeviceID
        let label: String
        let bufferSize: AVAudioFrameCount
    }

    private let format: AVAudioFormat
    var inputFormatError: Error?
    var validateError: Error?
    var startError: Error?
    private(set) var inputFormatCalls: [AudioDeviceID] = []
    private(set) var validateCalls: [ValidateCall] = []
    private(set) var startCalls: [StartCall] = []
    private(set) var createdSessions: [FakeAudioInputCaptureSession] = []

    init(format: AVAudioFormat? = nil) {
        self.format = format ?? AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 96_000,
            channels: 2,
            interleaved: false
        )!
    }

    func inputOnlyCaptureFormat(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        inputFormatCalls.append(deviceID)
        if let inputFormatError { throw inputFormatError }
        return format
    }

    func validateInputOnlyDevice(deviceID: AudioDeviceID, label: String) throws {
        validateCalls.append(.init(deviceID: deviceID, label: label))
        if let validateError { throw validateError }
    }

    func startInputOnlyCapture(
        deviceID: AudioDeviceID,
        label: String,
        bufferSize: AVAudioFrameCount,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws -> AudioInputCaptureSession {
        startCalls.append(.init(deviceID: deviceID, label: label, bufferSize: bufferSize))
        if let startError { throw startError }
        let session = FakeAudioInputCaptureSession()
        createdSessions.append(session)
        return session
    }
}

private final class FakeCoreAudioHALInputOperations: CoreAudioHALInputOperating {
    struct EnableIOCall: Equatable {
        let enabled: UInt32
        let scope: AudioUnitScope
        let element: AudioUnitElement
    }

    struct RenderCall: Equatable {
        let busNumber: UInt32
        let frameCount: UInt32
    }

    let audioUnit: AudioUnit = AudioUnit(bitPattern: 0x1)!
    var currentDeviceError: Error?
    var renderStatus: OSStatus = noErr
    private(set) var enableIOCalls: [EnableIOCall] = []
    private(set) var currentDeviceCalls: [AudioDeviceID] = []
    private(set) var streamFormatCalls: [AudioStreamBasicDescription] = []
    private(set) var inputCallback: AURenderCallbackStruct?
    private(set) var initializeCalls = 0
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var uninitializeCalls = 0
    private(set) var disposeCalls = 0
    private(set) var renderCalls: [RenderCall] = []

    func makeInputUnit() throws -> AudioUnit {
        audioUnit
    }

    func setEnableIO(
        _ enabled: UInt32,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        audioUnit: AudioUnit,
        label: String
    ) throws {
        enableIOCalls.append(.init(enabled: enabled, scope: scope, element: element))
    }

    func setCurrentDevice(_ deviceID: AudioDeviceID, audioUnit: AudioUnit, label: String) throws {
        if let currentDeviceError { throw currentDeviceError }
        currentDeviceCalls.append(deviceID)
    }

    func setStreamFormat(_ streamDescription: inout AudioStreamBasicDescription, audioUnit: AudioUnit, label: String) throws {
        streamFormatCalls.append(streamDescription)
    }

    func setInputCallback(_ callback: inout AURenderCallbackStruct, audioUnit: AudioUnit, label: String) throws {
        inputCallback = callback
    }

    func initialize(_ audioUnit: AudioUnit, label: String) throws {
        initializeCalls += 1
    }

    func start(_ audioUnit: AudioUnit, label: String) throws {
        startCalls += 1
    }

    func stop(_ audioUnit: AudioUnit) {
        stopCalls += 1
    }

    func uninitialize(_ audioUnit: AudioUnit) {
        uninitializeCalls += 1
    }

    func dispose(_ audioUnit: AudioUnit) {
        disposeCalls += 1
    }

    func render(
        audioUnit: AudioUnit,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32,
        data: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        renderCalls.append(.init(busNumber: busNumber, frameCount: frameCount))
        return renderStatus
    }
}

private final class FakeReadinessClock {
    var now: TimeInterval = 0
}

private final class FakeAudioInputReadinessChecker: AudioInputReadinessChecking {
    struct WaitCall: Equatable {
        let label: String
    }

    private(set) var waitCalls: [WaitCall] = []

    func waitForInitialInput(
        label: String,
        hasCapturedInitialInput: () -> Bool,
        isEngineRunning: (() -> Bool)?
    ) throws {
        waitCalls.append(.init(label: label))
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
