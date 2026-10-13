import AVFoundation
import Foundation
import os
import SoundAnalysis

/// Finds where a recording holds speech.
///
/// Whisper-style engines write text for stretches without speech: the quiet minute
/// before a call starts comes back as subtitle credits, names from the dictionary
/// prompt or a sentence in another language (#1553). The Recorder sends only the
/// parts this detector reports.
protocol SpeechRegionDetecting: Sendable {
    /// The parts of 16 kHz mono `samples` that hold speech, in seconds and in order.
    /// No regions means no speech.
    func speechRegions(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>]
}

/// One classifier window and how likely it holds speech.
struct SpeechActivityWindow: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speechConfidence: Double
}

/// Turns classifier windows into speech regions.
///
/// The values favor keeping speech over removing noise. On real dictations made
/// worse with telephone bandwidth, 12 kbit/s Opus and pink noise at about 5 dB
/// below the speech, these values cut 4 of 625 speech windows, while pink noise,
/// typing and call join chimes stayed out entirely.
enum SpeechRegionPolicy {
    /// A window at or above this confidence belongs to a speech region.
    static let speechThreshold = 0.03
    /// A recording holds speech only when one window reaches this confidence.
    /// Noise, typing and chimes stayed below 0.05 in testing.
    static let evidenceThreshold = 0.06
    /// Audio kept before and after each speech window.
    static let padding: TimeInterval = 1.5
    /// Shorter stretches without speech stay in the audio.
    static let minimumRemovedStretch: TimeInterval = 3

    static func regions(
        from windows: [SpeechActivityWindow],
        duration: TimeInterval
    ) -> [ClosedRange<TimeInterval>] {
        guard duration > 0,
              windows.contains(where: { $0.speechConfidence >= evidenceThreshold }) else {
            return []
        }

        var regions: [ClosedRange<TimeInterval>] = []
        for window in windows.sorted(by: { $0.start < $1.start })
        where window.speechConfidence >= speechThreshold {
            let start = max(0, window.start - padding)
            let end = min(duration, window.end + padding)
            guard start < end else { continue }
            if let last = regions.last, start - last.upperBound < minimumRemovedStretch {
                regions[regions.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                regions.append(start...end)
            }
        }

        if let first = regions.first, first.lowerBound < minimumRemovedStretch {
            regions[0] = 0...first.upperBound
        }
        if let last = regions.last, duration - last.upperBound < minimumRemovedStretch {
            regions[regions.count - 1] = last.lowerBound...duration
        }
        return regions
    }
}

/// Speech detection with the sound classifier built into macOS, which needs no
/// model download and runs in about 2.5 seconds for 33 minutes of audio.
struct SoundAnalysisSpeechRegionDetector: SpeechRegionDetecting {
    /// Classifier labels that count as speech. Whisper also writes sung lyrics.
    static let speechLabels: Set<String> = [
        "speech", "whispering", "shout", "yell", "children_shouting",
        "singing", "choir_singing", "rapping",
    ]
    static let windowDuration: TimeInterval = 1
    static let overlapFactor = 0.5
    /// Long recordings are classified in parallel parts of this length.
    static let partDuration: TimeInterval = 300

    func speechRegions(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>] {
        guard !samples.isEmpty else { return [] }
        let sampleRate = AudioRecorderService.transcriptionSampleRate
        let duration = Double(samples.count) / sampleRate
        let windows = try await Self.windows(in: samples, sampleRate: sampleRate)
        // Audio shorter than one window gets no verdict, so all of it is kept.
        guard !windows.isEmpty else { return [0...duration] }
        return SpeechRegionPolicy.regions(from: windows, duration: duration)
    }

