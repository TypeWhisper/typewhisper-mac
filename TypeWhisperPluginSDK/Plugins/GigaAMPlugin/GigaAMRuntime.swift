import Foundation
import OnnxRuntimeBindings

/// Runs the GigaAM v3 end-to-end RNN-T model (Russian, with punctuation and casing) through
/// ONNX Runtime on the CPU.
///
/// The pipeline matches onnx-asr (MIT, github.com/istupakov/onnx-asr), which published the ONNX
/// exports: a small bundled ONNX graph turns 16 kHz audio into 64 log-mel features, the Conformer
/// encoder runs once per chunk, and a greedy transducer loop calls the decoder and joint networks.
final class GigaAMRuntime: @unchecked Sendable {
    static let sampleRate = 16_000
    /// The model was trained on short utterances; longer recordings are cut at quiet points.
    static let maximumChunkDuration: TimeInterval = 20

    private static let predictionHiddenSize = 320
    private static let maxTokensPerStep = 3

    private let preprocessor: ORTSession
    private let encoder: ORTSession
    private let decoder: ORTSession
    private let joint: ORTSession
    private let vocabulary: GigaAMVocabulary
    private let lock = NSLock()

    init(modelDirectory: URL, preprocessorURL: URL) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        func session(_ url: URL) throws -> ORTSession {
            try ORTSession(env: environment, modelPath: url.path, sessionOptions: options)
        }
        preprocessor = try session(preprocessorURL)
        encoder = try session(modelDirectory.appendingPathComponent(GigaAMModelFiles.encoder))
        decoder = try session(modelDirectory.appendingPathComponent(GigaAMModelFiles.decoder))
        joint = try session(modelDirectory.appendingPathComponent(GigaAMModelFiles.joint))
        vocabulary = try GigaAMVocabulary(contentsOf: modelDirectory.appendingPathComponent(GigaAMModelFiles.vocabulary))
    }

    /// Transcribes one chunk of 16 kHz mono audio.
    func transcribe(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        // The feature extractor uses no centering, so very short input would yield no frames.
        let padded = Self.paddedToMinimumDuration(samples)
        return try lock.withLock {
            let (features, featureLength) = try extractFeatures(padded)
            let (encoded, frameCount) = try encode(features, featureLength: featureLength)
            let tokens = try decodeGreedy(encoded, frameCount: frameCount)
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

    private func decodeGreedy(_ encoded: [[Float]], frameCount: Int) throws -> [Int] {
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
                prediction = try runDecoder(token: lastToken, hidden: hidden, cell: cell)
            }
            let logits = try runJoint(encoded[frame], prediction: prediction!.output)
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

    private func runDecoder(token: Int, hidden: [Float], cell: [Float]) throws -> (ORTValue, [Float], [Float]) {
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

    private func runJoint(_ frame: [Float], prediction: ORTValue) throws -> [Float] {
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

/// The files of the `istupakov/gigaam-v3-onnx` repository this plugin uses (int8 weights).
enum GigaAMModelFiles {
    static let encoder = "v3_e2e_rnnt_encoder.int8.onnx"
    static let decoder = "v3_e2e_rnnt_decoder.int8.onnx"
    static let joint = "v3_e2e_rnnt_joint.int8.onnx"
    static let vocabulary = "v3_e2e_rnnt_vocab.txt"
    static let all = [encoder, decoder, joint, vocabulary]
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
