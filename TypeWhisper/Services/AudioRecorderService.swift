import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import ScreenCaptureKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecorderService")

struct SystemAudioSampleProcessingResult {
    let pcmBuffer: AVAudioPCMBuffer
    let frameCount: Int
    let rms: Float
    let level: Float
    let transcriptionSamples: [Float]
}

enum SystemAudioSampleProcessingError: LocalizedError {
    case invalidSampleBuffer
    case missingAudioFormat
    case unsupportedAudioFormat
    case emptyAudioBufferList
    case emptyAudioData
    case bufferListExtractionFailed(OSStatus)
    case cannotCreateOutputFormat
    case cannotCreatePCMBuffer

    var errorDescription: String? {
        switch self {
        case .invalidSampleBuffer:
            "Invalid system audio sample buffer."
        case .missingAudioFormat:
            "System audio sample buffer is missing its audio format."
        case .unsupportedAudioFormat:
            "Unsupported system audio sample format."
        case .emptyAudioBufferList:
            "System audio sample buffer did not contain audio buffers."
        case .emptyAudioData:
            "System audio sample buffer did not contain audio data."
        case .bufferListExtractionFailed(let status):
            "Could not read system audio buffer list: \(status)."
        case .cannotCreateOutputFormat:
            "Could not create system audio output format."
        case .cannotCreatePCMBuffer:
            "Could not create system audio PCM buffer."
        }
    }
}

struct SystemAudioSampleProcessor {
    static func process(
        _ sampleBuffer: CMSampleBuffer,
        transcriptionSampleRate: Double = AudioRecorderService.transcriptionSampleRate
    ) throws -> SystemAudioSampleProcessingResult {
        guard sampleBuffer.isValid else {
            throw SystemAudioSampleProcessingError.invalidSampleBuffer
        }
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw SystemAudioSampleProcessingError.missingAudioFormat
        }

        var bufferListSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard status == noErr, bufferListSizeNeeded > 0 else {
            throw SystemAudioSampleProcessingError.bufferListExtractionFailed(status)
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        rawPointer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferListSizeNeeded)

        var retainedBlockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: rawPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            throw SystemAudioSampleProcessingError.bufferListExtractionFailed(status)
        }

        let audioBufferList = UnsafeMutableAudioBufferListPointer(rawPointer.assumingMemoryBound(to: AudioBufferList.self))
        return try process(
            audioBufferList: audioBufferList,
            asbd: asbdPointer.pointee,
            transcriptionSampleRate: transcriptionSampleRate
        )
    }

    static func process(
        audioBufferList: UnsafeMutableAudioBufferListPointer,
        asbd: AudioStreamBasicDescription,
        transcriptionSampleRate: Double
    ) throws -> SystemAudioSampleProcessingResult {
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0,
              asbd.mBitsPerChannel > 0 else {
            throw SystemAudioSampleProcessingError.unsupportedAudioFormat
        }
        guard !audioBufferList.isEmpty else {
            throw SystemAudioSampleProcessingError.emptyAudioBufferList
        }

        let bytesPerSample = Int(asbd.mBitsPerChannel / 8)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard (isFloat && bytesPerSample == MemoryLayout<Float>.size)
            || (isSignedInteger && bytesPerSample == MemoryLayout<Int16>.size) else {
            throw SystemAudioSampleProcessingError.unsupportedAudioFormat
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = frameCount(
            in: audioBufferList,
            bytesPerSample: bytesPerSample,
            channelCount: channelCount,
            isNonInterleaved: isNonInterleaved
        )
        guard frameCount > 0 else {
            throw SystemAudioSampleProcessingError.emptyAudioData
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw SystemAudioSampleProcessingError.cannotCreateOutputFormat
        }
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw SystemAudioSampleProcessingError.cannotCreatePCMBuffer
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let outputChannels = pcmBuffer.floatChannelData else {
            throw SystemAudioSampleProcessingError.cannotCreatePCMBuffer
        }
        clear(outputChannels: outputChannels, channelCount: channelCount, frameCount: frameCount)

        if isNonInterleaved {
            copyNonInterleaved(
                audioBufferList,
                outputChannels: outputChannels,
                channelCount: channelCount,
                frameCount: frameCount,
                isFloat: isFloat
            )
        } else {
            try copyInterleaved(
                audioBufferList,
                outputChannels: outputChannels,
                channelCount: channelCount,
                frameCount: frameCount,
                isFloat: isFloat
            )
        }

        let rms = rms(outputChannels: outputChannels, channelCount: channelCount, frameCount: frameCount)
        return SystemAudioSampleProcessingResult(
            pcmBuffer: pcmBuffer,
            frameCount: frameCount,
            rms: rms,
            level: min(1, rms * 5),
            transcriptionSamples: transcriptionSamples(
                outputChannels: outputChannels,
                channelCount: channelCount,
                frameCount: frameCount,
                sampleRate: asbd.mSampleRate,
                targetSampleRate: transcriptionSampleRate
            )
        )
    }

    private static func frameCount(
        in audioBufferList: UnsafeMutableAudioBufferListPointer,
        bytesPerSample: Int,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> Int {
        if isNonInterleaved {
            let counts = audioBufferList.compactMap { buffer -> Int? in
                guard buffer.mData != nil else { return nil }
                let channels = max(1, Int(buffer.mNumberChannels))
                return Int(buffer.mDataByteSize) / max(1, bytesPerSample * channels)
            }
            return counts.min() ?? 0
        }

        let firstBuffer = audioBufferList[0]
        guard firstBuffer.mData != nil else { return 0 }
        let channels = max(1, Int(firstBuffer.mNumberChannels), channelCount)
        return Int(firstBuffer.mDataByteSize) / max(1, bytesPerSample * channels)
    }

    private static func clear(
        outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) {
        for channel in 0..<channelCount {
            outputChannels[channel].update(repeating: 0, count: frameCount)
        }
    }

    private static func copyInterleaved(
        _ audioBufferList: UnsafeMutableAudioBufferListPointer,
        outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        isFloat: Bool
    ) throws {
        let inputBuffer = audioBufferList[0]
        guard let data = inputBuffer.mData else {
            throw SystemAudioSampleProcessingError.emptyAudioData
        }
        let inputChannels = max(1, Int(inputBuffer.mNumberChannels), channelCount)

        if isFloat {
            let input = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    outputChannels[channel][frame] = input[frame * inputChannels + channel]
                }
            }
        } else {
            let input = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    outputChannels[channel][frame] = Float(input[frame * inputChannels + channel]) / Float(Int16.max)
                }
            }
        }
    }

    private static func copyNonInterleaved(
        _ audioBufferList: UnsafeMutableAudioBufferListPointer,
        outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        isFloat: Bool
    ) {
        var outputChannelIndex = 0
        for inputBuffer in audioBufferList {
            guard outputChannelIndex < channelCount, let data = inputBuffer.mData else { continue }
            let channelsInBuffer = max(1, Int(inputBuffer.mNumberChannels))
            if isFloat {
                let input = data.assumingMemoryBound(to: Float.self)
                for localChannel in 0..<channelsInBuffer where outputChannelIndex + localChannel < channelCount {
                    for frame in 0..<frameCount {
                        outputChannels[outputChannelIndex + localChannel][frame] = input[frame * channelsInBuffer + localChannel]
                    }
                }
            } else {
                let input = data.assumingMemoryBound(to: Int16.self)
                for localChannel in 0..<channelsInBuffer where outputChannelIndex + localChannel < channelCount {
                    for frame in 0..<frameCount {
                        outputChannels[outputChannelIndex + localChannel][frame] =
                            Float(input[frame * channelsInBuffer + localChannel]) / Float(Int16.max)
                    }
                }
            }
            outputChannelIndex += channelsInBuffer
        }
    }

    private static func rms(
        outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int
    ) -> Float {
        var sum: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = outputChannels[channel][frame]
                sum += sample * sample
            }
        }
        return sqrt(sum / Float(frameCount * channelCount))
    }

    private static func transcriptionSamples(
        outputChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        guard frameCount > 0, channelCount > 0, sampleRate > 0, targetSampleRate > 0 else { return [] }
        let decimationFactor = max(1, Int(sampleRate / targetSampleRate))
        var samples: [Float] = []
        samples.reserveCapacity(frameCount / decimationFactor)

        for frame in stride(from: 0, to: frameCount, by: decimationFactor) {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += outputChannels[channel][frame]
            }
            samples.append(sample / Float(channelCount))
        }

        return samples
    }
}

