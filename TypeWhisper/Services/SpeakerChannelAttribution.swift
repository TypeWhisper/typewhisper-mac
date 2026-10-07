import Foundation
import TypeWhisperPluginSDK

/// Uses the Recorder's separate microphone and system-audio capture to tell
/// the user's own speech from everyone else's in a call.
///
/// The microphone carries the user; the system audio carries the other
/// participants. Where the microphone is active, the speech belongs to the
/// user, whatever the diarizer heard in the mixed recording. This removes the
/// most common error in call recordings: the user's voice split in two or
/// merged with a remote voice.
enum SpeakerChannelAttribution {
    /// Provider-style label of the user's own speech before speakers are numbered.
    static let ownSpeakerLabel = "typewhisper.own-microphone"

    static let frameDuration: TimeInterval = 0.03
    /// Microphone level below this is noise, whatever the recording's levels are.
    static let minimumLevel: Float = 0.003
    /// Pauses shorter than this stay inside one stretch of own speech.
    static let maximumPause: TimeInterval = 0.4
    static let minimumDuration: TimeInterval = 0.3
    static let padding: TimeInterval = 0.1

    /// Stretches where the microphone carries the user's own speech.
    ///
    /// A frame counts when the microphone is clearly above its noise floor
    /// and, relative to each track's own loudness, at least as present as
    /// the system audio. The second condition keeps remote voices that the
    /// microphone picks up from loudspeakers from counting as the user.
    static func ownSpeechRanges(
        microphone: [Float],
        system: [Float],
        sampleRate: Double = 16_000
    ) -> [ClosedRange<TimeInterval>] {
        let frameLength = max(1, Int(frameDuration * sampleRate))
        let microphoneLevels = levels(of: microphone, frameLength: frameLength)
        guard !microphoneLevels.isEmpty else { return [] }
        let systemLevels = levels(of: system, frameLength: frameLength)

        let microphoneReference = percentile(microphoneLevels, 0.95)
        let microphoneFloor = percentile(microphoneLevels, 0.10)
        let systemReference = max(percentile(systemLevels, 0.95), minimumLevel)
        let threshold = max(minimumLevel, microphoneFloor * 3, microphoneReference * 0.12)
        guard microphoneReference > threshold else { return [] }

        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        for (index, level) in microphoneLevels.enumerated() {
            let systemLevel = index < systemLevels.count ? systemLevels[index] : 0
            guard level > threshold,
                  level / microphoneReference >= 0.8 * systemLevel / systemReference else { continue }
            let start = Double(index) * frameDuration
            let end = start + frameDuration
            if let last = ranges.last, start - last.end <= maximumPause {
                ranges[ranges.count - 1].end = end
            } else {
                ranges.append((start, end))
            }
        }

        let duration = Double(microphone.count) / sampleRate
        return ranges
            .filter { $0.end - $0.start >= minimumDuration }
            .map { max(0, $0.start - padding)...min(duration, $0.end + padding) }
    }

    /// Diarizer turns with the user's own speech cut out of them and added
    /// as turns of `ownSpeakerLabel`.
    static func combining(
        _ turns: [PluginSpeakerTurn],
        ownSpeech: [ClosedRange<TimeInterval>]
    ) -> [PluginSpeakerTurn] {
        guard !ownSpeech.isEmpty else { return turns }
        let own = ownSpeech.sorted { $0.lowerBound < $1.lowerBound }
        var combined: [PluginSpeakerTurn] = []
        for turn in turns {
            var start = turn.start
            for range in own where range.upperBound > start && range.lowerBound < turn.end {
                if range.lowerBound - start >= minimumRemainder {
                    combined.append(PluginSpeakerTurn(speakerLabel: turn.speakerLabel, start: start, end: range.lowerBound))
                }
                start = max(start, range.upperBound)
            }
            if turn.end - start >= minimumRemainder {
                combined.append(PluginSpeakerTurn(speakerLabel: turn.speakerLabel, start: start, end: turn.end))
            }
        }
        combined.append(contentsOf: own.map {
            PluginSpeakerTurn(speakerLabel: ownSpeakerLabel, start: $0.lowerBound, end: $0.upperBound)
        })
        return combined.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// What is left of a diarizer turn around own speech only counts from this length.
    static let minimumRemainder: TimeInterval = 0.2

    private static func levels(of samples: [Float], frameLength: Int) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        return samples.withUnsafeBufferPointer { buffer in
            stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { offset in
                var sum: Float = 0
                for index in offset..<(offset + frameLength) {
                    sum += buffer[index] * buffer[index]
                }
                return (sum / Float(frameLength)).squareRoot()
            }
        }
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}
