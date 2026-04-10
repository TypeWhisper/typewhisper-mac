import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import AppKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecordingService")

final class DelayedReleaseRetainer<Object: AnyObject>: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func retain(_ object: Object, for duration: TimeInterval) {
        let retainedObject = object
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
        case engineStartFailed(String)
        case noAudioData

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission denied. Please grant access in System Settings."
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

    /// CoreAudio device ID to use for recording. nil = system default input.
    var selectedDeviceID: AudioDeviceID? {
        get { configLock.withLock { _selectedDeviceID } }
        set { configLock.withLock { _selectedDeviceID = newValue } }
    }

    private var _selectedDeviceID: AudioDeviceID?

    private var audioEngine: AVAudioEngine?
    private var configChangeObserver: NSObjectProtocol?
    private var sampleBuffer: [Float] = []
    private var _peakRawAudioLevel: Float = 0
    private let bufferLock = NSLock()
    private let configLock = NSLock()
    private let stopStateLock = NSLock()
    private let engineLock = NSLock()
    private let processingQueue = DispatchQueue(label: "com.typewhisper.audio-processing", qos: .userInteractive)
    private let engineTeardownRetainer = DelayedReleaseRetainer<AVAudioEngine>(label: "com.typewhisper.audio-engine-teardown")
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
        AVAudioApplication.shared.recordPermission == .granted
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

        let engine = AVAudioEngine()

        // Set the input device before reading the format
        if let deviceID = selectedDeviceID {
            if !setInputDevice(deviceID, on: engine, label: "recording") {
                logger.error("Failed to set recording input device (\(deviceID)), falling back to system default")
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Recording input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecordingError.engineStartFailed("No audio input available")
        }

        // Target format: 16kHz mono Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecordingError.engineStartFailed("Cannot create target audio format")
        }

        let tapFormat = Self.monoTapFormat(for: inputFormat)

        let converter = AVAudioConverter(from: tapFormat, to: targetFormat)
        guard let converter else {
            throw AudioRecordingError.engineStartFailed("Cannot create audio converter")
        }

        bufferLock.lock()
        sampleBuffer.removeAll()
        _peakRawAudioLevel = 0
        bufferLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: Self.captureTapFrames, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioRecordingError.engineStartFailed(error.localizedDescription)
        }

        engineLock.withLock { audioEngine = engine }
        isRecording = true

        // Restart engine when macOS changes audio config (e.g. notification sounds)
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func stopRecording(policy: StopPolicy) async -> [Float] {
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

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
    private func handleConfigurationChange() {
        let engine: AVAudioEngine? = engineLock.withLock { audioEngine }
        guard isRecording, let engine else { return }
        logger.warning("Audio engine configuration changed during recording, restarting engine")

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let deviceID = selectedDeviceID
        if let deviceID {
            if !setInputDevice(deviceID, on: engine, label: "config-change") {
                logger.warning("Failed to re-set device after config change (\(deviceID)), using default")
            }
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Config-change input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("Cannot restart engine: no audio input available")
            return
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            logger.error("Cannot restart engine: failed to create target format")
            return
        }

        let tapFormat = Self.monoTapFormat(for: inputFormat)

        guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
            logger.error("Cannot restart engine: failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: Self.captureTapFrames, format: tapFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        do {
            try engine.start()
            logger.info("Audio engine restarted successfully")
        } catch {
            inputNode.removeTap(onBus: 0)
            logger.error("Failed to restart audio engine: \(error.localizedDescription)")
        }
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
}
