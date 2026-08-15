import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecordingService")

enum BuiltInRecordingInputPreparationPolicy {
    static func isEligible(
        hasMicrophonePermission: Bool,
        selectedDeviceID: AudioDeviceID?,
        hasExplicitDeviceSelection: Bool,
        usesBluetoothTransport: Bool,
        defaultInputDeviceID: AudioDeviceID?,
        defaultInputTransport: UInt32?
    ) -> Bool {
        hasMicrophonePermission
            && selectedDeviceID == nil
            && !hasExplicitDeviceSelection
            && !usesBluetoothTransport
            && defaultInputDeviceID != nil
            && defaultInputTransport == kAudioDeviceTransportTypeBuiltIn
    }
}

enum USBRecordingInputPreparationPolicy {
    static func isEligible(
        hasMicrophonePermission: Bool,
        selectedDeviceID: AudioDeviceID?,
        hasExplicitDeviceSelection: Bool,
        usesBluetoothTransport: Bool,
        selectedInputTransport: UInt32?
    ) -> Bool {
        hasMicrophonePermission
            && selectedDeviceID != nil
            && hasExplicitDeviceSelection
            && !usesBluetoothTransport
            && selectedInputTransport == kAudioDeviceTransportTypeUSB
    }
}

enum AirPodsRecordingInputPreparationPolicy {
    static func isAirPods(deviceName: String?, usesBluetoothTransport: Bool) -> Bool {
        guard usesBluetoothTransport, let deviceName else { return false }
        return deviceName.range(
            of: "AirPods",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    static func isEligible(
        hasMicrophonePermission: Bool,
        isEnabled: Bool,
        selectedDeviceID: AudioDeviceID?,
        selectedDeviceName: String?,
        usesBluetoothTransport: Bool
    ) -> Bool {
        hasMicrophonePermission
            && isEnabled
            && selectedDeviceID != nil
            && isAirPods(
                deviceName: selectedDeviceName,
                usesBluetoothTransport: usesBluetoothTransport
            )
    }
}

struct MicrophoneBoostProcessingResult {
    let samples: [Float]
    let inputRMS: Float
    let outputRMS: Float
    let gain: Float
}

final class MicrophoneBoostProcessor: @unchecked Sendable {
    static let targetRMS: Float = 0.1
    static let maximumGain: Float = 20
    static let minimumGain: Float = 1
    static let activationRMS: Float = 0.0015
    static let peakCeiling: Float = 0.96

    private static let gainAttack: Float = 0.45
    private static let gainRelease: Float = 0.06
    private static let peakDecay: Float = 0.95
    private static let limiterKnee: Float = 0.8
    private static let limiterCeiling: Float = 0.98

    private struct State {
        var gain: Float = 1
        var recentPeak: Float = 0
    }

    private let stateLock = OSAllocatedUnfairLock(initialState: State())

    func reset() {
        stateLock.withLock { state in
            state = State()
        }
    }

    func process(_ samples: [Float], enabled: Bool) -> MicrophoneBoostProcessingResult {
        guard !samples.isEmpty else {
            return MicrophoneBoostProcessingResult(samples: [], inputRMS: 0, outputRMS: 0, gain: 1)
        }

        let inputRMS = Self.rms(samples)
        guard enabled else {
            reset()
            return MicrophoneBoostProcessingResult(samples: samples, inputRMS: inputRMS, outputRMS: inputRMS, gain: 1)
        }

        let inputPeak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let gain = stateLock.withLock { state -> Float in
            state.recentPeak = max(inputPeak, state.recentPeak * Self.peakDecay)

            // Hold the current gain through near-silence instead of normalizing each
            // quiet buffer independently. This avoids pumping the room noise between words.
            guard inputRMS >= Self.activationRMS else {
                return state.gain
            }

            var desiredGain = min(
                max(Self.targetRMS / inputRMS, Self.minimumGain),
                Self.maximumGain
            )
            if state.recentPeak > 0 {
                desiredGain = min(desiredGain, Self.peakCeiling / state.recentPeak)
            }

            let smoothing = desiredGain > state.gain ? Self.gainAttack : Self.gainRelease
            state.gain += (desiredGain - state.gain) * smoothing

            // Peak protection is immediate even when the normal gain release is gentle.
            if inputPeak > 0 {
                state.gain = min(state.gain, Self.peakCeiling / inputPeak)
            }
            state.gain = min(max(state.gain, Self.minimumGain), Self.maximumGain)
            return state.gain
        }

        guard gain > 1 else {
            return MicrophoneBoostProcessingResult(samples: samples, inputRMS: inputRMS, outputRMS: inputRMS, gain: 1)
        }

        let boosted = samples.map { Self.softLimited($0 * gain) }
        return MicrophoneBoostProcessingResult(
            samples: boosted,
            inputRMS: inputRMS,
            outputRMS: Self.rms(boosted),
            gain: gain
        )
    }

    private static func softLimited(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterKnee else { return sample }

        let normalizedExcess = (magnitude - limiterKnee) / (limiterCeiling - limiterKnee)
        let limitedMagnitude = limiterKnee + (limiterCeiling - limiterKnee) * tanh(normalizedExcess)
        return sample < 0 ? -limitedMagnitude : limitedMagnitude
    }

    private static func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }
}

/// Captures microphone audio via AVAudioEngine and converts to 16kHz mono Float32 samples.
final class AudioRecordingService: ObservableObject, @unchecked Sendable {
    private let recoveryNotificationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.typewhisper.audio-recovery.notifications"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    enum StopPolicy {
        case immediate
        case finalizeShortSpeech(
            minBufferedDuration: TimeInterval = 0.05,
            maxExtraCapture: TimeInterval = 0.06,
            pollInterval: TimeInterval = 0.01
        )

        var logDescription: String {
            switch self {
            case .immediate:
                "immediate"
            case .finalizeShortSpeech(let minBufferedDuration, let maxExtraCapture, let pollInterval):
                String(
                    format: "finalizeShortSpeech(min=%.3f,max=%.3f,poll=%.3f)",
                    minBufferedDuration,
                    maxExtraCapture,
                    pollInterval
                )
            }
        }

        func shouldApplyGracePeriod(bufferedDuration: TimeInterval) -> Bool {
            switch self {
            case .immediate:
                false
            case .finalizeShortSpeech(let minBufferedDuration, _, _):
                bufferedDuration < minBufferedDuration
            }
        }
    }

    enum AudioRecordingError: LocalizedError {
        case microphonePermissionDenied
        case noMicrophoneDetected
        case selectedInputDeviceUnavailable
        case selectedInputDeviceIncompatible(AudioInputDeviceCompatibilityIssue)
        case audioRoutingConflict
        case engineStartFailed(String)
        case noAudioData

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission denied. Please grant access in System Settings."
            case .noMicrophoneDetected:
                String(localized: "No mic detected.")
            case .selectedInputDeviceUnavailable:
                SelectedInputDeviceError.unavailable.errorDescription
            case .selectedInputDeviceIncompatible(let issue):
                SelectedInputDeviceError.incompatible(issue).errorDescription
            case .audioRoutingConflict:
                localizedAppText(
                    "The selected microphone conflicts with your current audio routing. Disconnect Bluetooth or choose a different input.",
                    de: "Das ausgewählte Mikrofon kollidiert mit deiner aktuellen Audio-Route. Trenne Bluetooth oder wähle ein anderes Eingabegerät."
                )
            case .engineStartFailed(let detail):
                "Failed to start audio engine: \(detail)"
            case .noAudioData:
                "No audio data was recorded."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var rawAudioLevel: Float = 0
    /// Set when the recovery coordinator gives up (e.g. burst circuit breaker
    /// trips). The view model observes this and surfaces the error to the UI,
    /// tears down the session, and resumes any paused media / restores ducking.
    /// Reset to nil at the start of each `startRecording`.
    @Published private(set) var recoveryError: AudioRecordingError?
    @Published private(set) var recoverableRecordingURLs: [URL]
    @Published private(set) var recoverableRecordingURL: URL?
    var hasMicrophonePermissionOverride: Bool?
    var inputAvailabilityOverride: ((AudioDeviceID?) -> Bool)?
    var startRecordingOverride: (() throws -> Void)?
    var stopRecordingOverride: ((StopPolicy) async -> [Float])?
    var onFirstRecordingAudioBuffer: (() -> Void)?

    /// CoreAudio device ID to use for recording. nil = system default input.
    var selectedDeviceID: AudioDeviceID? {
        get { configLock.withLock { _selectedDeviceID } }
        set {
            let changed = configLock.withLock { () -> Bool in
                guard _selectedDeviceID != newValue else { return false }
                _selectedDeviceID = newValue
                _selectedInputDeviceName = nil
                return true
            }
            if changed { invalidatePreparedRecordingInputs(reason: "selected-device-changed") }
        }
    }
    var hasExplicitDeviceSelection: Bool {
        get { configLock.withLock { _hasExplicitDeviceSelection } }
        set {
            let changed = configLock.withLock { () -> Bool in
                guard _hasExplicitDeviceSelection != newValue else { return false }
                _hasExplicitDeviceSelection = newValue
                return true
            }
            if changed { invalidatePreparedRecordingInputs(reason: "input-selection-mode-changed") }
        }
    }
    var selectedInputDeviceUsesBluetoothTransport: Bool {
        get { configLock.withLock { _selectedInputDeviceUsesBluetoothTransport } }
        set {
            let changed = configLock.withLock { () -> Bool in
                guard _selectedInputDeviceUsesBluetoothTransport != newValue else { return false }
                _selectedInputDeviceUsesBluetoothTransport = newValue
                return true
            }
            if changed { invalidatePreparedRecordingInputs(reason: "input-transport-changed") }
        }
    }
    var microphoneBoostEnabled: Bool {
        get { microphoneBoostEnabledLock.withLock { $0 } }
        set { microphoneBoostEnabledLock.withLock { $0 = newValue } }
    }
    private var _selectedDeviceID: AudioDeviceID?
    private var _hasExplicitDeviceSelection = false
    private var _selectedInputDeviceUsesBluetoothTransport = false
    private var _selectedInputDeviceName: String?

    private struct StartupConfigurationChangeGuard {
        let engineID: ObjectIdentifier
        let expectedSampleRate: Double
        let expectedChannelCount: AVAudioChannelCount

        init(engine: AVAudioEngine, expectedTapFormat: AVAudioFormat) {
            engineID = ObjectIdentifier(engine)
            expectedSampleRate = expectedTapFormat.sampleRate
            expectedChannelCount = expectedTapFormat.channelCount
        }

        func matches(_ liveFormat: AVAudioFormat) -> Bool {
            liveFormat.sampleRate == expectedSampleRate && liveFormat.channelCount == expectedChannelCount
        }
    }

    private struct PreparedBuiltInInput {
        let engine: AVAudioEngine
        let defaultInputDeviceID: AudioDeviceID
        let tapFormat: AVAudioFormat
    }

    private struct PreparedUSBInput {
        let session: AudioInputCaptureSession
        let deviceID: AudioDeviceID
    }

    private struct PreparedBluetoothInput {
        let engine: AVAudioEngine
        let deviceID: AudioDeviceID
        let tapFormat: AVAudioFormat
        let inputGeneration: UInt64
    }

    private struct ConfiguredEngineCapture {
        let inputNode: AVAudioInputNode
        let tapFormat: AVAudioFormat
        let bluetoothInputGeneration: UInt64?
    }

