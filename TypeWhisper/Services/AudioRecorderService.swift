import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "AudioRecorderService")

/// Records audio from microphone and/or system audio to file.
/// Uses AVAudioEngine for mic and ScreenCaptureKit for system audio.
final class AudioRecorderService: ObservableObject, @unchecked Sendable {

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

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private let micFileLock = OSAllocatedUnfairLock<AVAudioFile?>(initialState: nil)
    private var scStream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private let sysFileLock = OSAllocatedUnfairLock<AVAudioFile?>(initialState: nil)
    private var durationTimer: Timer?
    private var startTime: Date?

    private var micTempURL: URL?
    private var systemTempURL: URL?
    private var finalOutputURL: URL?
    private var outputFormat: OutputFormat = .wav
    private var micEnabled = false
    private var systemAudioEnabled = false

    static let recordingsDirectoryName = "TypeWhisper Recordings"

    var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.recordingsDirectoryName)
    }

    func startRecording(micEnabled: Bool, systemAudioEnabled: Bool, format: OutputFormat) async throws -> URL {
        guard micEnabled || systemAudioEnabled else {
            throw RecorderError.noSourceEnabled
        }

        self.micEnabled = micEnabled
        self.systemAudioEnabled = systemAudioEnabled
        self.outputFormat = format

        // Create recordings directory
        let dir = recordingsDirectory
        try createDirectoryIfNeeded(dir)

        // Generate output filename
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let outputURL = dir.appendingPathComponent("Recording \(timestamp).\(format.fileExtension)")
        self.finalOutputURL = outputURL

        // Setup temp files
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString

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

        return outputURL
    }

    func stopRecording() async -> URL? {
        // Stop timer
        durationTimer?.invalidate()
        durationTimer = nil

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

        let finalURL = finalOutputURL

        // Mix or copy to final output
        if let finalURL {
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
            }
        }

        // Cleanup temp files
        cleanupTempFile(micTempURL)
        cleanupTempFile(systemTempURL)
        micTempURL = nil
        systemTempURL = nil

        DispatchQueue.main.async {
            self.isRecording = false
            self.duration = 0
            self.micLevel = 0
            self.systemLevel = 0
        }

        return finalURL
    }

    // MARK: - Microphone Recording

    private func startMicRecording(outputURL: URL) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.engineStartFailed("No audio input available")
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

        let converter: AVAudioConverter?
        if inputFormat.channelCount > 1 || inputFormat.commonFormat != .pcmFormatFloat32 {
            converter = AVAudioConverter(from: inputFormat, to: monoFormat)
        } else {
            converter = nil
        }

        micFileLock.withLock { $0 = audioFile }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let writeBuffer: AVAudioPCMBuffer
            if let converter {
                let frameCount = AVAudioFrameCount(buffer.frameLength)
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
                    return buffer
                }
                guard error == nil, converted.frameLength > 0 else { return }
                writeBuffer = converted
            } else {
                writeBuffer = buffer
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
        }

        try engine.start()
        audioEngine = engine
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
        output.audioFile = audioFile
        output.fileLock = sysFileLock
        let levelSetter = SystemLevelSetter(service: self)
        output.levelCallback = { level in
            levelSetter.setLevel(level)
        }

        streamOutput = output

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.typewhisper.system-audio", qos: .userInteractive))

        try await stream.startCapture()
        scStream = stream
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

        // Mix buffers
        guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: totalFrames) else { return }
        mixedBuffer.frameLength = totalFrames

        for ch in 0..<Int(targetChannels) {
            guard let mixedData = mixedBuffer.floatChannelData?[ch],
                  let micData = micBuffer.floatChannelData?[ch],
                  let sysData = sysBuffer.floatChannelData?[ch] else { continue }

            for i in 0..<Int(totalFrames) {
                let micSample = i < Int(micBuffer.frameLength) ? micData[i] : 0
                let sysSample = i < Int(sysBuffer.frameLength) ? sysData[i] : 0
                mixedData[i] = micSample + sysSample
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
    var audioFile: AVAudioFile?
    var fileLock: OSAllocatedUnfairLock<AVAudioFile?>?
    var levelCallback: ((Float) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        // Calculate level from raw samples
        let bytesPerSample = Int(asbd.pointee.mBitsPerChannel / 8)
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        guard bytesPerSample > 0, channelCount > 0 else { return }
        let sampleCount = length / (bytesPerSample * channelCount)
        guard sampleCount > 0 else { return }

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 && bytesPerSample == 4 {
            let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount * channelCount)
            var sum: Float = 0
            for i in 0..<(sampleCount * channelCount) {
                let sample = floatPointer[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(sampleCount * channelCount))
            let level = min(1.0, rms * 5)
            levelCallback?(level)
        } else if bytesPerSample == 2 {
            let int16Pointer = UnsafeRawPointer(dataPointer).bindMemory(to: Int16.self, capacity: sampleCount * channelCount)
            var sum: Float = 0
            for i in 0..<(sampleCount * channelCount) {
                let sample = Float(int16Pointer[i]) / Float(Int16.max)
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(sampleCount * channelCount))
            let level = min(1.0, rms * 5)
            levelCallback?(level)
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer and write
        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard let format = AVAudioFormat(
            commonFormat: isFloat && bytesPerSample == 4 ? .pcmFormatFloat32 : .pcmFormatInt16,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: !isNonInterleaved
        ) else { return }

        let frameCount = AVAudioFrameCount(sampleCount)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        // Copy data into buffer
        if let bufferData = pcmBuffer.audioBufferList.pointee.mBuffers.mData {
            memcpy(bufferData, dataPointer, length)
        }

        fileLock?.withLock { file in
            guard let file else { return }
            do {
                try file.write(from: pcmBuffer)
            } catch {
                logger.error("Failed to write system audio: \(error.localizedDescription)")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("SCStream stopped with error: \(error.localizedDescription)")
    }
}