struct SystemAudioCaptureDiagnostics {
    private(set) var buffersReceived = 0
    private(set) var framesReceived = 0
    private(set) var lastErrorDescription: String?
    private(set) var lastNonSilentRMS: Float = 0
    private(set) var lastRMS: Float = 0
    private var sessionStartedAt: Date?
    private var isActive = false

    mutating func beginSession(startedAt: Date = Date()) {
        buffersReceived = 0
        framesReceived = 0
        lastErrorDescription = nil
        lastNonSilentRMS = 0
        lastRMS = 0
        sessionStartedAt = startedAt
        isActive = true
    }

    mutating func endSession() {
        isActive = false
    }

    mutating func recordProcessedBuffer(frameCount: Int, rms: Float, nonSilentThreshold: Float) {
        buffersReceived += 1
        framesReceived += frameCount
        lastErrorDescription = nil
        lastRMS = rms
        if rms >= nonSilentThreshold {
            lastNonSilentRMS = rms
        }
    }

    mutating func recordError(_ error: Error) {
        lastErrorDescription = error.localizedDescription
    }

    func noAudioWarningIfNeeded(now: Date, gracePeriod: TimeInterval) -> String? {
        guard isActive, let sessionStartedAt else { return nil }
        guard now.timeIntervalSince(sessionStartedAt) >= gracePeriod else { return nil }
        guard lastNonSilentRMS <= 0 else { return nil }
        return AudioRecorderService.noSystemAudioDetectedWarning
    }
}

/// Records audio from microphone and/or system audio to file.
/// Uses AVAudioEngine for mic and ScreenCaptureKit for system audio.
final class AudioRecorderService: ObservableObject, @unchecked Sendable {
    private struct MicDuckingProfile {
        let gains: [Float]
        let minimumGain: Float
        let averageGain: Float
    }

    private struct MicDuckingParameters {
        let minimumMicGain: Float
        let lowThreshold: Float
        let highThreshold: Float
        let holdTime: Double
        let envelopeAttackTime: Double
        let envelopeReleaseTime: Double
        let gainAttackTime: Double
        let gainReleaseTime: Double
    }

    enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case noSourceEnabled
        case engineStartFailed(String)
        case screenCaptureNotAvailable
        case outputDirectoryFailed

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                "Microphone permission denied."
            case .noSourceEnabled:
                "At least one audio source must be enabled."
            case .engineStartFailed(let detail):
                "Failed to start audio engine: \(detail)"
            case .screenCaptureNotAvailable:
                "Screen recording permission is required for system audio capture."
            case .outputDirectoryFailed:
                "Could not create recordings directory."
            }
        }
    }

    enum OutputFormat: String, CaseIterable, Sendable {
        case wav, m4a
        var fileExtension: String { rawValue }
    }

    enum TrackMode: String, CaseIterable, Sendable {
        case mixed
        case separate

        var displayName: String {
            switch self {
            case .mixed:
                return String(localized: "trackMode.mixed")
            case .separate:
                return String(localized: "trackMode.separate")
            }
        }
    }

    enum MicDuckingMode: String, CaseIterable, Sendable {
        case aggressive
        case medium
        case off

        var displayName: String {
            switch self {
            case .aggressive:
                return String(localized: "Aggressive")
            case .medium:
                return String(localized: "Medium")
            case .off:
                return String(localized: "Off")
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var systemAudioWarningMessage: String?
    var recordingsDirectoryOverride: URL?
    var startRecordingOverride: ((_ micEnabled: Bool, _ systemAudioEnabled: Bool, _ format: OutputFormat, _ outputURL: URL) async throws -> URL)?
    var stopRecordingOverride: ((_ outputURL: URL) async throws -> URL?)?
    var currentBufferOverride: (() -> [Float])?

    private var audioEngine: AVAudioEngine?
    private let micDefaultInputController: AudioInputDeviceDefaultControlling = CoreAudioInputDeviceDefaultController()
    private let micTransportResolver: AudioDeviceTransportResolving = CoreAudioDeviceTransportResolver()
    private let micFileLock = OSAllocatedUnfairLock<AVAudioFile?>(initialState: nil)
    private var scStream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private let sysFileLock = OSAllocatedUnfairLock<AVAudioFile?>(initialState: nil)
    private var durationTimer: Timer?
    private var startTime: Date?
    private let systemAudioDiagnosticsLock = OSAllocatedUnfairLock(initialState: SystemAudioCaptureDiagnostics())

    private var micTempURL: URL?
    private var systemTempURL: URL?
    private var finalOutputURL: URL?
    private var outputFormat: OutputFormat = .wav
    private var micEnabled = false
    private var systemAudioEnabled = false
    var trackMode: TrackMode = .mixed
    var micDuckingMode: MicDuckingMode = .aggressive

    // 16kHz mono buffer for streaming transcription
    private let transcriptionBufferLock = OSAllocatedUnfairLock<RecorderTranscriptionBuffer>(initialState: RecorderTranscriptionBuffer())
    static let transcriptionSampleRate: Double = 16000
    static var noSystemAudioDetectedWarning: String {
        localizedAppText(
            "No system audio was detected. If the other app is playing audio, macOS may be blocking that source from ScreenCaptureKit.",
            de: "Es wurde kein Systemaudio erkannt. Wenn die andere App Audio abspielt, blockiert macOS diese Quelle möglicherweise für ScreenCaptureKit."
        )
    }
    private static let systemAudioDetectionGracePeriod: TimeInterval = 2
    private static let systemAudioNonSilentThreshold: Float = 0.0001

    static let recordingsDirectoryName = "TypeWhisper Recordings"

    var recordingsDirectory: URL {
        if let recordingsDirectoryOverride {
            return recordingsDirectoryOverride
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.recordingsDirectoryName)
    }

    // MARK: - Transcription Buffer Access

    /// Thread-safe snapshot of the current 16kHz mono buffer for streaming transcription.
    func getCurrentBuffer() -> [Float] {
        if let currentBufferOverride {
            return currentBufferOverride()
        }
        let micEnabled = self.micEnabled
        let systemAudioEnabled = self.systemAudioEnabled
        let micDuckingMode = self.micDuckingMode
        return transcriptionBufferLock.withLock { buffer in
            buffer.currentBuffer(
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled,
                mixer: { range, micSamples, systemSamples in
                    Self.mixTranscriptionBuffer(
                        in: range,
                        micSamples: micSamples,
                        systemSamples: systemSamples,
                        micDuckingMode: micDuckingMode
                    )
                }
            )
        }
    }

    /// Returns at most the last `maxDuration` seconds of 16kHz audio.
    func getRecentBuffer(maxDuration: TimeInterval) -> [Float] {
        if let currentBufferOverride {
            let samples = currentBufferOverride()
            let maxSampleCount = Int(maxDuration * Self.transcriptionSampleRate)
            return Array(samples.suffix(maxSampleCount))
        }
        let micEnabled = self.micEnabled
        let systemAudioEnabled = self.systemAudioEnabled
        let micDuckingMode = self.micDuckingMode
        let maxSampleCount = Int(maxDuration * Self.transcriptionSampleRate)
        return transcriptionBufferLock.withLock { buffer in
            buffer.recentBuffer(
                maxSampleCount: maxSampleCount,
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled,
                mixer: { range, micSamples, systemSamples in
                    Self.mixTranscriptionBuffer(
                        in: range,
                        micSamples: micSamples,
                        systemSamples: systemSamples,
                        micDuckingMode: micDuckingMode
                    )
                }
            )
        }
    }

    /// Returns audio appended since `sampleOffset` and the updated absolute offset.
    func getBufferDelta(since sampleOffset: Int) -> (samples: [Float], nextOffset: Int) {
        if let currentBufferOverride {
            let samples = currentBufferOverride()
            let startIndex = min(max(0, sampleOffset), samples.count)
            return (Array(samples.dropFirst(startIndex)), samples.count)
        }
        let micEnabled = self.micEnabled
        let systemAudioEnabled = self.systemAudioEnabled
        let micDuckingMode = self.micDuckingMode
        return transcriptionBufferLock.withLock { buffer in
            buffer.delta(
                since: sampleOffset,
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled,
                mixer: { range, micSamples, systemSamples in
                    Self.mixTranscriptionBuffer(
                        in: range,
                        micSamples: micSamples,
                        systemSamples: systemSamples,
                        micDuckingMode: micDuckingMode
                    )
                }
            )
        }
    }

    /// Total duration of transcription buffer in seconds.
    var totalBufferDuration: TimeInterval {
        if let currentBufferOverride {
            return Double(currentBufferOverride().count) / Self.transcriptionSampleRate
        }
        return transcriptionBufferLock.withLock { buffer in
            Double(buffer.mixedSampleCount) / Self.transcriptionSampleRate
        }
    }

    func startRecording(micEnabled: Bool, systemAudioEnabled: Bool, format: OutputFormat) async throws -> URL {
        guard micEnabled || systemAudioEnabled else {
            throw RecorderError.noSourceEnabled
        }

        self.micEnabled = micEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.outputFormat = format
        resetSystemAudioMonitoring(systemAudioEnabled: systemAudioEnabled)

        // Clear transcription buffer
        transcriptionBufferLock.withLock { $0.reset() }

        // Create recordings directory
        let dir = recordingsDirectory
        try createDirectoryIfNeeded(dir)

        // Generate output filename
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let outputURL = dir.appendingPathComponent("Recording \(timestamp).\(format.fileExtension)")
        self.finalOutputURL = outputURL

        if let startRecordingOverride {
            do {
                self.finalOutputURL = try await startRecordingOverride(micEnabled, systemAudioEnabled, format, outputURL)
            } catch {
                await rollbackFailedStart()
                throw error
            }
        } else {
            // Setup temp files
            let tempDir = FileManager.default.temporaryDirectory
            let sessionId = UUID().uuidString

            do {
                // Start mic recording
                if micEnabled {
                    guard AVAudioApplication.shared.recordPermission == .granted else {
                        throw RecorderError.microphonePermissionDenied
                    }

                    let micURL = tempDir.appendingPathComponent("mic-\(sessionId).wav")
                    self.micTempURL = micURL
                    try startMicRecording(outputURL: micURL)
                }

                // Start system audio recording
                if systemAudioEnabled {
                    let sysURL = tempDir.appendingPathComponent("sys-\(sessionId).wav")
                    self.systemTempURL = sysURL
                    try await startSystemAudioRecording(outputURL: sysURL)
                }
            } catch {
                await rollbackFailedStart()
                throw error
            }
        }

        // Start duration timer
        startTime = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startTime = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            DispatchQueue.main.async {
                self.duration = elapsed
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer

        DispatchQueue.main.async {
            self.isRecording = true
        }

        return finalOutputURL ?? outputURL
    }

    func stopRecording() async -> URL? {
        // Stop timer
        durationTimer?.invalidate()
        durationTimer = nil
        endSystemAudioMonitoring()

        if let stopRecordingOverride, let finalURL = finalOutputURL {
            let completedURL: URL?
            do {
                completedURL = try await stopRecordingOverride(finalURL)
            } catch {
                logger.error("Failed to finalize recording with override: \(error.localizedDescription)")
                cleanupTempFile(finalURL)
                completedURL = nil
            }

            cleanupTempFile(micTempURL)
            cleanupTempFile(systemTempURL)
            micTempURL = nil
            systemTempURL = nil
            finalOutputURL = nil
            startTime = nil

            DispatchQueue.main.async {
                self.isRecording = false
                self.duration = 0
                self.micLevel = 0
                self.systemLevel = 0
            }

            return completedURL
        }

        // Stop mic
        if micEnabled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
            micFileLock.withLock { $0 = nil }
        }

        // Stop system audio
        if systemAudioEnabled, let stream = scStream {
            do {
                try await stream.stopCapture()
            } catch {
                logger.error("Failed to stop SCStream: \(error.localizedDescription)")
            }
            scStream = nil
            sysFileLock.withLock { $0 = nil }
            streamOutput = nil
        }

        var completedURL = finalOutputURL

        // Mix or copy to final output
        if let finalURL = completedURL {
            do {
                if micEnabled && systemAudioEnabled,
                   let micURL = micTempURL, let sysURL = systemTempURL {
                    try mixAudioFiles(micURL: micURL, systemURL: sysURL, outputURL: finalURL)
                } else if micEnabled, let micURL = micTempURL {
                    try copyOrConvert(from: micURL, to: finalURL)
                } else if systemAudioEnabled, let sysURL = systemTempURL {
                    try copyOrConvert(from: sysURL, to: finalURL)
                }
            } catch {
                logger.error("Failed to finalize recording: \(error.localizedDescription)")
                cleanupTempFile(finalURL)
                completedURL = nil
            }
        }

        // Cleanup temp files
        cleanupTempFile(micTempURL)
        cleanupTempFile(systemTempURL)
        micTempURL = nil
        systemTempURL = nil
        finalOutputURL = nil
        startTime = nil

        DispatchQueue.main.async {
            self.isRecording = false
            self.duration = 0
            self.micLevel = 0
            self.systemLevel = 0
        }

        return completedURL
    }

    // MARK: - Microphone Recording

    private func startMicRecording(outputURL: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.engineStartFailed("No audio input available")
        }

        if try enableMicVoiceProcessingIfNeeded(on: inputNode, currentFormat: inputFormat) {
            inputFormat = inputNode.outputFormat(forBus: 0)
        }

        // Write at native format to preserve quality
        let audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )

        // Mono format for writing
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let tapFormat = Self.micTapFormat(for: inputFormat)
        let converterInputFormat = tapFormat.channelCount == 1
            ? tapFormat
            : (AudioInputBufferNormalizer.monoFloatFormat(for: tapFormat) ?? tapFormat)
        let converter: AVAudioConverter?
        if Self.audioFormatsMatch(converterInputFormat, monoFormat) {
            converter = nil
        } else {
            converter = AVAudioConverter(from: converterInputFormat, to: monoFormat)
        }

        // 16kHz converter for transcription buffer
        guard let transcriptionFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.transcriptionSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.engineStartFailed("Cannot create transcription format")
        }
        let transcriptionConverter = AVAudioConverter(from: monoFormat, to: transcriptionFormat)

        micFileLock.withLock { $0 = audioFile }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let micBuffer = Self.normalizedMicInputBuffer(buffer) else { return }

            let writeBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCount = AVAudioFrameCount(micBuffer.frameLength)
                guard let converted = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else { return }
                var error: NSError?
                let consumed = OSAllocatedUnfairLock(initialState: false)
                converter.convert(to: converted, error: &error) { _, outStatus in
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
                    return micBuffer
                }
                guard error == nil, converted.frameLength > 0 else { return }
                writeBuffer = converted
            } else {
                writeBuffer = micBuffer
            }

            // Calculate level
            if let channelData = writeBuffer.floatChannelData?[0] {
                let samples = UnsafeBufferPointer(start: channelData, count: Int(writeBuffer.frameLength))
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                let level = min(1.0, rms * 5)
                DispatchQueue.main.async {
                    self.micLevel = level
                }
            }

            // Write to file
            self.micFileLock.withLock { file in
                guard let file else { return }
                do {
                    try file.write(from: writeBuffer)
                } catch {
                    logger.error("Failed to write mic audio: \(error.localizedDescription)")
                }
            }

            // Convert to 16kHz mono for transcription buffer
            if let transcriptionConverter {
                let targetFrameCount = AVAudioFrameCount(
                    Double(writeBuffer.frameLength) * Self.transcriptionSampleRate / monoFormat.sampleRate
                )
                guard targetFrameCount > 0,
                      let convertedBuffer = AVAudioPCMBuffer(pcmFormat: transcriptionFormat, frameCapacity: targetFrameCount) else { return }
                var convError: NSError?
                let convConsumed = OSAllocatedUnfairLock(initialState: false)
                transcriptionConverter.convert(to: convertedBuffer, error: &convError) { _, outStatus in
                    let wasConsumed = convConsumed.withLock { flag in
                        let prev = flag
                        flag = true
                        return prev
                    }
                    if wasConsumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return writeBuffer
                }
                if convError == nil, convertedBuffer.frameLength > 0,
                   let data = convertedBuffer.floatChannelData?[0] {
                    let samples = Array(UnsafeBufferPointer(start: data, count: Int(convertedBuffer.frameLength)))
                    self.appendMicTranscriptionSamples(samples)
                }
            }
        }

        try engine.start()
        audioEngine = engine
    }

    private func enableMicVoiceProcessingIfNeeded(
        on inputNode: AVAudioInputNode,
        currentFormat: AVAudioFormat
    ) throws -> Bool {
        guard currentFormat.channelCount == 3,
              defaultInputUsesBuiltInTransport() else {
            return false
        }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingBypassed = false
            inputNode.isVoiceProcessingAGCEnabled = true
            inputNode.isVoiceProcessingInputMuted = false
            logger.info("Recorder microphone enabled voice processing for 3-channel built-in default input")
            return true
        } catch {
            logger.warning("Recorder microphone could not enable voice processing for 3-channel built-in default input: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func defaultInputUsesBuiltInTransport() -> Bool {
        guard let defaultInputDeviceID = micDefaultInputController.defaultInputDeviceID(),
              let transportType = micTransportResolver.transportType(for: defaultInputDeviceID) else {
            return false
        }
        return transportType == kAudioDeviceTransportTypeBuiltIn
    }

    private static func micTapFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
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

    private static func normalizedMicInputBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else {
            return buffer
        }
        return AudioInputBufferNormalizer.monoFloatBuffer(from: buffer)
    }

    private static func audioFormatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    // MARK: - System Audio Recording

    private func startSystemAudioRecording(outputURL: URL) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw RecorderError.screenCaptureNotAvailable
        }

        guard let display = content.displays.first else {
            throw RecorderError.screenCaptureNotAvailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimize video capture - we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        config.sampleRate = 48000
        config.channelCount = 2

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let audioFile = try AVAudioFile(forWriting: outputURL, settings: audioSettings)
        sysFileLock.withLock { $0 = audioFile }

        let output = SystemAudioStreamOutput()
        output.fileLock = sysFileLock
        let levelSetter = SystemLevelSetter(service: self)
        output.levelCallback = { level in
            levelSetter.setLevel(level)
        }
        output.transcriptionBufferCallback = { [weak self] samples in
            self?.appendSystemTranscriptionSamples(samples)
        }
        output.processingResultCallback = { [weak self] result in
            self?.recordSystemAudioProcessingResult(result)
        }
        output.processingErrorCallback = { [weak self] error in
            self?.recordSystemAudioProcessingError(error)
        }

        streamOutput = output

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.typewhisper.system-audio", qos: .userInteractive))

        try await stream.startCapture()
        scStream = stream
        scheduleSystemAudioDetectionCheck()
    }

    // MARK: - Audio Mixing

    private func mixAudioFiles(micURL: URL, systemURL: URL, outputURL: URL) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: systemURL)

        // Use the higher sample rate
        let targetSampleRate = max(micFile.processingFormat.sampleRate, sysFile.processingFormat.sampleRate)
        let targetChannels: AVAudioChannelCount = 2

        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else { return }

        // Determine total length in frames at target sample rate
        let micDuration = Double(micFile.length) / micFile.processingFormat.sampleRate
        let sysDuration = Double(sysFile.length) / sysFile.processingFormat.sampleRate
        let totalDuration = max(micDuration, sysDuration)
        let totalFrames = AVAudioFrameCount(totalDuration * targetSampleRate)

        guard totalFrames > 0 else { return }

        // Read and convert both sources
        let micBuffer = try readAndConvert(file: micFile, to: mixFormat, totalFrames: totalFrames)
        let sysBuffer = try readAndConvert(file: sysFile, to: mixFormat, totalFrames: totalFrames)

        let micDuckingProfile: MicDuckingProfile?
        if trackMode == .mixed,
           let systemLeft = sysBuffer.floatChannelData?[0] {
            let systemRight = sysBuffer.format.channelCount > 1 ? sysBuffer.floatChannelData?[1] : nil
            micDuckingProfile = Self.buildMicDuckingProfile(
                frameCount: Int(totalFrames),
                sampleRate: targetSampleRate,
                mode: micDuckingMode
            ) { index in
                monoSample(left: systemLeft, right: systemRight, index: index)
            }
        } else {
            micDuckingProfile = nil
        }

        if let micDuckingProfile {
            logger.info("Applied mic ducking with minimum gain \(micDuckingProfile.minimumGain) and average gain \(micDuckingProfile.averageGain)")
        }

        // Mix buffers
        guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: totalFrames) else { return }
        mixedBuffer.frameLength = totalFrames

        if trackMode == .separate {
            guard let leftData = mixedBuffer.floatChannelData?[0],
                  let rightData = mixedBuffer.floatChannelData?[1],
                  let micLeft = micBuffer.floatChannelData?[0],
                  let systemLeft = sysBuffer.floatChannelData?[0] else { return }

            let micRight = micBuffer.format.channelCount > 1 ? micBuffer.floatChannelData?[1] : nil
            let systemRight = sysBuffer.format.channelCount > 1 ? sysBuffer.floatChannelData?[1] : nil

            for i in 0..<Int(totalFrames) {
                leftData[i] = i < Int(micBuffer.frameLength)
                    ? monoSample(left: micLeft, right: micRight, index: i)
                    : 0
            }

            for i in 0..<Int(totalFrames) {
                rightData[i] = i < Int(sysBuffer.frameLength)
                    ? monoSample(left: systemLeft, right: systemRight, index: i)
                    : 0
            }
        } else {
            for ch in 0..<Int(targetChannels) {
                guard let mixedData = mixedBuffer.floatChannelData?[ch],
                      let micData = micBuffer.floatChannelData?[ch],
                      let sysData = sysBuffer.floatChannelData?[ch] else { continue }

                for i in 0..<Int(totalFrames) {
                    let micSample = i < Int(micBuffer.frameLength) ? micData[i] : 0
                    let sysSample = i < Int(sysBuffer.frameLength) ? sysData[i] : 0
                    let micGain = micDuckingProfile?.gains[i] ?? 1
                    mixedData[i] = (micSample * micGain) + sysSample
                }
            }
        }

        // Write output
        let outputSettings: [String: Any]
        switch outputFormat {
        case .wav:
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: targetChannels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        case .m4a:
            outputSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: targetChannels,
                AVEncoderBitRateKey: 192000,
            ]
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        try outputFile.write(from: mixedBuffer)
    }

    private func readAndConvert(file: AVAudioFile, to targetFormat: AVAudioFormat, totalFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let sourceFormat = file.processingFormat
        let sourceFrames = AVAudioFrameCount(file.length)

        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrames) else {
            throw RecorderError.engineStartFailed("Cannot create read buffer")
        }
        try file.read(into: sourceBuffer)

        // If formats match, just zero-pad to totalFrames
        if sourceFormat.sampleRate == targetFormat.sampleRate && sourceFormat.channelCount == targetFormat.channelCount {
            guard let padded = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames) else {
                return sourceBuffer
            }
            padded.frameLength = totalFrames
            for ch in 0..<Int(targetFormat.channelCount) {
                guard let dst = padded.floatChannelData?[ch],
                      let src = sourceBuffer.floatChannelData?[ch] else { continue }
                let copyCount = min(Int(sourceFrames), Int(totalFrames))
                dst.update(from: src, count: copyCount)
                if copyCount < Int(totalFrames) {
                    dst.advanced(by: copyCount).update(repeating: 0, count: Int(totalFrames) - copyCount)
                }
            }
            return padded
        }

        // Convert format
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw RecorderError.engineStartFailed("Cannot create audio converter for mixing")
        }

        let convertedFrames = AVAudioFrameCount(Double(sourceFrames) * targetFormat.sampleRate / sourceFormat.sampleRate)
        let outputFrames = max(convertedFrames, totalFrames)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else {
            throw RecorderError.engineStartFailed("Cannot create converted buffer")
        }

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
            return sourceBuffer
        }

        if let error { throw error }

        // Zero-pad if needed
        if convertedBuffer.frameLength < totalFrames {
            guard let padded = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames) else {
                return convertedBuffer
            }
            padded.frameLength = totalFrames
            for ch in 0..<Int(targetFormat.channelCount) {
                guard let dst = padded.floatChannelData?[ch],
                      let src = convertedBuffer.floatChannelData?[ch] else { continue }
                let copyCount = Int(convertedBuffer.frameLength)
                dst.update(from: src, count: copyCount)
                dst.advanced(by: copyCount).update(repeating: 0, count: Int(totalFrames) - copyCount)
            }
            return padded
        }

        return convertedBuffer
    }

    // MARK: - Level Update (called from SystemLevelSetter on main queue)

    fileprivate func updateSystemLevel(_ level: Float) {
        systemLevel = level
    }

    // MARK: - System Audio Diagnostics

    private func resetSystemAudioMonitoring(systemAudioEnabled: Bool) {
        systemAudioDiagnosticsLock.withLock { diagnostics in
            if systemAudioEnabled {
                diagnostics.beginSession()
            } else {
                diagnostics.endSession()
            }
        }
        setSystemAudioWarningMessage(nil)
    }

    private func endSystemAudioMonitoring() {
        systemAudioDiagnosticsLock.withLock { diagnostics in
            diagnostics.endSession()
        }
    }

    private func scheduleSystemAudioDetectionCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.systemAudioDetectionGracePeriod) { [weak self] in
            self?.publishSystemAudioWarningIfNeeded()
        }
    }

    private func recordSystemAudioProcessingResult(_ result: SystemAudioSampleProcessingResult) {
        let shouldClearWarning = result.rms >= Self.systemAudioNonSilentThreshold
        let warning = systemAudioDiagnosticsLock.withLock { diagnostics in
            diagnostics.recordProcessedBuffer(
                frameCount: result.frameCount,
                rms: result.rms,
                nonSilentThreshold: Self.systemAudioNonSilentThreshold
            )
            return diagnostics.noAudioWarningIfNeeded(
                now: Date(),
                gracePeriod: Self.systemAudioDetectionGracePeriod
            )
        }

        if shouldClearWarning {
            setSystemAudioWarningMessage(nil)
        } else if let warning {
            setSystemAudioWarningMessage(warning)
        }
    }

    private func recordSystemAudioProcessingError(_ error: Error) {
        let warning = systemAudioDiagnosticsLock.withLock { diagnostics in
            diagnostics.recordError(error)
            return diagnostics.noAudioWarningIfNeeded(
                now: Date(),
                gracePeriod: Self.systemAudioDetectionGracePeriod
            )
        }

        if let warning {
            setSystemAudioWarningMessage(warning)
        }
    }

    private func publishSystemAudioWarningIfNeeded() {
        let warning = systemAudioDiagnosticsLock.withLock { diagnostics in
            diagnostics.noAudioWarningIfNeeded(
                now: Date(),
                gracePeriod: Self.systemAudioDetectionGracePeriod
            )
        }

        if let warning {
            setSystemAudioWarningMessage(warning)
        }
    }

    private func setSystemAudioWarningMessage(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.systemAudioWarningMessage = message
        }
    }

    // MARK: - Helpers

    private func copyOrConvert(from sourceURL: URL, to destinationURL: URL) throws {
        switch outputFormat {
        case .wav:
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        case .m4a:
            // Convert WAV to M4A
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let sourceFormat = sourceFile.processingFormat
            let sourceFrames = AVAudioFrameCount(sourceFile.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrames) else { return }
            try sourceFile.read(into: buffer)

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount,
                AVEncoderBitRateKey: 192000,
            ]
            let outputFile = try AVAudioFile(forWriting: destinationURL, settings: outputSettings)
            try outputFile.write(from: buffer)
        }
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func cleanupTempFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // Aggressively duck the mic while system audio is active to avoid replaying the same content twice.
    private static func buildMicDuckingProfile(
        frameCount: Int,
        sampleRate: Double,
        mode: MicDuckingMode,
        referenceSample: (Int) -> Float
    ) -> MicDuckingProfile? {
        guard frameCount > 0,
              let parameters = micDuckingParameters(for: mode) else {
            return nil
        }

        let holdSamples = max(1, Int(sampleRate * parameters.holdTime))
        let envelopeAttack = smoothingCoefficient(timeConstant: parameters.envelopeAttackTime, sampleRate: sampleRate)
        let envelopeRelease = smoothingCoefficient(timeConstant: parameters.envelopeReleaseTime, sampleRate: sampleRate)
        let gainAttack = smoothingCoefficient(timeConstant: parameters.gainAttackTime, sampleRate: sampleRate)
        let gainRelease = smoothingCoefficient(timeConstant: parameters.gainReleaseTime, sampleRate: sampleRate)

        var gains = [Float](repeating: 1, count: frameCount)
        var systemEnvelope: Float = 0
        var currentMicGain: Float = 1
        var remainingHold = 0
        var minimumGain: Float = 1
        var gainSum: Float = 0
        var duckingEngaged = false

        for index in 0..<frameCount {
            let sampleMagnitude = abs(referenceSample(index))
            let envelopeCoefficient = sampleMagnitude > systemEnvelope ? envelopeAttack : envelopeRelease
            systemEnvelope = sampleMagnitude + envelopeCoefficient * (systemEnvelope - sampleMagnitude)

            let targetMicGain: Float
            if systemEnvelope >= parameters.highThreshold {
                targetMicGain = parameters.minimumMicGain
                remainingHold = holdSamples
                duckingEngaged = true
            } else if systemEnvelope <= parameters.lowThreshold {
                if remainingHold > 0 {
                    remainingHold -= 1
                    targetMicGain = parameters.minimumMicGain
                    duckingEngaged = true
                } else {
                    targetMicGain = 1
                }
            } else {
                let progress = (systemEnvelope - parameters.lowThreshold) / (parameters.highThreshold - parameters.lowThreshold)
                targetMicGain = 1 - progress * (1 - parameters.minimumMicGain)
                duckingEngaged = true
            }

            let gainCoefficient = targetMicGain < currentMicGain ? gainAttack : gainRelease
            currentMicGain = targetMicGain + gainCoefficient * (currentMicGain - targetMicGain)

            gains[index] = currentMicGain
            minimumGain = min(minimumGain, currentMicGain)
            gainSum += currentMicGain
        }

        guard duckingEngaged, minimumGain < 0.99 else { return nil }

        return MicDuckingProfile(
            gains: gains,
            minimumGain: minimumGain,
            averageGain: gainSum / Float(frameCount)
        )
    }

    private static func micDuckingParameters(for mode: MicDuckingMode) -> MicDuckingParameters? {
        switch mode {
        case .aggressive:
            return MicDuckingParameters(
                minimumMicGain: 0.18,
                lowThreshold: 0.006,
                highThreshold: 0.025,
                holdTime: 0.12,
                envelopeAttackTime: 0.008,
                envelopeReleaseTime: 0.06,
                gainAttackTime: 0.02,
                gainReleaseTime: 0.28
            )
        case .medium:
            return MicDuckingParameters(
                minimumMicGain: 0.42,
                lowThreshold: 0.01,
                highThreshold: 0.04,
                holdTime: 0.08,
                envelopeAttackTime: 0.012,
                envelopeReleaseTime: 0.08,
                gainAttackTime: 0.035,
                gainReleaseTime: 0.2
            )
        case .off:
            return nil
        }
    }

    private static func smoothingCoefficient(timeConstant: Double, sampleRate: Double) -> Float {
        guard timeConstant > 0, sampleRate > 0 else { return 0 }
        return Float(exp(-1.0 / (timeConstant * sampleRate)))
    }

    private func monoSample(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>?,
        index: Int
    ) -> Float {
        let leftSample = left[index]
        guard let right else { return leftSample }
        return (leftSample + right[index]) * 0.5
    }

    private func appendMicTranscriptionSamples(_ samples: [Float]) {
        transcriptionBufferLock.withLock { $0.appendMic(samples) }
    }

    private func appendSystemTranscriptionSamples(_ samples: [Float]) {
        transcriptionBufferLock.withLock { $0.appendSystem(samples) }
    }

    private static func mixTranscriptionBuffer(
        in range: Range<Int>,
        micSamples: [Float],
        systemSamples: [Float],
        micDuckingMode: MicDuckingMode
    ) -> [Float] {
        guard !range.isEmpty else { return [] }

        let duckingProfile = buildMicDuckingProfile(
            frameCount: range.count,
            sampleRate: transcriptionSampleRate,
            mode: micDuckingMode
        ) { relativeIndex in
            let absoluteIndex = range.lowerBound + relativeIndex
            return absoluteIndex < systemSamples.count ? systemSamples[absoluteIndex] : 0
        }

        var mixed = [Float](repeating: 0, count: range.count)
        for relativeIndex in 0..<range.count {
            let absoluteIndex = range.lowerBound + relativeIndex
            let micSample = absoluteIndex < micSamples.count ? micSamples[absoluteIndex] : 0
            let systemSample = absoluteIndex < systemSamples.count ? systemSamples[absoluteIndex] : 0
            let micGain = duckingProfile?.gains[relativeIndex] ?? 1
            mixed[relativeIndex] = max(-1, min(1, (systemSample + (micSample * micGain)) * 0.5))
        }

        return mixed
    }

    private func rollbackFailedStart() async {
        durationTimer?.invalidate()
        durationTimer = nil
        startTime = nil
        endSystemAudioMonitoring()

        if let stream = scStream {
            try? await stream.stopCapture()
        }
        scStream = nil
        streamOutput = nil
        sysFileLock.withLock { $0 = nil }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        micFileLock.withLock { $0 = nil }

        cleanupTempFile(micTempURL)
        cleanupTempFile(systemTempURL)
        micTempURL = nil
        systemTempURL = nil
        finalOutputURL = nil
        transcriptionBufferLock.withLock { $0.reset() }

        DispatchQueue.main.async {
            self.isRecording = false
            self.duration = 0
            self.micLevel = 0
            self.systemLevel = 0
        }
    }
}

