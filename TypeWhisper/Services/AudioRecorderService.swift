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
                String(localized: "Microphone permission denied.")
            case .noSourceEnabled:
                String(localized: "At least one audio source must be enabled.")
            case .engineStartFailed(let detail):
                String(localized: "Failed to start audio engine: \(detail)")
            case .screenCaptureNotAvailable:
                String(localized: "Screen recording permission is required for system audio capture.")
            case .outputDirectoryFailed:
                String(localized: "Could not create recordings directory.")
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
        /// When the microphone carried the user's own speech; empty unless
        /// microphone and system audio were both captured.
        var ownSpeech: [ClosedRange<TimeInterval>] = []
        /// Frames of the mic file that repeated the audio of a frozen capture; the finished
        /// recording has silence there.
        var micSilencedFrameRanges: [Range<AVAudioFramePosition>] = []
    }

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var systemAudioWarningMessage: String?
    /// The latest time the microphone track stopped updating in this recording.
    @Published private(set) var microphoneIncident: RecorderMicrophoneIncident?

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
    var hasMicrophonePermissionOverride: Bool?
    /// The clock of the microphone watchdog, in uptime nanoseconds, which stops while the Mac
    /// sleeps. Tests move it by hand.
    var microphoneWatchdogUptime: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    /// Tests run the watchdog's checks themselves.
    var runsMicrophoneWatchdogTimer = true

    /// The running microphone capture, which the watchdog replaces when it stops updating.
    private let micCaptureLock = OSAllocatedUnfairLock(uncheckedState: MicrophoneCaptureState())
    private let micWatchdogQueue = DispatchQueue(label: "com.typewhisper.recorder-mic-watchdog", qos: .utility)
    private let micDefaultInputController: AudioInputDeviceDefaultControlling = CoreAudioInputDeviceDefaultController()
    private let micTransportResolver: AudioDeviceTransportResolving = CoreAudioDeviceTransportResolver()
    private let micBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing
    private let micInputCaptureFactory: AudioInputCaptureFactory
    private let micInputActivationGuard: AudioInputDeviceActivating
    private let micFileLock = OSAllocatedUnfairLock(uncheckedState: MicrophoneFileState())
    private var scStream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var systemLevelSetter: SystemLevelSetter?
    private let sysFileLock = OSAllocatedUnfairLock<AVAudioFile?>(uncheckedState: nil)
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

    /// The Recorder folder the user chose. Without a store, recordings go to the default folder.
    let folderStore: RecorderFolderStore?

    init(
        inputActivationGuard: AudioInputDeviceActivating = AudioInputDeviceActivationGuard(),
        bluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing = CoreAudioBluetoothInputRouteStabilizer(),
        inputCaptureFactory: AudioInputCaptureFactory = CoreAudioHALInputCaptureFactory(),
        folderStore: RecorderFolderStore? = nil
    ) {
        self.micInputActivationGuard = inputActivationGuard
        self.micBluetoothInputRouteStabilizer = bluetoothInputRouteStabilizer
        self.micInputCaptureFactory = inputCaptureFactory
        self.folderStore = folderStore
    }

    /// The folder new recordings are saved to.
    var recordingsDirectory: URL {
        if let recordingsDirectoryOverride {
            return recordingsDirectoryOverride
        }
        return folderStore?.destinationForNewRecordings() ?? RecorderFolderStore.defaultDirectory
    }

    /// The folders the Recorder lists recordings from: the folder new recordings go to, then
    /// earlier folders whose recordings stay where they were saved.
    var recordingsDirectories: [URL] {
        if let recordingsDirectoryOverride {
            return [recordingsDirectoryOverride]
        }
        return folderStore?.listedFolders() ?? [RecorderFolderStore.defaultDirectory]
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
        microphoneSelection: ResolvedRecordingInputSelection = .systemDefault,
        preferredBaseName: String? = nil
    ) async throws -> URL {
        guard micEnabled || systemAudioEnabled else {
            throw RecorderError.noSourceEnabled
        }

        self.micEnabled = micEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.outputFormat = format
        resetSystemAudioMonitoring(systemAudioEnabled: systemAudioEnabled)
        DispatchQueue.main.async { [weak self] in
            self?.microphoneIncident = nil
        }

        // Clear transcription buffer
        transcriptionBufferLock.withLock { $0.reset() }

        // Create recordings directory
        let dir = recordingsDirectory
        try createDirectoryIfNeeded(dir)

        // Generate output filename
        let baseName = preferredBaseName
            ?? CalendarMeetingRecordingFilename.preferredBaseName(title: "")
        let outputURL = CalendarMeetingRecordingFilename.availableURL(
            in: dir,
            preferredBaseName: baseName,
            fileExtension: format.fileExtension
        )
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
            let sessionId = UUID().uuidString

            do {
                // Start mic recording
                if micEnabled {
                    guard hasMicrophonePermissionOverride ?? (AVAudioApplication.shared.recordPermission == .granted) else {
                        throw RecorderError.microphonePermissionDenied
                    }

                    let micURL = UserDataLocations.temporaryItemURL("Recorder-mic-\(sessionId).wav")
                    self.micTempURL = micURL
                    try startMicRecording(outputURL: micURL, microphoneSelection: microphoneSelection)
                }

                // Start system audio recording
                if systemAudioEnabled {
                    let sysURL = UserDataLocations.temporaryItemURL("Recorder-sys-\(sessionId).wav")
                    self.systemTempURL = sysURL
                    try await startSystemAudioRecording(outputURL: sysURL)
                }
            } catch {
                await rollbackFailedStart()
                throw error
            }

            if micEnabled {
                startMicrophoneWatchdog()
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
        var micSilencedFrameRanges: [Range<AVAudioFramePosition>] = []
        if !usesFinalizationOverride {
            let silencedFrameRanges = await stopMicrophoneCapture()
            if stoppedMicEnabled {
                micSilencedFrameRanges = silencedFrameRanges
            }
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
            micInputActivationGuard.restore(reason: "recorder-mic-stop")
        }

        let transcriptionSamples = includeTranscriptionSamples ? getCurrentBuffer() : []
        let ownSpeech = includeTranscriptionSamples && stoppedMicEnabled && stoppedSystemAudioEnabled
            ? transcriptionBufferLock.withLock { buffer in
                SpeakerChannelAttribution.ownSpeechRanges(
                    microphone: buffer.micSamples,
                    system: buffer.systemSamples,
                    sampleRate: Self.transcriptionSampleRate
                )
            }
            : []

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
            usesFinalizationOverride: usesFinalizationOverride,
            ownSpeech: ownSpeech,
            micSilencedFrameRanges: micSilencedFrameRanges
        )
    }

    func finalizeRecording(_ stoppedRecording: StoppedRecording) async -> URL? {
        var completedURL: URL?
        if let finalURL = stoppedRecording.finalOutputURL {
            do {
                completedURL = try await writeFinalRecording(stoppedRecording, to: finalURL)
            } catch {
                logger.error("Failed to finalize recording: \(error.localizedDescription)")
                cleanupTempFile(finalURL)
                completedURL = await writeFinalRecordingToFallbackFolder(stoppedRecording, after: finalURL)
            }
        }
        if let completedURL {
            folderStore?.noteRecordingSaved(at: completedURL)
        }

        cleanupTempFile(stoppedRecording.micTempURL)
        cleanupTempFile(stoppedRecording.systemTempURL)

        return completedURL
    }

    private func writeFinalRecording(_ stoppedRecording: StoppedRecording, to url: URL) async throws -> URL? {
        if stoppedRecording.usesFinalizationOverride, let stopRecordingOverride {
            return try await stopRecordingOverride(url)
        }
        try await Task.detached(priority: .userInitiated) {
            try self.finalizeOutputFile(stoppedRecording, to: url)
        }.value
        return url
    }

    /// Saves the recording to the default folder when its own folder failed, for example because
    /// its disk was disconnected during the recording, so that the recording is not lost.
    private func writeFinalRecordingToFallbackFolder(
        _ stoppedRecording: StoppedRecording,
        after failedURL: URL
    ) async -> URL? {
        guard let directory = folderStore?.fallbackDirectory(
            afterFailureIn: failedURL.deletingLastPathComponent()
        ) else { return nil }
        let fallbackURL = CalendarMeetingRecordingFilename.availableURL(
            in: directory,
            preferredBaseName: failedURL.deletingPathExtension().lastPathComponent,
            fileExtension: failedURL.pathExtension
        )
        do {
            try createDirectoryIfNeeded(directory)
            let url = try await writeFinalRecording(stoppedRecording, to: fallbackURL)
            logger.info("Saved the recording to the default Recorder folder instead")
            return url
        } catch {
            logger.error("Failed to save the recording to the default folder: \(error.localizedDescription)")
            cleanupTempFile(fallbackURL)
            return nil
        }
    }

    // MARK: - Microphone Recording

    private func startMicRecording(
        outputURL: URL,
        microphoneSelection: ResolvedRecordingInputSelection
    ) throws {
        if microphoneSelection.hasExplicitDeviceSelection,
           microphoneSelection.usesBluetoothTransport {
            guard micInputActivationGuard.activateIfNeeded(
                deviceID: microphoneSelection.deviceID,
                usesBluetoothTransport: true,
                reason: "recorder-mic-start"
            ) else {
                throw RecorderError.engineStartFailed(String(localized: "Selected microphone conflicts with the current audio route."))
            }

            guard micBluetoothInputRouteStabilizer.waitForActivatedDefaultInput(
                deviceID: microphoneSelection.deviceID,
                reason: "recorder-mic-start"
            ) else {
                micInputActivationGuard.restore(reason: "recorder-mic-route-stabilization-failed")
                throw RecorderError.engineStartFailed(String(localized: "Selected microphone did not become the active input route."))
            }
        }

        let generation = micCaptureLock.withLock { $0.generation + 1 }
        let capture = try makeMicrophoneCapture(
            selection: microphoneSelection,
            newFileURL: outputURL,
            generation: generation,
            resumesAfterUptime: nil
        )
        let startedAt = microphoneWatchdogUptime()
        let previous = micCaptureLock.withLock { state -> (RecorderMicrophoneCapture?, DispatchSourceTimer?) in
            let previous = (state.capture, state.watchdogTimer)
            state = MicrophoneCaptureState()
            state.isActive = true
            state.generation = generation
            state.selection = microphoneSelection
            state.fileFormat = capture.pipeline.fileFormat
            state.capture = capture
            state.recordingStartUptime = startedAt
            state.captureStartUptime = startedAt
            state.nextRepetitionCheckUptime = RecorderMicrophoneWatchdogPolicy.uptime(
                startedAt,
                advancedBy: RecorderMicrophoneWatchdogPolicy.repetitionCheckInterval
            )
            return previous
        }
        // A finished recording leaves nothing behind; this only guards against a missed stop.
        previous.1?.cancel()
        previous.0?.pipeline.token.retire()
        previous.0?.stop()
    }

    /// Starts capturing `selection`. The first capture of a recording creates the mic file at its
    /// own sample rate (`newFileURL`); a restarted capture writes into the existing file.
    private func makeMicrophoneCapture(
        selection: ResolvedRecordingInputSelection,
        newFileURL: URL?,
        generation: Int,
        resumesAfterUptime: UInt64?
    ) throws -> RecorderMicrophoneCapture {
        if selection.hasExplicitDeviceSelection,
           !selection.usesBluetoothTransport,
           let deviceID = selection.deviceID {
            return try makeInputOnlyMicrophoneCapture(
                deviceID: deviceID,
                newFileURL: newFileURL,
                generation: generation,
                resumesAfterUptime: resumesAfterUptime
            )
        }
        return try makeEngineMicrophoneCapture(
            newFileURL: newFileURL,
            generation: generation,
            resumesAfterUptime: resumesAfterUptime
        )
    }

    private func makeEngineMicrophoneCapture(
        newFileURL: URL?,
        generation: Int,
        resumesAfterUptime: UInt64?
    ) throws -> RecorderMicrophoneCapture {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.engineStartFailed(String(localized: "No audio input available"))
        }

        if try enableMicVoiceProcessingIfNeeded(on: inputNode, currentFormat: inputFormat) {
            inputFormat = inputNode.outputFormat(forBus: 0)
        }

        // Mono at the input's own rate, which is also the rate of a new mic file
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.engineStartFailed(String(localized: "No audio input available"))
        }

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

        let pipeline = try makeMicrophonePipeline(
            captureFormat: monoFormat,
            newFileURL: newFileURL,
            generation: generation,
            resumesAfterUptime: resumesAfterUptime
        )

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self, let micBuffer = Self.normalizedMicInputBuffer(buffer) else { return }
            let monoBuffer: AVAudioPCMBuffer
            if let converter {
                guard let converted = RecorderMicrophonePipeline.convert(
                    micBuffer,
                    using: converter,
                    to: monoFormat,
                    frameCapacity: micBuffer.frameLength
                ) else { return }
                monoBuffer = converted
            } else {
                monoBuffer = micBuffer
            }
            self.handleMicrophoneBuffer(monoBuffer, pipeline: pipeline)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        return RecorderMicrophoneCapture(pipeline: pipeline, engine: engine)
    }

    private func makeInputOnlyMicrophoneCapture(
        deviceID: AudioDeviceID,
        newFileURL: URL?,
        generation: Int,
        resumesAfterUptime: UInt64?
    ) throws -> RecorderMicrophoneCapture {
        let inputFormat = try micInputCaptureFactory.inputOnlyCaptureFormat(deviceID: deviceID)
        guard let monoFormat = AudioInputBufferNormalizer.monoFloatFormat(for: inputFormat) else {
            throw RecorderError.engineStartFailed(String(localized: "Cannot create input-only microphone format"))
        }

        let pipeline = try makeMicrophonePipeline(
            captureFormat: monoFormat,
            newFileURL: newFileURL,
            generation: generation,
            resumesAfterUptime: resumesAfterUptime
        )
        let session = try micInputCaptureFactory.startInputOnlyCapture(
            deviceID: deviceID,
            label: "recorder-mic",
            bufferSize: 4096,
            deliveryQueue: nil
        ) { [weak self] buffer in
            guard let self,
                  let monoBuffer = AudioInputBufferNormalizer.monoFloatBuffer(from: buffer) else { return }
            self.handleMicrophoneBuffer(monoBuffer, pipeline: pipeline)
        }
        return RecorderMicrophoneCapture(pipeline: pipeline, session: session)
    }

    private func makeMicrophonePipeline(
        captureFormat: AVAudioFormat,
        newFileURL: URL?,
        generation: Int,
        resumesAfterUptime: UInt64?
    ) throws -> RecorderMicrophonePipeline {
        let fileFormat: AVAudioFormat
        if let newFileURL {
            // Write at the input's rate to preserve quality
            let audioFile = try AVAudioFile(
                forWriting: newFileURL,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: captureFormat.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            )
            fileFormat = audioFile.processingFormat
            micFileLock.withLock { $0 = MicrophoneFileState(file: audioFile) }
        } else if let existingFormat = micCaptureLock.withLockUnchecked({ $0.fileFormat }) {
            fileFormat = existingFormat
        } else {
            throw RecorderError.engineStartFailed("The recording has no microphone file to continue.")
        }

        // 16kHz mono for the transcription buffer
        guard let transcriptionFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.transcriptionSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.engineStartFailed(String(localized: "Cannot create transcription format"))
        }

        // A restarted capture can run at another rate than the mic file, for example after the
        // input switched devices.
        let fileConverter: AVAudioConverter?
        if Self.audioFormatsMatch(captureFormat, fileFormat) {
            fileConverter = nil
        } else if let converter = AVAudioConverter(from: captureFormat, to: fileFormat) {
            fileConverter = converter
        } else {
            throw RecorderError.engineStartFailed("Cannot convert the microphone to the recording's sample rate.")
        }

        let pipeline = RecorderMicrophonePipeline(
            generation: generation,
            captureFormat: captureFormat,
            fileFormat: fileFormat,
            fileConverter: fileConverter,
            transcriptionFormat: transcriptionFormat,
            transcriptionConverter: AVAudioConverter(from: captureFormat, to: transcriptionFormat),
            resumesAfterUptime: resumesAfterUptime
        )
