import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import AppKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecordingService")

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
    var hasMicrophonePermissionOverride: Bool?
    var inputAvailabilityOverride: ((AudioDeviceID?) -> Bool)?
    var startRecordingOverride: (() throws -> Void)?
    var stopRecordingOverride: ((StopPolicy) async -> [Float])?

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
    private let configLock = NSLock()
    private let stopStateLock = NSLock()
    private let engineLock = NSLock()
    private let processingQueue = DispatchQueue(label: "com.typewhisper.audio-processing", qos: .userInteractive)
    private let recoveryQueue = DispatchQueue(label: "com.typewhisper.audio-recovery", qos: .userInitiated)
    private let engineTeardownRetainer = DelayedReleaseRetainer<AVAudioEngine>(label: "com.typewhisper.audio-engine-teardown")
    private let recoveryCoordinator = AudioEngineRecoveryCoordinator()
    private let outputVolumeGuard: AudioOutputVolumeGuard
    private let inputActivationGuard: AudioInputDeviceActivating
    private let bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing
    private let inputReadinessChecker: AudioInputReadinessChecking
    private let inputCaptureFactory: AudioInputCaptureFactory
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
        inputCaptureFactory: AudioInputCaptureFactory = CoreAudioHALInputCaptureFactory()
    ) {
        self.outputVolumeGuard = outputVolumeGuard
        self.inputActivationGuard = inputActivationGuard
        self.bluetoothInputRouteStabilizer = bluetoothInputRouteStabilizer
        self.inputReadinessChecker = inputReadinessChecker
        self.inputCaptureFactory = inputCaptureFactory
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
    private static func monoTapFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
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

        let routeActivationRequest = selectedRouteActivationRequest
        outputVolumeGuard.captureBaseline()

        guard inputActivationGuard.activateIfNeeded(
            deviceID: routeActivationRequest.inputDeviceID,
            usesBluetoothTransport: routeActivationRequest.usesBluetoothTransport,
            reason: "recording-start"
        ) else {
            outputVolumeGuard.restoreIfRaised(reason: "recording-start-input-activation-failed")
            outputVolumeGuard.clear()
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
        clearRecordingBuffer()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recoveryError = error
            self.isRecording = false
            self.audioLevel = 0
            self.rawAudioLevel = 0
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
        let inputFormat = try settledInputFormat(for: inputNode, preferredDeviceID: inputRoute.engineDeviceID, label: label)
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

        let tapFormat = Self.monoTapFormat(for: currentInputFormat)

        guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            throw AudioRecordingError.engineStartFailed("Cannot create audio converter")
        }

        inputNode.removeTap(onBus: 0)

        do {
            _ = try ObjCExceptionCatcher.catching {
                inputNode.installTap(onBus: 0, bufferSize: Self.captureTapFrames, format: tapFormat) { [weak self] buffer, _ in
                    self?.markInitialInputTapSeenIfNeeded(buffer)
                    self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
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
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let normalizedLevel = AudioLevelMeter.normalizedLevel(rms: rms)
        var requestToFirstBufferMs: Double?

        bufferLock.lock()
        sampleBuffer.append(contentsOf: samples)
        if rms > _peakRawAudioLevel { _peakRawAudioLevel = rms }
        if !hasLoggedFirstConvertedSample {
            hasLoggedFirstConvertedSample = true
            requestToFirstBufferMs = Self.elapsedMilliseconds(
                from: recordingRequestUptimeNanoseconds,
                to: DispatchTime.now().uptimeNanoseconds
            )
        }
        bufferLock.unlock()

        if let requestToFirstBufferMs {
            logger.info(
                "First recording audio buffer appended: requestToFirstBufferMs=\(Self.formatMilliseconds(requestToFirstBufferMs), privacy: .public), sampleCount=\(samples.count, privacy: .public)"
            )
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevel = normalizedLevel
            self.rawAudioLevel = rms
        }
    }

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
}
#endif
