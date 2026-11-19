import AVFoundation
import CoreML
import Foundation
import SoundAnalysis
import TypeWhisperPluginSDK
import os

/// Tells which of the user's selected languages is spoken, so engines that accept a single
/// language still follow a multi-language selection.
///
/// The model ("TypeWhisper Ear") is whisper-tiny's encoder with a classifier trained on FLEURS,
/// VoxLingua107, VoxPopuli and AMI, plus Whisper's own language guess from one decoder step.
/// It runs through Core ML (about 15 ms per call on the Neural Engine) and never sends audio
/// anywhere. See MODEL.md for the training data and measurements.
@objc(LanguageDetectionPlugin)
final class LanguageDetectionPlugin: NSObject, SpokenLanguageIdentificationProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.language-detection"
    static let pluginName = "Language Detection"

    let spokenLanguageIdentificationProviderId = "typewhisper-ear"

    private let model = EarModel()

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {}

    func deactivate() {
        Task { await model.unload() }
    }

    func identifySpokenLanguage(
        samples: [Float],
        among candidates: [String]
    ) async throws -> PluginSpokenLanguageIdentification? {
        try await model.identify(samples: samples, among: candidates)
    }
}

/// Loads the Core ML model on first use and runs it.
actor EarModel {
    enum EarError: Error {
        case modelMissing
        case unexpectedOutput
    }

    private static let logger = Logger(subsystem: "com.typewhisper.language-detection", category: "EarModel")

    private var model: MLModel?
    private var labels: EarLabels?
    private var speechRequest: SNClassifySoundRequest?

    func unload() {
        model = nil
        speechRequest = nil
    }

    func identify(samples: [Float], among candidates: [String]) throws -> PluginSpokenLanguageIdentification? {
        let (_, labels) = try loaded()
        guard EarScoring.columns(for: candidates, labels: labels.languages).count >= 2 else { return nil }

        // The model hears English in ringing, clicks, room noise and silence with a margin near 1,
        // so it only judges audio from the first speech on, and nothing when there is none.
        let speechSecond: Range<Int>?
        do {
            guard let start = try SpeechOnset.firstSpeech(in: samples, request: loadedSpeechRequest()) else {
                Self.logger.info("No speech in \(samples.count / EarScoring.sampleRate) s of audio")
                return nil
            }
            speechSecond = start ..< min(samples.count, start + SpeechOnset.windowSamples)
        } catch {
            Self.logger.error("Speech search failed, judging from the first loud sound: \(error.localizedDescription, privacy: .public)")
            speechSecond = nil
        }
        return try identify(samples: samples, among: candidates, speechSecond: speechSecond)
    }

    /// The model's answer for the window at `speechSecond`, or from the first loud sound when it
    /// is nil, without looking for speech.
    func identify(
        samples: [Float],
        among candidates: [String],
        speechSecond: Range<Int>?
    ) throws -> PluginSpokenLanguageIdentification? {
        let (model, labels) = try loaded()
        let columns = EarScoring.columns(for: candidates, labels: labels.languages)
        guard columns.count >= 2 else { return nil }

        let window = EarScoring.speechWindow(samples, speechSecond: speechSecond)
        guard !window.isEmpty else { return nil }

        let audio = try MLMultiArray(shape: [1, NSNumber(value: EarScoring.windowSamples)], dataType: .float32)
        let pointer = audio.dataPointer.bindMemory(to: Float.self, capacity: EarScoring.windowSamples)
        pointer.initialize(repeating: 0, count: EarScoring.windowSamples)
        window.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                pointer.update(from: base, count: window.count)
            }
        }
        let validFrames = try MLMultiArray(shape: [1, 1], dataType: .float32)
        validFrames[0] = NSNumber(value: Float(EarScoring.validFrames(sampleCount: window.count)))

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "audio": MLFeatureValue(multiArray: audio),
            "valid_frames": MLFeatureValue(multiArray: validFrames),
        ])
        let start = CFAbsoluteTimeGetCurrent()
        let output = try model.prediction(from: input)
        guard let own = output.featureValue(for: "own_logprobs")?.multiArrayValue,
              let whisper = output.featureValue(for: "whisper_logprobs")?.multiArrayValue,
              own.count == labels.languages.count, whisper.count == labels.languages.count else {
            throw EarError.unexpectedOutput
        }

        let result = EarScoring.pick(
            columns: columns,
            own: (0 ..< own.count).map { own[$0].floatValue },
            whisper: (0 ..< whisper.count).map { whisper[$0].floatValue },
            labels: labels
        )
        let milliseconds = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        Self.logger.info(
            "Spoken language \(result.language, privacy: .public) among \(columns.count) known of \(candidates.count) candidates: p=\(result.confidence, format: .fixed(precision: 2)) margin=\(result.margin, format: .fixed(precision: 2)) from \((speechSecond?.lowerBound ?? 0) / EarScoring.sampleRate) s in \(milliseconds) ms"
        )
        return result
    }

    /// Creating the request loads the classifier (about 65 ms), so it is kept.
    private func loadedSpeechRequest() throws -> SNClassifySoundRequest {
        if let speechRequest {
            return speechRequest
        }
        let request = try SpeechOnset.makeRequest()
        speechRequest = request
        return request
    }

    private func loaded() throws -> (MLModel, EarLabels) {
        if let model, let labels {
            return (model, labels)
        }
        guard let url = pluginModuleBundle.url(forResource: "TypeWhisperEar", withExtension: "mlmodelc") else {
            throw EarError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        guard let labels = EarLabels(metadata: metadata) else { throw EarError.unexpectedOutput }
        model = loaded
        self.labels = labels
        return (loaded, labels)
    }
}

