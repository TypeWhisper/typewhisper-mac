import Foundation
import OnnxRuntimeBindings

/// Runs a GigaAM end-to-end RNN-T model (with punctuation and casing) through ONNX Runtime on
/// the CPU.
///
/// A small bundled ONNX graph turns 16 kHz audio into 64 log-mel features (all GigaAM models share
/// the feature settings) and the encoder runs once per chunk. The v3 export of onnx-asr (MIT,
/// github.com/istupakov/onnx-asr) is decoded by a greedy loop over its decoder and joint networks;
/// v4 and Multilingual v2 run that loop inside their `advance` graph.
final class GigaAMRuntime: @unchecked Sendable {
    static let sampleRate = 16_000
    /// The model was trained on short utterances; longer recordings are cut at quiet points.
    static let maximumChunkDuration: TimeInterval = 20

    private static let predictionHiddenSize = 320
    private static let maxTokensPerStep = 3

    private enum Decoder {
        case transducer(decoder: ORTSession, joint: ORTSession)
        case advance(ORTSession)
    }

    private let preprocessor: ORTSession
    private let encoder: ORTSession
    private let decoder: Decoder
    let files: GigaAMModelFiles
    private let vocabulary: GigaAMVocabulary
    private let lock = NSLock()

    init(modelDirectory: URL, files: GigaAMModelFiles, preprocessorURL: URL) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        func session(_ url: URL) throws -> ORTSession {
            try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        }
        func model(_ name: String) throws -> ORTSession {
            try session(modelDirectory.appendingPathComponent(name))
        }
        preprocessor = try session(preprocessorURL)
        encoder = try model(files.encoder)
        decoder = switch files.decoding {
        case .transducer(let decoder, let joint): .transducer(decoder: try model(decoder), joint: try model(joint))
        case .advance(let advance): .advance(try model(advance))
        }
        self.files = files
        vocabulary = try GigaAMVocabulary(contentsOf: modelDirectory.appendingPathComponent(files.vocabulary))
    }

    /// Transcribes one chunk of 16 kHz mono audio; a language-conditioned model detects the
    /// language itself when `language` is nil or not one of its languages.
    func transcribe(_ samples: [Float], language: String? = nil) throws -> String {
        guard !samples.isEmpty else { return "" }
        // The feature extractor uses no centering, so very short input would yield no frames.
        let padded = Self.paddedToMinimumDuration(samples)
        return try lock.withLock {
            let (features, featureLength) = try extractFeatures(padded)
            let tokens: [Int]
            switch decoder {
            case .transducer(let decoder, let joint):
                let (encoded, frameCount) = try encode(features, featureLength: featureLength)
                tokens = try decodeGreedy(encoded, frameCount: frameCount, decoder: decoder, joint: joint)
            case .advance(let advance):
                tokens = try decodeInGraph(features, featureLength: featureLength, language: language, advance: advance)
            }
            return vocabulary.text(for: tokens)
        }
    }

    static func paddedToMinimumDuration(_ samples: [Float]) -> [Float] {
        let minimum = sampleRate
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    // MARK: - Pipeline

    private func extractFeatures(_ samples: [Float]) throws -> (ORTValue, Int64) {
        let outputs = try preprocessor.run(
            withInputs: [
                "waveforms": try GigaAMTensor.make(samples, type: .float, shape: [1, samples.count]),
                "waveforms_lens": try GigaAMTensor.make([Int64(samples.count)], type: .int64, shape: [1]),
            ],
            outputNames: ["features", "features_lens"],
            runOptions: nil
        )
        guard let features = outputs["features"],
              let lengthValue = outputs["features_lens"],
              let length = (try GigaAMTensor.values(lengthValue) as [Int64]).first else {
            throw GigaAMRuntimeError.missingOutput("features")
        }
        return (features, length)
    }

    /// Returns the encoder output as frame-major vectors and the number of valid frames.
    private func encode(_ features: ORTValue, featureLength: Int64) throws -> ([[Float]], Int) {
        let outputs = try encoder.run(
            withInputs: [
                "audio_signal": features,
                "length": try GigaAMTensor.make([featureLength], type: .int64, shape: [1]),
            ],
            outputNames: ["encoded", "encoded_len"],
            runOptions: nil
        )
        guard let encodedValue = outputs["encoded"], let lengthValue = outputs["encoded_len"] else {
            throw GigaAMRuntimeError.missingOutput("encoded")
        }
        let shape = try encodedValue.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1 else { throw GigaAMRuntimeError.unexpectedShape(shape) }
        let (dimension, frames) = (shape[1], shape[2])
        let flat: [Float] = try GigaAMTensor.values(encodedValue)
        let validFrames = min(frames, Int((try GigaAMTensor.values(lengthValue) as [Int32]).first ?? 0))
        // The encoder emits [1, dimension, frames]; the joint network wants one frame at a time.
        let encoded = (0..<validFrames).map { frame in
            (0..<dimension).map { flat[$0 * frames + frame] }
        }
        return (encoded, validFrames)
    }

    /// The encoder emits the projections of both heads, and `advance` decodes both greedily;
    /// only the first, end-to-end head (with punctuation and casing) is read.
    private func decodeInGraph(_ features: ORTValue, featureLength: Int64, language: String?, advance: ORTSession) throws -> [Int] {
        var inputs = [
            "audio_signal": features,
            "length": try GigaAMTensor.make([featureLength], type: .int64, shape: [1]),
        ]
        if let vector = files.languageVector(for: language) {
            inputs["language_vector"] = try GigaAMTensor.make(vector, type: .float, shape: [1, vector.count])
        }
        let encoded = try encoder.run(
            withInputs: inputs,
            outputNames: ["head_outputs", "encoded_len"],
            runOptions: nil
        )
        guard let projected = encoded["head_outputs"], let lengths = encoded["encoded_len"] else {
            throw GigaAMRuntimeError.missingOutput("head_outputs")
        }
        let outputs = try advance.run(
            withInputs: ["projected": projected, "lengths": lengths],
            outputNames: ["tokens"],
            runOptions: nil
        )
        guard let tokens = outputs["tokens"] else { throw GigaAMRuntimeError.missingOutput("tokens") }
        return try Self.firstHeadTokens(
            GigaAMTensor.values(tokens), shape: tokens.tensorTypeAndShapeInfo().shape.map(\.intValue)
        )
    }

    /// `tokens` is [steps, heads, batch] with -1 where a step emitted nothing; the batch is one.
    static func firstHeadTokens(_ tokens: [Int64], shape: [Int]) throws -> [Int] {
        guard shape.count == 3, shape[1] > 0, shape[2] == 1,
              tokens.count.isMultiple(of: shape[1]), tokens.count / shape[1] == shape[0] else {
            throw GigaAMRuntimeError.unexpectedShape(shape)
        }
        return stride(from: 0, to: tokens.count, by: shape[1]).compactMap { tokens[$0] >= 0 ? Int(tokens[$0]) : nil }
    }

    private func decodeGreedy(_ encoded: [[Float]], frameCount: Int, decoder: ORTSession, joint: ORTSession) throws -> [Int] {
        let blank = vocabulary.blankID
        var hidden = [Float](repeating: 0, count: Self.predictionHiddenSize)
        var cell = hidden
        var lastToken = blank
        // The decoder only depends on the last emitted token, so its output is reused while
        // the joint network keeps predicting blanks.
        var prediction: (output: ORTValue, hidden: [Float], cell: [Float])?
        var tokens: [Int] = []
        var frame = 0
        var emittedThisFrame = 0

        while frame < frameCount {
            if prediction == nil {
                prediction = try runDecoder(decoder, token: lastToken, hidden: hidden, cell: cell)
            }
            let logits = try runJoint(joint, encoded[frame], prediction: prediction!.output)
            let token = Self.argmax(logits)

            if token != blank {
                tokens.append(token)
                lastToken = token
                hidden = prediction!.hidden
                cell = prediction!.cell
                prediction = nil
                emittedThisFrame += 1
            }
            if token == blank || emittedThisFrame == Self.maxTokensPerStep {
                frame += 1
                emittedThisFrame = 0
            }
        }
        return tokens
    }

    private func runDecoder(_ decoder: ORTSession, token: Int, hidden: [Float], cell: [Float]) throws -> (ORTValue, [Float], [Float]) {
        let size = Self.predictionHiddenSize
        let outputs = try decoder.run(
            withInputs: [
                "x": try GigaAMTensor.make([Int64(token)], type: .int64, shape: [1, 1]),
                "h.1": try GigaAMTensor.make(hidden, type: .float, shape: [1, 1, size]),
                "c.1": try GigaAMTensor.make(cell, type: .float, shape: [1, 1, size]),
            ],
            outputNames: ["dec", "h", "c"],
            runOptions: nil
        )
        guard let output = outputs["dec"], let newHidden = outputs["h"], let newCell = outputs["c"] else {
            throw GigaAMRuntimeError.missingOutput("dec")
        }
        // [1, 1, 320] and the joint input [1, 320, 1] share one memory layout.
        let reshaped = try GigaAMTensor.make(GigaAMTensor.values(output) as [Float], type: .float, shape: [1, size, 1])
        return (reshaped, try GigaAMTensor.values(newHidden), try GigaAMTensor.values(newCell))
    }

    private func runJoint(_ joint: ORTSession, _ frame: [Float], prediction: ORTValue) throws -> [Float] {
        let outputs = try joint.run(
            withInputs: [
                "enc": try GigaAMTensor.make(frame, type: .float, shape: [1, frame.count, 1]),
                "dec": prediction,
            ],
            outputNames: ["joint"],
            runOptions: nil
        )
        guard let logits = outputs["joint"] else { throw GigaAMRuntimeError.missingOutput("joint") }
        return try GigaAMTensor.values(logits)
    }

    static func argmax(_ values: [Float]) -> Int {
        var best = 0
        for index in values.indices where values[index] > values[best] { best = index }
        return best
    }
}

