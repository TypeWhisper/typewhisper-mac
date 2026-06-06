import Foundation
import AVFoundation

struct AudioFileLoadProgress: Sendable, Equatable {
    let fraction: Double?
    let currentTime: TimeInterval?
    let duration: TimeInterval?
}

/// Converts audio/video files to 16kHz mono Float32 PCM samples for transcription.
final class AudioFileService: Sendable {
    typealias ProgressHandler = @Sendable (AudioFileLoadProgress) async -> Bool

    enum AudioFileError: LocalizedError {
        case fileNotFound
        case unsupportedFormat
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound: "File not found."
            case .unsupportedFormat: "Unsupported audio format."
            case .conversionFailed(let detail): "Conversion failed: \(detail)"
            }
        }
    }

    static let supportedExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "aac", "ogg", "wma",
        "mp4", "mov", "mkv", "avi"
    ]

    /// Extracts audio from a file and returns 16kHz mono Float32 samples.
    func loadAudioSamples(
        from url: URL,
        onProgress: ProgressHandler? = nil
    ) async throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioFileError.fileNotFound
        }

        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw AudioFileError.unsupportedFormat
        }

        return try await extractSamples(from: url, onProgress: onProgress)
    }

    private func extractSamples(
        from url: URL,
        onProgress: ProgressHandler?
    ) async throws -> [Float] {
        let asset = AVURLAsset(url: url)

        let assetDuration = try? await asset.load(.duration)
        let duration = assetDuration?.seconds
        let tracks = try await asset.load(.tracks)
        guard let audioTrack = tracks.first(where: { $0.mediaType == .audio }) else {
            throw AudioFileError.conversionFailed("No audio track found")
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AudioFileError.conversionFailed("Could not create asset reader")
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw AudioFileError.conversionFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        var allSamples: [Float] = []
        var lastProgress = 0.0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if let onProgress {
                let currentTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let fraction = Self.progressFraction(currentTime: currentTime, duration: duration)
                if fraction - lastProgress >= 0.01 {
                    lastProgress = fraction
                    guard await onProgress(AudioFileLoadProgress(
                        fraction: fraction,
                        currentTime: currentTime.isFinite ? currentTime : nil,
                        duration: duration
                    )) else {
                        throw CancellationError()
                    }
                }
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = length / MemoryLayout<Float>.size

            var data = Data(count: length)
            data.withUnsafeMutableBytes { rawBuffer in
                _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBuffer.baseAddress!)
            }

            let floats = data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Float.self).prefix(sampleCount))
            }

            allSamples.append(contentsOf: floats)
        }

        guard reader.status == .completed else {
            throw AudioFileError.conversionFailed(reader.error?.localizedDescription ?? "Reading incomplete")
        }

        if let onProgress {
            guard await onProgress(AudioFileLoadProgress(
                fraction: 1.0,
                currentTime: duration,
                duration: duration
            )) else {
                throw CancellationError()
            }
        }

        return allSamples
    }

    private static func progressFraction(currentTime: TimeInterval, duration: TimeInterval?) -> Double {
        guard currentTime.isFinite,
              let duration,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(currentTime / duration, 0), 1)
    }
}