    private var audioEngine: AVAudioEngine?
    private var inputCaptureSession: AudioInputCaptureSession?
    private var preparedBuiltInInput: PreparedBuiltInInput?
    private var preparedUSBInput: PreparedUSBInput?
    private var preparedBluetoothInput: PreparedBluetoothInput?
    private var preparedInputGeneration: UInt64 = 0
    private var startupConfigurationChangeGuard: StartupConfigurationChangeGuard?
    private var configChangeObserver: NSObjectProtocol?
    private var sampleBuffer: [Float] = []
    private var _peakRawAudioLevel: Float = 0
    private let bufferLock = NSLock()
    private let microphoneBoostEnabledLock = OSAllocatedUnfairLock(initialState: false)
    private let microphoneBoostProcessor = MicrophoneBoostProcessor()
    private let configLock = NSLock()
    private let stopStateLock = NSLock()
    private let engineLock = NSLock()
    private let audioLevelPublishLock = NSLock()
    private let recordingActivityLock = OSAllocatedUnfairLock(initialState: false)
    private struct AsyncRecordingStartState {
        var nextRequestID: UInt64 = 0
        var activeRequestID: UInt64?
        var isCancelled = false
        var isCommitted = false
    }
    private let asyncRecordingStartState = OSAllocatedUnfairLock(initialState: AsyncRecordingStartState())
    private let recordingStartQueue = DispatchQueue(label: "com.typewhisper.audio-recording-start", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "com.typewhisper.audio-processing", qos: .userInteractive)
    private let recoveryQueue = DispatchQueue(label: "com.typewhisper.audio-recovery", qos: .userInitiated)
    private let engineTeardownRetainer = DelayedReleaseRetainer<AVAudioEngine>(label: "com.typewhisper.audio-engine-teardown")
    private let recoveryCoordinator = AudioEngineRecoveryCoordinator()
    private let recoveryAudioStore: DictationRecoveryAudioStore
    private let outputVolumeGuard: AudioOutputVolumeGuard
    private let inputActivationGuard: AudioInputDeviceActivating
    private let bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing
    private let inputReadinessChecker: AudioInputReadinessChecking
    private let inputCaptureFactory: AudioInputCaptureFactory
    private let defaultInputController: AudioInputDeviceDefaultControlling
    private let inputTransportResolver: AudioDeviceTransportResolving
    private let bluetoothInputStartupTracker = BluetoothInputStartupTracker()
    private var _lastStopGraceCaptureApplied = false
    private var recordingRequestUptimeNanoseconds: UInt64?
    private var hasLoggedFirstConvertedSample = false
    private var lastAudioLevelPublishUptimeNanoseconds: UInt64 = 0
    private var pendingAudioLevelUpdate: (level: Float, rms: Float)?
    private var isAudioLevelPublishScheduled = false

    static let targetSampleRate: Double = 16000
    private static let bluetoothInputReadinessTimeout: TimeInterval = 5.0
    private static let captureTapFrames: AVAudioFrameCount = 256
    private static let audioLevelPublishIntervalNanoseconds: UInt64 = 33_333_333
    private static let engineTeardownRetentionInterval: TimeInterval = 0.3
    private static let postRecordingInputPreparationDelay: TimeInterval = 0.25

    init(
        outputVolumeGuard: AudioOutputVolumeGuard = AudioOutputVolumeGuard(),
        inputActivationGuard: AudioInputDeviceActivating = AudioInputDeviceActivationGuard(),
        bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing = CoreAudioBluetoothInputRouteStabilizer(),
        inputReadinessChecker: AudioInputReadinessChecking = BluetoothInputReadinessChecker(),
        inputCaptureFactory: AudioInputCaptureFactory = CoreAudioHALInputCaptureFactory(),
        defaultInputController: AudioInputDeviceDefaultControlling = CoreAudioInputDeviceDefaultController(),
        inputTransportResolver: AudioDeviceTransportResolving = CoreAudioDeviceTransportResolver(),
        recoveryAudioStore: DictationRecoveryAudioStore = DictationRecoveryAudioStore()
    ) {
        self.outputVolumeGuard = outputVolumeGuard
        self.inputActivationGuard = inputActivationGuard
        self.bluetoothInputRouteStabilizer = bluetoothInputRouteStabilizer
        self.inputReadinessChecker = inputReadinessChecker
        self.inputCaptureFactory = inputCaptureFactory
        self.defaultInputController = defaultInputController
        self.inputTransportResolver = inputTransportResolver
        self.recoveryAudioStore = recoveryAudioStore
        let recoveryURLs = recoveryAudioStore.recoveryURLs
        self.recoverableRecordingURLs = recoveryURLs
        self.recoverableRecordingURL = recoveryURLs.first
        recoveryNotificationQueue.underlyingQueue = recoveryQueue
    }

    var peakRawAudioLevel: Float {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _peakRawAudioLevel
    }

    private var isRecordingActive: Bool {
        recordingActivityLock.withLock { $0 }
    }

    private func setRecordingActive(_ active: Bool) {
        recordingActivityLock.withLock { $0 = active }
        if Thread.isMainThread {
            isRecording = active
        } else {
            DispatchQueue.main.sync { [self] in
                isRecording = active
            }
        }
    }

    private func publishRecoveryError(_ error: AudioRecordingError?) {
        if Thread.isMainThread {
            recoveryError = error
        } else {
            DispatchQueue.main.sync { [self] in
                recoveryError = error
            }
        }
    }

    var lastStopGraceCaptureApplied: Bool {
        stopStateLock.withLock { _lastStopGraceCaptureApplied }
    }

    var hasMicrophonePermission: Bool {
        if let hasMicrophonePermissionOverride {
            return hasMicrophonePermissionOverride
        }
        return AVAudioApplication.shared.recordPermission == .granted
    }

    func requestMicrophonePermission() async -> Bool {
        let permission = AVAudioApplication.shared.recordPermission
        if permission == .granted {
            prepareRecordingInputIfEligible()
            return true
        }
        if permission == .undetermined {
            // Request permission via the official AVAudioApplication API
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted { prepareRecordingInputIfEligible() }
            return granted
        }
        // .denied — open System Settings so user can grant manually
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        return false
    }

    /// Prepares the automatic built-in microphone or explicitly selected USB input
    /// without starting capture. If the user explicitly opts in, an active AirPods
    /// stream can also be kept ready and reused by the next recording.
    func prepareRecordingInputIfEligible() {
        scheduleRecordingInputPreparation(after: 0)
    }

    func configureInputSelection(
        deviceID: AudioDeviceID?,
        hasExplicitDeviceSelection: Bool,
        usesBluetoothTransport: Bool,
        deviceName: String? = nil
    ) {
        let changed = configLock.withLock { () -> Bool in
            let changed = _selectedDeviceID != deviceID
                || _hasExplicitDeviceSelection != hasExplicitDeviceSelection
                || _selectedInputDeviceUsesBluetoothTransport != usesBluetoothTransport
                || _selectedInputDeviceName != deviceName
            _selectedDeviceID = deviceID
            _hasExplicitDeviceSelection = hasExplicitDeviceSelection
            _selectedInputDeviceUsesBluetoothTransport = usesBluetoothTransport
            _selectedInputDeviceName = deviceName
            return changed
        }
        if changed {
            inputSelectionDidChange(reason: "input-selection-changed")
        } else {
            prepareRecordingInputIfEligible()
        }
    }

    func handleAirPodsInstantStartPreferenceChange() {
        recordingStartQueue.async { [weak self] in
            guard let self else { return }
            self.invalidatePreparedRecordingInputs(reason: "airpods-instant-start-setting-changed")
            self.performRecordingInputPreparationIfEligible()
        }
    }

    private func scheduleRecordingInputPreparation(after delay: TimeInterval) {
        recordingStartQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performRecordingInputPreparationIfEligible()
        }
    }

    func handleSystemWake() {
        invalidatePreparedRecordingInputs(reason: "system-wake")
        prepareRecordingInputIfEligible()
    }

    private func inputSelectionDidChange(reason: String) {
        invalidatePreparedRecordingInputs(reason: reason)
        prepareRecordingInputIfEligible()
    }

    private func performRecordingInputPreparationIfEligible() {
        if bluetoothInputPreparationDeviceID() != nil {
            performBluetoothInputPreparationIfEligible()
        } else if builtInInputPreparationDeviceID() != nil {
            performBuiltInInputPreparationIfEligible()
        } else if usbInputPreparationDeviceID() != nil {
            performUSBInputPreparationIfEligible()
        }
    }

    private func bluetoothInputPreparationDeviceID() -> AudioDeviceID? {
        let selection = configLock.withLock {
            (
                selectedDeviceID: _selectedDeviceID,
                selectedDeviceName: _selectedInputDeviceName,
                usesBluetoothTransport: _selectedInputDeviceUsesBluetoothTransport
            )
        }
        guard AirPodsRecordingInputPreparationPolicy.isEligible(
            hasMicrophonePermission: hasMicrophonePermission,
            isEnabled: UserDefaults.standard.bool(forKey: UserDefaultsKeys.airPodsInstantStartEnabled),
            selectedDeviceID: selection.selectedDeviceID,
            selectedDeviceName: selection.selectedDeviceName,
            usesBluetoothTransport: selection.usesBluetoothTransport
        ), let selectedDeviceID = selection.selectedDeviceID else {
            return nil
        }
        return selectedDeviceID
    }

    private func builtInInputPreparationDeviceID() -> AudioDeviceID? {
        let selection = configLock.withLock {
            (
                selectedDeviceID: _selectedDeviceID,
                hasExplicitDeviceSelection: _hasExplicitDeviceSelection,
                usesBluetoothTransport: _selectedInputDeviceUsesBluetoothTransport
            )
        }
        let defaultInputDeviceID = defaultInputController.defaultInputDeviceID()
        let defaultInputTransport = defaultInputDeviceID.flatMap {
            inputTransportResolver.transportType(for: $0)
        }

        guard BuiltInRecordingInputPreparationPolicy.isEligible(
            hasMicrophonePermission: hasMicrophonePermission,
            selectedDeviceID: selection.selectedDeviceID,
            hasExplicitDeviceSelection: selection.hasExplicitDeviceSelection,
            usesBluetoothTransport: selection.usesBluetoothTransport,
            defaultInputDeviceID: defaultInputDeviceID,
            defaultInputTransport: defaultInputTransport
        ) else {
            return nil
        }
        return defaultInputDeviceID
    }

