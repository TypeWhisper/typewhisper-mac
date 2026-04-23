import Foundation

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