    static func windows(
        in samples: [Float],
        sampleRate: Double
    ) async throws -> [SpeechActivityWindow] {
        guard !samples.isEmpty else { return [] }
        let partLength = Int(partDuration * sampleRate)
        // Each part runs one window past its end, so no window is lost at a boundary.
        let overlapLength = Int(windowDuration * sampleRate)
        let partStarts = Array(stride(from: 0, to: samples.count, by: partLength))
        // The classifier only reports whole windows. Silence after the recording
        // completes the last one, so the end is judged on its own audio.
        let windowLength = Int(windowDuration * sampleRate)
        let hopLength = Int(windowDuration * (1 - overlapFactor) * sampleRate)
        let trailingSilence = samples.count < windowLength
            ? 0
            : (hopLength - (samples.count - windowLength) % hopLength) % hopLength
        let isCancelled = OSAllocatedUnfairLock(initialState: false)

        let parts: [[SpeechActivityWindow]] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let results = OSAllocatedUnfairLock(
                        initialState: [Result<[SpeechActivityWindow], any Error>?](
                            repeating: nil,
                            count: partStarts.count
                        )
                    )
                    DispatchQueue.concurrentPerform(iterations: partStarts.count) { index in
                        let start = partStarts[index]
                        let end = min(samples.count, start + partLength + overlapLength)
                        let result = Result {
                            try classify(
                                samples[start..<end],
                                // A last part shorter than one window cannot hold one;
                                // the part before it also reaches the end and covers it.
                                trailingSilence: end == samples.count ? trailingSilence : 0,
                                offset: Double(start) / sampleRate,
                                sampleRate: sampleRate,
                                isCancelled: { isCancelled.withLock { $0 } }
                            )
                        }
                        results.withLock { $0[index] = result }
                    }
                    let outcome = Result {
                        try results.withLock { $0 }.map { try $0?.get() ?? [] }
                    }
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()

        let duration = Double(samples.count) / sampleRate
        var windows = parts.flatMap { $0 }
            .filter { $0.start < duration }
            .map { window in
                SpeechActivityWindow(
                    start: window.start,
                    end: min(window.end, duration),
                    speechConfidence: window.speechConfidence
                )
            }
            .sorted { $0.start < $1.start }
        // Should the classifier still leave the end unreported, the last window covers it.
        if let last = windows.last, last.end < duration {
            windows[windows.count - 1] = SpeechActivityWindow(
                start: last.start,
                end: duration,
                speechConfidence: last.speechConfidence
            )
        }
        return windows
    }

    private static func classify(
        _ samples: ArraySlice<Float>,
        trailingSilence: Int,
        offset: TimeInterval,
        sampleRate: Double,
        isCancelled: () -> Bool
    ) throws -> [SpeechActivityWindow] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechDetectionError.unsupportedFormat
        }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: windowDuration, preferredTimescale: CMTimeScale(sampleRate))
        request.overlapFactor = overlapFactor
        let collector = SpeechWindowCollector(offset: offset, speechLabels: speechLabels)
        try analyzer.add(request, withObserver: collector)

        var framePosition: AVAudioFramePosition = 0
        func analyze(count: Int, fill: (UnsafeMutablePointer<Float>) -> Void) throws {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw SpeechDetectionError.unsupportedFormat
            }
            buffer.frameLength = AVAudioFrameCount(count)
            fill(channel)
            analyzer.analyze(buffer, atAudioFramePosition: framePosition)
            framePosition += AVAudioFramePosition(count)
        }

        let blockLength = Int(10 * sampleRate)
        var position = samples.startIndex
        while position < samples.endIndex {
            guard !isCancelled() else { throw CancellationError() }
            let count = min(blockLength, samples.endIndex - position)
            try analyze(count: count) { channel in
                samples[position..<(position + count)].withUnsafeBufferPointer { source in
                    if let baseAddress = source.baseAddress {
                        channel.update(from: baseAddress, count: count)
                    }
                }
            }
            position += count
        }
        if trailingSilence > 0 {
            try analyze(count: trailingSilence) { $0.update(repeating: 0, count: trailingSilence) }
        }
        analyzer.completeAnalysis()
        if let error = collector.error {
            throw error
        }
        return collector.windows
    }
}

enum SpeechDetectionError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "The sound classifier could not read the recording."
    }
}

private final class SpeechWindowCollector: NSObject, SNResultsObserving, Sendable {
    private struct State {
        var windows: [SpeechActivityWindow] = []
        var error: (any Error)?
    }

    private let offset: TimeInterval
    private let speechLabels: Set<String>
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(offset: TimeInterval, speechLabels: Set<String>) {
        self.offset = offset
        self.speechLabels = speechLabels
    }

    var windows: [SpeechActivityWindow] { state.withLock { $0.windows } }
    var error: (any Error)? { state.withLock { $0.error } }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let confidence = result.classifications
            .filter { speechLabels.contains($0.identifier) }
            .map(\.confidence)
            .max() ?? 0
        let window = SpeechActivityWindow(
            start: offset + result.timeRange.start.seconds,
            end: offset + result.timeRange.end.seconds,
            speechConfidence: confidence
        )
        state.withLock { $0.windows.append(window) }
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        state.withLock { $0.error = error }
    }
}