    private func performBuiltInInputPreparationIfEligible() {
        guard !isRecordingActive,
              let defaultInputDeviceID = builtInInputPreparationDeviceID() else {
            return
        }

        let alreadyPrepared = engineLock.withLock {
            preparedBuiltInInput?.defaultInputDeviceID == defaultInputDeviceID
        }
        guard !alreadyPrepared else { return }
        let preparationGeneration = engineLock.withLock { preparedInputGeneration }

        let engine = AVAudioEngine()
        let preparationStart = CFAbsoluteTimeGetCurrent()
        do {
            let configuredCapture = try configureEngineCapture(
                engine,
                label: "built-in-prewarm",
                readinessDeadline: nil,
                shouldCancel: { false }
            )
            engine.prepare()

            guard !isRecordingActive,
                  builtInInputPreparationDeviceID() == defaultInputDeviceID else {
                teardownPreparedEngine(engine)
                return
            }

            let preparedInput = PreparedBuiltInInput(
                engine: engine,
                defaultInputDeviceID: defaultInputDeviceID,
                tapFormat: configuredCapture.tapFormat
            )
            let storageResult = engineLock.withLock { () -> (stored: Bool, replaced: PreparedBuiltInInput?) in
                guard preparedInputGeneration == preparationGeneration,
                      audioEngine == nil,
                      inputCaptureSession == nil else {
                    return (false, preparedInput)
                }
                let previous = preparedBuiltInInput
                preparedBuiltInInput = preparedInput
                return (true, previous)
            }
            if let replacedInput = storageResult.replaced {
                teardownPreparedEngine(replacedInput.engine)
            }
            guard storageResult.stored else { return }

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - preparationStart) * 1000
            logger.info(
                "Prepared built-in recording input without starting capture in \(String(format: "%.1f", elapsedMs), privacy: .public)ms"
            )
        } catch {
            teardownPreparedEngine(engine)
            logger.warning(
                "Could not prepare built-in recording input; keeping cold-start fallback: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func usbInputPreparationDeviceID() -> AudioDeviceID? {
        let selection = configLock.withLock {
            (
                selectedDeviceID: _selectedDeviceID,
                hasExplicitDeviceSelection: _hasExplicitDeviceSelection,
                usesBluetoothTransport: _selectedInputDeviceUsesBluetoothTransport
            )
        }
        let selectedInputTransport = selection.selectedDeviceID.flatMap {
            inputTransportResolver.transportType(for: $0)
        }
        guard USBRecordingInputPreparationPolicy.isEligible(
            hasMicrophonePermission: hasMicrophonePermission,
            selectedDeviceID: selection.selectedDeviceID,
            hasExplicitDeviceSelection: selection.hasExplicitDeviceSelection,
            usesBluetoothTransport: selection.usesBluetoothTransport,
            selectedInputTransport: selectedInputTransport
        ) else {
            return nil
        }
        return selection.selectedDeviceID
    }

    private func performUSBInputPreparationIfEligible() {
        guard !isRecordingActive,
              let deviceID = usbInputPreparationDeviceID() else {
            return
        }

        let alreadyPrepared = engineLock.withLock {
            preparedUSBInput?.deviceID == deviceID
        }
        guard !alreadyPrepared else { return }
        let preparationGeneration = engineLock.withLock { preparedInputGeneration }
        let preparationStart = CFAbsoluteTimeGetCurrent()

        do {
            let preparedInput = try prepareInputOnlyRecording(deviceID: deviceID, label: "usb-prewarm")
            guard !isRecordingActive,
                  usbInputPreparationDeviceID() == deviceID else {
                preparedInput.session.stop()
                return
            }

            let storageResult = engineLock.withLock { () -> (stored: Bool, replaced: PreparedUSBInput?) in
                guard preparedInputGeneration == preparationGeneration,
                      audioEngine == nil,
                      inputCaptureSession == nil else {
                    return (false, preparedInput)
                }
                let previous = preparedUSBInput
                preparedUSBInput = preparedInput
                return (true, previous)
            }
            storageResult.replaced?.session.stop()
            guard storageResult.stored else { return }

            let elapsedMs = (CFAbsoluteTimeGetCurrent() - preparationStart) * 1000
            logger.info(
                "Prepared selected USB recording input without starting capture in \(String(format: "%.1f", elapsedMs), privacy: .public)ms"
            )
        } catch {
            logger.warning(
                "Could not prepare selected USB recording input; keeping cold-start fallback: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performBluetoothInputPreparationIfEligible() {
        guard !isRecordingActive,
              let deviceID = bluetoothInputPreparationDeviceID() else {
            return
        }

        let alreadyPrepared = engineLock.withLock {
            preparedBluetoothInput?.deviceID == deviceID
        }
        guard !alreadyPrepared else { return }
        let preparationGeneration = engineLock.withLock { preparedInputGeneration }
        let preparationStart = CFAbsoluteTimeGetCurrent()
        let engine = AVAudioEngine()
        let readinessDeadline = CFAbsoluteTimeGetCurrent() + Self.bluetoothInputReadinessTimeout

        outputVolumeGuard.captureBaseline()
        guard inputActivationGuard.activateIfNeeded(
            deviceID: deviceID,
            usesBluetoothTransport: true,
            reason: "airpods-instant-start-prewarm"
        ) else {
            outputVolumeGuard.clear()
            return
        }

        do {
            try waitForBluetoothRouteStabilizationIfNeeded(
                inputDeviceID: deviceID,
                usesBluetoothTransport: true,
                reason: "airpods-instant-start-prewarm",
                readinessDeadline: readinessDeadline,
                shouldCancel: { false }
            )
            let configuredCapture = try configureEngineCapture(
                engine,
                label: "airpods-instant-start-prewarm",
                readinessDeadline: readinessDeadline,
                shouldCancel: { false }
            )
            guard let inputGeneration = configuredCapture.bluetoothInputGeneration else {
                throw AudioRecordingError.engineStartFailed("Missing Bluetooth input generation")
            }
            try engine.start()
            try waitForInitialInputReadinessIfNeeded(
                label: "airpods-instant-start-prewarm",
                generation: inputGeneration,
                deadline: readinessDeadline,
                isEngineRunning: { engine.isRunning },
                shouldCancel: { false }
            )
            bluetoothInputStartupTracker.disarm(generation: inputGeneration)

            guard !isRecordingActive,
                  bluetoothInputPreparationDeviceID() == deviceID else {
                teardownPreparedEngine(engine)
                bluetoothInputStartupTracker.reset()
                inputActivationGuard.restore(reason: "airpods-instant-start-prewarm-ineligible")
                outputVolumeGuard.clear()
                return
            }

            let preparedInput = PreparedBluetoothInput(
                engine: engine,
                deviceID: deviceID,
                tapFormat: configuredCapture.tapFormat,
                inputGeneration: inputGeneration
            )
            let storageResult = engineLock.withLock { () -> (stored: Bool, replaced: PreparedBluetoothInput?) in
                guard preparedInputGeneration == preparationGeneration,
                      audioEngine == nil,
                      inputCaptureSession == nil else {
                    return (false, preparedInput)
                }
                let previous = preparedBluetoothInput
                preparedBluetoothInput = preparedInput
                return (true, previous)
            }
            if let replacedInput = storageResult.replaced {
                teardownPreparedEngine(replacedInput.engine)
            }
            guard storageResult.stored else {
                bluetoothInputStartupTracker.reset()
                inputActivationGuard.restore(reason: "airpods-instant-start-prewarm-not-stored")
                outputVolumeGuard.clear()
                return
            }

            outputVolumeGuard.restoreIfRaised(reason: "airpods-instant-start-prewarm")
            outputVolumeGuard.clear()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - preparationStart) * 1000
            logger.warning(
                "AirPods Instant Start is ready in \(String(format: "%.1f", elapsedMs), privacy: .public)ms"
            )
        } catch {
            teardownPreparedEngine(engine)
            bluetoothInputStartupTracker.reset()
            inputActivationGuard.restore(reason: "airpods-instant-start-prewarm-failed")
            outputVolumeGuard.restoreIfRaised(reason: "airpods-instant-start-prewarm-failed")
            outputVolumeGuard.clear()
            logger.warning(
                "AirPods Instant Start preparation failed; keeping cold-start fallback: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func claimPreparedBuiltInInputIfEligible() -> PreparedBuiltInInput? {
        guard let defaultInputDeviceID = builtInInputPreparationDeviceID() else {
            invalidatePreparedRecordingInputs(reason: "recording-route-ineligible")
            return nil
        }

        var staleInput: PreparedBuiltInInput?
        let claimedInput = engineLock.withLock { () -> PreparedBuiltInInput? in
            guard let preparedInput = preparedBuiltInInput else { return nil }
            preparedBuiltInInput = nil
            guard preparedInput.defaultInputDeviceID == defaultInputDeviceID,
                  audioEngine == nil,
                  inputCaptureSession == nil else {
                staleInput = preparedInput
                return nil
            }
            audioEngine = preparedInput.engine
            startupConfigurationChangeGuard = nil
            return preparedInput
        }
        if let staleInput {
            teardownPreparedEngine(staleInput.engine)
        }
        return claimedInput
    }

    private func claimPreparedUSBInputIfEligible(deviceID: AudioDeviceID) -> PreparedUSBInput? {
        guard usbInputPreparationDeviceID() == deviceID else {
            invalidatePreparedRecordingInputs(reason: "usb-recording-route-ineligible")
            return nil
        }

        var staleInput: PreparedUSBInput?
        let claimedInput = engineLock.withLock { () -> PreparedUSBInput? in
            guard let preparedInput = preparedUSBInput else { return nil }
            preparedUSBInput = nil
            guard preparedInput.deviceID == deviceID,
                  audioEngine == nil,
                  inputCaptureSession == nil else {
                staleInput = preparedInput
                return nil
            }
            return preparedInput
        }
        staleInput?.session.stop()
        return claimedInput
    }

    private func claimPreparedBluetoothInputIfEligible() -> PreparedBluetoothInput? {
        guard let deviceID = bluetoothInputPreparationDeviceID() else {
            invalidatePreparedRecordingInputs(reason: "bluetooth-recording-route-ineligible")
            return nil
        }

        var staleInput: PreparedBluetoothInput?
        let claimedInput = engineLock.withLock { () -> PreparedBluetoothInput? in
            guard let preparedInput = preparedBluetoothInput else { return nil }
            preparedBluetoothInput = nil
            guard preparedInput.deviceID == deviceID,
                  preparedInput.engine.isRunning,
                  audioEngine == nil,
                  inputCaptureSession == nil else {
                staleInput = preparedInput
                return nil
            }
            audioEngine = preparedInput.engine
            startupConfigurationChangeGuard = nil
            return preparedInput
        }
        if let staleInput {
            teardownPreparedEngine(staleInput.engine)
            bluetoothInputStartupTracker.reset()
            inputActivationGuard.restore(reason: "airpods-instant-start-prewarm-stale")
        } else if claimedInput != nil {
            inputActivationGuard.restore(reason: "airpods-instant-start-prewarm-claimed")
        }
        return claimedInput
    }

    private func invalidatePreparedRecordingInputs(reason: String) {
        let preparedInputs = engineLock.withLock { () -> (PreparedBuiltInInput?, PreparedUSBInput?, PreparedBluetoothInput?) in
            preparedInputGeneration &+= 1
            let builtInInput = preparedBuiltInInput
            let usbInput = preparedUSBInput
            let bluetoothInput = preparedBluetoothInput
            preparedBuiltInInput = nil
            preparedUSBInput = nil
            preparedBluetoothInput = nil
            return (builtInInput, usbInput, bluetoothInput)
        }
        if let builtInInput = preparedInputs.0 {
            teardownPreparedEngine(builtInInput.engine)
        }
        preparedInputs.1?.session.stop()
        if let bluetoothInput = preparedInputs.2 {
            teardownPreparedEngine(bluetoothInput.engine)
            bluetoothInputStartupTracker.reset()
            inputActivationGuard.restore(reason: "airpods-instant-start-prewarm-invalidated")
        }
        guard preparedInputs.0 != nil || preparedInputs.1 != nil || preparedInputs.2 != nil else { return }
        logger.info("Invalidated prepared recording input: \(reason, privacy: .public)")
    }

    /// Thread-safe snapshot of the current recording buffer for streaming transcription.
    func getCurrentBuffer() -> [Float] {
        bufferLock.lock()
        let copy = Array(sampleBuffer)
        bufferLock.unlock()
        return copy
    }

    /// Returns at most the last `maxDuration` seconds of audio for streaming.
    func getRecentBuffer(maxDuration: TimeInterval) -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let maxSamples = Int(maxDuration * Self.targetSampleRate)
        if sampleBuffer.count <= maxSamples { return sampleBuffer }
        return Array(sampleBuffer.suffix(maxSamples))
    }

    /// Returns audio appended since `sampleOffset` and the updated absolute offset.
    func getBufferDelta(since sampleOffset: Int) -> (samples: [Float], nextOffset: Int) {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let clampedOffset = max(0, min(sampleOffset, sampleBuffer.count))
        let samples = Array(sampleBuffer.dropFirst(clampedOffset))
        return (samples, sampleBuffer.count)
    }

    /// Total duration of the recorded audio in seconds.
    var totalBufferDuration: TimeInterval {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Double(sampleBuffer.count) / Self.targetSampleRate
    }

    /// Build a mono tap format from a (possibly multi-channel) input format.
    ///
    /// AVAudioConverter silently produces zero-filled output when asked to downmix
    /// non-standard multi-channel layouts (e.g. 6-channel USB interfaces like
    /// Focusrite Scarlett) to mono. By requesting a mono tap format, AVAudioEngine
    /// performs the channel downmix internally — which handles arbitrary layouts
    /// correctly — and the converter only needs to resample.
    private static func tapFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        if inputFormat.channelCount == 3 {
            return inputFormat
        }
        if inputFormat.channelCount > 1,
           let mono = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: inputFormat.sampleRate,
               channels: 1,
               interleaved: false
           ) {
            return mono
        }
        return inputFormat
    }

    func startRecording(requestUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        try performStartRecording(
            requestUptimeNanoseconds: requestUptimeNanoseconds,
            shouldCancel: { false },
            commitStart: { true }
        )
    }

    func startRecordingAsync(
        requestUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) async throws {
        let requestID = asyncRecordingStartState.withLock { state -> UInt64 in
            state.nextRequestID &+= 1
            state.activeRequestID = state.nextRequestID
            state.isCancelled = false
            state.isCommitted = false
            return state.nextRequestID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recordingStartQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    defer {
                        self.asyncRecordingStartState.withLock { state in
                            if state.activeRequestID == requestID {
                                state.activeRequestID = nil
                                state.isCancelled = false
                                state.isCommitted = false
                            }
                        }
                    }

                    do {
                        try self.performStartRecording(
                            requestUptimeNanoseconds: requestUptimeNanoseconds,
                            shouldCancel: { [weak self] in
                                self?.isRecordingStartCancelled(requestID: requestID) ?? true
                            },
                            commitStart: { [weak self] in
                                self?.commitRecordingStart(requestID: requestID) ?? false
                            }
                        )
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            asyncRecordingStartState.withLock { state in
                guard state.activeRequestID == requestID, !state.isCommitted else { return }
                state.isCancelled = true
            }
        }
    }

    func cancelPendingRecordingStart() {
        asyncRecordingStartState.withLock { state in
            guard state.activeRequestID != nil, !state.isCommitted else { return }
            state.isCancelled = true
        }
    }

    private func isRecordingStartCancelled(requestID: UInt64) -> Bool {
        asyncRecordingStartState.withLock { state in
            state.activeRequestID != requestID || state.isCancelled
        }
    }

    private func commitRecordingStart(requestID: UInt64) -> Bool {
        asyncRecordingStartState.withLock { state in
            guard state.activeRequestID == requestID,
                  !state.isCancelled,
                  !state.isCommitted else {
                return false
            }
            state.isCommitted = true
            return true
        }
    }

    private func throwIfRecordingStartCancelled(_ shouldCancel: () -> Bool) throws {
        if shouldCancel() {
            throw CancellationError()
        }
    }

    private func throwIfRecordingStartExpired(_ deadline: TimeInterval?) throws {
        guard let deadline, CFAbsoluteTimeGetCurrent() >= deadline else { return }
        throw AudioRecordingError.noAudioData
    }

    private func waitBeforeRecordingStartRetry(
        _ delay: TimeInterval,
        readinessDeadline: TimeInterval?,
        shouldCancel: () -> Bool
    ) throws {
        let requestedEnd = CFAbsoluteTimeGetCurrent() + delay
        let end = min(requestedEnd, readinessDeadline ?? requestedEnd)
        while CFAbsoluteTimeGetCurrent() < end {
            try throwIfRecordingStartCancelled(shouldCancel)
            let remaining = end - CFAbsoluteTimeGetCurrent()
            Thread.sleep(forTimeInterval: min(0.01, max(0, remaining)))
        }
        try throwIfRecordingStartCancelled(shouldCancel)
        try throwIfRecordingStartExpired(readinessDeadline)
    }

    private func performStartRecording(
        requestUptimeNanoseconds: UInt64,
        shouldCancel: @escaping () -> Bool,
        commitStart: @escaping () -> Bool
    ) throws {
        try throwIfRecordingStartCancelled(shouldCancel)
        guard hasMicrophonePermission else {
            throw AudioRecordingError.microphonePermissionDenied
        }
        let readinessDeadline = requiresInitialInputReadiness
            ? CFAbsoluteTimeGetCurrent() + Self.bluetoothInputReadinessTimeout
            : nil

        // Clear any terminal-recovery error from a previous session so the
        // view model doesn't see a stale failure on the first buffer update.
        publishRecoveryError(nil)

        try validateRecordingInputAvailability()
        try throwIfRecordingStartCancelled(shouldCancel)
        try throwIfRecordingStartExpired(readinessDeadline)
        clearRecordingBuffer(requestUptimeNanoseconds: requestUptimeNanoseconds)
        recoveryAudioStore.startNewRecording()
        publishRecoverableRecordingURLs(recoveryAudioStore.recoveryURLs)

        let routeActivationRequest = selectedRouteActivationRequest
        outputVolumeGuard.captureBaseline()

        guard inputActivationGuard.activateIfNeeded(
            deviceID: routeActivationRequest.inputDeviceID,
            usesBluetoothTransport: routeActivationRequest.usesBluetoothTransport,
            reason: "recording-start"
        ) else {
            outputVolumeGuard.restoreIfRaised(reason: "recording-start-input-activation-failed")
            outputVolumeGuard.clear()
            discardActiveRecoveryRecording(keepingLatest: true)
            throw AudioRecordingError.audioRoutingConflict
        }

        do {
            try waitForBluetoothRouteStabilizationIfNeeded(
                inputDeviceID: routeActivationRequest.inputDeviceID,
                usesBluetoothTransport: routeActivationRequest.usesBluetoothTransport,
                reason: "recording-start",
                readinessDeadline: readinessDeadline,
                shouldCancel: shouldCancel
            )
        } catch {
            outputVolumeGuard.restoreIfRaised(reason: "recording-start-route-stabilization-failed")
            outputVolumeGuard.clear()
            inputActivationGuard.restore(reason: "recording-start-route-stabilization-failed")
            discardActiveRecoveryRecording(keepingLatest: true)
            throw error
        }
        do {
            try throwIfRecordingStartCancelled(shouldCancel)
            try throwIfRecordingStartExpired(readinessDeadline)
        } catch {
            outputVolumeGuard.restoreIfRaised(reason: "recording-start-cancelled")
            outputVolumeGuard.clear()
            inputActivationGuard.restore(reason: "recording-start-cancelled")
            discardActiveRecoveryRecording(keepingLatest: true)
            throw error
        }

        if let startRecordingOverride {
            bufferLock.lock()
            sampleBuffer.removeAll()
            _peakRawAudioLevel = 0
            bufferLock.unlock()
            do {
                try startRecordingOverride()
                try throwIfRecordingStartCancelled(shouldCancel)
                guard commitStart() else { throw CancellationError() }
                outputVolumeGuard.restoreIfRaised(reason: "recording-start-override")
                outputVolumeGuard.clear()
                setRecordingActive(true)
            } catch {
                outputVolumeGuard.restoreIfRaised(reason: "recording-start-override-failed")
                outputVolumeGuard.clear()
                inputActivationGuard.restore(reason: "recording-start-override-failed")
                discardActiveRecoveryRecording(keepingLatest: true)
                throw error
            }
            return
        }

        if case .inputOnlyDevice(let inputOnlyDeviceID) = selectedCaptureRoute {
            do {
                if let preparedInput = claimPreparedUSBInputIfEligible(deviceID: inputOnlyDeviceID) {
                    do {
                        try startPreparedInputOnlyRecording(preparedInput, label: "recording")
                    } catch {
                        logger.warning(
                            "recording prepared USB input was stale; retrying with cold-start fallback: \(error.localizedDescription, privacy: .public)"
                        )
                        try startInputOnlyRecording(deviceID: inputOnlyDeviceID, label: "recording-usb-cold-fallback")
                    }
                } else {
                    try startInputOnlyRecording(deviceID: inputOnlyDeviceID, label: "recording")
                }
                try throwIfRecordingStartCancelled(shouldCancel)
                guard commitStart() else { throw CancellationError() }
                outputVolumeGuard.restoreIfRaised(reason: "recording-start")
                outputVolumeGuard.clear()
                setRecordingActive(true)
            } catch {
                cleanupAfterFailedInputOnlyStart()
                discardActiveRecoveryRecording(keepingLatest: true)
                throw error
            }
            return
        }

        let preparedBluetoothInput = claimPreparedBluetoothInputIfEligible()
        let preparedBuiltInInput = preparedBluetoothInput == nil
            ? claimPreparedBuiltInInputIfEligible()
            : nil
        let engine = preparedBluetoothInput?.engine ?? preparedBuiltInInput?.engine ?? AVAudioEngine()
        if preparedBluetoothInput == nil, preparedBuiltInInput == nil {
            engineLock.withLock {
                audioEngine = engine
                inputCaptureSession = nil
                startupConfigurationChangeGuard = nil
            }
        }
        recoveryCoordinator.beginStarting()
        installConfigurationObserver(for: engine)

        do {
            if let preparedBluetoothInput {
                try startPreparedBluetoothEngineWithFallback(
                    preparedBluetoothInput,
                    label: "recording",
                    readinessDeadline: readinessDeadline,
                    shouldCancel: shouldCancel
                )
            } else if let preparedBuiltInInput {
                try startPreparedBuiltInEngineWithFallback(
                    preparedBuiltInInput,
                    label: "recording",
                    readinessDeadline: readinessDeadline,
                    shouldCancel: shouldCancel
                )
            } else {
                try startEngineWithRecovery(
                    engine,
                    label: "recording",
                    readinessDeadline: readinessDeadline,
                    shouldCancel: shouldCancel
                )
            }

            if recoveryCoordinator.finishStartingSuccessfully() == .performImmediateRecovery {
                guard let currentEngine = engineLock.withLock({ audioEngine }) else {
                    throw AudioRecordingError.engineStartFailed("Recording engine disappeared during startup recovery")
                }
                if consumeStartupConfigurationChangeGuardIfNeeded(for: currentEngine) {
                    logger.info("Ignoring benign post-start audio engine configuration change after tap renegotiation")
                } else {
                    logger.warning("Audio engine configuration changed while recording was starting, restarting with fresh input format")
                    try restartEngineWithRecovery(
                        currentEngine,
                        label: "recording-startup",
                        readinessDeadline: readinessDeadline,
                        shouldCancel: shouldCancel
                    )
                }
                scheduleRecoveryIfNeeded(recoveryCoordinator.finishRecovery())
            }

            try throwIfRecordingStartCancelled(shouldCancel)
            guard commitStart() else { throw CancellationError() }
            finishBluetoothInputStartupIfNeeded()
            outputVolumeGuard.restoreIfRaised(reason: "recording-start")
            outputVolumeGuard.clear()
            setRecordingActive(true)
        } catch {
            let failedEngine = engineLock.withLock { audioEngine } ?? engine
            cleanupAfterFailedStart(failedEngine)
            discardActiveRecoveryRecording(keepingLatest: true)
            throw error
        }
    }

    func stopRecording(policy: StopPolicy) async -> [Float] {
        if let stopRecordingOverride {
            outputVolumeGuard.captureBaseline()
            let samples = await stopRecordingOverride(policy)
            outputVolumeGuard.restoreIfRaised(reason: "recording-stop-override")
            outputVolumeGuard.clear()
            inputActivationGuard.restore(reason: "recording-stop-override")
            let rms: Float
            if samples.isEmpty {
                rms = 0
            } else {
                rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
            }
            let normalizedLevel = AudioLevelMeter.normalizedLevel(rms: rms)

            bufferLock.withLock {
                _peakRawAudioLevel = rms
            }

            setLastStopGraceCaptureApplied(false)
            setRecordingActive(false)
            resetAudioLevelPublishing()
            DispatchQueue.main.async { [weak self] in
                self?.audioLevel = normalizedLevel
                self?.rawAudioLevel = rms
            }
            return samples
        }

        // Atomically claim the engine - only the first concurrent caller proceeds
        let capture: (engine: AVAudioEngine?, inputCaptureSession: AudioInputCaptureSession?) = engineLock.withLock {
            let capture = (engine: audioEngine, inputCaptureSession: inputCaptureSession)
            audioEngine = nil
            inputCaptureSession = nil
            startupConfigurationChangeGuard = nil
            return capture
        }
        setRecordingActive(false)
        if let inputCaptureSession = capture.inputCaptureSession {
            let bufferedDuration = totalBufferDuration
            var graceApplied = false

            if policy.shouldApplyGracePeriod(bufferedDuration: bufferedDuration),
               case .finalizeShortSpeech(_, let maxExtraCapture, let pollInterval) = policy {
                let deadline = Date().addingTimeInterval(maxExtraCapture)
                graceApplied = true

                while Date() < deadline, policy.shouldApplyGracePeriod(bufferedDuration: totalBufferDuration) {
                    try? await Task.sleep(for: .seconds(pollInterval))
                }
            }

            setLastStopGraceCaptureApplied(graceApplied)
            recoveryCoordinator.transitionToIdle()
            removeConfigurationObserver()
            outputVolumeGuard.captureBaseline()
            inputCaptureSession.stop()
            outputVolumeGuard.restoreIfRaised(reason: "recording-stop")
            outputVolumeGuard.clear()
            inputActivationGuard.restore(reason: "recording-stop")
            processingQueue.sync { }

            let samples = drainSampleBuffer()

            resetAudioLevelPublishing()
            DispatchQueue.main.async { [weak self] in
                self?.audioLevel = 0
                self?.rawAudioLevel = 0
            }

            scheduleRecordingInputPreparation(after: Self.postRecordingInputPreparationDelay)

            return samples
        }

        guard let engine = capture.engine else {
            outputVolumeGuard.clear()
            return []
        }

        let bufferedDuration = totalBufferDuration
        var graceApplied = false

        if policy.shouldApplyGracePeriod(bufferedDuration: bufferedDuration),
           case .finalizeShortSpeech(_, let maxExtraCapture, let pollInterval) = policy {
            let deadline = Date().addingTimeInterval(maxExtraCapture)
            graceApplied = true

            while Date() < deadline, policy.shouldApplyGracePeriod(bufferedDuration: totalBufferDuration) {
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }

        setLastStopGraceCaptureApplied(graceApplied)
        recoveryCoordinator.transitionToIdle()

        removeConfigurationObserver()
        outputVolumeGuard.captureBaseline()
        teardownEngine(engine)
        // Keep the engine alive briefly so CoreAudio's internal teardown callbacks
        // cannot outlive the AVAudioEngine objects they still reference.
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
        outputVolumeGuard.restoreIfRaised(reason: "recording-stop")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "recording-stop")

        // Flush pending audio processing before grabbing the buffer
        processingQueue.sync { }

        let samples = drainSampleBuffer()

        resetAudioLevelPublishing()
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = 0
            self?.rawAudioLevel = 0
        }

        scheduleRecordingInputPreparation(after: Self.postRecordingInputPreparationDelay)

        return samples
    }

    /// Re-setup the audio engine after a system configuration change (e.g. notification sound).
    /// Preserves already-buffered samples so no audio is lost.
    private func handleConfigurationChangeNotification() {
        scheduleRecoveryIfNeeded(recoveryCoordinator.noteConfigurationChange())
    }

    private func scheduleRecoveryIfNeeded(_ action: AudioEngineRecoveryAction) {
        switch action {
        case .none, .performImmediateRecovery:
            return
        case .schedule(let generation, let delay):
            recoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performScheduledRecovery(generation: generation)
            }
        case .fail(let failure):
            handleRecoveryFailure(failure)
        }
    }