#if DEBUG
        if newFileURL != nil {
            pipeline.debugFault = RecorderMicrophoneDebugFault.configured()
        }
#endif
        return pipeline
    }

    /// Writes one mono buffer of a capture to the mic file and the transcription buffer.
    private func handleMicrophoneBuffer(_ incoming: AVAudioPCMBuffer, pipeline: RecorderMicrophonePipeline) {
        guard !pipeline.token.isRetired else { return }
        var buffer = incoming
#if DEBUG
        if let debugFault = pipeline.debugFault {
            guard let faulted = debugFault.apply(to: buffer) else { return }
            buffer = faulted
        }
#endif
        guard buffer.frameLength > 0, let channelData = buffer.floatChannelData?[0] else { return }

        let now = microphoneWatchdogUptime()
        let isFirstBuffer = pipeline.noteBuffer(at: now)

        // Calculate level
        let samples = UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        micLevelThrottle.publish(min(1.0, rms * 5)) { [weak self] level in
            self?.micLevel = level
        }

        // A restarted capture first fills the time the microphone delivered nothing with
        // silence, so the microphone track stays in step with the recording.
        let resumesRecording = isFirstBuffer && pipeline.resumesAfterUptime != nil
        let gap: TimeInterval
        if resumesRecording, let resumesAfterUptime = pipeline.resumesAfterUptime {
            let bufferDuration = Double(buffer.frameLength) / buffer.format.sampleRate
            gap = max(0, RecorderMicrophoneWatchdogPolicy.seconds(from: resumesAfterUptime, to: now) - bufferDuration)
        } else {
            gap = 0
        }

        // Write to file
        let fileBuffer = pipeline.fileBuffer(from: buffer)
        let fileSampleRate = pipeline.fileFormat.sampleRate
        let bufferFileFrame = micFileLock.withLock { state -> AVAudioFramePosition? in
            guard !pipeline.token.isRetired, let file = state.file else { return nil }
            do {
                if gap > 0 {
                    let gapFrames = AVAudioFramePosition((gap * fileSampleRate).rounded())
                    try RecorderMicrophonePipeline.writeSilence(frameCount: gapFrames, to: file)
                    state.framesWritten += gapFrames
                }
            } catch {
                logger.error("Failed to fill the mic gap with silence: \(error.localizedDescription)")
            }
            let bufferFileFrame = state.framesWritten
            if let fileBuffer {
                do {
                    try file.write(from: fileBuffer)
                    state.framesWritten += AVAudioFramePosition(fileBuffer.frameLength)
                    state.lastWriteUptime = now
                } catch {
                    logger.error("Failed to write mic audio: \(error.localizedDescription)")
                }
            }
            return bufferFileFrame
        }

        // 16kHz mono for the transcription buffer
        let transcriptionSamples = pipeline.transcriptionSamples(from: buffer)
        let gapSampleCount = Int((gap * Self.transcriptionSampleRate).rounded())
        let bufferTranscriptionIndex = transcriptionBufferLock.withLock { transcription -> Int? in
            guard !pipeline.token.isRetired else { return nil }
            transcription.appendMicSilence(count: gapSampleCount)
            let bufferTranscriptionIndex = transcription.micSamples.count
            transcription.appendMic(transcriptionSamples)
            return bufferTranscriptionIndex
        }

        if isFirstBuffer, let bufferFileFrame, let bufferTranscriptionIndex {
            pipeline.noteStart(RecorderMicrophonePipeline.StartPosition(
                fileFrame: bufferFileFrame,
                transcriptionIndex: bufferTranscriptionIndex
            ))
            if resumesRecording {
                microphoneCaptureResumed(
                    generation: pipeline.generation,
                    at: TimeInterval(bufferFileFrame) / fileSampleRate
                )
            }
        }
        pipeline.appendToHistory(buffer)
    }

    // MARK: - Microphone Watchdog

    /// Checks the microphone every second while it records: a capture can stop delivering
    /// audio, or freeze into a looping buffer that repeats the same audio (#1863), while the
    /// recording itself keeps running.
    private func startMicrophoneWatchdog() {
        guard runsMicrophoneWatchdogTimer else { return }
        micCaptureLock.withLock { state in
            guard state.isActive, state.watchdogTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: micWatchdogQueue)
            timer.schedule(
                deadline: .now() + RecorderMicrophoneWatchdogPolicy.checkInterval,
                repeating: RecorderMicrophoneWatchdogPolicy.checkInterval,
                leeway: .milliseconds(100)
            )
            timer.setEventHandler { [weak self] in
                self?.checkMicrophoneHealth()
            }
            state.watchdogTimer = timer
            timer.resume()
        }
    }