/// The files of one GigaAM ONNX export and how its tokens are decoded.
enum GigaAMModelFiles: String, Sendable {
    case v3 = "v3_e2e_rnnt"
    case v4 = "v4_rnnt"
    case multilingualV2 = "multilingual_v2_rnnt"

    enum Decoding: Sendable {
        /// Separate decoder and joint networks, driven by the greedy loop in Swift.
        case transducer(decoder: String, joint: String)
        /// One graph that runs the greedy loop itself.
        case advance(String)
    }

    var encoder: String { "\(rawValue)_encoder.int8.onnx" }
    var vocabulary: String { rawValue + (self == .v3 ? "_vocab.txt" : "_e2e_vocab.txt") }

    var decoding: Decoding {
        switch self {
        case .v3: .transducer(decoder: "\(rawValue)_decoder.int8.onnx", joint: "\(rawValue)_joint.int8.onnx")
        case .v4, .multilingualV2: .advance("\(rawValue)_advance.onnx")
        }
    }

    var all: [String] {
        switch decoding {
        case .transducer(let decoder, let joint): [encoder, decoder, joint, vocabulary]
        case .advance(let advance): [encoder, advance, vocabulary]
        }
    }

    var languages: [String] {
        switch self {
        case .v3: ["ru"]
        case .v4: ["ru", "en"]
        // The encoder's language slots, not alphabetical order.
        case .multilingualV2: ["ru", "en", "kk", "ky", "uz", "be", "fr", "es", "ba", "ka", "hy",
                               "ro", "tk", "az", "tg", "de", "it", "nl", "pl", "pt", "tt"]
        }
    }

