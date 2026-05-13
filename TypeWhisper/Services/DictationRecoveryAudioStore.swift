import Foundation

/// Persists the active dictation as a temporary 16 kHz mono PCM WAV so the
/// audio can be recovered if transcription fails after recording has stopped.
final class DictationRecoveryAudioStore: @unchecked Sendable {
    private enum Constants {
        static let sampleRate: UInt32 = 16_000
        static let bitsPerSample: UInt16 = 16
        static let channelCount: UInt16 = 1
        static let bytesPerSample = 2
        static let wavHeaderByteCount = 44
        static let activeFileName = "active-dictation-recovery.wav"
        static let latestFileName = "last-dictation-recovery.wav"
    }

    private let directory: URL
    private let activeFileURL: URL
    private let latestFileURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.typewhisper.dictation-recovery-audio", qos: .utility)

    private var activeHandle: FileHandle?
    private var activeSampleCount = 0
    private var hasActiveRecording = false

    init(
        directory: URL = AppConstants.appSupportDirectory
            .appendingPathComponent("dictation-recovery", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.activeFileURL = directory.appendingPathComponent(Constants.activeFileName)
        self.latestFileURL = directory.appendingPathComponent(Constants.latestFileName)
        self.fileManager = fileManager
    }

    var latestRecoveryURL: URL? {
        queue.sync {
            fileManager.fileExists(atPath: latestFileURL.path) ? latestFileURL : nil
        }
    }

    func startNewRecording() {
        queue.sync {
            closeActiveHandle()
            removeItemIfExists(at: activeFileURL)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            fileManager.createFile(
                atPath: activeFileURL.path,
                contents: Self.wavHeader(sampleCount: 0),
                attributes: nil
            )
            activeHandle = try? FileHandle(forWritingTo: activeFileURL)
            _ = try? activeHandle?.seekToEnd()
            activeSampleCount = 0
            hasActiveRecording = activeHandle != nil
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = Self.pcm16Data(from: samples)

        queue.async { [weak self] in
            guard let self, self.hasActiveRecording, let activeHandle = self.activeHandle else { return }
            do {
                try activeHandle.write(contentsOf: data)
                self.activeSampleCount += samples.count
            } catch {
                self.closeActiveHandle()
                self.removeItemIfExists(at: self.activeFileURL)
                self.hasActiveRecording = false
                self.activeSampleCount = 0
            }
        }
    }

    @discardableResult
    func preserveActiveRecording() -> URL? {
        queue.sync {
            guard hasActiveRecording else {
                return fileManager.fileExists(atPath: latestFileURL.path) ? latestFileURL : nil
            }

            closeActiveHandle()
            hasActiveRecording = false

            guard activeSampleCount > 0 else {
                activeSampleCount = 0
                removeItemIfExists(at: activeFileURL)
                removeItemIfExists(at: latestFileURL)
                return nil
            }

            finalizeActiveWavHeader(sampleCount: activeSampleCount)
            removeItemIfExists(at: latestFileURL)

            do {
                try fileManager.moveItem(at: activeFileURL, to: latestFileURL)
                activeSampleCount = 0
                return latestFileURL
            } catch {
                activeSampleCount = 0
                removeItemIfExists(at: activeFileURL)
                return fileManager.fileExists(atPath: latestFileURL.path) ? latestFileURL : nil
            }
        }
    }

    func discardActiveRecording(keepingLatest: Bool = false) {
        queue.sync {
            closeActiveHandle()
            activeSampleCount = 0
            hasActiveRecording = false
            removeItemIfExists(at: activeFileURL)
            if !keepingLatest {
                removeItemIfExists(at: latestFileURL)
            }
        }
    }

    func discardLatestRecovery() {
        queue.sync {
            removeItemIfExists(at: latestFileURL)
        }
    }

    private func finalizeActiveWavHeader(sampleCount: Int) {
        guard let handle = try? FileHandle(forWritingTo: activeFileURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.wavHeader(sampleCount: sampleCount))
        } catch {
            removeItemIfExists(at: activeFileURL)
        }
    }

    private func closeActiveHandle() {
        try? activeHandle?.synchronize()
        try? activeHandle?.close()
        activeHandle = nil
    }

    private func removeItemIfExists(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * Constants.bytesPerSample)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    private static func wavHeader(sampleCount: Int) -> Data {
        let dataByteCount = UInt32(sampleCount * Constants.bytesPerSample)
        let fileByteCount = UInt32(Constants.wavHeaderByteCount - 8) + dataByteCount
        let byteRate = Constants.sampleRate * UInt32(Constants.channelCount) * UInt32(Constants.bytesPerSample)
        let blockAlign = Constants.channelCount * Constants.bitsPerSample / 8

        var data = Data()
        data.reserveCapacity(Constants.wavHeaderByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(fileByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(Constants.channelCount)
        data.appendLittleEndian(Constants.sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(Constants.bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