    private func performScheduledRecovery(generation: UInt64) {
        guard recoveryCoordinator.beginScheduledRecovery(generation: generation) else { return }
        defer {
            scheduleRecoveryIfNeeded(recoveryCoordinator.finishRecovery())
        }

        let engine: AVAudioEngine? = engineLock.withLock { audioEngine }
        guard isRecordingActive, let engine else { return }

        if consumeStartupConfigurationChangeGuardIfNeeded(for: engine) {
            logger.info("Ignoring benign post-start audio engine configuration change after tap renegotiation")
            return
        }

        logger.warning("Audio engine configuration changed during recording, restarting engine")

        do {
            try restartEngineWithRecovery(engine, label: "config-change")
        } catch {
            logger.error("Failed to restart audio engine after configuration change: \(error.localizedDescription)")
        }
    }

    private func handleRecoveryFailure(_ failure: AudioEngineRecoveryFailure) {
        let error: AudioRecordingError
        switch failure {
        case .configurationChangeBurstLimitExceeded:
            logger.error("Audio engine recovery circuit breaker tripped after repeated configuration changes")
            if hasExplicitDeviceSelection {
                error = .audioRoutingConflict
            } else {
                error = .engineStartFailed("Audio engine kept restarting after repeated configuration changes")
            }
        }

        failActiveRecordingDueToRecovery(error)
    }