/// Finds the first speech with the system's sound classifier, which tells speech from ringing,
/// clicks and noise that are as loud.
enum SpeechOnset {
    /// Classifier windows of one second; shorter audio is padded with silence to one window.
    static let windowSamples = EarScoring.sampleRate
    /// Speech scores 0.8 to 0.95 per second in clean and telephone recordings and above 0.3 in
    /// most seconds of quiet or noisy speech; ring tones, clicks and room noise score 0.01 to 0.02.
    static let minimumConfidence = 0.3
    static let speechLabels = ["speech", "whispering", "shout", "yell"]

    static func makeRequest() throws -> SNClassifySoundRequest {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: CMTimeValue(windowSamples), timescale: CMTimeScale(EarScoring.sampleRate))
        request.overlapFactor = 0
        return request
    }

    /// The first sample of the first second that holds speech, or nil when none does. Stops at
    /// the first speech, so a long recording costs only the time until someone speaks.
    static func firstSpeech(in samples: [Float], request: SNClassifySoundRequest) throws -> Int? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Double(EarScoring.sampleRate),
                  channels: 1,
                  interleaved: false
              ) else {
            return nil
        }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let observer = SpeechObserver()
        try analyzer.add(request, withObserver: observer)
        defer { analyzer.removeAllRequests() }

        var offset = 0
        // The analyzer classifies on the calling thread, so each whole window reports before
        // the next one is fed.
        while offset < samples.count, observer.firstSpeech == nil {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(windowSamples)),
                  let channel = buffer.floatChannelData?[0] else {
                return nil
            }
            buffer.frameLength = AVAudioFrameCount(windowSamples)
            let count = min(windowSamples, samples.count - offset)
            channel.initialize(repeating: 0, count: windowSamples)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base + offset, count: count)
                }
            }
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(offset))
            if let failure = observer.failure {
                throw failure
            }
            offset += windowSamples
        }
        if observer.firstSpeech == nil {
            analyzer.completeAnalysis()
            if let failure = observer.failure {
                throw failure
            }
        }
        guard let start = observer.firstSpeech else { return nil }
        return min(samples.count, max(0, Int((start.seconds * Double(EarScoring.sampleRate)).rounded())))
    }

    private final class SpeechObserver: NSObject, SNResultsObserving {
        private(set) var firstSpeech: CMTime?
        private(set) var failure: Error?

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard firstSpeech == nil, let result = result as? SNClassificationResult else { return }
            let confidence = SpeechOnset.speechLabels
                .compactMap { result.classification(forIdentifier: $0)?.confidence }
                .max() ?? 0
            if confidence >= SpeechOnset.minimumConfidence {
                firstSpeech = result.timeRange.start
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            failure = error
        }
    }
}

/// The model's label set, read from its metadata.
struct EarLabels: Equatable {
    /// Output order of both log-prob vectors.
    let languages: [String]
    /// Languages Whisper's own guess covers.
    let whisperLanguages: Set<String>
    /// Weight of Whisper's log-probs when they are mixed in.
    let whisperWeight: Float

    init(languages: [String], whisperLanguages: Set<String>, whisperWeight: Float) {
        self.languages = languages
        self.whisperLanguages = whisperLanguages
        self.whisperWeight = whisperWeight
    }

    init?(metadata: [String: String]) {
        let languages = (metadata["languages"] ?? "").split(separator: ",").map(String.init)
        guard !languages.isEmpty else { return nil }
        self.languages = languages
        whisperLanguages = Set((metadata["whisper_languages"] ?? "").split(separator: ",").map(String.init))
        whisperWeight = Float(metadata["fusion_beta"] ?? "") ?? 1
    }
}

/// Model-independent steps, kept pure so they can be tested without Core ML.
enum EarScoring {
    static let sampleRate = 16_000
    static let windowSamples = 30 * sampleRate
    static let encoderFrames = 1_500
    static let samplesPerEncoderFrame = 320

    /// Codes that name the same language for the model.
    private static let aliases: [String: String] = [
        "nb": "no", "nn": "no", "iw": "he", "tl": "fil", "jw": "jv", "in": "id",
    ]

