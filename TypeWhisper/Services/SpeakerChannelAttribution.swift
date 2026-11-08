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

    /// Longest delay searched between a sound on the system audio and its
    /// echo on the microphone. The system capture starts after the
    /// microphone, and the output device and the room add their latency.
    static let maximumEchoDelay: TimeInterval = 2
    /// Own speech is at least this much louder than the echo the system
    /// audio is expected to leave on the microphone.
    static let echoMargin: Float = 2.5
    /// Share of the expected echo left after each frame once the system
    /// audio stops, for the room's reverberation (about 3 dB per frame).
    static let echoDecay: Float = 0.7
    /// Below this correlation the microphone doesn't follow the system
    /// audio at any delay, and there is no echo to measure.
    static let minimumEchoCorrelation = 0.05

    /// Stretches where the microphone carries the user's own speech.
    ///
    /// A frame counts when the microphone is clearly above its noise floor
    /// and clearly above the echo the system audio leaves on it. Calls on
    /// loudspeakers reach the microphone as loud as the user, and a few
    /// hundred milliseconds after the system audio has them, so the echo is
    /// measured from the recording itself: its delay, and how loud the
    /// system audio comes back on the microphone.
    ///
    /// The microphone also has to be at least as present as the system
    /// audio, relative to each track's own loudness. That rule alone applies
    /// without a measurable echo, and it keeps an echo measured at the wrong
    /// delay from adding own speech.
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
        let threshold = max(minimumLevel, microphoneFloor * 3, microphoneReference * 0.12)
        guard microphoneReference > threshold else { return [] }
        let echo = expectedEcho(microphone: microphoneLevels, system: systemLevels)
        let systemReference = max(percentile(systemLevels, 0.95), minimumLevel)
        func standsOutFromSystemAudio(_ index: Int, _ level: Float) -> Bool {
            let systemLevel = index < systemLevels.count ? systemLevels[index] : 0
            guard level / microphoneReference >= 0.8 * systemLevel / systemReference else { return false }
            return echo.map { level >= echoMargin * $0[index] } ?? true
        }

        var ranges: [(start: TimeInterval, end: TimeInterval)] = []
        for (index, level) in microphoneLevels.enumerated() {
            guard level > threshold, standsOutFromSystemAudio(index, level) else { continue }
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
    ///
    /// A diarizer speaker who mostly talks where the microphone carries the
    /// user is the user too. What the microphone missed of them (soft words,
    /// overlap) goes to `ownSpeakerLabel` as well, so the user doesn't show
    /// up a second time, or under the name of their own voice profile.
    static func combining(
        _ turns: [PluginSpeakerTurn],
        ownSpeech: [ClosedRange<TimeInterval>]
    ) -> [PluginSpeakerTurn] {
        guard !ownSpeech.isEmpty else { return turns }
        let own = ownSpeech.sorted { $0.lowerBound < $1.lowerBound }
        let ownLabels = labelsMostlyOnMicrophone(turns, ownSpeech: own)
        var combined: [PluginSpeakerTurn] = []
        for turn in turns {
            let label = ownLabels.contains(turn.speakerLabel) ? ownSpeakerLabel : turn.speakerLabel
            var start = turn.start
            for range in own where range.upperBound > start && range.lowerBound < turn.end {
                if range.lowerBound - start >= minimumRemainder {
                    combined.append(PluginSpeakerTurn(speakerLabel: label, start: start, end: range.lowerBound))
                }
                start = max(start, range.upperBound)
            }
            if turn.end - start >= minimumRemainder {
                combined.append(PluginSpeakerTurn(speakerLabel: label, start: start, end: turn.end))
            }
        }
        combined.append(contentsOf: own.map {
            PluginSpeakerTurn(speakerLabel: ownSpeakerLabel, start: $0.lowerBound, end: $0.upperBound)
        })
        return combined.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Diarizer speakers with at least half of their speech inside own speech,
    /// the same rule `SpeakerWorkspaceModel.microphoneSpeaker` uses.
    private static func labelsMostlyOnMicrophone(
        _ turns: [PluginSpeakerTurn],
        ownSpeech: [ClosedRange<TimeInterval>]
    ) -> Set<String> {
        var spoken: [String: TimeInterval] = [:]
        var onMicrophone: [String: TimeInterval] = [:]
        for turn in turns {
            spoken[turn.speakerLabel, default: 0] += max(0, turn.end - turn.start)
            for range in ownSpeech where range.upperBound > turn.start && range.lowerBound < turn.end {
                onMicrophone[turn.speakerLabel, default: 0] += min(turn.end, range.upperBound) - max(turn.start, range.lowerBound)
            }
        }
        return Set(onMicrophone.filter { $0.value >= spoken[$0.key, default: 0] / 2 }.keys)
    }

    /// What is left of a diarizer turn around own speech only counts from this length.
    static let minimumRemainder: TimeInterval = 0.2

    /// The level the system audio's echo is expected to reach in each
    /// microphone frame, or nil when the recording shows no echo.
    ///
    /// The system level is shifted by the echo's delay, widened by a frame
    /// on either side for jitter, held while the room still reverberates,
    /// and scaled by how loud the system audio comes back on the microphone.
    /// That ratio is read over the loudest quarter of the system audio, from
    /// its lower quarter: the echo is there whenever the system audio is
    /// loud, the user's voice only now and then.
    private static func expectedEcho(microphone: [Float], system: [Float]) -> [Float]? {
        guard let delay = echoDelay(microphone: microphone, system: system) else { return nil }
        var source = [Float](repeating: 0, count: microphone.count)
        var held: Float = 0
        for index in microphone.indices {
            let center = index - delay
            var level: Float = 0
            for systemIndex in (center - 1)...(center + 1) where system.indices.contains(systemIndex) {
                level = max(level, system[systemIndex])
            }
            held = max(level, held * echoDecay)
            source[index] = held
        }

        let systemThreshold = max(
            minimumLevel,
            percentile(system, 0.10) * 3,
            percentile(system, 0.95) * 0.12
        )
        let loudest = source.indices
            .filter { source[$0] > systemThreshold }
            .sorted { (source[$0], -$0) > (source[$1], -$1) }
        // Under a second of system audio says nothing about the echo.
        guard Double(loudest.count) * frameDuration >= 1 else { return nil }
        let sampled = loudest.prefix(max(1, loudest.count / 4))
        let gain = percentile(sampled.map { microphone[$0] / source[$0] }, 0.25)
        return source.map { $0 * gain }
    }

    /// Frames by which the microphone trails the system audio: the shift
    /// with the strongest correlation between the two tracks' loudness, or
    /// nil when no shift reaches `minimumEchoCorrelation`.
    ///
    /// Only frames with system audio count. Over a whole conversation the
    /// tracks take turns, which correlates them negatively at every shift
    /// and would let the search settle on any delay.
    private static func echoDelay(microphone: [Float], system: [Float]) -> Int? {
        let floor = Double(minimumLevel)
        let x = microphone.map { log(max(Double($0), floor)) }
        let y = system.map { log(max(Double($0), floor)) }
        let active = system.indices.filter { system[$0] > minimumLevel }

        var best: (delay: Int, correlation: Double)?
        let maximumDelay = Int((maximumEchoDelay / frameDuration).rounded())
        for delay in 0...maximumDelay {
            var n = 0.0, sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
            for systemIndex in active {
                let microphoneIndex = systemIndex + delay
                guard microphoneIndex < x.count else { break }
                let (a, b) = (x[microphoneIndex], y[systemIndex])
                n += 1
                sumX += a; sumY += b
                sumXX += a * a; sumYY += b * b; sumXY += a * b
            }
            guard n > 1 else { continue }
            let meanX = sumX / n, meanY = sumY / n
            let varianceX = sumXX / n - meanX * meanX
            let varianceY = sumYY / n - meanY * meanY
            guard varianceX > 1e-9, varianceY > 1e-9 else { continue }
            let correlation = (sumXY / n - meanX * meanY) / (varianceX * varianceY).squareRoot()
            if correlation > (best?.correlation ?? minimumEchoCorrelation) {
                best = (delay, correlation)
            }
        }
        return best?.delay
    }

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
