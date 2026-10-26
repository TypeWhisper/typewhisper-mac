import CoreML
import Foundation
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

    func unload() {
        model = nil
    }

    func identify(samples: [Float], among candidates: [String]) throws -> PluginSpokenLanguageIdentification? {
        let (model, labels) = try loaded()
        let columns = EarScoring.columns(for: candidates, labels: labels.languages)
        guard columns.count >= 2 else { return nil }

        let window = EarScoring.speechWindow(samples)
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
            "Spoken language \(result.language, privacy: .public) among \(candidates.joined(separator: ","), privacy: .public): p=\(result.confidence, format: .fixed(precision: 2)) margin=\(result.margin, format: .fixed(precision: 2)) in \(milliseconds) ms"
        )
        return result
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

    static func canonicalCode(_ code: String) -> String {
        let lowered = code.lowercased()
        let base = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lowered
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

    /// Up to 30 s starting shortly before the first speech, the way the model was trained:
    /// 20 ms frames within 35 dB of the loudest frame count as speech.
    static func speechWindow(_ samples: [Float]) -> [Float] {
        let frame = samplesPerEncoderFrame
        let frameCount = samples.count / frame
        var start = 0
        if frameCount >= 2 {
            var levels = [Float](repeating: 0, count: frameCount)
            samples.withUnsafeBufferPointer { buffer in
                for index in 0 ..< frameCount {
                    var energy: Float = 0
                    let offset = index * frame
                    for sample in buffer[offset ..< offset + frame] {
                        energy += sample * sample
                    }
                    levels[index] = 10 * log10(energy / Float(frame) + 1e-12)
                }
            }
            let threshold = (levels.max() ?? 0) - 35
            if let first = levels.firstIndex(where: { $0 > threshold }) {
                start = max(0, first * frame - sampleRate / 10)
            }
        }
        let end = min(samples.count, start + windowSamples)
        return Array(samples[start ..< end])
    }

    static func validFrames(sampleCount: Int) -> Int {
        let frames = (sampleCount + samplesPerEncoderFrame - 1) / samplesPerEncoderFrame
        return min(max(frames, 1), encoderFrames)
    }

    /// Softmax over the candidates. Whisper's guess helps with accents and noisy audio, but it
    /// knows nothing about some languages; mixing it in then would push those candidates out,
    /// so it only joins when it covers every candidate.
    static func pick(
        columns: [(code: String, index: Int)],
        own: [Float],
        whisper: [Float],
        labels: EarLabels
    ) -> PluginSpokenLanguageIdentification {
        let mixWhisper = columns.allSatisfy { labels.whisperLanguages.contains(labels.languages[$0.index]) }
        let scores = columns.map { own[$0.index] + (mixWhisper ? labels.whisperWeight * whisper[$0.index] : 0) }
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
