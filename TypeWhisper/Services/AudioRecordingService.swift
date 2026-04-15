import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import AppKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecordingService")

final class DelayedReleaseRetainer<Object: AnyObject>: @unchecked Sendable {
    private final class RetainedObjectBox: @unchecked Sendable {
        let object: Object

        init(_ object: Object) {
            self.object = object
        }
    }

    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func retain(_ object: Object, for duration: TimeInterval) {
        let retainedObject = RetainedObjectBox(object)
        queue.asyncAfter(deadline: .now() + duration) {
            withExtendedLifetime(retainedObject) {}
        }
    }
}

/// Captures microphone audio via AVAudioEngine and converts to 16kHz mono Float32 samples.
final class AudioRecordingService: ObservableObject, @unchecked Sendable {
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

    private var _selectedDeviceID: AudioDeviceID?
    private var _hasExplicitDeviceSelection = false

    private var audioEngine: AVAudioEngine?
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
    private var _lastStopGraceCaptureApplied = false

    static let targetSampleRate: Double = 16000
    private static let captureTapFrames: AVAudioFrameCount = 1024
    private static let engineTeardownRetentionInterval: TimeInterval = 0.3

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
        let copy = sampleBuffer
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

    func startRecording() throws {
        guard hasMicrophonePermission else {
            throw AudioRecordingError.microphonePermissionDenied
        }

        try validateRecordingInputAvailability()

        if let startRecordingOverride {
            bufferLock.lock()
            sampleBuffer.removeAll()
            _peakRawAudioLevel = 0
            bufferLock.unlock()
            try startRecordingOverride()
            isRecording = true
            return
        }

        clearRecordingBuffer()
        let engine = AVAudioEngine()
        engineLock.withLock { audioEngine = engine }
        recoveryCoordinator.beginStarting()
        installConfigurationObserver(for: engine)

        do {
            try startEngineWithRecovery(engine, label: "recording")

            if recoveryCoordinator.finishStartingSuccessfully() == .performImmediateRecovery {
                logger.warning("Audio engine configuration changed while recording was starting, restarting with fresh input format")
                try restartEngineWithRecovery(engine, label: "recording-startup")
                scheduleRecoveryIfNeeded(recoveryCoordinator.finishRecovery())
            }

            isRecording = true
        } catch {
            cleanupAfterFailedStart(engine)
            throw error
        }
    }

    func stopRecording(policy: StopPolicy) async -> [Float] {
        if let stopRecordingOverride {
            let samples = await stopRecordingOverride(policy)
            setLastStopGraceCaptureApplied(false)
            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
                self?.audioLevel = 0
            }
            return samples
        }