    private func failActiveRecordingDueToRecovery(_ error: AudioRecordingError) {
        setRecordingActive(false)
        recoveryCoordinator.transitionToIdle()
        removeConfigurationObserver()
        outputVolumeGuard.captureBaselineIfNeeded()
        let engine: AVAudioEngine? = engineLock.withLock {
            let engine = audioEngine
            audioEngine = nil
            startupConfigurationChangeGuard = nil
            return engine
        }
        if let engine {
            teardownEngine(engine)
            engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
        }
        outputVolumeGuard.restoreIfRaised(reason: "recording-recovery-failure")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "recording-recovery-failure")
        processingQueue.sync { }
        let recoveryURL = preserveActiveRecoveryRecording()
        let recoveryURLs = recoveryRecordingURLs
        clearRecordingBuffer()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recoveryError = error
            self.audioLevel = 0
            self.rawAudioLevel = 0
            self.recoverableRecordingURLs = recoveryURLs
            self.recoverableRecordingURL = recoveryURL
        }
    }

    private func installConfigurationObserver(for engine: AVAudioEngine) {
        removeConfigurationObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: recoveryNotificationQueue
        ) { [weak self] _ in
            self?.handleConfigurationChangeNotification()
        }
    }

    private func removeConfigurationObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func startEngineWithRecovery(
        _ engine: AVAudioEngine,
        label: String,
        readinessDeadline: TimeInterval? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws {
        let explicitDeviceSelected = hasExplicitDeviceSelection
        let selectedBluetoothDevice = requiresInitialInputReadiness
        let effectiveReadinessDeadline = readinessDeadline ?? (
            selectedBluetoothDevice
                ? CFAbsoluteTimeGetCurrent() + Self.bluetoothInputReadinessTimeout
                : nil
        )
        var currentEngine = engine
        // Main-thread callers (e.g. startRecording from hotkey) get a bounded
        // backoff to keep UI responsive; the observer-based recovery queue
        // uses the full schedule. See AudioEngineRecoveryPolicy.
        let backoff = AudioEngineRecoveryPolicy.retryBackoffForCurrentThread()
        var retryCount = 0
        while true {
            do {
                try throwIfRecordingStartCancelled(shouldCancel)
                try throwIfRecordingStartExpired(effectiveReadinessDeadline)
                try configureAndStartEngine(
                    currentEngine,
                    label: label,
                    readinessDeadline: effectiveReadinessDeadline,
                    shouldCancel: shouldCancel
                )
                return
            } catch let error as SelectedInputDeviceError {
                throw mapSelectedInputDeviceError(error)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AudioRecordingError {
                throw error
            } catch {
                guard AudioEngineRecoveryPolicy.isRetryable(error: error) else {
                    if explicitDeviceSelected && !selectedBluetoothDevice {
                        throw AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed)
                    }
                    throw AudioRecordingError.engineStartFailed(error.localizedDescription)
                }

                if !selectedBluetoothDevice, retryCount >= backoff.count {
                    if explicitDeviceSelected {
                        throw AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed)
                    }
                    throw AudioRecordingError.engineStartFailed(error.localizedDescription)
                }

                try throwIfRecordingStartExpired(effectiveReadinessDeadline)
                let delay = backoff.isEmpty
                    ? 0.05
                    : backoff[min(retryCount, backoff.count - 1)]
                retryCount += 1
                logger.warning("\(label, privacy: .public) audio engine start failed with retryable error, retry \(retryCount, privacy: .public) in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
                recoveryCoordinator.consumePendingConfigurationChangeForEngineReplacement()
                if let replacementEngine = replaceAudioEngineForRecoveryIfNeeded(currentEngine) {
                    installConfigurationObserver(for: replacementEngine)
                    teardownEngine(currentEngine)
                    engineTeardownRetainer.retain(currentEngine, for: Self.engineTeardownRetentionInterval)
                    currentEngine = replacementEngine
                }
                try throwIfRecordingStartCancelled(shouldCancel)
                try waitBeforeRecordingStartRetry(
                    delay,
                    readinessDeadline: effectiveReadinessDeadline,
                    shouldCancel: shouldCancel
                )
            }
        }
    }

    private func startPreparedBuiltInEngineWithFallback(
        _ preparedInput: PreparedBuiltInInput,
        label: String,
        readinessDeadline: TimeInterval?,
        shouldCancel: @escaping () -> Bool
    ) throws {
        let engine = preparedInput.engine
        do {
            try throwIfRecordingStartCancelled(shouldCancel)
            try validateTapInstallationPreconditions(
                expected: preparedInput.tapFormat,
                current: engine.inputNode.outputFormat(forBus: 0)
            )

            let engineStartTime = CFAbsoluteTimeGetCurrent()
            try engine.start()
            armStartupConfigurationChangeGuard(for: engine, expectedTapFormat: preparedInput.tapFormat)
            recoveryCoordinator.noteEngineStarted()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - engineStartTime) * 1000
            logger.info(
                "\(label, privacy: .public) prepared built-in audio engine started in \(String(format: "%.1f", elapsedMs), privacy: .public)ms"
            )
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning(
                "\(label, privacy: .public) prepared built-in audio engine was stale; retrying with cold-start fallback: \(error.localizedDescription, privacy: .public)"
            )
        }

        recoveryCoordinator.consumePendingConfigurationChangeForEngineReplacement()
        guard let replacementEngine = replaceAudioEngineForRecoveryIfNeeded(engine) else {
            throw AudioRecordingError.engineStartFailed("Prepared built-in audio engine disappeared before fallback")
        }
        installConfigurationObserver(for: replacementEngine)
        teardownEngine(engine)
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
        try startEngineWithRecovery(
            replacementEngine,
            label: "\(label)-cold-fallback",
            readinessDeadline: readinessDeadline,
            shouldCancel: shouldCancel
        )
    }

    private func startPreparedBluetoothEngineWithFallback(
        _ preparedInput: PreparedBluetoothInput,
        label: String,
        readinessDeadline: TimeInterval?,
        shouldCancel: @escaping () -> Bool
    ) throws {
        let engine = preparedInput.engine
        do {
            try throwIfRecordingStartCancelled(shouldCancel)
            guard engine.isRunning else {
                throw AudioRecordingError.engineStartFailed("Prepared Bluetooth audio engine stopped")
            }
            try validateTapInstallationPreconditions(
                expected: preparedInput.tapFormat,
                current: engine.inputNode.outputFormat(forBus: 0)
            )
            guard let recordingInputGeneration = bluetoothInputStartupTracker.armExistingGeneration(
                preparedInput.inputGeneration
            ) else {
                throw AudioRecordingError.engineStartFailed("Prepared Bluetooth input generation became stale")
            }

            recoveryCoordinator.noteEngineStarted()
            try waitForInitialInputReadinessIfNeeded(
                label: "\(label)-prepared-bluetooth",
                generation: recordingInputGeneration,
                deadline: readinessDeadline,
                isEngineRunning: { [recoveryCoordinator] in
                    engine.isRunning && !recoveryCoordinator.hasPendingConfigurationChange
                },
                shouldCancel: shouldCancel
            )
            logger.warning("\(label, privacy: .public) claimed actively prewarmed Bluetooth audio engine")
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning(
                "\(label, privacy: .public) actively prewarmed Bluetooth engine was stale; retrying cold: \(error.localizedDescription, privacy: .public)"
            )
        }

        bluetoothInputStartupTracker.reset()
        recoveryCoordinator.consumePendingConfigurationChangeForEngineReplacement()
        guard let replacementEngine = replaceAudioEngineForRecoveryIfNeeded(engine) else {
            throw AudioRecordingError.engineStartFailed("Prepared Bluetooth audio engine disappeared before fallback")
        }
        installConfigurationObserver(for: replacementEngine)
        teardownEngine(engine)
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
        try startEngineWithRecovery(
            replacementEngine,
            label: "\(label)-bluetooth-cold-fallback",
            readinessDeadline: readinessDeadline,
            shouldCancel: shouldCancel
        )
    }

    private func restartEngineWithRecovery(
        _ engine: AVAudioEngine,
        label: String,
        readinessDeadline: TimeInterval? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws {
        outputVolumeGuard.captureBaselineIfNeeded()
        guard let replacementEngine = replaceAudioEngineForRecoveryIfNeeded(engine) else { return }
        defer {
            outputVolumeGuard.restoreIfRaised(reason: "\(label)-engine-restart")
            outputVolumeGuard.clear()
        }

        installConfigurationObserver(for: replacementEngine)
        teardownEngine(engine)
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)

        do {
            try startEngineWithRecovery(
                replacementEngine,
                label: label,
                readinessDeadline: readinessDeadline,
                shouldCancel: shouldCancel
            )
            if isRecordingActive {
                finishBluetoothInputStartupIfNeeded()
            }
        } catch {
            cleanupAfterFailedStart(replacementEngine)
            throw error
        }
    }

    private func configureEngineCapture(
        _ engine: AVAudioEngine,
        label: String,
        readinessDeadline: TimeInterval?,
        shouldCancel: @escaping () -> Bool
    ) throws -> ConfiguredEngineCapture {
        try throwIfRecordingStartCancelled(shouldCancel)
        let inputRoute = selectedEngineInputRoute
        // Set non-Bluetooth explicit inputs before reading the format so each retry sees fresh hardware state.
        // Bluetooth inputs are first activated as the system default input and then left to AVAudioEngine's
        // default aggregate route; setting the raw AirPods/Jabra input here can break mixed input/output routing.
        if let deviceID = inputRoute.engineDeviceID {
            try configureExplicitInputDevice(deviceID, on: engine, label: label)
        } else if inputRoute.selectedDeviceID != nil {
            logger.info("\(label, privacy: .public) using default aggregate input route for selected Bluetooth input")
        }

        let inputNode = engine.inputNode
        var inputFormat = try settledInputFormat(for: inputNode, preferredDeviceID: inputRoute.engineDeviceID, label: label)
        if try enableVoiceProcessingIfNeeded(
            on: inputNode,
            inputRoute: inputRoute,
            currentFormat: inputFormat,
            label: label
        ) {
            inputFormat = try settledInputFormat(
                for: inputNode,
                preferredDeviceID: inputRoute.engineDeviceID,
                label: "\(label)-voice-processing"
            )
        }
        logger.info("\(label, privacy: .public) input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        try validateRecordingInputFormat(inputFormat, preferredDeviceID: inputRoute.engineDeviceID)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecordingError.engineStartFailed("Cannot create target audio format")
        }

        let currentInputFormat = try settledInputFormat(for: inputNode, preferredDeviceID: inputRoute.engineDeviceID, label: "\(label)-tap")
        try validateTapInstallationPreconditions(expected: inputFormat, current: currentInputFormat)

        let tapFormat = Self.tapFormat(for: currentInputFormat)
        let converterInputFormat = tapFormat.channelCount == 1
            ? tapFormat
            : (AudioInputBufferNormalizer.monoFloatFormat(for: tapFormat) ?? tapFormat)

        guard let converter = AVAudioConverter(from: converterInputFormat, to: targetFormat) else {
            throw AudioRecordingError.engineStartFailed("Cannot create audio converter")
        }

        let bluetoothInputGeneration = requiresInitialInputReadiness
            ? bluetoothInputStartupTracker.beginGeneration()
            : nil
        inputNode.removeTap(onBus: 0)

        do {
            _ = try ObjCExceptionCatcher.catching {
                inputNode.installTap(onBus: 0, bufferSize: Self.captureTapFrames, format: tapFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    let captureGeneration: UInt64?
                    if bluetoothInputGeneration != nil {
                        guard let generation = self.bluetoothInputStartupTracker.currentGenerationIfAvailable else {
                            return
                        }
                        captureGeneration = generation
                    } else {
                        captureGeneration = nil
                    }
                    guard let normalizedBuffer = Self.normalizedInputBuffer(buffer) else {
                        return
                    }
                    self.processAudioBuffer(
                        normalizedBuffer,
                        converter: converter,
                        targetFormat: targetFormat,
                        bluetoothInputGeneration: captureGeneration
                    )
                }
            }
        } catch {
            let tapError = error as NSError? ?? NSError(
                domain: AudioEngineRecoveryErrorDomains.avfException,
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "installTap raised NSException"]
            )
            let exceptionName = tapError.userInfo[AudioEngineRecoveryErrorUserInfoKeys.exceptionName] as? String ?? "NSException"
            logger.error("\(label, privacy: .public) installTap raised \(exceptionName, privacy: .public): \(tapError.localizedDescription, privacy: .public)")
            throw tapError
        }

        return ConfiguredEngineCapture(
            inputNode: inputNode,
            tapFormat: tapFormat,
            bluetoothInputGeneration: bluetoothInputGeneration
        )
    }

    private func configureAndStartEngine(
        _ engine: AVAudioEngine,
        label: String,
        readinessDeadline: TimeInterval?,
        shouldCancel: @escaping () -> Bool
    ) throws {
        let configuredCapture = try configureEngineCapture(
            engine,
            label: label,
            readinessDeadline: readinessDeadline,
            shouldCancel: shouldCancel
        )

        let engineStartTime = CFAbsoluteTimeGetCurrent()
        do {
            try engine.start()
            armStartupConfigurationChangeGuard(for: engine, expectedTapFormat: configuredCapture.tapFormat)
            // Open the post-start quiescence window so configuration-change
            // notifications caused by our own AudioUnitSetProperty / start
            // sequence (Bluetooth A2DP↔HFP renegotiation) are deferred
            // instead of driving an infinite restart loop. See issue #332.
            recoveryCoordinator.noteEngineStarted()
            try waitForInitialInputReadinessIfNeeded(
                label: label,
                generation: configuredCapture.bluetoothInputGeneration,
                deadline: readinessDeadline,
                isEngineRunning: { [recoveryCoordinator] in
                    engine.isRunning && !recoveryCoordinator.hasPendingConfigurationChange
                },
                shouldCancel: shouldCancel
            )
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - engineStartTime) * 1000
            logger.info("\(label, privacy: .public) audio engine started in \(String(format: "%.1f", elapsedMs), privacy: .public)ms")
        } catch {
            configuredCapture.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    private var requiresInitialInputReadiness: Bool {
        configLock.withLock {
            _selectedInputDeviceUsesBluetoothTransport
        }
    }

    private var selectedRouteActivationRequest: (
        inputDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool
    ) {
        configLock.withLock {
            let usesBluetoothTransport = _selectedInputDeviceUsesBluetoothTransport
            return (
                _selectedDeviceID,
                usesBluetoothTransport
            )
        }
    }

    private var selectedEngineInputRoute: (selectedDeviceID: AudioDeviceID?, engineDeviceID: AudioDeviceID?) {
        configLock.withLock {
            let usesBluetoothTransport = _selectedInputDeviceUsesBluetoothTransport
            return (
                _selectedDeviceID,
                AudioEngineInputRoute.preferredDeviceIDForEngine(
                    selectedDeviceID: _selectedDeviceID,
                    usesBluetoothTransport: usesBluetoothTransport
                )
            )
        }
    }

    private var selectedCaptureRoute: AudioInputCaptureRoute {
        configLock.withLock {
            AudioInputCaptureRoute.selectedRoute(
                selectedDeviceID: _hasExplicitDeviceSelection ? _selectedDeviceID : nil,
                usesBluetoothTransport: _selectedInputDeviceUsesBluetoothTransport
            )
        }
    }

    private func waitForBluetoothRouteStabilizationIfNeeded(
        inputDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool,
        reason: String,
        readinessDeadline: TimeInterval?,
        shouldCancel: @escaping () -> Bool
    ) throws {
        guard usesBluetoothTransport else { return }
        try throwIfRecordingStartCancelled(shouldCancel)
        try throwIfRecordingStartExpired(readinessDeadline)
        let timeout = readinessDeadline.map {
            max(0, $0 - CFAbsoluteTimeGetCurrent())
        } ?? BluetoothAudioRouteStabilizer.defaultTimeout

        guard bluetoothInputRouteStabilizer.waitForActivatedDefaultInput(
            deviceID: inputDeviceID,
            reason: reason,
            timeout: timeout,
            shouldCancel: shouldCancel
        ) else {
            try throwIfRecordingStartCancelled(shouldCancel)
            try throwIfRecordingStartExpired(readinessDeadline)
            throw AudioRecordingError.audioRoutingConflict
        }
    }

    private func waitForInitialInputReadinessIfNeeded(
        label: String,
        generation: UInt64?,
        deadline: TimeInterval? = nil,
        isEngineRunning: (() -> Bool)? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws {
        guard requiresInitialInputReadiness, let generation else { return }

        try inputReadinessChecker.waitForInitialInput(
            label: label,
            deadline: deadline,
            readinessSnapshot: { [weak self] in
                self?.bluetoothInputStartupTracker.snapshot(for: generation)
            },
            isEngineRunning: isEngineRunning,
            shouldCancel: shouldCancel
        )
    }

    private func finishBluetoothInputStartupIfNeeded() {
        guard requiresInitialInputReadiness else { return }

        var promotion: BluetoothInputStartupTracker.Promotion?
        processingQueue.sync {
            promotion = bluetoothInputStartupTracker.promoteCurrentGeneration()
            guard let promotion else { return }
            bufferLock.withLock {
                sampleBuffer.append(contentsOf: promotion.samples)
                if promotion.peakInputRMS > _peakRawAudioLevel {
                    _peakRawAudioLevel = promotion.peakInputRMS
                }
            }
            recoveryAudioStore.append(promotion.samples)
        }
        guard let promotion else { return }

        logger.info(
            "Bluetooth recording input ready: generation=\(promotion.generation, privacy: .public), bufferedSamples=\(promotion.samples.count, privacy: .public), readinessMs=\(String(format: "%.1f", promotion.readinessDuration * 1000), privacy: .public)"
        )
        DispatchQueue.main.async { [weak self] in
            self?.onFirstRecordingAudioBuffer?()
        }
    }

    private func teardownEngine(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func teardownPreparedEngine(_ engine: AVAudioEngine) {
        teardownEngine(engine)
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
    }

    @discardableResult
    private func replaceAudioEngineForRecoveryIfNeeded(_ engine: AVAudioEngine) -> AVAudioEngine? {
        let replacementEngine = AVAudioEngine()
        let didReplace = engineLock.withLock { () -> Bool in
            guard audioEngine === engine else { return false }
            audioEngine = replacementEngine
            inputCaptureSession = nil
            startupConfigurationChangeGuard = nil
            return true
        }
        return didReplace ? replacementEngine : nil
    }

    private func cleanupAfterFailedStart(_ engine: AVAudioEngine) {
        setRecordingActive(false)
        bluetoothInputStartupTracker.reset()
        recoveryCoordinator.transitionToIdle()
        removeConfigurationObserver()
        engineLock.withLock {
            if audioEngine === engine {
                audioEngine = nil
            }
            inputCaptureSession = nil
            if startupConfigurationChangeGuard?.engineID == ObjectIdentifier(engine) {
                startupConfigurationChangeGuard = nil
            }
        }
        teardownEngine(engine)
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
        outputVolumeGuard.restoreIfRaised(reason: "recording-start-failed")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "recording-start-failed")
        resetAudioLevelPublishing()
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = 0
            self?.rawAudioLevel = 0
        }
    }

    private func validateRecordingInputAvailability() throws {
        if hasExplicitDeviceSelection {
            if let inputAvailabilityOverride {
                guard inputAvailabilityOverride(selectedDeviceID) else {
                    throw AudioRecordingError.noMicrophoneDetected
                }
                return
            }
            guard let selectedDeviceID else {
                throw AudioRecordingError.selectedInputDeviceUnavailable
            }
            guard AudioDeviceService.isInputDeviceAvailable(selectedDeviceID) else {
                throw AudioRecordingError.selectedInputDeviceUnavailable
            }
            return
        }
    }

    private func clearRecordingBuffer(requestUptimeNanoseconds: UInt64? = nil) {
        // Drain already converted samples before resetting processing state. Prepared
        // Bluetooth capture can keep producing buffers while it is waiting to be armed.
        processingQueue.sync {
            microphoneBoostProcessor.reset()
            bluetoothInputStartupTracker.reset()
        }
        bufferLock.lock()
        sampleBuffer.removeAll()
        _peakRawAudioLevel = 0
        recordingRequestUptimeNanoseconds = requestUptimeNanoseconds
        hasLoggedFirstConvertedSample = false
        bufferLock.unlock()
        resetAudioLevelPublishing()
    }

    private func enableVoiceProcessingIfNeeded(
        on inputNode: AVAudioInputNode,
        inputRoute: (selectedDeviceID: AudioDeviceID?, engineDeviceID: AudioDeviceID?),
        currentFormat: AVAudioFormat,
        label: String
    ) throws -> Bool {
        guard inputRoute.selectedDeviceID == nil,
              inputRoute.engineDeviceID == nil,
              currentFormat.channelCount == 3,
              defaultInputUsesBuiltInTransport() else {
            return false
        }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingBypassed = false
            inputNode.isVoiceProcessingAGCEnabled = true
            inputNode.isVoiceProcessingInputMuted = false
            logger.info("\(label, privacy: .public) enabled voice processing for 3-channel built-in default input")
            return true
        } catch {
            logger.warning("\(label, privacy: .public) could not enable voice processing for 3-channel built-in default input: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func defaultInputUsesBuiltInTransport() -> Bool {
        guard let defaultInputDeviceID = defaultInputController.defaultInputDeviceID(),
              let transportType = inputTransportResolver.transportType(for: defaultInputDeviceID) else {
            return false
        }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    private static func normalizedInputBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else {
            return buffer
        }
        return AudioInputBufferNormalizer.monoFloatBuffer(from: buffer)
    }

    private func processAudioBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        bluetoothInputGeneration: UInt64? = nil
    ) {
        // Convert sample rate on the render thread (AVAudioConverter requires thread consistency)
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * Self.targetSampleRate / buffer.format.sampleRate
        )
        guard frameCount > 0 else { return }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: frameCount
        ) else { return }

        var error: NSError?
        let consumed = OSAllocatedUnfairLock(initialState: false)

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            let wasConsumed = consumed.withLock { flag in
                let prev = flag
                flag = true
                return prev
            }
            if wasConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, convertedBuffer.frameLength > 0 else { return }
        guard let channelData = convertedBuffer.floatChannelData?[0] else { return }

        // Quick copy of converted samples, then dispatch heavy work off the render thread
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        processingQueue.async { [weak self] in
            self?.processConvertedSamples(
                samples,
                bluetoothInputGeneration: bluetoothInputGeneration
            )
        }
    }

    private func startInputOnlyRecording(deviceID: AudioDeviceID, label: String) throws {
        do {
            let inputFormat = try inputCaptureFactory.inputOnlyCaptureFormat(deviceID: deviceID)
            guard let monoFormat = AudioInputBufferNormalizer.monoFloatFormat(for: inputFormat),
                  let targetFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.targetSampleRate,
                      channels: 1,
                      interleaved: false
                  ),
                  let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
                throw AudioRecordingError.engineStartFailed("Cannot create input-only audio converter")
            }

            let session = try inputCaptureFactory.startInputOnlyCapture(
                deviceID: deviceID,
                label: label,
                bufferSize: Self.captureTapFrames
            ) { [weak self] buffer in
                guard let self,
                      let monoBuffer = AudioInputBufferNormalizer.monoFloatBuffer(from: buffer) else {
                    return
                }
                self.processAudioBuffer(monoBuffer, converter: converter, targetFormat: targetFormat)
            }

            recoveryCoordinator.transitionToIdle()
            removeConfigurationObserver()
            engineLock.withLock {
                audioEngine = nil
                inputCaptureSession = session
                startupConfigurationChangeGuard = nil
            }
        } catch let error as SelectedInputDeviceError {
            throw mapSelectedInputDeviceError(error)
        } catch let error as AudioRecordingError {
            throw error
        } catch {
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    private func prepareInputOnlyRecording(
        deviceID: AudioDeviceID,
        label: String
    ) throws -> PreparedUSBInput {
        do {
            let inputFormat = try inputCaptureFactory.inputOnlyCaptureFormat(deviceID: deviceID)
            guard let monoFormat = AudioInputBufferNormalizer.monoFloatFormat(for: inputFormat),
                  let targetFormat = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: Self.targetSampleRate,
                      channels: 1,
                      interleaved: false
                  ),
                  let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
                throw AudioRecordingError.engineStartFailed("Cannot create prepared input-only audio converter")
            }

            let session = try inputCaptureFactory.prepareInputOnlyCapture(
                deviceID: deviceID,
                label: label,
                bufferSize: Self.captureTapFrames
            ) { [weak self] buffer in
                guard let self,
                      let monoBuffer = AudioInputBufferNormalizer.monoFloatBuffer(from: buffer) else {
                    return
                }
                self.processAudioBuffer(monoBuffer, converter: converter, targetFormat: targetFormat)
            }
            return PreparedUSBInput(session: session, deviceID: deviceID)
        } catch let error as SelectedInputDeviceError {
            throw mapSelectedInputDeviceError(error)
        } catch let error as AudioRecordingError {
            throw error
        } catch {
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    private func startPreparedInputOnlyRecording(
        _ preparedInput: PreparedUSBInput,
        label: String
    ) throws {
        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            try preparedInput.session.start()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger.info(
                "\(label, privacy: .public) prepared USB capture started in \(String(format: "%.1f", elapsedMs), privacy: .public)ms"
            )
            recoveryCoordinator.transitionToIdle()
            removeConfigurationObserver()
            engineLock.withLock {
                audioEngine = nil
                inputCaptureSession = preparedInput.session
                startupConfigurationChangeGuard = nil
            }
        } catch let error as SelectedInputDeviceError {
            preparedInput.session.stop()
            throw mapSelectedInputDeviceError(error)
        } catch let error as AudioRecordingError {
            preparedInput.session.stop()
            throw error
        } catch {
            preparedInput.session.stop()
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    private func cleanupAfterFailedInputOnlyStart() {
        setRecordingActive(false)
        recoveryCoordinator.transitionToIdle()
        removeConfigurationObserver()
        let session: AudioInputCaptureSession? = engineLock.withLock {
            let session = inputCaptureSession
            inputCaptureSession = nil
            audioEngine = nil
            startupConfigurationChangeGuard = nil
            return session
        }
        session?.stop()
        outputVolumeGuard.restoreIfRaised(reason: "recording-start-failed")
        outputVolumeGuard.clear()
        inputActivationGuard.restore(reason: "recording-start-failed")
        resetAudioLevelPublishing()
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = 0
            self?.rawAudioLevel = 0
        }
    }

    private func processConvertedSamples(
        _ samples: [Float],
        bluetoothInputGeneration: UInt64? = nil
    ) {
        if let bluetoothInputGeneration,
           !bluetoothInputStartupTracker.isActiveGeneration(bluetoothInputGeneration) {
            return
        }

        let boostResult = microphoneBoostProcessor.process(samples, enabled: microphoneBoostEnabled)
        let processedSamples = boostResult.samples
        let rms = boostResult.outputRMS
        let normalizedLevel = AudioLevelMeter.normalizedLevel(rms: rms)
        var requestToFirstBufferMs: Double?
        var didReceiveFirstBuffer = false

        if let bluetoothInputGeneration {
            let disposition = bluetoothInputStartupTracker.consume(
                samples: processedSamples,
                inputRMS: boostResult.inputRMS,
                generation: bluetoothInputGeneration
            )
            switch disposition {
            case .ignored:
                return
            case .staged:
                logFirstConvertedBufferIfNeeded(
                    sampleCount: processedSamples.count,
                    requestToFirstBufferMs: &requestToFirstBufferMs
                )
                publishAudioLevel(normalizedLevel, rms: rms, force: requestToFirstBufferMs != nil)
                return
            case .appendDirectly:
                break
            }
        }

        bufferLock.lock()
        sampleBuffer.append(contentsOf: processedSamples)
        if boostResult.inputRMS > _peakRawAudioLevel { _peakRawAudioLevel = boostResult.inputRMS }
        if !hasLoggedFirstConvertedSample {
            hasLoggedFirstConvertedSample = true
            didReceiveFirstBuffer = true
            requestToFirstBufferMs = Self.elapsedMilliseconds(
                from: recordingRequestUptimeNanoseconds,
                to: DispatchTime.now().uptimeNanoseconds
            )
        }
        bufferLock.unlock()
        recoveryAudioStore.append(processedSamples)

        if let requestToFirstBufferMs {
            logger.info(
                "First recording audio buffer appended: requestToFirstBufferMs=\(Self.formatMilliseconds(requestToFirstBufferMs), privacy: .public), sampleCount=\(processedSamples.count, privacy: .public)"
            )
        }

        publishAudioLevel(normalizedLevel, rms: rms, force: didReceiveFirstBuffer)
        if didReceiveFirstBuffer {
            DispatchQueue.main.async { [weak self] in
                self?.onFirstRecordingAudioBuffer?()
            }
        }
    }

    private func logFirstConvertedBufferIfNeeded(
        sampleCount: Int,
        requestToFirstBufferMs: inout Double?
    ) {
        bufferLock.withLock {
            guard !hasLoggedFirstConvertedSample else { return }
            hasLoggedFirstConvertedSample = true
            requestToFirstBufferMs = Self.elapsedMilliseconds(
                from: recordingRequestUptimeNanoseconds,
                to: DispatchTime.now().uptimeNanoseconds
            )
        }

        if let requestToFirstBufferMs {
            logger.info(
                "First recording audio buffer received: requestToFirstBufferMs=\(Self.formatMilliseconds(requestToFirstBufferMs), privacy: .public), sampleCount=\(sampleCount, privacy: .public)"
            )
        }
    }

    private func publishAudioLevel(_ level: Float, rms: Float, force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        var shouldPublishNow = false
        var publishDelayNanoseconds: UInt64?

        audioLevelPublishLock.lock()
        let elapsed = now &- lastAudioLevelPublishUptimeNanoseconds
        if force || lastAudioLevelPublishUptimeNanoseconds == 0 || elapsed >= Self.audioLevelPublishIntervalNanoseconds {
            lastAudioLevelPublishUptimeNanoseconds = now
            pendingAudioLevelUpdate = nil
            shouldPublishNow = true
        } else {
            pendingAudioLevelUpdate = (level, rms)
            if !isAudioLevelPublishScheduled {
                isAudioLevelPublishScheduled = true
                publishDelayNanoseconds = Self.audioLevelPublishIntervalNanoseconds - elapsed
            }
        }
        audioLevelPublishLock.unlock()

        if shouldPublishNow {
            DispatchQueue.main.async { [weak self] in
                self?.audioLevel = level
                self?.rawAudioLevel = rms
            }
        }

        if let publishDelayNanoseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(publishDelayNanoseconds))) { [weak self] in
                self?.flushPendingAudioLevelUpdate()
            }
        }
    }

    private func flushPendingAudioLevelUpdate() {
        let update: (level: Float, rms: Float)?

        audioLevelPublishLock.lock()
        update = pendingAudioLevelUpdate
        pendingAudioLevelUpdate = nil
        isAudioLevelPublishScheduled = false
        if update != nil {
            lastAudioLevelPublishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        audioLevelPublishLock.unlock()

        guard let update else { return }
        audioLevel = update.level
        rawAudioLevel = update.rms
    }

    private func resetAudioLevelPublishing() {
        audioLevelPublishLock.lock()
        lastAudioLevelPublishUptimeNanoseconds = 0
        pendingAudioLevelUpdate = nil
        isAudioLevelPublishScheduled = false
        audioLevelPublishLock.unlock()
    }

#if DEBUG
    func testingNotifyFirstRecordingAudioBuffer() {
        onFirstRecordingAudioBuffer?()
    }
#endif

    private func setLastStopGraceCaptureApplied(_ applied: Bool) {
        stopStateLock.withLock {
            _lastStopGraceCaptureApplied = applied
        }
    }

    private func drainSampleBuffer() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let samples = sampleBuffer
        sampleBuffer.removeAll()
        return samples
    }

    private static func elapsedMilliseconds(from start: UInt64?, to end: UInt64) -> Double? {
        guard let start, end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }

    private static func formatMilliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value)
    }

    private func validateRecordingInputFormat(_ format: AVAudioFormat, preferredDeviceID: AudioDeviceID?) throws {
        do {
            try validateInputFormat(format, for: preferredDeviceID)
        } catch let error as SelectedInputDeviceError {
            throw mapSelectedInputDeviceError(error)
        } catch {
            throw AudioRecordingError.noMicrophoneDetected
        }
    }

    /// Clears the terminal-recovery error after a downstream observer has
    /// handled it. Called from `DictationViewModel` once the session is
    /// unwound so the @Published value doesn't linger for later bindings.
    func clearRecoveryError() {
        publishRecoveryError(nil)
    }

    var latestRecoveryRecordingURL: URL? {
        recoveryAudioStore.latestRecoveryURL
    }

    var recoveryRecordingURLs: [URL] {
        recoveryAudioStore.recoveryURLs
    }

    @MainActor
    @discardableResult
    func updateRecoveryRetentionPolicy(_ policy: DictationRecoveryRetentionPolicy) -> [URL] {
        let urls = recoveryAudioStore.updateRetentionPolicy(policy)
        publishRecoverableRecordingURLs(urls)
        return urls
    }

    @MainActor
    @discardableResult
    func refreshRecoveryRecordings() -> [URL] {
        let urls = recoveryAudioStore.refreshRetention()
        publishRecoverableRecordingURLs(urls)
        return urls
    }

    @discardableResult
    func preserveActiveRecoveryRecording() -> URL? {
        let url = recoveryAudioStore.preserveActiveRecording()
        publishRecoverableRecordingURLs(recoveryAudioStore.recoveryURLs)
        return url
    }

    func discardActiveRecoveryRecording() {
        discardActiveRecoveryRecording(keepingLatest: true)
    }

    func discardRecoveryRecording(at url: URL) {
        recoveryAudioStore.discardRecovery(at: url)
        publishRecoverableRecordingURLs(recoveryAudioStore.recoveryURLs)
    }

    func discardAllRecoveryRecordings() {
        recoveryAudioStore.discardAllRecoveries()
        publishRecoverableRecordingURLs([])
    }

    private func discardActiveRecoveryRecording(keepingLatest: Bool) {
        recoveryAudioStore.discardActiveRecording(keepingLatest: keepingLatest)
        publishRecoverableRecordingURLs(recoveryAudioStore.recoveryURLs)
    }

    private func publishRecoverableRecordingURLs(_ urls: [URL]) {
        let latestURL = urls.first
        if Thread.isMainThread {
            recoverableRecordingURLs = urls
            recoverableRecordingURL = latestURL
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.recoverableRecordingURLs = urls
                self?.recoverableRecordingURL = latestURL
            }
        }
    }

    private func mapSelectedInputDeviceError(_ error: SelectedInputDeviceError) -> AudioRecordingError {
        switch error {
        case .unavailable:
            return .selectedInputDeviceUnavailable
        case .incompatible(let issue):
            return .selectedInputDeviceIncompatible(issue)
        case .routingConflict:
            return .audioRoutingConflict
        }
    }

    private func armStartupConfigurationChangeGuard(for engine: AVAudioEngine, expectedTapFormat: AVAudioFormat) {
        engineLock.withLock {
            startupConfigurationChangeGuard = StartupConfigurationChangeGuard(engine: engine, expectedTapFormat: expectedTapFormat)
        }
    }

    private func consumeStartupConfigurationChangeGuardIfNeeded(for engine: AVAudioEngine) -> Bool {
        let engineID = ObjectIdentifier(engine)
        let shouldInspectLiveFormat = engineLock.withLock {
            startupConfigurationChangeGuard?.engineID == engineID
        }
        guard shouldInspectLiveFormat else { return false }
        return consumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: engine.inputNode.outputFormat(forBus: 0))
    }

    private func consumeStartupConfigurationChangeGuardIfMatching(for engine: AVAudioEngine, liveFormat: AVAudioFormat) -> Bool {
        let engineID = ObjectIdentifier(engine)
        let guardState: StartupConfigurationChangeGuard? = engineLock.withLock {
            guard let guardState = startupConfigurationChangeGuard, guardState.engineID == engineID else {
                return nil
            }
            startupConfigurationChangeGuard = nil
            return guardState
        }
        guard let guardState else { return false }
        return guardState.matches(liveFormat)
    }

    private func validateTapInstallationPreconditions(expected: AVAudioFormat, current: AVAudioFormat) throws {
        let currentSampleRate = current.sampleRate
        let currentChannelCount = current.channelCount
        let matchesExpected = currentSampleRate == expected.sampleRate && currentChannelCount == expected.channelCount

        guard currentSampleRate > 0, currentChannelCount > 0, matchesExpected else {
            throw Self.makeTransientFormatMismatchError(expected: expected, current: current)
        }
    }

    static func makeTransientFormatMismatchError(expected: AVAudioFormat, current: AVAudioFormat) -> NSError {
        NSError(
            domain: AudioEngineRecoveryErrorDomains.transientFormatMismatch,
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "Format mismatch before installTap: expected \(expected.sampleRate) Hz/\(expected.channelCount) ch, got \(current.sampleRate) Hz/\(current.channelCount) ch"
            ]
        )
    }
}

