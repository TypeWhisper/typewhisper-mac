import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
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

private final class AudioFileChunkReader {
    private let audioFile: ExtAudioFileRef
    private let buffer: AVAudioPCMBuffer

    init(
        url: URL,
        clientFormat: AVAudioFormat,
        chunkFrameCount: AVAudioFrameCount
    ) throws {
        var openedFile: ExtAudioFileRef?
        let openStatus = ExtAudioFileOpenURL(url as CFURL, &openedFile)
        guard openStatus == noErr, let openedFile else {
            throw Self.error(operation: "open", url: url, status: openStatus)
        }

        var streamDescription = clientFormat.streamDescription.pointee
        let formatStatus = ExtAudioFileSetProperty(
            openedFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &streamDescription
        )
        guard formatStatus == noErr else {
            ExtAudioFileDispose(openedFile)
            throw Self.error(operation: "configure", url: url, status: formatStatus)
        }

        self.audioFile = openedFile
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: clientFormat,
            frameCapacity: chunkFrameCount
        ) else {
            ExtAudioFileDispose(openedFile)
            throw NSError(
                domain: "AudioRecorderService.AudioFileChunkReader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio finalization buffer."]
            )
        }
        self.buffer = buffer
    }

    deinit {
        ExtAudioFileDispose(audioFile)
    }

    func read() throws -> AVAudioPCMBuffer {
        var frameCount = buffer.frameCapacity
        buffer.frameLength = frameCount
        let readStatus = ExtAudioFileRead(audioFile, &frameCount, buffer.mutableAudioBufferList)
        guard readStatus == noErr else {
            throw Self.error(operation: "read", url: nil, status: readStatus)
        }
        buffer.frameLength = frameCount
        return buffer
    }

    private static func error(operation: String, url: URL?, status: OSStatus) -> NSError {
        var description = "Could not \(operation) audio during recorder finalization (OSStatus \(status))."
        if let url {
            description += " File: \(url.lastPathComponent)"
        }
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
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

    private struct MicDuckingProcessor {
        private let parameters: MicDuckingParameters
        private let holdSamples: Int
        private let envelopeAttack: Float
        private let envelopeRelease: Float
        private let gainAttack: Float
        private let gainRelease: Float
        private var systemEnvelope: Float = 0
        private var currentMicGain: Float = 1
        private var remainingHold = 0
        private(set) var minimumGain: Float = 1
        private var gainSum: Float = 0
        private var processedFrameCount = 0
        private var duckingEngaged = false

        init(parameters: MicDuckingParameters, sampleRate: Double) {
            self.parameters = parameters
            self.holdSamples = max(1, Int(sampleRate * parameters.holdTime))
            self.envelopeAttack = AudioRecorderService.smoothingCoefficient(
                timeConstant: parameters.envelopeAttackTime,
                sampleRate: sampleRate
            )
            self.envelopeRelease = AudioRecorderService.smoothingCoefficient(
                timeConstant: parameters.envelopeReleaseTime,
                sampleRate: sampleRate
            )
            self.gainAttack = AudioRecorderService.smoothingCoefficient(
                timeConstant: parameters.gainAttackTime,
                sampleRate: sampleRate
            )
            self.gainRelease = AudioRecorderService.smoothingCoefficient(
                timeConstant: parameters.gainReleaseTime,
                sampleRate: sampleRate
            )
        }

        mutating func gain(for referenceSample: Float) -> Float {
            let sampleMagnitude = abs(referenceSample)
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
                let progress = (systemEnvelope - parameters.lowThreshold)
                    / (parameters.highThreshold - parameters.lowThreshold)
                targetMicGain = 1 - progress * (1 - parameters.minimumMicGain)
                duckingEngaged = true
            }

            let gainCoefficient = targetMicGain < currentMicGain ? gainAttack : gainRelease
            currentMicGain = targetMicGain + gainCoefficient * (currentMicGain - targetMicGain)
            minimumGain = min(minimumGain, currentMicGain)
            gainSum += currentMicGain
            processedFrameCount += 1
            return currentMicGain
        }

        var summary: (minimumGain: Float, averageGain: Float)? {
            guard duckingEngaged, minimumGain < 0.99, processedFrameCount > 0 else { return nil }
            return (minimumGain, gainSum / Float(processedFrameCount))
        }
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

    struct StoppedRecording: Sendable {
        let finalOutputURL: URL?
        let micTempURL: URL?
        let systemTempURL: URL?
        let outputFormat: OutputFormat
        let trackMode: TrackMode
        let micDuckingMode: MicDuckingMode
        let transcriptionSamples: [Float]
        let usesFinalizationOverride: Bool
    }

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var systemAudioWarningMessage: String?

    /// Caps how often `micLevel`/`systemLevel` are actually published while
    /// recording. Audio buffers can arrive tens of times per second (mic
    /// taps) or even faster (system audio via ScreenCaptureKit, OS-paced),
    /// and each unthrottled `@Published` write triggers a SwiftUI re-render
    /// plus a Core Animation commit in every indicator view observing this
    /// service. Left unthrottled, that flood of main-run-loop work starves
    /// the queue used to deliver discrete `NSEvent.scrollWheel` ticks,
    /// making menus/lists feel laggy under mouse-wheel scrolling while
    /// recording (scrollbar-thumb dragging is unaffected, since AppKit just
    /// re-samples the mouse position on each pass of its own tracking loop
    /// instead of draining a backlog of discrete events).
    private let micLevelThrottle = LevelPublishThrottle()
    var recordingsDirectoryOverride: URL?
    var startRecordingOverride: ((
        _ micEnabled: Bool,
        _ systemAudioEnabled: Bool,
        _ format: OutputFormat,
        _ outputURL: URL,
        _ microphoneSelection: ResolvedRecordingInputSelection
    ) async throws -> URL)?
    var stopRecordingOverride: ((_ outputURL: URL) async throws -> URL?)?
    var currentBufferOverride: (() -> [Float])?

    private var audioEngine: AVAudioEngine?
    private var micInputCaptureSession: AudioInputCaptureSession?
    private let micDefaultInputController: AudioInputDeviceDefaultControlling = CoreAudioInputDeviceDefaultController()
    private let micTransportResolver: AudioDeviceTransportResolving = CoreAudioDeviceTransportResolver()
    private let micBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing
    private let micInputCaptureFactory: AudioInputCaptureFactory
    private let micInputActivationGuard: AudioInputDeviceActivating
    private let micFileLock = OSAllocatedUnfairLock<AVAudioFile?>(initialState: nil)
    private var scStream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var systemLevelSetter: SystemLevelSetter?
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
    static let finalizationChunkFrameCount: AVAudioFrameCount = 8_192

    init(
        inputActivationGuard: AudioInputDeviceActivating = AudioInputDeviceActivationGuard(),
        bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing = CoreAudioBluetoothInputRouteStabilizer(),
        inputCaptureFactory: AudioInputCaptureFactory = CoreAudioHALInputCaptureFactory()
    ) {
        self.micInputActivationGuard = inputActivationGuard
        self.micBluetoothInputRouteStabilizer = bluetoothInputRouteStabilizer
        self.micInputCaptureFactory = inputCaptureFactory
    }

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

    func startRecording(
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        format: OutputFormat,
        microphoneSelection: ResolvedRecordingInputSelection = .systemDefault
    ) async throws -> URL {
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
                self.finalOutputURL = try await startRecordingOverride(
                    micEnabled,
                    systemAudioEnabled,
                    format,
                    outputURL,
                    microphoneSelection
                )
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
                    try startMicRecording(outputURL: micURL, microphoneSelection: microphoneSelection)
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
        let stoppedRecording = await stopCapture()
        return await finalizeRecording(stoppedRecording)
    }

    func stopCapture(includeTranscriptionSamples: Bool = false) async -> StoppedRecording {
        // Stop timer
        durationTimer?.invalidate()
        durationTimer = nil
        endSystemAudioMonitoring()

        let usesFinalizationOverride = stopRecordingOverride != nil
        let stoppedMicEnabled = micEnabled
        let stoppedSystemAudioEnabled = systemAudioEnabled
        let stoppedMicTempURL = stoppedMicEnabled ? micTempURL : nil
        let stoppedSystemTempURL = stoppedSystemAudioEnabled ? systemTempURL : nil
        let stoppedFinalOutputURL = finalOutputURL
        let stoppedOutputFormat = outputFormat
        let stoppedTrackMode = trackMode
        let stoppedMicDuckingMode = micDuckingMode

        // Test overrides own their capture lifecycle. Production capture must be fully
        // stopped before any live-session or file finalization work begins.
        if !usesFinalizationOverride, stoppedMicEnabled {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
            micFileLock.withLock { $0 = nil }
        }

        if !usesFinalizationOverride, stoppedSystemAudioEnabled, let stream = scStream {
            do {
                try await stream.stopCapture()
            } catch {
                logger.error("Failed to stop SCStream: \(error.localizedDescription)")
            }
            scStream = nil
            sysFileLock.withLock { $0 = nil }
            streamOutput = nil
        }

        if !usesFinalizationOverride {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
            audioEngine = nil
            micInputCaptureSession?.stop()
            micInputCaptureSession = nil
            micInputActivationGuard.restore(reason: "recorder-mic-stop")
            micFileLock.withLock { $0 = nil }
        }

        let transcriptionSamples = includeTranscriptionSamples ? getCurrentBuffer() : []

        micTempURL = nil
        systemTempURL = nil
        finalOutputURL = nil
        startTime = nil

        // Must happen before the reset below: an already-scheduled flush
        // from a value received just before this stop would otherwise still
        // land afterward and restore a stale nonzero reading.
        micLevelThrottle.reset()
        systemLevelSetter?.reset()
        systemLevelSetter = nil

        DispatchQueue.main.async {
            self.isRecording = false
            self.duration = 0
            self.micLevel = 0
            self.systemLevel = 0
        }

        return StoppedRecording(
            finalOutputURL: stoppedFinalOutputURL,
            micTempURL: stoppedMicTempURL,
            systemTempURL: stoppedSystemTempURL,
            outputFormat: stoppedOutputFormat,
            trackMode: stoppedTrackMode,
            micDuckingMode: stoppedMicDuckingMode,
            transcriptionSamples: transcriptionSamples,
            usesFinalizationOverride: usesFinalizationOverride
        )
    }

    func finalizeRecording(_ stoppedRecording: StoppedRecording) async -> URL? {
        var completedURL = stoppedRecording.finalOutputURL

        if stoppedRecording.usesFinalizationOverride,
           let stopRecordingOverride,
           let finalURL = completedURL {
            do {
                completedURL = try await stopRecordingOverride(finalURL)
            } catch {
                logger.error("Failed to finalize recording with override: \(error.localizedDescription)")
                cleanupTempFile(finalURL)
                completedURL = nil
            }
        } else if let finalURL = completedURL {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try self.finalizeOutputFile(stoppedRecording)
                }.value
            } catch {
                logger.error("Failed to finalize recording: \(error.localizedDescription)")
                cleanupTempFile(finalURL)
                completedURL = nil
            }
        }

        cleanupTempFile(stoppedRecording.micTempURL)
        cleanupTempFile(stoppedRecording.systemTempURL)

        return completedURL
    }

    // MARK: - Microphone Recording

    private func startMicRecording(
        outputURL: URL,
        microphoneSelection: ResolvedRecordingInputSelection
    ) throws {
        if microphoneSelection.hasExplicitDeviceSelection,
           !microphoneSelection.usesBluetoothTransport,
           let deviceID = microphoneSelection.deviceID {
            try startInputOnlyMicRecording(deviceID: deviceID, outputURL: outputURL)
            return
        }

        if microphoneSelection.hasExplicitDeviceSelection,
           microphoneSelection.usesBluetoothTransport {
            guard micInputActivationGuard.activateIfNeeded(
                deviceID: microphoneSelection.deviceID,
                usesBluetoothTransport: true,
                reason: "recorder-mic-start"
            ) else {
                throw RecorderError.engineStartFailed("Selected microphone conflicts with the current audio route.")
            }

            guard micBluetoothInputRouteStabilizer.waitForActivatedDefaultInput(
                deviceID: microphoneSelection.deviceID,
                reason: "recorder-mic-start"
            ) else {
                micInputActivationGuard.restore(reason: "recorder-mic-route-stabilization-failed")
                throw RecorderError.engineStartFailed("Selected microphone did not become the active input route.")
            }
        }

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
                self.micLevelThrottle.publish(level) { [weak self] level in
                    self?.micLevel = level
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

    private func startInputOnlyMicRecording(deviceID: AudioDeviceID, outputURL: URL) throws {
        let inputFormat = try micInputCaptureFactory.inputOnlyCaptureFormat(deviceID: deviceID)
        guard let monoFormat = AudioInputBufferNormalizer.monoFloatFormat(for: inputFormat) else {
            throw RecorderError.engineStartFailed("Cannot create input-only microphone format")
        }

        let audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: monoFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )

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

        let session = try micInputCaptureFactory.startInputOnlyCapture(
            deviceID: deviceID,
            label: "recorder-mic",
            bufferSize: 4096
        ) { [weak self] buffer in
            guard let self,
                  let writeBuffer = AudioInputBufferNormalizer.monoFloatBuffer(from: buffer) else { return }

            if let channelData = writeBuffer.floatChannelData?[0] {
                let samples = UnsafeBufferPointer(start: channelData, count: Int(writeBuffer.frameLength))
                let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
                let level = min(1.0, rms * 5)
                self.micLevelThrottle.publish(level) { [weak self] level in
                    self?.micLevel = level
                }
            }

            self.micFileLock.withLock { file in
                guard let file else { return }
                do {
                    try file.write(from: writeBuffer)
                } catch {
                    logger.error("Failed to write input-only mic audio: \(error.localizedDescription)")
                }
            }

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

        micInputCaptureSession = session
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
        systemLevelSetter = levelSetter
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

    private func mixAudioFiles(
        micURL: URL,
        systemURL: URL,
        outputURL: URL,
        trackMode: TrackMode,
        micDuckingMode: MicDuckingMode,
        outputFormat: OutputFormat
    ) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: systemURL)

        let targetSampleRate = max(micFile.processingFormat.sampleRate, sysFile.processingFormat.sampleRate)
        let targetChannels: AVAudioChannelCount = 2

        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else { return }

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
        let micReader = try AudioFileChunkReader(
            url: micURL,
            clientFormat: mixFormat,
            chunkFrameCount: Self.finalizationChunkFrameCount
        )
        let systemReader = try AudioFileChunkReader(
            url: systemURL,
            clientFormat: mixFormat,
            chunkFrameCount: Self.finalizationChunkFrameCount
        )
        var duckingProcessor = trackMode == .mixed
            ? Self.makeMicDuckingProcessor(mode: micDuckingMode, sampleRate: targetSampleRate)
            : nil

        while true {
            let micBuffer = try micReader.read()
            let systemBuffer = try systemReader.read()
            let frameCount = max(micBuffer.frameLength, systemBuffer.frameLength)
            guard frameCount > 0 else { break }

            guard let mixedBuffer = AVAudioPCMBuffer(
                pcmFormat: mixFormat,
                frameCapacity: frameCount
            ) else {
                throw RecorderError.engineStartFailed("Cannot create finalization mix buffer")
            }
            mixedBuffer.frameLength = frameCount

            guard let outputLeft = mixedBuffer.floatChannelData?[0],
                  let outputRight = mixedBuffer.floatChannelData?[1],
                  let micLeft = micBuffer.floatChannelData?[0],
                  let micRight = micBuffer.floatChannelData?[1],
                  let systemLeft = systemBuffer.floatChannelData?[0],
                  let systemRight = systemBuffer.floatChannelData?[1] else {
                throw RecorderError.engineStartFailed("Cannot access finalization mix channels")
            }

            let micFrameCount = Int(micBuffer.frameLength)
            let systemFrameCount = Int(systemBuffer.frameLength)
            for index in 0..<Int(frameCount) {
                let hasMicFrame = index < micFrameCount
                let hasSystemFrame = index < systemFrameCount
                if trackMode == .separate {
                    outputLeft[index] = hasMicFrame ? (micLeft[index] + micRight[index]) * 0.5 : 0
                    outputRight[index] = hasSystemFrame
                        ? (systemLeft[index] + systemRight[index]) * 0.5
                        : 0
                    continue
                }

                let systemLeftSample = hasSystemFrame ? systemLeft[index] : 0
                let systemRightSample = hasSystemFrame ? systemRight[index] : 0
                let micGain = duckingProcessor?.gain(
                    for: (systemLeftSample + systemRightSample) * 0.5
                ) ?? 1
                outputLeft[index] = (hasMicFrame ? micLeft[index] * micGain : 0) + systemLeftSample
                outputRight[index] = (hasMicFrame ? micRight[index] * micGain : 0) + systemRightSample
            }

            try outputFile.write(from: mixedBuffer)
        }

        if let summary = duckingProcessor?.summary {
            logger.info("Applied mic ducking with minimum gain \(summary.minimumGain) and average gain \(summary.averageGain)")
        }
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

    private func finalizeOutputFile(_ stoppedRecording: StoppedRecording) throws {
        guard let finalURL = stoppedRecording.finalOutputURL else { return }

        if let micURL = stoppedRecording.micTempURL,
           let systemURL = stoppedRecording.systemTempURL {
            try mixAudioFiles(
                micURL: micURL,
                systemURL: systemURL,
                outputURL: finalURL,
                trackMode: stoppedRecording.trackMode,
                micDuckingMode: stoppedRecording.micDuckingMode,
                outputFormat: stoppedRecording.outputFormat
            )
        } else if let micURL = stoppedRecording.micTempURL {
            try copyOrConvert(
                from: micURL,
                to: finalURL,
                outputFormat: stoppedRecording.outputFormat
            )
        } else if let systemURL = stoppedRecording.systemTempURL {
            try copyOrConvert(
                from: systemURL,
                to: finalURL,
                outputFormat: stoppedRecording.outputFormat
            )
        }
    }

    private func copyOrConvert(from sourceURL: URL, to destinationURL: URL, outputFormat: OutputFormat) throws {
        switch outputFormat {
        case .wav:
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        case .m4a:
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            let sourceFormat = sourceFile.processingFormat
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: sourceFormat.channelCount,
                AVEncoderBitRateKey: 192000,
            ]
            let outputFile: AVAudioFile
            do {
                outputFile = try AVAudioFile(forWriting: destinationURL, settings: outputSettings)
            } catch {
                throw RecorderError.engineStartFailed(
                    "Cannot create M4A finalization output: \(error.localizedDescription)"
                )
            }
            let reader = try AudioFileChunkReader(
                url: sourceURL,
                clientFormat: outputFile.processingFormat,
                chunkFrameCount: Self.finalizationChunkFrameCount
            )

            while true {
                let buffer = try reader.read()
                guard buffer.frameLength > 0 else { break }
                do {
                    try outputFile.write(from: buffer)
                } catch {
                    throw RecorderError.engineStartFailed(
                        "Cannot write M4A finalization output: \(error.localizedDescription)"
                    )
                }
            }
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
    private static func makeMicDuckingProcessor(
        mode: MicDuckingMode,
        sampleRate: Double
    ) -> MicDuckingProcessor? {
        guard let parameters = micDuckingParameters(for: mode) else { return nil }
        return MicDuckingProcessor(parameters: parameters, sampleRate: sampleRate)
    }

    private static func buildMicDuckingProfile(
        frameCount: Int,
        sampleRate: Double,
        mode: MicDuckingMode,
        referenceSample: (Int) -> Float
    ) -> MicDuckingProfile? {
        guard frameCount > 0,
              var processor = makeMicDuckingProcessor(mode: mode, sampleRate: sampleRate) else {
            return nil
        }

        var gains = [Float](repeating: 1, count: frameCount)
        for index in 0..<frameCount {
            gains[index] = processor.gain(for: referenceSample(index))
        }

        guard let summary = processor.summary else { return nil }

        return MicDuckingProfile(
            gains: gains,
            minimumGain: summary.minimumGain,
            averageGain: summary.averageGain
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
        micInputCaptureSession?.stop()
        micInputCaptureSession = nil
        micInputActivationGuard.restore(reason: "recorder-mic-rollback")
        micFileLock.withLock { $0 = nil }

        cleanupTempFile(micTempURL)
        cleanupTempFile(systemTempURL)
        micTempURL = nil
        systemTempURL = nil
        finalOutputURL = nil
        transcriptionBufferLock.withLock { $0.reset() }

        // See the matching comment in stopCapture().
        micLevelThrottle.reset()
        systemLevelSetter?.reset()
        systemLevelSetter = nil

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
    private let throttle = LevelPublishThrottle()

    init(service: AudioRecorderService) {
        self.service = service
    }

    func setLevel(_ level: Float) {
        throttle.publish(level) { [weak service] level in
            service?.updateSystemLevel(level)
        }
    }

    /// See `LevelPublishThrottle.reset()`.
    func reset() {
        throttle.reset()
    }
}

// MARK: - Level Publish Throttle

/// Caps a value stream to at most one publish per `minInterval` — appropriate
/// for a UI level meter, where only the latest reading matters. Unlike a
/// naive throttle, a value that arrives inside the window is never silently
/// lost: it's held as `pending` and flushed once the window closes, so the
/// meter can't get stuck showing a stale reading if buffers happen to stop
/// arriving right after a drop. Thread-safe so it can be called from the
/// background audio/capture callback queues that produce levels.
///
/// Mirrors the equivalent `publishAudioLevel`/`flushPendingAudioLevelUpdate`
/// pattern already used at the same ~30 Hz cadence for the dictation audio
/// pipeline in `AudioRecordingService.swift`. Not shared into one type since
/// the two host services have unrelated lifecycles and this fix intentionally
/// stays scoped to the Recorder path that was reported laggy — worth
/// extracting if a third caller shows up.
private final class LevelPublishThrottle: @unchecked Sendable {
    private let minIntervalNanoseconds: UInt64
    private let lock = NSLock()
    private var lastPublishUptimeNanoseconds: UInt64 = 0
    private var pendingValue: Float?

    /// Defaults to ~30 Hz — smooth enough for a level meter while staying
    /// well clear of the main-run-loop contention that unthrottled
    /// buffer-rate publishing causes (see `micLevelThrottle` for details).
    init(minInterval: TimeInterval = 1.0 / 30.0) {
        self.minIntervalNanoseconds = UInt64(minInterval * 1_000_000_000)
    }

    /// Publishes `value` on the main queue via `deliver`, immediately if
    /// outside the throttle window, or after the remainder of the window
    /// elapses otherwise. Uses `DispatchTime.uptimeNanoseconds` (monotonic)
    /// rather than wall-clock time, since a wall-clock adjustment (NTP sync,
    /// manual clock change, DST) moving backward mid-recording would
    /// otherwise make the elapsed-time check permanently fail and freeze the
    /// meter until wall-clock time caught back up.
    func publish(_ value: Float, deliver: @escaping @Sendable (Float) -> Void) {
        var publishImmediately = false
        var flushDelayNanoseconds: UInt64?

        lock.lock()
        // Sampled under the lock, not before it: if `now` were captured
        // first, a concurrent `flushPending` could advance
        // `lastPublishUptimeNanoseconds` past this (now-stale) `now` while
        // this call was waiting on the lock, making the unsigned subtraction
        // below underflow/wrap to a huge value and slip an extra publish
        // through inside the throttle window.
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- lastPublishUptimeNanoseconds
        if lastPublishUptimeNanoseconds == 0 || elapsed >= minIntervalNanoseconds {
            lastPublishUptimeNanoseconds = now
            pendingValue = nil
            publishImmediately = true
        } else {
            let alreadyScheduled = pendingValue != nil
            pendingValue = value
            if !alreadyScheduled {
                flushDelayNanoseconds = minIntervalNanoseconds - elapsed
            }
        }
        lock.unlock()

        if publishImmediately {
            DispatchQueue.main.async { deliver(value) }
        }
        if let flushDelayNanoseconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(flushDelayNanoseconds))) { [weak self] in
                self?.flushPending(deliver: deliver)
            }
        }
    }

    private func flushPending(deliver: @Sendable (Float) -> Void) {
        lock.lock()
        let value = pendingValue
        pendingValue = nil
        if value != nil {
            lastPublishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()

        guard let value else { return }
        deliver(value)
    }

    /// Clears any pending value and rearms the throttle to publish
    /// immediately next time. Call this when a recording session ends and
    /// its level is explicitly reset to 0 — without it, a flush already
    /// scheduled from a value received just before the stop would otherwise
    /// still fire afterward and restore a stale nonzero reading.
    func reset() {
        lock.lock()
        pendingValue = nil
        lastPublishUptimeNanoseconds = 0
        lock.unlock()
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
