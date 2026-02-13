import Foundation
import AVFoundation

/// Converts audio/video files to 16kHz mono Float32 PCM samples for transcription.
final class AudioFileService: Sendable {

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
    func loadAudioSamples(from url: URL) async throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioFileError.fileNotFound
        }

        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw AudioFileError.unsupportedFormat
        }

        return try await extractSamples(from: url)
    }

    private func extractSamples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
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

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            let length = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = length / MemoryLayout<Float>.size

            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { rawBuffer in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawBuffer.baseAddress!)
            }

            let floats = data.withUnsafeBytes { rawBuffer in
                Array(rawBuffer.bindMemory(to: Float.self).prefix(sampleCount))
            }

            allSamples.append(contentsOf: floats)
        }

        guard reader.status == .completed else {
            throw AudioFileError.conversionFailed(reader.error?.localizedDescription ?? "Reading incomplete")
        }

        return allSamples
    }
}