#if DEBUG
    /// Runs one watchdog check now, as the timer would.
    func testingCheckMicrophoneHealth() {
        micWatchdogQueue.sync { checkMicrophoneHealth() }
    }
#endif

    /// Restarts the microphone capture when it stopped delivering audio or keeps repeating it.
    /// Runs on the watchdog queue, like every restart.
    private func checkMicrophoneHealth() {
        let now = microphoneWatchdogUptime()
        let snapshot = micCaptureLock.withLock { state -> MicrophoneWatchdogSnapshot? in
            guard state.isActive else { return nil }
            let checksRepetition = now >= state.nextRepetitionCheckUptime
            if checksRepetition {
                state.nextRepetitionCheckUptime = RecorderMicrophoneWatchdogPolicy.uptime(
                    now,
                    advancedBy: RecorderMicrophoneWatchdogPolicy.repetitionCheckInterval
                )
            }
            return MicrophoneWatchdogSnapshot(
                pipeline: state.capture?.pipeline,
                generation: state.generation,
                captureStartUptime: state.captureStartUptime,
                checksRepetition: checksRepetition,
                retryUptime: state.retryUptime
            )
        }
        guard let snapshot else { return }

        guard let pipeline = snapshot.pipeline else {
            // The microphone could not be restarted yet.
            if let retryUptime = snapshot.retryUptime, now >= retryUptime {
                startReplacementMicrophoneCapture(generation: snapshot.generation)
            }
            return
        }

        if RecorderMicrophoneWatchdogPolicy.hasStalled(
            lastBufferUptime: pipeline.lastBufferUptime,
            captureStartUptime: snapshot.captureStartUptime,
            now: now
        ) {
            let framesWritten = micFileLock.withLock { $0.framesWritten }
            restartMicrophoneCapture(
                cause: .noAudio,
                stoppedAt: TimeInterval(framesWritten) / pipeline.fileFormat.sampleRate,
                repeatedFrom: nil,
                generation: snapshot.generation
            )
            return
        }

        guard snapshot.checksRepetition,
              let repeatedFrom = repeatingMicrophoneAudioStart(in: pipeline) else { return }
        restartMicrophoneCapture(
            cause: .repeatedAudio,
            stoppedAt: TimeInterval(repeatedFrom.fileFrame) / pipeline.fileFormat.sampleRate,
            repeatedFrom: repeatedFrom,
            generation: snapshot.generation
        )
    }

    /// Where the capture started repeating audio, once it has repeated long enough to restart it.
    private func repeatingMicrophoneAudioStart(
        in pipeline: RecorderMicrophonePipeline
    ) -> RecorderMicrophonePipeline.StartPosition? {
        let configuration = RecorderMicrophoneRepetitionDetector.Configuration(sampleRate: pipeline.historySampleRate)
        let recent = pipeline.recentHistory(last: configuration.maximumLag + configuration.probeLength)
        guard let lag = recent.samples.withUnsafeBufferPointer({
            RecorderMicrophoneRepetitionDetector.repeatingLag(in: $0, configuration: configuration)
        }) else { return nil }

        // The whole history, so the repetition's start is found even when it began a while ago.
        let history = pipeline.recentHistory()
        let repeatingCount = history.samples.withUnsafeBufferPointer {
            RecorderMicrophoneRepetitionDetector.repeatingSampleCount(in: $0, lag: lag, configuration: configuration)
        }
        let requiredCount = Int(RecorderMicrophoneWatchdogPolicy.repetitionDuration * pipeline.historySampleRate)
        guard repeatingCount >= requiredCount else { return nil }
        return pipeline.position(ofHistorySample: history.startIndex + history.samples.count - repeatingCount)
    }

    /// Replaces the current microphone capture with a new one that writes into the same file.
    private func restartMicrophoneCapture(
        cause: RecorderMicrophoneIncident.Cause,
        stoppedAt: TimeInterval,
        repeatedFrom: RecorderMicrophonePipeline.StartPosition?,
        generation: Int
    ) {
        let restart = micCaptureLock.withLock { state -> MicrophoneRestart? in
            guard state.isActive, state.generation == generation else { return nil }
            var incident: RecorderMicrophoneIncident
            if let openIncident = state.openIncident {
                // The capture of the last restart did not deliver audio either.
                incident = openIncident
                incident.failedRestarts += 1
            } else {
                state.incidentCount += 1
                incident = RecorderMicrophoneIncident(number: state.incidentCount, cause: cause, stoppedAt: stoppedAt)
            }
            state.openIncident = incident
            state.generation += 1
            let capture = state.capture
            state.capture = nil
            return MicrophoneRestart(capture: capture, incident: incident, generation: state.generation)
        }
        guard let restart else { return }

        switch cause {
        case .repeatedAudio:
            logger.warning("Recorder microphone repeats the same audio since \(stoppedAt, privacy: .public)s; restarting it")
        case .noAudio:
            logger.warning("Recorder microphone delivers no audio since \(stoppedAt, privacy: .public)s; restarting it")
        }

        if let capture = restart.capture {
            // Repeated audio must not reach the file anymore. A stalled capture may still hand
            // over audio it captured before it stopped.
            if cause == .repeatedAudio {
                capture.pipeline.token.retire()
            }
            capture.stop()
            capture.pipeline.token.retire()
        }
        if let repeatedFrom {
            silenceRepeatedMicrophoneAudio(from: repeatedFrom)
        }
        publishMicrophoneIncident(restart.incident)
        startReplacementMicrophoneCapture(generation: restart.generation)
    }

    /// Silences the repeated audio up to now: right away in the transcription buffer, and in
    /// the mic file when the recording is finished.
    private func silenceRepeatedMicrophoneAudio(from position: RecorderMicrophonePipeline.StartPosition) {
        transcriptionBufferLock.withLock { $0.silenceMic(from: position.transcriptionIndex) }
        micFileLock.withLock { state in
            guard position.fileFrame < state.framesWritten else { return }
            state.silencedRanges.append(position.fileFrame..<state.framesWritten)
        }
    }

    /// Starts the capture that replaces a stopped one, or schedules another attempt.
    private func startReplacementMicrophoneCapture(generation: Int) {
        guard let restart = micCaptureLock.withLock({ state -> (ResolvedRecordingInputSelection, UInt64)? in
            guard state.isActive, state.generation == generation else { return nil }
            return (state.selection, state.recordingStartUptime)
        }) else { return }
        // The gap starts where the last written audio ended, or at the start of the recording.
        let resumesAfterUptime = micFileLock.withLock { $0.lastWriteUptime } ?? restart.1

        do {
            let capture = try makeMicrophoneCapture(
                selection: restart.0,
                newFileURL: nil,
                generation: generation,
                resumesAfterUptime: resumesAfterUptime
            )
            let startedAt = microphoneWatchdogUptime()
            let installed = micCaptureLock.withLock { state -> Bool in
                guard state.isActive, state.generation == generation else { return false }
                state.capture = capture
                state.captureStartUptime = startedAt
                state.retryUptime = nil
                return true
            }
            guard installed else {
                capture.pipeline.token.retire()
                capture.stop()
                return
            }
            logger.info("Restarted the Recorder microphone")
        } catch {
            let now = microphoneWatchdogUptime()
            let incident = micCaptureLock.withLock { state -> RecorderMicrophoneIncident? in
                guard state.isActive, state.generation == generation, var incident = state.openIncident else {
                    return nil
                }
                incident.failedRestarts += 1
                state.openIncident = incident
                state.retryUptime = RecorderMicrophoneWatchdogPolicy.uptime(
                    now,
                    advancedBy: RecorderMicrophoneWatchdogPolicy.retryDelay(afterFailedRestarts: incident.failedRestarts)
                )
                return incident
            }
            logger.error("Could not restart the Recorder microphone: \(error.localizedDescription, privacy: .public)")
            if let incident {
                publishMicrophoneIncident(incident)
            }
        }
    }

    private func microphoneCaptureResumed(generation: Int, at position: TimeInterval) {
        let incident = micCaptureLock.withLock { state -> RecorderMicrophoneIncident? in
            // Also while the recording stops: its last audio can be the restarted capture's first.
            guard state.generation == generation, var incident = state.openIncident else {
                return nil
            }
            incident.resumedAt = position
            state.openIncident = nil
            return incident
        }
        guard let incident else { return }
        logger.info("Recorder microphone records again at \(position, privacy: .public)s")
        publishMicrophoneIncident(incident)
    }

    private func publishMicrophoneIncident(_ incident: RecorderMicrophoneIncident) {
        DispatchQueue.main.async { [weak self] in
            self?.microphoneIncident = incident
        }
    }

    /// Stops the microphone capture for good, after any restart that is running, and closes the
    /// mic file. Returns the frames to silence when the recording is finished.
    private func stopMicrophoneCapture() async -> [Range<AVAudioFramePosition>] {
        let stopped = micCaptureLock.withLock { state -> (RecorderMicrophoneCapture?, DispatchSourceTimer?) in
            state.isActive = false
            let stopped = (state.capture, state.watchdogTimer)
            state.capture = nil
            state.watchdogTimer = nil
            return stopped
        }
        stopped.1?.cancel()
        // A restart that is running finishes first. It stops the capture it started, so nothing
        // writes into the mic file after it closed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            micWatchdogQueue.async { continuation.resume() }
        }
        // The HAL session's stop drains its ring into the mic file, so it must finish before the
        // file is closed or the recording loses its tail. A restarted capture whose first audio
        // arrives only now still reports where the microphone records again.
        stopped.0?.stop()
        stopped.0?.pipeline.token.retire()
        micCaptureLock.withLock { state in
            let generation = state.generation
            state = MicrophoneCaptureState()
            state.generation = generation + 1
        }
        return micFileLock.withLock { state in
            let silencedRanges = state.silencedRanges
            state = MicrophoneFileState()
            return silencedRanges
        }
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
        outputFormat: OutputFormat,
        micSilencedFrameRanges: [Range<AVAudioFramePosition>]
    ) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let sysFile = try AVAudioFile(forReading: systemURL)

        let targetSampleRate = max(micFile.processingFormat.sampleRate, sysFile.processingFormat.sampleRate)
        // The mic reader converts to the target rate, so the silenced frames scale with it.
        let micSilencedRanges = Self.scaled(
            micSilencedFrameRanges,
            by: targetSampleRate / micFile.processingFormat.sampleRate
        )
        var micReadPosition: AVAudioFramePosition = 0
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
            Self.silence(micBuffer, startingAt: micReadPosition, in: micSilencedRanges)
            micReadPosition += AVAudioFramePosition(micBuffer.frameLength)
            let systemBuffer = try systemReader.read()
            let frameCount = max(micBuffer.frameLength, systemBuffer.frameLength)
            guard frameCount > 0 else { break }

            guard let mixedBuffer = AVAudioPCMBuffer(
                pcmFormat: mixFormat,
                frameCapacity: frameCount
            ) else {
                throw RecorderError.engineStartFailed(String(localized: "Cannot create finalization mix buffer"))
            }
            mixedBuffer.frameLength = frameCount

            guard let outputLeft = mixedBuffer.floatChannelData?[0],
                  let outputRight = mixedBuffer.floatChannelData?[1],
                  let micLeft = micBuffer.floatChannelData?[0],
                  let micRight = micBuffer.floatChannelData?[1],
                  let systemLeft = systemBuffer.floatChannelData?[0],
                  let systemRight = systemBuffer.floatChannelData?[1] else {
                throw RecorderError.engineStartFailed(String(localized: "Cannot access finalization mix channels"))
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

    private func finalizeOutputFile(_ stoppedRecording: StoppedRecording, to finalURL: URL) throws {
        if let micURL = stoppedRecording.micTempURL,
           let systemURL = stoppedRecording.systemTempURL {
            try mixAudioFiles(
                micURL: micURL,
                systemURL: systemURL,
                outputURL: finalURL,
                trackMode: stoppedRecording.trackMode,
                micDuckingMode: stoppedRecording.micDuckingMode,
                outputFormat: stoppedRecording.outputFormat,
                micSilencedFrameRanges: stoppedRecording.micSilencedFrameRanges
            )
        } else if let micURL = stoppedRecording.micTempURL {
            try copyOrConvert(
                from: micURL,
                to: finalURL,
                outputFormat: stoppedRecording.outputFormat,
                silencedFrameRanges: stoppedRecording.micSilencedFrameRanges
            )
        } else if let systemURL = stoppedRecording.systemTempURL {
            try copyOrConvert(
                from: systemURL,
                to: finalURL,
                outputFormat: stoppedRecording.outputFormat
            )
        }
    }

    private func copyOrConvert(
        from sourceURL: URL,
        to destinationURL: URL,
        outputFormat: OutputFormat,
        silencedFrameRanges: [Range<AVAudioFramePosition>] = []
    ) throws {
        switch outputFormat {
        case .wav where silencedFrameRanges.isEmpty:
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        case .wav:
            try copySilencing(silencedFrameRanges, from: sourceURL, to: destinationURL)
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
            // The output keeps the source's sample rate, so the silenced frames need no scaling.
            var readPosition: AVAudioFramePosition = 0

            while true {
                let buffer = try reader.read()
                guard buffer.frameLength > 0 else { break }
                Self.silence(buffer, startingAt: readPosition, in: silencedFrameRanges)
                readPosition += AVAudioFramePosition(buffer.frameLength)
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

    /// Copies a WAV file with silence in `silencedFrameRanges`.
    private func copySilencing(
        _ silencedFrameRanges: [Range<AVAudioFramePosition>],
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let outputFile = try AVAudioFile(forWriting: destinationURL, settings: sourceFile.fileFormat.settings)
        let reader = try AudioFileChunkReader(
            url: sourceURL,
            clientFormat: outputFile.processingFormat,
            chunkFrameCount: Self.finalizationChunkFrameCount
        )
        var readPosition: AVAudioFramePosition = 0
        while true {
            let buffer = try reader.read()
            guard buffer.frameLength > 0 else { break }
            Self.silence(buffer, startingAt: readPosition, in: silencedFrameRanges)
            readPosition += AVAudioFramePosition(buffer.frameLength)
            try outputFile.write(from: buffer)
        }
    }

    /// Zeroes the frames of `buffer`, which starts at frame `position` of its file, that fall
    /// into `ranges`.
    private static func silence(
        _ buffer: AVAudioPCMBuffer,
        startingAt position: AVAudioFramePosition,
        in ranges: [Range<AVAudioFramePosition>]
    ) {
        guard !ranges.isEmpty, buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        let bufferRange = position..<(position + AVAudioFramePosition(buffer.frameLength))
        let channelCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samplesPerFrame = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        for range in ranges {
            let overlap = range.clamped(to: bufferRange)
            guard !overlap.isEmpty else { continue }
            let firstFrame = Int(overlap.lowerBound - position)
            for channel in 0..<channelCount {
                (channels[channel] + firstFrame * samplesPerFrame)
                    .update(repeating: 0, count: Int(overlap.count) * samplesPerFrame)
            }
        }
    }

    private static func scaled(
        _ ranges: [Range<AVAudioFramePosition>],
        by factor: Double
    ) -> [Range<AVAudioFramePosition>] {
        guard factor != 1 else { return ranges }
        return ranges.map { range in
            let lowerBound = AVAudioFramePosition((Double(range.lowerBound) * factor).rounded(.down))
            let upperBound = AVAudioFramePosition((Double(range.upperBound) * factor).rounded(.up))
            return lowerBound..<max(lowerBound, upperBound)
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

        _ = await stopMicrophoneCapture()
        micInputActivationGuard.restore(reason: "recorder-mic-rollback")

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
    private var scheduledWork: DispatchWorkItem?

    /// Defaults to ~30 Hz — smooth enough for a level meter while staying
    /// well clear of the main-run-loop contention that unthrottled
    /// buffer-rate publishing causes (see `micLevelThrottle` for details).
    init(minInterval: TimeInterval = 1.0 / 30.0) {
        self.minIntervalNanoseconds = UInt64(minInterval * 1_000_000_000)
    }

    /// Publishes `value` on the main queue via `deliver`. At most one
    /// delivery is ever scheduled on the main queue at a time: if one is
    /// already pending (immediate or delayed), this call just replaces the
    /// value it will eventually carry instead of scheduling a second one.
    ///
    /// A prior version scheduled an "immediate" `.async` block and a delayed
    /// `.asyncAfter` flush as two independent main-queue submissions, and
    /// stamped `lastPublishUptimeNanoseconds` at decision time rather than
    /// actual delivery time. Under main-queue congestion past a throttle
    /// window, later `publish()` calls could see enough elapsed time to take
    /// the "immediate" path again — enqueuing their own block — while an
    /// older delayed flush was still sitting in the queue; GCD gives no
    /// ordering guarantee between two independently-submitted blocks once
    /// both are eligible to run, so they could execute in either order and
    /// deliver values out of sequence (e.g. inputs 1,2,3,4 arriving as
    /// 1,4,3). Coalescing to a single scheduled work item removes the
    /// second submission entirely, so there's nothing left to reorder.
    func publish(_ value: Float, deliver: @escaping @Sendable (Float) -> Void) {
        lock.lock()
        pendingValue = value
        guard scheduledWork == nil else {
            lock.unlock()
            return
        }

        // Sampled under the lock, not before it: if `now` were captured
        // first, a concurrent delivery could advance
        // `lastPublishUptimeNanoseconds` past this (now-stale) `now` while
        // this call was waiting on the lock, making the unsigned subtraction
        // below underflow/wrap to a huge value and slip an extra publish
        // through inside the throttle window.
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- lastPublishUptimeNanoseconds
        let delayNanoseconds = (lastPublishUptimeNanoseconds == 0 || elapsed >= minIntervalNanoseconds)
            ? 0
            : minIntervalNanoseconds - elapsed

        let work = DispatchWorkItem { [weak self] in
            self?.deliverPending(deliver: deliver)
        }
        scheduledWork = work
        lock.unlock()

        if delayNanoseconds == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNanoseconds)), execute: work)
        }
    }

    private func deliverPending(deliver: @Sendable (Float) -> Void) {
        lock.lock()
        let value = pendingValue
        pendingValue = nil
        scheduledWork = nil
        // Stamped at actual delivery time, not when the work item was
        // scheduled — the whole point of coalescing is that those two
        // moments can now be far apart under main-queue congestion.
        lastPublishUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        guard let value else { return }
        deliver(value)
    }

    /// Clears any pending value, cancels an already-scheduled delivery so it
    /// can't fire, and rearms the throttle to publish immediately next time.
    /// Call this when a recording session ends and its level is explicitly
    /// reset to 0 — without it, a delivery already scheduled from a value
    /// received just before the stop would otherwise still fire afterward
    /// and restore a stale nonzero reading.
    func reset() {
        lock.lock()
        pendingValue = nil
        scheduledWork?.cancel()
        scheduledWork = nil
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

// MARK: - Microphone Capture

/// The mic temp file and how far it got.
private struct MicrophoneFileState {
    var file: AVAudioFile?
    var framesWritten: AVAudioFramePosition = 0
    /// When the last buffer reached the file; a restarted capture fills the time since then
    /// with silence.
    var lastWriteUptime: UInt64?
    /// Frames that repeated the audio of a frozen capture; the finished recording has silence there.
    var silencedRanges: [Range<AVAudioFramePosition>] = []
}

/// The running microphone capture and what the watchdog knows about it.
private struct MicrophoneCaptureState {
    var isActive = false
    /// Advances with every capture, so a replaced or stopped capture changes nothing anymore.
    var generation = 0
    var selection = ResolvedRecordingInputSelection.systemDefault
    /// The mic file's processing format, which restarted captures convert to.
    var fileFormat: AVAudioFormat?
    var capture: RecorderMicrophoneCapture?
    var watchdogTimer: DispatchSourceTimer?
    var recordingStartUptime: UInt64 = 0
    var captureStartUptime: UInt64 = 0
    var nextRepetitionCheckUptime: UInt64 = 0
    /// When to try again while the microphone could not be restarted.
    var retryUptime: UInt64?
    /// The incident whose restarted capture has not delivered audio yet.
    var openIncident: RecorderMicrophoneIncident?
    var incidentCount = 0
}

private struct MicrophoneWatchdogSnapshot: Sendable {
    let pipeline: RecorderMicrophonePipeline?
    let generation: Int
    let captureStartUptime: UInt64
    let checksRepetition: Bool
    let retryUptime: UInt64?
}

private struct MicrophoneRestart: Sendable {
    let capture: RecorderMicrophoneCapture?
    let incident: RecorderMicrophoneIncident
    let generation: Int
}

/// One running microphone capture of a recording. A restart replaces it with a new one that
/// writes into the same mic file.
private final class RecorderMicrophoneCapture: @unchecked Sendable {
    let pipeline: RecorderMicrophonePipeline
    private let engine: AVAudioEngine?
    private let session: AudioInputCaptureSession?

    init(pipeline: RecorderMicrophonePipeline, engine: AVAudioEngine) {
        self.pipeline = pipeline
        self.engine = engine
        self.session = nil
    }

    init(pipeline: RecorderMicrophonePipeline, session: AudioInputCaptureSession) {
        self.pipeline = pipeline
        self.engine = nil
        self.session = session
    }

    /// Stops the capture. A HAL session first hands its pending audio to the pipeline.
    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        session?.stop()
    }
}

/// Carries one capture's mono audio to the mic file and the transcription buffer.
private final class RecorderMicrophonePipeline: @unchecked Sendable {
    /// Where the capture's first audio landed in the mic file and the transcription buffer.
    struct StartPosition: Sendable {
        let fileFrame: AVAudioFramePosition
        let transcriptionIndex: Int
    }

    /// The capture's recent audio for the repetition check, every `historyDecimation`-th sample.
    private struct History {
        var samples: [Float] = []
        /// Samples dropped from the front, so that indices count from the capture's start.
        var droppedCount = 0
        /// Where in the next buffer the next sample is picked.
        var phase = 0
    }

    private static let historyDuration: TimeInterval = 60

    let generation: Int
    /// Retired when the capture is replaced or stopped, so its late buffers are dropped.
    let token = CaptureStreamToken()
    let captureFormat: AVAudioFormat
    let fileFormat: AVAudioFormat
    /// Where the previous capture's audio ended; nil for the first capture of a recording.
    let resumesAfterUptime: UInt64?
    let historyDecimation: Int
    var historySampleRate: Double { captureFormat.sampleRate / Double(historyDecimation) }
    private let fileConverter: AVAudioConverter?
    private let transcriptionFormat: AVAudioFormat
    private let transcriptionConverter: AVAudioConverter?
    private let lastBuffer = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private let start = OSAllocatedUnfairLock<StartPosition?>(initialState: nil)
    private let history = OSAllocatedUnfairLock(initialState: History())
#if DEBUG
    var debugFault: RecorderMicrophoneDebugFault?
#endif

    init(
        generation: Int,
        captureFormat: AVAudioFormat,
        fileFormat: AVAudioFormat,
        fileConverter: AVAudioConverter?,
        transcriptionFormat: AVAudioFormat,
        transcriptionConverter: AVAudioConverter?,
        resumesAfterUptime: UInt64?
    ) {
        self.generation = generation
        self.captureFormat = captureFormat
        self.fileFormat = fileFormat
        self.fileConverter = fileConverter
        self.transcriptionFormat = transcriptionFormat
        self.transcriptionConverter = transcriptionConverter
        self.resumesAfterUptime = resumesAfterUptime
        self.historyDecimation = RecorderMicrophoneRepetitionDetector.decimation(forSampleRate: captureFormat.sampleRate)
    }

    /// When the capture last delivered audio; nil until its first buffer.
    var lastBufferUptime: UInt64? {
        lastBuffer.withLock { $0 }
    }

    /// Notes a buffer's arrival; true for the capture's first buffer.
    func noteBuffer(at uptime: UInt64) -> Bool {
        lastBuffer.withLock { last in
            defer { last = uptime }
            return last == nil
        }
    }

    var startPosition: StartPosition? {
        start.withLock { $0 }
    }

    func noteStart(_ position: StartPosition) {
        start.withLock { $0 = $0 ?? position }
    }

    /// Where a sample of the history lies in the mic file and the transcription buffer.
    func position(ofHistorySample index: Int) -> StartPosition? {
        guard let startPosition else { return nil }
        let seconds = Double(index * historyDecimation) / captureFormat.sampleRate
        return StartPosition(
            fileFrame: startPosition.fileFrame + AVAudioFramePosition((seconds * fileFormat.sampleRate).rounded(.down)),
            transcriptionIndex: startPosition.transcriptionIndex
                + Int((seconds * AudioRecorderService.transcriptionSampleRate).rounded(.down))
        )
    }

    func appendToHistory(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        let decimation = historyDecimation
        let capacity = Int(Self.historyDuration * historySampleRate)
        history.withLockUnchecked { history in
            var index = history.phase
            while index < frameCount {
                history.samples.append(data[index])
                index += decimation
            }
            history.phase = index - frameCount
            if history.samples.count > 2 * capacity {
                let excess = history.samples.count - capacity
                history.samples.removeFirst(excess)
                history.droppedCount += excess
            }
        }
    }

    /// The newest `count` samples of the history, and the index of the first one.
    func recentHistory(last count: Int = .max) -> (samples: [Float], startIndex: Int) {
        history.withLock { history in
            let first = max(0, history.samples.count - count)
            return (Array(history.samples[first...]), history.droppedCount + first)
        }
    }

    func fileBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let fileConverter else { return buffer }
        let frameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * fileFormat.sampleRate / captureFormat.sampleRate).rounded(.up)
        ) + 1
        return Self.convert(buffer, using: fileConverter, to: fileFormat, frameCapacity: frameCapacity)
    }

    func transcriptionSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let transcriptionConverter else { return [] }
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * transcriptionFormat.sampleRate / captureFormat.sampleRate
        )
        guard let converted = Self.convert(
            buffer,
            using: transcriptionConverter,
            to: transcriptionFormat,
            frameCapacity: frameCapacity
        ), let data = converted.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(converted.frameLength)))
    }

    /// Converts one buffer with a converter that keeps its state from one buffer to the next.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard frameCapacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        var error: NSError?
        let consumed = OSAllocatedUnfairLock(initialState: false)
        converter.convert(to: converted, error: &error) { _, outStatus in
            let wasConsumed = consumed.withLock { flag in
                let previous = flag
                flag = true
                return previous
            }
            if wasConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return nil }
        return converted
    }

    static func writeSilence(frameCount: AVAudioFramePosition, to file: AVAudioFile) throws {
        let format = file.processingFormat
        let chunkCapacity = AVAudioFrameCount(max(1, Int(format.sampleRate)))
        guard frameCount > 0,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return }
        if let channels = chunk.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(chunkCapacity))
            }
        }
        var remaining = frameCount
        while remaining > 0 {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunkCapacity), remaining))
            chunk.frameLength = count
            try file.write(from: chunk)
            remaining -= AVAudioFramePosition(count)
        }
    }
}
