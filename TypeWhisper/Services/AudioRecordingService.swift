import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import AppKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecordingService")

struct MicrophoneBoostProcessingResult {
    let samples: [Float]
    let inputRMS: Float
    let outputRMS: Float
    let gain: Float
}

enum MicrophoneBoostProcessor {
    static let targetRMS: Float = 0.1
    static let maximumGain: Float = 20
    static let minimumGain: Float = 1
    static let minimumInputRMS: Float = 0.0001

    static func process(_ samples: [Float], enabled: Bool) -> MicrophoneBoostProcessingResult {
        guard !samples.isEmpty else {
            return MicrophoneBoostProcessingResult(samples: [], inputRMS: 0, outputRMS: 0, gain: 1)
        }

        let inputRMS = rms(samples)
        guard enabled, inputRMS > minimumInputRMS else {
            return MicrophoneBoostProcessingResult(samples: samples, inputRMS: inputRMS, outputRMS: inputRMS, gain: 1)
        }

        let gain = min(max(targetRMS / inputRMS, minimumGain), maximumGain)
        guard gain > 1 else {
            return MicrophoneBoostProcessingResult(samples: samples, inputRMS: inputRMS, outputRMS: inputRMS, gain: 1)
        }

        let boosted = samples.map { max(-1, min(1, $0 * gain)) }
        return MicrophoneBoostProcessingResult(
            samples: boosted,
            inputRMS: inputRMS,
            outputRMS: rms(boosted),
            gain: gain
        )
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
        set { configLock.withLock { _selectedDeviceID = newValue } }
    }
    var hasExplicitDeviceSelection: Bool {
        get { configLock.withLock { _hasExplicitDeviceSelection } }
        set { configLock.withLock { _hasExplicitDeviceSelection = newValue } }
    }
    var selectedInputDeviceUsesBluetoothTransport: Bool {
        get { configLock.withLock { _selectedInputDeviceUsesBluetoothTransport } }
        set { configLock.withLock { _selectedInputDeviceUsesBluetoothTransport = newValue } }
    }
    var microphoneBoostEnabled: Bool {
        get { microphoneBoostEnabledLock.withLock { $0 } }
        set { microphoneBoostEnabledLock.withLock { $0 = newValue } }
    }
    private var _selectedDeviceID: AudioDeviceID?
    private var _hasExplicitDeviceSelection = false
    private var _selectedInputDeviceUsesBluetoothTransport = false

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

    private var audioEngine: AVAudioEngine?
    private var inputCaptureSession: AudioInputCaptureSession?
    private var startupConfigurationChangeGuard: StartupConfigurationChangeGuard?
    private var configChangeObserver: NSObjectProtocol?
    private var sampleBuffer: [Float] = []
    private var _peakRawAudioLevel: Float = 0
    private let bufferLock = NSLock()
    private let microphoneBoostEnabledLock = OSAllocatedUnfairLock(initialState: false)
    private let configLock = NSLock()
    private let stopStateLock = NSLock()
    private let engineLock = NSLock()
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
    private let initialInputTapSeenLock = OSAllocatedUnfairLock(initialState: false)
    private var _lastStopGraceCaptureApplied = false
    private var recordingRequestUptimeNanoseconds: UInt64?
    private var hasLoggedFirstConvertedSample = false