    /// Neither advance graph returns a detected language. Report a language only when it
    /// was explicitly selected for Multilingual v2, or when using the monolingual v3.
    func transcriptLanguage(for language: String?) -> String? {
        switch self {
        case .v3: return "ru"
        case .v4: return nil
        case .multilingualV2:
            guard let language, let code = Locale(identifier: language).language.languageCode?.identifier,
                  languages.contains(code) else { return nil }
            return code
        }
    }

    /// Only Multilingual v2 takes this 32-slot input; slot 0 requests automatic detection.
    func languageVector(for language: String?) -> [Float]? {
        guard self == .multilingualV2 else { return nil }
        let index = transcriptLanguage(for: language).flatMap { languages.firstIndex(of: $0) }
        var vector = [Float](repeating: 0, count: 32)
        vector[index.map { $0 + 1 } ?? 0] = 1
        return vector
    }
}

enum GigaAMRuntimeError: LocalizedError {
    case missingOutput(String)
    case unexpectedShape([Int])
    case invalidVocabulary

    var errorDescription: String? {
        switch self {
        case .missingOutput(let name): "GigaAM returned no \(name) output."
        case .unexpectedShape(let shape): "GigaAM returned an unexpected tensor shape \(shape)."
        case .invalidVocabulary: "The GigaAM vocabulary file is invalid."
        }
    }
}

/// SentencePiece pieces with "▁" marking the start of a word, one "<piece> <id>" per line.
struct GigaAMVocabulary {
    let pieces: [Int: String]
    let blankID: Int

    init(contentsOf url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }

    init(text: String) throws {
        var pieces: [Int: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // The piece itself can be a space-free symbol only, so the id is after the last space.
            guard let separator = line.lastIndex(of: " "), let id = Int(line[line.index(after: separator)...]) else {
                throw GigaAMRuntimeError.invalidVocabulary
            }
            pieces[id] = String(line[..<separator])
        }
        guard let blank = pieces.first(where: { $0.value == "<blk>" })?.key else {
            throw GigaAMRuntimeError.invalidVocabulary
        }
        self.pieces = pieces
        self.blankID = blank
    }

    func text(for tokens: [Int]) -> String {
        let joined = tokens.compactMap { pieces[$0] }.joined().replacingOccurrences(of: "\u{2581}", with: " ")
        return Self.normalizeSpacing(joined)
    }

    /// Collapses runs of spaces and removes spaces before closing and after opening punctuation.
    static func normalizeSpacing(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " +([.,!?:;…»)\\]])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "([«(\\[]) +", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}

enum GigaAMTensor {
    static func make<T>(_ values: [T], type: ORTTensorElementDataType, shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
    }

    static func values<T>(_ value: ORTValue) throws -> [T] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
    }
}