struct AudioInputReadinessSnapshot: Equatable, Sendable {
    let generation: UInt64
    let consecutiveBufferCount: Int
    let buffersSinceSignal: Int
    let continuousDuration: TimeInterval
    let lastBufferTimestamp: TimeInterval
}

final class BluetoothInputStartupTracker: @unchecked Sendable {
    enum ConsumeDisposition: Equatable {
        case ignored
        case staged
        case appendDirectly
    }

    struct Promotion {
        let generation: UInt64
        let samples: [Float]
        let peakInputRMS: Float
        let readinessDuration: TimeInterval
    }

    private struct State {
        var generation: UInt64 = 0
        var isActive = false
        var isReady = false
        var generationStartedAt: TimeInterval = 0
        var streakStartedAt: TimeInterval?
        var lastBufferTimestamp: TimeInterval?
        var consecutiveBufferCount = 0
        var buffersSinceSignal = 0
        var stagedSamples: [Float] = []
        var peakInputRMS: Float = 0
    }

    private static let maximumBufferGap: TimeInterval = 0.25
    private static let signalPeakThreshold: Float = 0.000_01
    private let now: @Sendable () -> TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(now: @escaping @Sendable () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }) {
        self.now = now
    }

    func beginGeneration() -> UInt64 {
        let timestamp = now()
        return state.withLock { state in
            state.generation &+= 1
            state.isActive = true
            state.isReady = false
            state.generationStartedAt = timestamp
            state.streakStartedAt = nil
            state.lastBufferTimestamp = nil
            state.consecutiveBufferCount = 0
            state.buffersSinceSignal = 0
            state.stagedSamples.removeAll(keepingCapacity: true)
            state.peakInputRMS = 0
            return state.generation
        }
    }

    func disarm(generation: UInt64) {
        state.withLock { state in
            guard state.generation == generation else { return }
            state.isActive = false
            state.isReady = false
            state.streakStartedAt = nil
            state.lastBufferTimestamp = nil
            state.consecutiveBufferCount = 0
            state.buffersSinceSignal = 0
            state.stagedSamples.removeAll(keepingCapacity: false)
            state.peakInputRMS = 0
        }
    }

    var currentGenerationIfAvailable: UInt64? {
        state.withLockIfAvailable { $0.generation }
    }

    func isActiveGeneration(_ generation: UInt64) -> Bool {
        state.withLock { $0.isActive && $0.generation == generation }
    }

    func armExistingGeneration(_ generation: UInt64) -> UInt64? {
        let timestamp = now()
        return state.withLock { state in
            guard state.generation == generation else { return nil }
            state.generation &+= 1
            state.isActive = true
            state.isReady = false
            state.generationStartedAt = timestamp
            state.streakStartedAt = nil
            state.lastBufferTimestamp = nil
            state.consecutiveBufferCount = 0
            state.buffersSinceSignal = 0
            state.stagedSamples.removeAll(keepingCapacity: true)
            state.peakInputRMS = 0
            return state.generation
        }
    }

    func consume(
        samples: [Float],
        inputRMS: Float,
        generation: UInt64
    ) -> ConsumeDisposition {
        let timestamp = now()
        let containsSignal = samples.contains { abs($0) > Self.signalPeakThreshold }

        return state.withLock { state in
            guard state.isActive, state.generation == generation else {
                return .ignored
            }
            guard !state.isReady else {
                return .appendDirectly
            }

            if let lastBufferTimestamp = state.lastBufferTimestamp,
               timestamp - lastBufferTimestamp <= Self.maximumBufferGap {
                state.consecutiveBufferCount += 1
                if state.buffersSinceSignal > 0 {
                    state.buffersSinceSignal += 1
                }
            } else {
                state.streakStartedAt = timestamp
                state.consecutiveBufferCount = 1
                state.buffersSinceSignal = 0
            }

            if containsSignal, state.buffersSinceSignal == 0 {
                state.buffersSinceSignal = 1
            }
            state.lastBufferTimestamp = timestamp
            state.stagedSamples.append(contentsOf: samples)
            if inputRMS > state.peakInputRMS {
                state.peakInputRMS = inputRMS
            }
            return .staged
        }
    }

    func snapshot(for generation: UInt64) -> AudioInputReadinessSnapshot? {
        state.withLock { state in
            guard state.isActive,
                  !state.isReady,
                  state.generation == generation,
                  let streakStartedAt = state.streakStartedAt,
                  let lastBufferTimestamp = state.lastBufferTimestamp else {
                return nil
            }
            return AudioInputReadinessSnapshot(
                generation: generation,
                consecutiveBufferCount: state.consecutiveBufferCount,
                buffersSinceSignal: state.buffersSinceSignal,
                continuousDuration: max(0, lastBufferTimestamp - streakStartedAt),
                lastBufferTimestamp: lastBufferTimestamp
            )
        }
    }

    func promoteCurrentGeneration() -> Promotion? {
        let timestamp = now()
        return state.withLock { state in
            guard state.isActive, !state.isReady else { return nil }
            state.isReady = true
            let promotion = Promotion(
                generation: state.generation,
                samples: state.stagedSamples,
                peakInputRMS: state.peakInputRMS,
                readinessDuration: max(0, timestamp - state.generationStartedAt)
            )
            state.stagedSamples.removeAll(keepingCapacity: false)
            return promotion
        }
    }

    func reset() {
        state.withLock { state in
            state.isActive = false
            state.isReady = false
            state.streakStartedAt = nil
            state.lastBufferTimestamp = nil
            state.consecutiveBufferCount = 0
            state.buffersSinceSignal = 0
            state.stagedSamples.removeAll(keepingCapacity: false)
            state.peakInputRMS = 0
        }
    }
}

