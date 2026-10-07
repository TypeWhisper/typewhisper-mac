import Foundation

// MARK: - Long Audio Chunking

/// Transcribes long recordings in chunks that cloud transcription APIs accept
/// and merges the chunk results into one transcript.
///
/// OpenAI and Groq cap a request at 25 MB. Their proxies close the connection
/// once a larger body arrives, so URLSession reports a lost connection instead
/// of the 413 (#1538). Ten minutes of 16 kHz mono audio is 19.2 MB as WAV and
/// about 3.6 MB as 48 kbit/s AAC, so a chunk fits even when the upload falls
/// back to WAV. Each cut lands on the quietest stretch near its boundary, so it
/// does not split a word.
public enum PluginAudioChunking {
    public static let defaultMaximumChunkDuration: TimeInterval = 600

    private static let sampleRate = PluginAudioUploadEncoder.sampleRate
    /// 20 ms energy frames, compared over a 200 ms stretch.
    private static let frameLength = sampleRate / 50
    private static let quietStretchFrames = 10

    /// Calls `transcribeChunk` once with `audio` when it fits into one chunk,
    /// otherwise once per chunk in order. Segment and word times in the merged
    /// result refer to the whole recording.
    public static func transcribe(
        _ audio: AudioData,
        maximumChunkDuration: TimeInterval = defaultMaximumChunkDuration,
        transcribeChunk: (AudioData) async throws -> PluginTranscriptionResult
    ) async throws -> PluginTranscriptionResult {
        let ranges = chunkRanges(
            for: audio.samples,
            maximumChunkSampleCount: Int(maximumChunkDuration * Double(sampleRate))
        )
        guard ranges.count > 1 else {
            return try await transcribeChunk(audio)
        }

        let collectsWords = PluginWordTimings.collector != nil
        var results: [PluginTranscriptionResult] = []
        var segments: [PluginTranscriptionSegment] = []
        var words: [PluginWordTiming] = []

        for range in ranges {
            try Task.checkCancellation()
            let samples = Array(audio.samples[range])
            let chunk = AudioData(
                samples: samples,
                wavData: PluginWavEncoder.encode(samples, sampleRate: sampleRate),
                duration: Double(samples.count) / Double(sampleRate)
            )
            let offset = Double(range.lowerBound) / Double(sampleRate)

            // Each chunk reports its own words, and a report replaces the
            // previous one, so every chunk gets its own collector.
            let result: PluginTranscriptionResult
            if collectsWords {
                let chunkWords = PluginWordTimingCollector()
                result = try await PluginWordTimings.$collector.withValue(chunkWords) {
                    try await transcribeChunk(chunk)
                }
                words += chunkWords.words.map {
                    PluginWordTiming(text: $0.text, start: $0.start + offset, end: $0.end + offset)
                }
            } else {
                result = try await transcribeChunk(chunk)
            }

            results.append(result)
            segments += result.segments.map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
        }

        if collectsWords {
            PluginWordTimings.report(words)
        }

        return PluginTranscriptionResult(
            text: joinedText(results.map(\.text)),
            detectedLanguage: mostFrequentLanguage(results.compactMap(\.detectedLanguage)),
            segments: segments
        )
    }

    /// Splits `samples` into the fewest chunks of at most
    /// `maximumChunkSampleCount` samples, each cut at the quietest stretch
    /// within 5 % of the chunk length around an even split.
    static func chunkRanges(for samples: [Float], maximumChunkSampleCount: Int) -> [Range<Int>] {
        let count = samples.count
        guard maximumChunkSampleCount > 0, count > maximumChunkSampleCount else {
            return [0..<count]
        }

        let searchRadius = maximumChunkSampleCount / 20
        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > maximumChunkSampleCount {
            let remaining = count - start
            let chunkCount = (remaining + maximumChunkSampleCount - 1) / maximumChunkSampleCount
            let evenCut = start + remaining / chunkCount
            // Cutting earlier than this would leave more than the remaining
            // chunks can hold and add a chunk.
            let earliestCut = count - (chunkCount - 1) * maximumChunkSampleCount
            let searchRange = max(evenCut - searchRadius, earliestCut)
                ..< min(evenCut + searchRadius, start + maximumChunkSampleCount)
            let cut = searchRange.isEmpty ? evenCut : quietestPoint(in: samples, range: searchRange)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<count)
        return ranges
    }

    /// The middle of the 200 ms stretch with the least energy in `range`.
    static func quietestPoint(in samples: [Float], range: Range<Int>) -> Int {
        let frameCount = range.count / frameLength
        guard frameCount > 0 else { return range.lowerBound + range.count / 2 }

        var energies = [Double](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                let frameStart = range.lowerBound + frame * frameLength
                var energy: Double = 0
                for index in frameStart..<(frameStart + frameLength) {
                    let sample = Double(buffer[index])
                    energy += sample * sample
                }
                energies[frame] = energy
            }
        }

        let stretch = min(quietStretchFrames, frameCount)
        var energy = energies[0..<stretch].reduce(0, +)
        var quietestEnergy = energy
        var quietestStart = 0
        for frame in stretch..<frameCount {
            energy += energies[frame] - energies[frame - stretch]
            if energy < quietestEnergy {
                quietestEnergy = energy
                quietestStart = frame - stretch + 1
            }
        }
        return range.lowerBound + quietestStart * frameLength + stretch * frameLength / 2
    }

    static func joinedText(_ texts: [String]) -> String {
        var joined = ""
        for text in texts {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = joined.last, let first = text.first,
               !(isWrittenWithoutSpaces(last) && isWrittenWithoutSpaces(first)) {
                joined += " "
            }
            joined += text
        }
        return joined
    }

    /// Chinese and Japanese put no spaces between words or after their
    /// punctuation. Korean does, so Hangul is not included.
    private static func isWrittenWithoutSpaces(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana and Katakana
             0x3400...0x4DBF, // CJK extension A
             0x4E00...0x9FFF, // CJK ideographs
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF00...0xFFEF, // Halfwidth and fullwidth forms
             0x20000...0x323AF: // CJK extensions B to H
            return true
        default:
            return false
        }
    }

    /// The language most chunks detected; the earliest one wins a tie.
    private static func mostFrequentLanguage(_ languages: [String]) -> String? {
        var counts: [String: Int] = [:]
        for language in languages {
            counts[language, default: 0] += 1
        }
        return languages.max { counts[$0, default: 0] < counts[$1, default: 0] }
    }
}