    /// Whisper has no Cantonese and hears it as Chinese, so its Chinese score stands in. Whisper
    /// then stays in the mix for a Cantonese candidate, and the model's own guess alone separates
    /// Cantonese from Mandarin.
    private static let whisperStandIns: [String: String] = ["yue": "zh"]

    static func canonicalCode(_ code: String) -> String {
        let lowered = code.lowercased()
        let parts = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        let base = parts.first ?? lowered
        // Speech engines such as Apple Speech and Deepgram use zh-HK for Hong Kong Cantonese.
        if base == "zh", parts.dropFirst().contains("hk") {
            return "yue"
        }
        return aliases[base] ?? base
    }

    /// Candidates the model knows, with their output column; the first code wins when two
    /// candidates name the same language.
    static func columns(for candidates: [String], labels: [String]) -> [(code: String, index: Int)] {
        var columns: [(code: String, index: Int)] = []
        for code in candidates {
            if let index = labels.firstIndex(of: canonicalCode(code)),
               !columns.contains(where: { $0.index == index }) {
                columns.append((code, index))
            }
        }
        return columns
    }

    /// Up to 30 s starting shortly before the first speech, the way the model was trained: the
    /// window starts 0.1 s before the first 20 ms frame within 35 dB of the loudest frame. With
    /// `speechSecond` (sample indices of the second the classifier heard speech in), both the
    /// loudest and the first frame come from that second, so louder sounds elsewhere in the
    /// recording cannot move the window off quiet speech; without it, from the whole recording.
    static func speechWindow(_ samples: [Float], speechSecond: Range<Int>? = nil) -> [Float] {
        let frame = samplesPerEncoderFrame
        let frameCount = samples.count / frame
        let searched = speechSecond.map { second in
            min(max(second.lowerBound, 0), samples.count) / frame ..< min(frameCount, (second.upperBound + frame - 1) / frame)
        } ?? 0 ..< frameCount
        var start = min(max(speechSecond?.lowerBound ?? 0, 0), samples.count)
        if searched.count >= 2 {
            let levels = samples.withUnsafeBufferPointer { buffer in
                searched.map { index -> Float in
                    var energy: Float = 0
                    let offset = index * frame
                    for sample in buffer[offset ..< offset + frame] {
                        energy += sample * sample
                    }
                    return 10 * log10(energy / Float(frame) + 1e-12)
                }
            }
            let threshold = (levels.max() ?? 0) - 35
            if let first = levels.firstIndex(where: { $0 > threshold }) {
                start = max(0, (searched.lowerBound + first) * frame - sampleRate / 10)
            }
        }
        let end = min(samples.count, start + windowSamples)
        return Array(samples[start ..< end])
    }

    static func validFrames(sampleCount: Int) -> Int {
        let frames = (sampleCount + samplesPerEncoderFrame - 1) / samplesPerEncoderFrame
        return min(max(frames, 1), encoderFrames)
    }

    /// The column of Whisper's guess for a label: its own, a stand-in's, or nil when Whisper
    /// knows neither.
    static func whisperIndex(for index: Int, labels: EarLabels) -> Int? {
        let language = labels.languages[index]
        if labels.whisperLanguages.contains(language) {
            return index
        }
        guard let standIn = whisperStandIns[language], labels.whisperLanguages.contains(standIn) else {
            return nil
        }
        return labels.languages.firstIndex(of: standIn)
    }

    /// Softmax over the candidates. Whisper's guess helps with accents and noisy audio, but it
    /// knows nothing about some languages; mixing it in then would push those candidates out,
    /// so it only joins when it covers every candidate, itself or through a stand-in.
    static func pick(
        columns: [(code: String, index: Int)],
        own: [Float],
        whisper: [Float],
        labels: EarLabels
    ) -> PluginSpokenLanguageIdentification {
        let whisperColumns = columns.map { whisperIndex(for: $0.index, labels: labels) }
        let mixWhisper = whisperColumns.allSatisfy { $0 != nil }
        let scores = zip(columns, whisperColumns).map { column, whisperColumn in
            own[column.index] + (mixWhisper ? whisperColumn.map { labels.whisperWeight * whisper[$0] } ?? 0 : 0)
        }
        let peak = scores.max() ?? 0
        let exps = scores.map { Foundation.exp($0 - peak) }
        let sum = exps.reduce(0, +)
        let probabilities = exps.map { $0 / sum }
        let ranked = probabilities.enumerated().sorted { $0.element > $1.element }
        let best = ranked[0]
        let runnerUp = ranked.count > 1 ? ranked[1].element : 0
        return PluginSpokenLanguageIdentification(
            language: columns[best.offset].code,
            confidence: Double(best.element),
            margin: Double(best.element - runnerUp)
        )
    }
}

private let pluginModuleBundle: Bundle = {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: LanguageDetectionPlugin.self)
#endif
}()