protocol AudioInputReadinessChecking: AnyObject {
    func waitForInitialInput(
        label: String,
        deadline: TimeInterval?,
        readinessSnapshot: () -> AudioInputReadinessSnapshot?,
        isEngineRunning: (() -> Bool)?,
        shouldCancel: () -> Bool
    ) throws
}

final class BluetoothInputReadinessChecker: AudioInputReadinessChecking {
    private let timeout: TimeInterval
    private let silentFallback: TimeInterval
    private let missingBufferRecoveryInterval: TimeInterval
    private let maximumBufferGap: TimeInterval
    private let requiredSignalBufferCount: Int
    private let pollInterval: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    init(
        timeout: TimeInterval = 5.0,
        silentFallback: TimeInterval = 3.0,
        missingBufferRecoveryInterval: TimeInterval = 3.0,
        maximumBufferGap: TimeInterval = 0.25,
        requiredSignalBufferCount: Int = 3,
        pollInterval: TimeInterval = 0.01,
        now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.timeout = timeout
        self.silentFallback = silentFallback
        self.missingBufferRecoveryInterval = missingBufferRecoveryInterval
        self.maximumBufferGap = maximumBufferGap
        self.requiredSignalBufferCount = requiredSignalBufferCount
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    func waitForInitialInput(
        label: String,
        deadline: TimeInterval?,
        readinessSnapshot: () -> AudioInputReadinessSnapshot?,
        isEngineRunning: (() -> Bool)?,
        shouldCancel: () -> Bool
    ) throws {
        let startedAt = now()
        let localDeadline = startedAt + timeout
        let effectiveDeadline = min(localDeadline, deadline ?? localDeadline)
        while now() < effectiveDeadline {
            if shouldCancel() {
                throw CancellationError()
            }
            if let isEngineRunning, !isEngineRunning() {
                throw makeStartupRouteChangeError(
                    label: label,
                    detail: "Bluetooth input route changed before readiness"
                )
            }
            if let snapshot = readinessSnapshot() {
                if snapshot.buffersSinceSignal >= requiredSignalBufferCount {
                    logger.info(
                        "\(label, privacy: .public) Bluetooth input delivered stable non-silent audio in generation \(snapshot.generation, privacy: .public)"
                    )
                    return
                }
                if snapshot.consecutiveBufferCount >= requiredSignalBufferCount,
                   snapshot.continuousDuration >= silentFallback {
                    logger.info(
                        "\(label, privacy: .public) Bluetooth input delivered a stable silent stream for \(self.silentFallback, privacy: .public)s in generation \(snapshot.generation, privacy: .public)"
                    )
                    return
                }
                if now() - snapshot.lastBufferTimestamp > maximumBufferGap {
                    throw makeStartupRouteChangeError(
                        label: label,
                        detail: "Bluetooth input stalled before readiness"
                    )
                }
            } else if now() - startedAt >= missingBufferRecoveryInterval {
                throw makeStartupRouteChangeError(
                    label: label,
                    detail: "Bluetooth input did not deliver buffers before readiness"
                )
            }
            sleep(min(pollInterval, max(0, effectiveDeadline - now())))
        }

        if shouldCancel() {
            throw CancellationError()
        }
        if let isEngineRunning, !isEngineRunning() {
            throw makeStartupRouteChangeError(
                label: label,
                detail: "Bluetooth input route changed before readiness"
            )
        }

        logger.error("\(label, privacy: .public) Bluetooth input did not deliver audio within \(self.timeout, privacy: .public)s after engine start")
        throw AudioRecordingService.AudioRecordingError.noAudioData
    }

    private func makeStartupRouteChangeError(label: String, detail: String) -> NSError {
        NSError(
            domain: AudioEngineRecoveryErrorDomains.transientFormatMismatch,
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "\(label) \(detail)"
            ]
        )
    }
}