        // Atomically claim the engine - only the first concurrent caller proceeds
        let engine: AVAudioEngine? = engineLock.withLock {
            let e = audioEngine
            audioEngine = nil
            return e
        }
        guard let engine else { return [] }

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
        teardownEngine(engine)
        // Keep the engine alive briefly so CoreAudio's internal teardown callbacks
        // cannot outlive the AVAudioEngine objects they still reference.
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)

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
        guard case .schedule(let generation, let delay) = action else { return }

        recoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performScheduledRecovery(generation: generation)
        }
    }

    private func performScheduledRecovery(generation: UInt64) {
        guard recoveryCoordinator.beginScheduledRecovery(generation: generation) else { return }
        defer {
            scheduleRecoveryIfNeeded(recoveryCoordinator.finishRecovery())
        }

        let engine: AVAudioEngine? = engineLock.withLock { audioEngine }
        guard isRecording, let engine else { return }

        logger.warning("Audio engine configuration changed during recording, restarting engine")

        do {
            try restartEngineWithRecovery(engine, label: "config-change")
        } catch {
            logger.error("Failed to restart audio engine after configuration change: \(error.localizedDescription)")
        }
    }

    private func installConfigurationObserver(for engine: AVAudioEngine) {
        removeConfigurationObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
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
        for (attempt, delay) in AudioEngineRecoveryPolicy.retryBackoff.enumerated() {
            do {
                try configureAndStartEngine(engine, label: label)
                return
            } catch let error as SelectedInputDeviceError {
                throw mapSelectedInputDeviceError(error)
            } catch let error as AudioRecordingError {
                throw error
            } catch {
                guard AudioEngineRecoveryPolicy.isRetryable(error: error) else {
                    if explicitDeviceSelected {
                        throw AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed)
                    }
                    throw AudioRecordingError.engineStartFailed(error.localizedDescription)
                }

                logger.warning("\(label, privacy: .public) audio engine start failed with retryable error, retry \(attempt + 1) in \(delay, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: delay)
            }
        }

        do {
            try configureAndStartEngine(engine, label: label)
        } catch let error as SelectedInputDeviceError {
            throw mapSelectedInputDeviceError(error)
        } catch let error as AudioRecordingError {
            throw error
        } catch {
            if explicitDeviceSelected {
                throw AudioRecordingError.selectedInputDeviceIncompatible(.engineStartFailed)
            }
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }
    }

    private func restartEngineWithRecovery(_ engine: AVAudioEngine, label: String) throws {
        teardownEngine(engine)
        try startEngineWithRecovery(engine, label: label)
    }

    private func configureAndStartEngine(_ engine: AVAudioEngine, label: String) throws {
        // Set the input device before reading the format so each retry sees fresh hardware state.
        if let deviceID = selectedDeviceID {
            try configureExplicitInputDevice(deviceID, on: engine, label: label)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("\(label, privacy: .public) input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        try validateRecordingInputFormat(inputFormat)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecordingError.engineStartFailed("Cannot create target audio format")
        }

        let tapFormat = Self.monoTapFormat(for: inputFormat)

        guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            throw AudioRecordingError.engineStartFailed("Cannot create audio converter")
        }

        inputNode.installTap(onBus: 0, bufferSize: Self.captureTapFrames, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        let engineStartTime = CFAbsoluteTimeGetCurrent()
        do {
            try engine.start()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - engineStartTime) * 1000
            logger.info("\(label, privacy: .public) audio engine started in \(String(format: "%.1f", elapsedMs), privacy: .public)ms")
        } catch {
            inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
    }

    private func teardownEngine(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func cleanupAfterFailedStart(_ engine: AVAudioEngine) {
        recoveryCoordinator.transitionToIdle()
        removeConfigurationObserver()
        engineLock.withLock {
            if audioEngine === engine {
                audioEngine = nil
            }
        }
        teardownEngine(engine)
        engineTeardownRetainer.retain(engine, for: Self.engineTeardownRetentionInterval)
        DispatchQueue.main.async { [weak self] in
            self?.isRecording = false
            self?.audioLevel = 0
            self?.rawAudioLevel = 0
        }
    }

    private func validateRecordingInputAvailability() throws {
        if let inputAvailabilityOverride {
            guard inputAvailabilityOverride(selectedDeviceID) else {
                throw AudioRecordingError.noMicrophoneDetected
            }
            return
        }

        if hasExplicitDeviceSelection {
            guard let selectedDeviceID else {
                throw AudioRecordingError.selectedInputDeviceUnavailable
            }
            guard AudioDeviceService.isInputDeviceAvailable(selectedDeviceID) else {
                throw AudioRecordingError.selectedInputDeviceUnavailable
            }
            return
        }

        guard AudioDeviceService.hasAvailableInputDevice() else {
            throw AudioRecordingError.noMicrophoneDetected
        }
    }

    private func clearRecordingBuffer() {
        bufferLock.lock()
        sampleBuffer.removeAll()
        _peakRawAudioLevel = 0
        bufferLock.unlock()
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

    private func processConvertedSamples(_ samples: [Float]) {
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let normalizedLevel = min(1.0, rms * 5) // Scale up for visibility

        bufferLock.lock()
        sampleBuffer.append(contentsOf: samples)
        if rms > _peakRawAudioLevel { _peakRawAudioLevel = rms }
        bufferLock.unlock()

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

    private func validateRecordingInputFormat(_ format: AVAudioFormat) throws {
        do {
            try validateInputFormat(format, for: hasExplicitDeviceSelection ? selectedDeviceID : nil)
        } catch let error as SelectedInputDeviceError {
            throw mapSelectedInputDeviceError(error)
        } catch {
            throw AudioRecordingError.noMicrophoneDetected
        }
    }

    private func mapSelectedInputDeviceError(_ error: SelectedInputDeviceError) -> AudioRecordingError {
        switch error {
        case .unavailable:
            return .selectedInputDeviceUnavailable
        case .incompatible(let issue):
            return .selectedInputDeviceIncompatible(issue)
        }
    }
}