// MARK: - System Level Setter (breaks Sendable capture chain for Swift 6)

private final class SystemLevelSetter: @unchecked Sendable {
    private weak var service: AudioRecorderService?

    init(service: AudioRecorderService) {
        self.service = service
    }

    func setLevel(_ level: Float) {
        DispatchQueue.main.async { [weak service] in
            service?.updateSystemLevel(level)
        }
    }
}

// MARK: - SCStream Output Handler

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var fileLock: OSAllocatedUnfairLock<AVAudioFile?>?
    var levelCallback: ((Float) -> Void)?
    var transcriptionBufferCallback: (([Float]) -> Void)?
    var processingResultCallback: ((SystemAudioSampleProcessingResult) -> Void)?
    var processingErrorCallback: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        do {
            let result = try SystemAudioSampleProcessor.process(sampleBuffer)
            processingResultCallback?(result)
            levelCallback?(result.level)

            fileLock?.withLock { file in
                guard let file else { return }
                do {
                    try file.write(from: result.pcmBuffer)
                } catch {
                    processingErrorCallback?(error)
                    logger.error("Failed to write system audio: \(error.localizedDescription)")
                }
            }

            if !result.transcriptionSamples.isEmpty {
                transcriptionBufferCallback?(result.transcriptionSamples)
            }
        } catch {
            processingErrorCallback?(error)
            logger.error("Failed to process system audio: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        processingErrorCallback?(error)
        logger.error("SCStream stopped with error: \(error.localizedDescription)")
    }
}
