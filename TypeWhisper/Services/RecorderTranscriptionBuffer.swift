@preconcurrency import AVFoundation
import Foundation
import os

/// Converts the Recorder's microphone buffers to the transcription buffer's
/// rate, one capture buffer at a time, without losing time.
///
/// A converter emits no more frames than the output buffer holds and drops
/// what doesn't fit. Room for `frames * rate / inputRate` rounded down lost
/// that fraction of a frame on every buffer: 0.4 % of the microphone at
/// 48 kHz in 512-frame buffers, 14 seconds an hour. The own speech the
/// microphone marks then drifted away from the recording, and in a long call
/// it landed on the other person's turns.
final class RecorderTranscriptionResampler: @unchecked Sendable {
    /// Extra output room for the converter's varying frame count per buffer.
    static let headroomFrames: AVAudioFrameCount = 16

    private let converter: AVAudioConverter
    let outputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat, sampleRate: Double) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// The samples `buffer` adds at the output rate. Calls must come in capture order.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return [] }
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + Self.headroomFrames
        let offered = OSAllocatedUnfairLock(initialState: false)
        var samples: [Float] = []
        while let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                let wasOffered = offered.withLock { flag in
                    defer { flag = true }
                    return flag
                }
                if wasOffered {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil else { break }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            // A full output buffer can leave converted frames behind.
            guard status == .haveData, output.frameLength == capacity else { break }
        }
        return samples
    }
}

struct RecorderTranscriptionBuffer {
    typealias Mixer = (_ range: Range<Int>, _ micSamples: [Float], _ systemSamples: [Float]) -> [Float]

    var micSamples: [Float] = []
    var systemSamples: [Float] = []

    var mixedSampleCount: Int {
        max(micSamples.count, systemSamples.count)
    }

    mutating func reset() {
        micSamples.removeAll(keepingCapacity: false)
        systemSamples.removeAll(keepingCapacity: false)
    }

    mutating func appendMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        micSamples.append(contentsOf: samples)
    }

    mutating func appendSystem(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        systemSamples.append(contentsOf: samples)
    }

    func currentBuffer(
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        mixer: Mixer
    ) -> [Float] {
        snapshot(
            in: 0..<mixedSampleCount,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled,
            mixer: mixer
        )
    }

    func recentBuffer(
        maxSampleCount: Int,
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        mixer: Mixer
    ) -> [Float] {
        let nextOffset = mixedSampleCount
        let startOffset = max(0, nextOffset - max(0, maxSampleCount))
        return snapshot(
            in: startOffset..<nextOffset,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled,
            mixer: mixer
        )
    }

    func delta(
        since sampleOffset: Int,
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        mixer: Mixer
    ) -> (samples: [Float], nextOffset: Int) {
        let nextOffset = mixedSampleCount
        let clampedOffset = max(0, min(sampleOffset, nextOffset))
        let samples = snapshot(
            in: clampedOffset..<nextOffset,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled,
            mixer: mixer
        )
        return (samples, nextOffset)
    }

    private func snapshot(
        in range: Range<Int>,
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        mixer: Mixer
    ) -> [Float] {
        let clampedMixedRange = clampedRange(range, upperBound: mixedSampleCount)
        guard !clampedMixedRange.isEmpty else { return [] }

        switch (micEnabled, systemAudioEnabled) {
        case (true, false):
            return sliceCopy(of: micSamples, in: clampedMixedRange)
        case (false, true):
            return sliceCopy(of: systemSamples, in: clampedMixedRange)
        case (true, true):
            return mixer(clampedMixedRange, micSamples, systemSamples)
        case (false, false):
            return []
        }
    }

    private func sliceCopy(of samples: [Float], in range: Range<Int>) -> [Float] {
        let clamped = clampedRange(range, upperBound: samples.count)
        guard !clamped.isEmpty else { return [] }
        return Array(samples[clamped])
    }

    private func clampedRange(_ range: Range<Int>, upperBound: Int) -> Range<Int> {
        let lowerBound = max(0, min(range.lowerBound, upperBound))
        let upperBound = max(lowerBound, min(range.upperBound, upperBound))
        return lowerBound..<upperBound
    }
}
