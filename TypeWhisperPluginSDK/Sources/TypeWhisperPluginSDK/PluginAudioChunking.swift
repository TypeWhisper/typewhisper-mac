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
        guard let chunks = try await transcribeChunks(
            audio,
            maximumChunkDuration: maximumChunkDuration,
            transcribeChunk: transcribeChunk
        ) else {
            return try await transcribeChunk(audio)
        }

        let results = chunks.map(\.result)
        return PluginTranscriptionResult(
            text: joinedText(results.map(\.text)),
            detectedLanguage: mostFrequentLanguage(results.compactMap(\.detectedLanguage)),
            segments: chunks.flatMap { chunk in
                chunk.result.segments.map {
                    PluginTranscriptionSegment(text: $0.text, start: $0.start + chunk.offset, end: $0.end + chunk.offset)
                }
            }
        )
    }

    /// Like `transcribe`, for engines that label speakers. An engine numbers
    /// the speakers anew in every request, so labels from different chunks
    /// cannot be matched. Each chunk's speakers get numbers of their own
    /// instead: one person may appear under several numbers, but two people
    /// never end up under one.
    public static func transcribeStructured(
        _ audio: AudioData,
        maximumChunkDuration: TimeInterval = defaultMaximumChunkDuration,
        transcribeChunk: (AudioData) async throws -> PluginStructuredTranscriptionResult
    ) async throws -> PluginStructuredTranscriptionResult {
        guard let chunks = try await transcribeChunks(
            audio,
            maximumChunkDuration: maximumChunkDuration,
            transcribeChunk: transcribeChunk
        ) else {
            return try await transcribeChunk(audio)
        }

        var segments: [PluginStructuredTranscriptionSegment] = []
        var texts: [String] = []
        var speakerCount = 0
        for chunk in chunks {
            var speakers: [String: String] = [:]
            let chunkSegments = chunk.result.segments.map { segment in
                let speaker = segment.speakerLabel.map { label in
                    if let speaker = speakers[label] { return speaker }
                    speakerCount += 1
                    speakers[label] = "Speaker \(speakerCount)"
                    return "Speaker \(speakerCount)"
                }
                return PluginStructuredTranscriptionSegment(
                    text: segment.text,
                    start: segment.start + chunk.offset,
                    end: segment.end + chunk.offset,
                    speakerLabel: speaker,
                    speakerConfidence: segment.speakerConfidence
                )
            }
            segments += chunkSegments
            // Engines write the labels into the text as well, so labelled
            // text is rebuilt from the renumbered segments.
            if speakers.isEmpty {
                texts.append(chunk.result.text)
            } else {
                texts.append(chunkSegments.map { segment in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return segment.speakerLabel.map { "\($0): \(text)" } ?? text
                }.joined(separator: "\n"))
            }
        }

        let results = chunks.map(\.result)
        return PluginStructuredTranscriptionResult(
            text: speakerCount == 0
                ? joinedText(texts)
                : texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n"),
            detectedLanguage: mostFrequentLanguage(results.compactMap(\.detectedLanguage)),
            segments: segments
        )
    }

    /// Transcribes the chunks of `audio` in order, or returns nil when it fits
    /// into one chunk. Word times reported by the chunks refer to the whole
    /// recording.
    private static func transcribeChunks<Result>(
        _ audio: AudioData,
        maximumChunkDuration: TimeInterval,
        transcribeChunk: (AudioData) async throws -> Result
    ) async throws -> [(offset: TimeInterval, result: Result)]? {
        let ranges = chunkRanges(
            for: audio.samples,
            maximumChunkSampleCount: Int(maximumChunkDuration * Double(sampleRate))
        )
        guard ranges.count > 1 else { return nil }

        let collectsWords = PluginWordTimings.collector != nil
        var chunks: [(offset: TimeInterval, result: Result)] = []
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
            if collectsWords {
                let chunkWords = PluginWordTimingCollector()
                let result = try await PluginWordTimings.$collector.withValue(chunkWords) {
                    try await transcribeChunk(chunk)
                }
                words += chunkWords.words.map {
                    PluginWordTiming(text: $0.text, start: $0.start + offset, end: $0.end + offset)
                }
                chunks.append((offset, result))
            } else {
                chunks.append((offset, try await transcribeChunk(chunk)))
            }
        }

        if collectsWords {
            PluginWordTimings.report(words)
        }
        return chunks
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