    static let targetSampleRate: Double = 16000
    private static let captureTapFrames: AVAudioFrameCount = 256
    private static let engineTeardownRetentionInterval: TimeInterval = 0.3

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
        if permission == .granted { return true }
        if permission == .undetermined {
            // Request permission via the official AVAudioApplication API
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        // .denied — open System Settings so user can grant manually
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
        return false
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
        guard hasMicrophonePermission else {
            throw AudioRecordingError.microphonePermissionDenied
        }

        // Clear any terminal-recovery error from a previous session so the
        // view model doesn't see a stale failure on the first buffer update.
        recoveryError = nil

        try validateRecordingInputAvailability()
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
                reason: "recording-start"
            )
        } catch {
            outputVolumeGuard.restoreIfRaised(reason: "recording-start-route-stabilization-failed")
            outputVolumeGuard.clear()
            inputActivationGuard.restore(reason: "recording-start-route-stabilization-failed")
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
                outputVolumeGuard.restoreIfRaised(reason: "recording-start-override")
                outputVolumeGuard.clear()
                isRecording = true
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
                try startInputOnlyRecording(deviceID: inputOnlyDeviceID, label: "recording")
                outputVolumeGuard.restoreIfRaised(reason: "recording-start")
                outputVolumeGuard.clear()
                isRecording = true
            } catch {
                cleanupAfterFailedInputOnlyStart()
                discardActiveRecoveryRecording(keepingLatest: true)
                throw error
            }
            return
        }

        let engine = AVAudioEngine()
        engineLock.withLock {
            audioEngine = engine
            inputCaptureSession = nil
            startupConfigurationChangeGuard = nil
        }
        recoveryCoordinator.beginStarting()
        installConfigurationObserver(for: engine)

        do {
            try startEngineWithRecovery(engine, label: "recording")

            if recoveryCoordinator.finishStartingSuccessfully() == .performImmediateRecovery {
                guard let currentEngine = engineLock.withLock({ audioEngine }) else {
                    throw AudioRecordingError.engineStartFailed("Recording engine disappeared during startup recovery")
                }
                if consumeStartupConfigurationChangeGuardIfNeeded(for: currentEngine) {
                    logger.info("Ignoring benign post-start audio engine configuration change after tap renegotiation")
                } else {
                    logger.warning("Audio engine configuration changed while recording was starting, restarting with fresh input format")
                    try restartEngineWithRecovery(currentEngine, label: "recording-startup")
                }
                scheduleRecoveryIfNeeded(recoveryCoordinator.finishRecovery())
            }

            outputVolumeGuard.restoreIfRaised(reason: "recording-start")
            outputVolumeGuard.clear()
            isRecording = true
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
            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
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

            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
                self?.audioLevel = 0
            }

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

        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.audioLevel = 0
        }

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
        guard isRecording, let engine else { return }

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
            self.isRecording = false
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

    private func startEngineWithRecovery(_ engine: AVAudioEngine, label: String) throws {
        let explicitDeviceSelected = hasExplicitDeviceSelection
        let selectedBluetoothDevice = requiresInitialInputReadiness
        var currentEngine = engine
        // Main-thread callers (e.g. startRecording from hotkey) get a bounded
        // backoff to keep UI responsive; the observer-based recovery queue
        // uses the full schedule. See AudioEngineRecoveryPolicy.
        let backoff = AudioEngineRecoveryPolicy.retryBackoffForCurrentThread()
        for (attempt, delay) in backoff.enumerated() {
            do {
                try configureAndStartEngine(currentEngine, label: label)
                return
            } catch let error as SelectedInputDeviceError {
                throw mapSelectedInputDeviceError(error)
            } catch let error as AudioRecordingError {
                throw error
            } catch {
                guard AudioEngineRecoveryPolicy.isRetryable(error: error) else {
                    if explicitDeviceSelected && !selectedBluetoothDevice {
                        throw AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed)
                    }
                    throw AudioRecordingError.engineStartFailed(error.localizedDescription)
                }

                logger.warning("\(label, privacy: .public) audio engine start failed with retryable error, retry \(attempt + 1) in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
                if let replacementEngine = replaceAudioEngineForRecoveryIfNeeded(currentEngine) {
                    installConfigurationObserver(for: replacementEngine)
                    teardownEngine(currentEngine)
                    engineTeardownRetainer.retain(currentEngine, for: Self.engineTeardownRetentionInterval)
                    currentEngine = replacementEngine
                }
                Thread.sleep(forTimeInterval: delay)
            }
        }

        do {
            try configureAndStartEngine(currentEngine, label: label)
        } catch let error as SelectedInputDeviceError {
            throw mapSelectedInputDeviceError(error)
        } catch let error as AudioRecordingError {
            throw error
        } catch {
            if explicitDeviceSelected && !selectedBluetoothDevice {
                throw AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed)
            }
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    private func restartEngineWithRecovery(_ engine: AVAudioEngine, label: String) throws {
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
            try startEngineWithRecovery(replacementEngine, label: label)
        } catch {
            cleanupAfterFailedStart(replacementEngine)
            throw error
        }
    }

    private func configureAndStartEngine(_ engine: AVAudioEngine, label: String) throws {
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

        inputNode.removeTap(onBus: 0)

        do {
            _ = try ObjCExceptionCatcher.catching {
                inputNode.installTap(onBus: 0, bufferSize: Self.captureTapFrames, format: tapFormat) { [weak self] buffer, _ in
                    guard let normalizedBuffer = Self.normalizedInputBuffer(buffer) else {
                        return
                    }
                    self?.markInitialInputTapSeenIfNeeded(normalizedBuffer)
                    self?.processAudioBuffer(normalizedBuffer, converter: converter, targetFormat: targetFormat)
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

        let engineStartTime = CFAbsoluteTimeGetCurrent()
        do {
            try engine.start()
            armStartupConfigurationChangeGuard(for: engine, expectedTapFormat: tapFormat)
            // Open the post-start quiescence window so configuration-change
            // notifications caused by our own AudioUnitSetProperty / start
            // sequence (Bluetooth A2DP↔HFP renegotiation) are deferred
            // instead of driving an infinite restart loop. See issue #332.
            recoveryCoordinator.noteEngineStarted()
            try waitForInitialInputReadinessIfNeeded(label: label, isEngineRunning: { engine.isRunning })
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - engineStartTime) * 1000
            logger.info("\(label, privacy: .public) audio engine started in \(String(format: "%.1f", elapsedMs), privacy: .public)ms")
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    private var requiresInitialInputReadiness: Bool {
        configLock.withLock {
            _hasExplicitDeviceSelection && _selectedInputDeviceUsesBluetoothTransport
        }
    }

    private var selectedRouteActivationRequest: (
        inputDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool
    ) {
        configLock.withLock {
            let usesBluetoothTransport = _hasExplicitDeviceSelection && _selectedInputDeviceUsesBluetoothTransport
            return (
                _selectedDeviceID,
                usesBluetoothTransport
            )
        }
    }

    private var selectedEngineInputRoute: (selectedDeviceID: AudioDeviceID?, engineDeviceID: AudioDeviceID?) {
        configLock.withLock {
            let usesBluetoothTransport = _hasExplicitDeviceSelection && _selectedInputDeviceUsesBluetoothTransport
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
                usesBluetoothTransport: _hasExplicitDeviceSelection && _selectedInputDeviceUsesBluetoothTransport
            )
        }
    }

    private var hasCapturedInitialInput: Bool {
        initialInputTapSeenLock.withLock { $0 }
    }

    private func waitForBluetoothRouteStabilizationIfNeeded(
        inputDeviceID: AudioDeviceID?,
        usesBluetoothTransport: Bool,
        reason: String
    ) throws {
        guard usesBluetoothTransport else { return }

        guard bluetoothInputRouteStabilizer.waitForActivatedDefaultInput(
            deviceID: inputDeviceID,
            reason: reason
        ) else {
            throw AudioRecordingError.audioRoutingConflict
        }
    }

    private func waitForInitialInputReadinessIfNeeded(
        label: String,
        isEngineRunning: (() -> Bool)? = nil
    ) throws {
        guard requiresInitialInputReadiness else { return }

        try inputReadinessChecker.waitForInitialInput(
            label: label,
            hasCapturedInitialInput: { [weak self] in
                self?.hasCapturedInitialInput ?? false
            },
            isEngineRunning: isEngineRunning
        )
    }

    private func teardownEngine(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
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
        bufferLock.lock()
        sampleBuffer.removeAll()
        _peakRawAudioLevel = 0
        recordingRequestUptimeNanoseconds = requestUptimeNanoseconds
        hasLoggedFirstConvertedSample = false
        bufferLock.unlock()
        initialInputTapSeenLock.withLock { $0 = false }
    }

    private func markInitialInputTapSeenIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard AudioInputSignal.containsSignal(buffer) else { return }
        initialInputTapSeenLock.withLock { $0 = true }
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
        targetFormat: AVAudioFormat
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
            self?.processConvertedSamples(samples)
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
                self.markInitialInputTapSeenIfNeeded(monoBuffer)
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

    private func cleanupAfterFailedInputOnlyStart() {
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
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.audioLevel = 0
            self?.rawAudioLevel = 0
        }
    }

    private func processConvertedSamples(_ samples: [Float]) {
        let boostResult = MicrophoneBoostProcessor.process(samples, enabled: microphoneBoostEnabled)
        let processedSamples = boostResult.samples
        let rms = boostResult.outputRMS
        let normalizedLevel = AudioLevelMeter.normalizedLevel(rms: rms)
        var requestToFirstBufferMs: Double?
        var didReceiveFirstBuffer = false

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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevel = normalizedLevel
            self.rawAudioLevel = rms
            if didReceiveFirstBuffer {
                self.onFirstRecordingAudioBuffer?()
            }
        }
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
        recoveryError = nil
    }

    var latestRecoveryRecordingURL: URL? {
        recoveryAudioStore.latestRecoveryURL
    }

    var recoveryRecordingURLs: [URL] {
        recoveryAudioStore.recoveryURLs
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

protocol AudioInputReadinessChecking: AnyObject {
    func waitForInitialInput(
        label: String,
        hasCapturedInitialInput: () -> Bool,
        isEngineRunning: (() -> Bool)?
    ) throws
}

final class BluetoothInputReadinessChecker: AudioInputReadinessChecking {
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    init(
        timeout: TimeInterval = 1.0,
        pollInterval: TimeInterval = 0.01,
        now: @escaping () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    func waitForInitialInput(
        label: String,
        hasCapturedInitialInput: () -> Bool,
        isEngineRunning: (() -> Bool)?
    ) throws {
        let deadline = now() + timeout
        while now() < deadline {
            if hasCapturedInitialInput() {
                logger.info("\(label, privacy: .public) Bluetooth input delivered initial non-silent audio")
                return
            }
            if let isEngineRunning, !isEngineRunning() {
                throw makeStartupRouteChangeError(label: label)
            }
            sleep(min(pollInterval, max(0, deadline - now())))
        }

        if let isEngineRunning, !isEngineRunning() {
            throw makeStartupRouteChangeError(label: label)
        }

        logger.error("\(label, privacy: .public) Bluetooth input did not deliver audio within \(self.timeout, privacy: .public)s after engine start")
        throw AudioRecordingService.AudioRecordingError.noAudioData
    }

    private func makeStartupRouteChangeError(label: String) -> NSError {
        NSError(
            domain: AudioEngineRecoveryErrorDomains.transientFormatMismatch,
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: "\(label) Bluetooth input route changed before initial audio"
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

    func testingValidateTapInstallationPreconditions(expected: AVAudioFormat, current: AVAudioFormat) throws {
        try validateTapInstallationPreconditions(expected: expected, current: current)
    }

    func testingArmStartupConfigurationChangeGuard(for engine: AVAudioEngine, expectedTapFormat: AVAudioFormat) {
        armStartupConfigurationChangeGuard(for: engine, expectedTapFormat: expectedTapFormat)
    }

    func testingConsumeStartupConfigurationChangeGuardIfMatching(for engine: AVAudioEngine, liveFormat: AVAudioFormat) -> Bool {
        consumeStartupConfigurationChangeGuardIfMatching(for: engine, liveFormat: liveFormat)
    }

    func testingWaitForInitialInputReadinessIfNeeded(isEngineRunning: (() -> Bool)? = nil) throws {
        try waitForInitialInputReadinessIfNeeded(label: "test", isEngineRunning: isEngineRunning)
    }

    func testingMarkInitialInputTapSeen() {
        initialInputTapSeenLock.withLock { $0 = true }
    }

    func testingMarkInitialInputTapSeen(_ buffer: AVAudioPCMBuffer) {
        markInitialInputTapSeenIfNeeded(buffer)
    }

    func testingProcessConvertedSamples(_ samples: [Float]) {
        processConvertedSamples(samples)
    }

    func testingFailActiveRecordingDueToRecovery(_ error: AudioRecordingError) {
        failActiveRecordingDueToRecovery(error)
    }
}
#endif