/// A recording with the stretches between its speech regions taken out, and the
/// way back from its times to the recording's.
struct SpeechOnlyAudio: Sendable {
    /// Silence between two kept parts, so the engine hears a pause there.
    static let pauseBetweenParts: TimeInterval = 0.5
    /// Kept parts fade in and out over this time, so a cut does not click.
    static let fadeDuration: TimeInterval = 0.01

    struct Part: Equatable, Sendable {
        let originalStart: TimeInterval
        let start: TimeInterval
        let duration: TimeInterval
    }

    let samples: [Float]
    let parts: [Part]
    let originalDuration: TimeInterval

    /// `nil` when the regions keep the whole recording, which then needs no change.
    init?(
        samples original: [Float],
        sampleRate: Double,
        speechRegions: [ClosedRange<TimeInterval>]
    ) {
        let originalDuration = Double(original.count) / sampleRate
        var ranges: [Range<Int>] = []
        let sampleRanges = speechRegions.compactMap { region -> Range<Int>? in
            let start = max(0, min(original.count, Int((region.lowerBound * sampleRate).rounded())))
            let end = max(0, min(original.count, Int((region.upperBound * sampleRate).rounded())))
            return start < end ? start..<end : nil
        }
        for range in sampleRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        guard !ranges.isEmpty,
              ranges.reduce(0, { $0 + $1.count }) < original.count else {
            return nil
        }

        let pauseLength = Int(Self.pauseBetweenParts * sampleRate)
        let fadeLength = Int(Self.fadeDuration * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(ranges.reduce(0) { $0 + $1.count + pauseLength })
        var parts: [Part] = []
        for (index, range) in ranges.enumerated() {
            if index > 0 {
                samples.append(contentsOf: repeatElement(0, count: pauseLength))
            }
            let partStart = samples.count
            samples.append(contentsOf: original[range])
            let length = range.count
            let fade = min(fadeLength, length / 2)
            if fade > 0 {
                for offset in 0..<fade {
                    let gain = Float(offset) / Float(fade)
                    if range.lowerBound > 0 {
                        samples[partStart + offset] *= gain
                    }
                    if range.upperBound < original.count {
                        samples[partStart + length - 1 - offset] *= gain
                    }
                }
            }
            parts.append(Part(
                originalStart: Double(range.lowerBound) / sampleRate,
                start: Double(partStart) / sampleRate,
                duration: Double(length) / sampleRate
            ))
        }

        self.samples = samples
        self.parts = parts
        self.originalDuration = originalDuration
    }

    /// The recording's time for a start time in `samples`. A start in a pause
    /// belongs to the speech after it.
    func originalStart(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite, let last = parts.last else { return time }
        guard let part = parts.first(where: { time < $0.start + $0.duration }) else {
            return last.originalStart + last.duration
        }
        return part.originalStart + max(0, time - part.start)
    }

    /// The recording's time for an end time in `samples`. An end in a pause
    /// belongs to the speech before it.
    func originalEnd(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite, let first = parts.first else { return time }
        guard let part = parts.last(where: { $0.start < time }) else {
            return first.originalStart
        }
        return part.originalStart + min(time - part.start, part.duration)
    }

    /// The result with segment and word times on the recording's timeline.
    func restoringOriginalTimes(of result: TranscriptionResult) -> TranscriptionResult {
        TranscriptionResult(
            text: result.text,
            detectedLanguage: result.detectedLanguage,
            duration: originalDuration,
            processingTime: result.processingTime,
            engineUsed: result.engineUsed,
            segments: result.segments.map { segment in
                let (start, end) = originalRange(segment.start, segment.end)
                return TranscriptionSegment(
                    text: segment.text,
                    start: start,
                    end: end,
                    speakerLabel: segment.speakerLabel,
                    speakerConfidence: segment.speakerConfidence
                )
            },
            words: result.words.map { word in
                let (start, end) = originalRange(word.start, word.end)
                return TranscriptionWord(text: word.text, start: start, end: end)
            }
        )
    }

    /// Text that lies entirely in a pause keeps a zero length.
    private func originalRange(
        _ start: TimeInterval,
        _ end: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        let originalStart = originalStart(start)
        let originalEnd = originalEnd(end)
        guard originalStart.isFinite, originalEnd.isFinite else {
            return (originalStart, originalEnd)
        }
        return (originalStart, max(originalStart, originalEnd))
    }
}