#if DEBUG
extension AudioRecordingService {
    @discardableResult
    func testingReplaceAudioEngineForRecoveryIfNeeded(_ engine: AVAudioEngine) -> AVAudioEngine? {
        replaceAudioEngineForRecoveryIfNeeded(engine)
    }

    func testingSetAudioEngine(_ engine: AVAudioEngine?) {
        engineLock.withLock {
            audioEngine = engine
            inputCaptureSession = nil
        }
    }

    func testingCurrentAudioEngine() -> AVAudioEngine? {
        engineLock.withLock { audioEngine }
    }

    func testingHasPreparedUSBInput(deviceID: AudioDeviceID) -> Bool {
        engineLock.withLock { preparedUSBInput?.deviceID == deviceID }
    }

    func testingSelectedInputDeviceName() -> String? {
        configLock.withLock { _selectedInputDeviceName }
    }

    func testingValidateTapInstallationPreconditions(expected: AVAudioFormat, current: AVAudioFormat) throws {
        try validateTapInstallationPreconditions(expected: expected, current: current)
    }

    func testingArmStartupConfigurationChangeGuard(for engine: AVAudioEngine, expectedTapFormat: AVAudioFormat) {
        armStartupConfigurationChangeGuard(for: engine, expectedTapFormat: expectedTapFormat)
    }

    func testingConsumeStartupConfigurationChangeGuardIfMatching(for engine: AVAudioEngine, liveFormat: AVAudioFormat) -> Bool {
        consumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: liveFormat)
    }

    func testingWaitForInitialInputReadinessIfNeeded(
        generation: UInt64,
        isEngineRunning: (() -> Bool)? = nil,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws {
        try waitForInitialInputReadinessIfNeeded(
            label: "test",
            generation: generation,
            isEngineRunning: isEngineRunning,
            shouldCancel: shouldCancel
        )
    }

    func testingBeginBluetoothInputGeneration() -> UInt64 {
        bluetoothInputStartupTracker.beginGeneration()
    }

    @discardableResult
    func testingConsumeBluetoothInputSamples(
        _ samples: [Float],
        inputRMS: Float,
        generation: UInt64
    ) -> BluetoothInputStartupTracker.ConsumeDisposition {
        bluetoothInputStartupTracker.consume(
            samples: samples,
            inputRMS: inputRMS,
            generation: generation
        )
    }

    func testingProcessConvertedSamples(_ samples: [Float]) {
        processConvertedSamples(samples)
    }

    func testingMarkAudioLevelPublishedNow() {
        audioLevelPublishLock.lock()
        lastAudioLevelPublishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        pendingAudioLevelUpdate = nil
        isAudioLevelPublishScheduled = false
        audioLevelPublishLock.unlock()
    }

    func testingFailActiveRecordingDueToRecovery(_ error: AudioRecordingError) {
        failActiveRecordingDueToRecovery(error)
    }
}
#endif
