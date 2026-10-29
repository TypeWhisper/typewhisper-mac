import CoreML
import FluidAudio
import Foundation
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

/// A Parakeet TDT model the user imported as Core ML files, for example a fine-tune for one language.
struct ParakeetImportedModel: Hashable, Sendable {
    let id: String
    let displayName: String
    let sizeDescription: String
    let origin: String
    let directory: URL
    let settings: ParakeetModelImport.Settings

    init(_ model: PluginCustomModelStore.Model, directory: URL, settings: ParakeetModelImport.Settings) {
        id = model.id
        displayName = model.displayName
        sizeDescription = model.sizeDescription
        origin = model.origin
        self.directory = directory
        self.settings = settings
    }

    /// The FluidAudio decode contract: v2 for 1,024 tokens, v3 for 8,192 tokens or more.
    var asrModelVersion: AsrModelVersion { settings.vocabularySize == 1024 ? .v2 : .v3 }

    /// Present when the model's blank token is not where FluidAudio expects it, as in fine-tunes
    /// that add tokens to the v3 vocabulary.
    var tokenRemapping: ParakeetTokenRemapping? {
        ParakeetTokenRemapping(fluidBlank: asrModelVersion.blankId, modelBlank: settings.vocabularySize)
    }
}

/// Imports Parakeet TDT models converted to Core ML. Accepted are FluidAudio's layout
/// (`Preprocessor.mlmodelc`, `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`,
/// `parakeet_vocab.json`) and the raw output of FluidInference's mobius converter
/// (`parakeet_preprocessor.mlpackage` …), compiled during the import.
enum ParakeetModelImport {
    static let modelType = "parakeet_tdt_coreml"
    static let settingsFileName = "parakeet-model.json"
    static let jointFileName = "JointDecision.mlmodelc"
    static let converterMetadataName = "metadata.json"
    static let vocabularyNames = ["parakeet_vocab.json", "parakeet_v3_vocab.json", "vocab.json", "vocab.txt"]

    struct Settings: Codable, Hashable, Sendable {
        /// Tokens without the blank, which follows them: 8,192 for v3, 8,225 for the Greek fine-tune.
        let vocabularySize: Int
        /// Whether the joint network reports top-K candidates, which FluidAudio's language hint needs.
        let hasTopK: Bool
    }

    enum Role: CaseIterable {
        case preprocessor, encoder, decoder, joint

        var installedName: String {
            switch self {
            case .preprocessor: ModelNames.ASR.preprocessorFile
            case .encoder: ModelNames.ASR.encoderFile
            case .decoder: ModelNames.ASR.decoderFile
            case .joint: ParakeetModelImport.jointFileName
            }
        }

        /// Names in order of preference. mobius' `parakeet_joint_decision` takes whole sequences
        /// and `parakeet_joint` returns raw logits; FluidAudio needs the single-step decision.
        var sourceNames: [String] {
            let names = switch self {
            case .preprocessor: ["Preprocessor", "parakeet_preprocessor"]
            case .encoder: ["Encoder", "parakeet_encoder"]
            case .decoder: ["Decoder", "parakeet_decoder"]
            case .joint: ["JointDecisionv3", "JointDecision", "parakeet_joint_decision_single_step"]
            }
            return names.flatMap { ["\($0).mlmodelc", "\($0).mlpackage"] }
        }

        var displayName: String {
            switch self {
            case .preprocessor: "preprocessor"
            case .encoder: "encoder"
            case .decoder: "decoder"
            case .joint: "joint decision"
            }
        }
    }

    /// The entries of a model folder or repository the import uses.
    struct Layout: Equatable, Sendable {
        let models: [Role: String]
        let vocabulary: String?
        let converterMetadata: String?

        var entries: Set<String> {
            Set(models.values).union([vocabulary, converterMetadata].compactMap { $0 })
        }
    }

    /// Picks the files to import from the names at the top of a folder or repository.
    static func layout(of names: Set<String>) throws -> Layout {
        var models: [Role: String] = [:]
        var missing: [Role] = []
        for role in Role.allCases {
            if let name = role.sourceNames.first(where: names.contains) {
                models[role] = name
            } else {
                missing.append(role)
            }
        }
        guard missing.isEmpty else {
            let list = missing.map { "\($0.displayName) (\($0.sourceNames[0]) or \($0.sourceNames.last!))" }
            throw PluginModelImportError.invalidModel(
                "No Parakeet Core ML model found. Missing: \(list.joined(separator: ", "))"
            )
        }
        return Layout(
            models: models,
            vocabulary: vocabularyNames.first(where: names.contains),
            converterMetadata: names.contains(converterMetadataName) ? converterMetadataName : nil
        )
    }

    static func layout(of candidate: PluginModelImportCandidate) throws -> Layout {
        switch candidate.source {
        case .folder(let folder):
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return try layout(of: Set(names))
        case .huggingFace:
            return try layout(of: topLevelNames(candidate.repositoryFiles))
        }
    }

    static func topLevelNames(_ paths: [String]) -> Set<String> {
        Set(paths.compactMap { $0.split(separator: "/").first.map(String.init) })
    }

    // MARK: Vocabulary

    /// Reads `parakeet_vocab.json` / `vocab.json` (`{"0": "<unk>", …}` or `["<unk>", …]`) or a
    /// NeMo/onnx-asr `vocab.txt` (`<piece> <id>` per line). The blank entry is dropped, since
    /// FluidAudio adds it, and `▁` becomes a space like in FluidAudio's own vocabularies.
    static func parseVocabulary(_ data: Data, fileName: String) throws -> [Int: String] {
        var tokens: [Int: String] = [:]
        if fileName.hasSuffix(".txt") {
            guard let text = String(data: data, encoding: .utf8) else {
                throw PluginModelImportError.invalidModel("\(fileName) is not UTF-8 text")
            }
            for line in text.split(whereSeparator: \.isNewline) {
                guard let separator = line.lastIndex(of: " "),
                      let id = Int(line[line.index(after: separator)...]) else { continue }
                tokens[id] = String(line[..<separator])
            }
        } else {
            let json = try? JSONSerialization.jsonObject(with: data)
            if let dictionary = json as? [String: String] {
                for (key, token) in dictionary {
                    if let id = Int(key) { tokens[id] = token }
                }
            } else if let array = json as? [String] {
                for (id, token) in array.enumerated() { tokens[id] = token }
            } else {
                throw PluginModelImportError.invalidModel("\(fileName) is not a Parakeet vocabulary")
            }
        }
        tokens = tokens.filter { !blankMarkers.contains($0.value) }
        guard !tokens.isEmpty, tokens.count == (tokens.keys.max() ?? -1) + 1 else {
            throw PluginModelImportError.invalidModel("\(fileName) has gaps in its token IDs")
        }
        return tokens.mapValues { $0.replacingOccurrences(of: "\u{2581}", with: " ") }
    }

    private static let blankMarkers: Set<String> = ["<blk>", "<blank>", "<b>"]

    /// The token count mobius records in `metadata.json`.
    static func converterVocabularySize(_ data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["vocab_size"] as? Int
    }

    // MARK: Preparing an import

    /// Turns the copied files into the layout the plugin loads: compiled models under FluidAudio's
    /// names, `parakeet_vocab.json` and the settings. `stockVocabulary` supplies the stock
    /// vocabulary for a token count when the model brings none.
    static func prepare(
        directory: URL,
        layout: Layout,
        stockVocabulary: (_ size: Int) async throws -> Data?,
        compile: (URL) async throws -> URL = { try await MLModel.compileModel(at: $0) }
    ) async throws -> Settings {
        // The vocabulary is checked first: a model without one fails before the slow compile.
        let expectedSize = layout.converterMetadata
            .flatMap { try? Data(contentsOf: directory.appendingPathComponent($0)) }
            .flatMap(converterVocabularySize)
        let tokens: [Int: String]
        if let name = layout.vocabulary {
            tokens = try parseVocabulary(Data(contentsOf: directory.appendingPathComponent(name)), fileName: name)
        } else if let expectedSize, let data = try await stockVocabulary(expectedSize) {
            tokens = try parseVocabulary(data, fileName: ModelNames.ASR.vocabularyFile)
        } else {
            throw missingVocabulary(tokenCount: expectedSize)
        }
        try checkTokenCount(tokens.count, expectedSize: expectedSize)

        let fileManager = FileManager.default
        for role in Role.allCases {
            guard let name = layout.models[role] else { continue }
            try Task.checkCancellation()
            let source = directory.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(role.installedName)
            if source.pathExtension == "mlpackage" {
                let compiled = try await compile(source)
                defer { try? fileManager.removeItem(at: compiled) }
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: compiled, to: destination)
                try fileManager.removeItem(at: source)
            } else if source.lastPathComponent != destination.lastPathComponent {
                try fileManager.moveItem(at: source, to: destination)
            }
        }

        let vocabulary = Dictionary(uniqueKeysWithValues: tokens.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(vocabulary).write(
            to: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile), options: .atomic
        )
        let joint = try MLModel(contentsOf: directory.appendingPathComponent(jointFileName))
        let outputs = joint.modelDescription.outputDescriptionsByName
        let settings = Settings(
            vocabularySize: tokens.count,
            hasTopK: outputs["top_k_ids"] != nil && outputs["top_k_logits"] != nil
        )
        try encoder.encode(settings).write(to: directory.appendingPathComponent(settingsFileName), options: .atomic)
        return settings
    }

    /// Token counts whose stock vocabulary the plugin supplies when a model brings none.
    static let stockVocabularySizes: Set<Int> = [8192, 1024]

    /// Without a vocabulary, only mobius' `metadata.json` tells which stock vocabulary fits.
    static func missingVocabulary(tokenCount: Int?) -> PluginModelImportError {
        guard let tokenCount else {
            return .invalidModel(
                "The model has no vocabulary file. Put its vocabulary (parakeet_vocab.json, vocab.json or vocab.txt) next to the model files and import it again."
            )
        }
        return .invalidModel(
            "The model has no vocabulary file, and its \(tokenCount) tokens match no standard Parakeet vocabulary. Put the vocabulary of the original model (vocab.txt or vocab.json) next to the model files and import it again."
        )
    }

    /// The token-count rules the inspection and `prepare` share.
    static func checkTokenCount(_ count: Int, expectedSize: Int?) throws {
        if let expectedSize, expectedSize != count {
            throw PluginModelImportError.invalidModel(
                "The vocabulary has \(count) tokens, but the model was converted with \(expectedSize)."
            )
        }
        guard count == 1024 || count >= 8192 else {
            throw PluginModelImportError.invalidModel(
                "Parakeet models with \(count) tokens are not supported. Supported are the vocabularies of Parakeet TDT v2 (1,024 tokens) and v3 (8,192 tokens or more)."
            )
        }
    }

    /// Fails a local folder with a missing or unusable vocabulary before anything is copied.
    static func checkVocabulary(in folder: URL, layout: Layout) throws {
        let metadata = layout.converterMetadata.flatMap { try? Data(contentsOf: folder.appendingPathComponent($0)) }
        if let name = layout.vocabulary {
            let tokens = try parseVocabulary(Data(contentsOf: folder.appendingPathComponent(name)), fileName: name)
            try checkTokenCount(tokens.count, expectedSize: metadata.flatMap(converterVocabularySize))
        } else {
            try checkVocabulary(converterMetadata: metadata, layout: layout)
        }
    }

    /// Fails a model without a vocabulary unless `metadata.json` names a stock vocabulary size.
    static func checkVocabulary(converterMetadata: Data?, layout: Layout) throws {
        guard layout.vocabulary == nil else { return }
        let size = converterMetadata.flatMap(converterVocabularySize)
        guard let size, stockVocabularySizes.contains(size) else { throw missingVocabulary(tokenCount: size) }
    }

    static func settings(in directory: URL) -> Settings? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(settingsFileName)) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    static func isInstalled(at directory: URL) -> Bool {
        let fileManager = FileManager.default
        return settings(in: directory) != nil
            && Role.allCases.allSatisfy { fileManager.fileExists(atPath: directory.appendingPathComponent($0.installedName).path) }
            && fileManager.fileExists(atPath: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile).path)
    }

    // MARK: Loading

    /// Loads the imported model locally, wrapping the decoder and joint network when its
    /// token IDs need remapping.
    static func loadModels(_ model: ParakeetImportedModel) throws -> AsrModels {
        let directory = model.directory
        let data = try Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        let tokens = try parseVocabulary(data, fileName: ModelNames.ASR.vocabularyFile)
        let remapping = model.tokenRemapping
        var vocabulary: [Int: String] = [:]
        for (id, token) in tokens {
            vocabulary[remapping?.fluidId(forModelId: id) ?? id] = token
        }
        let configuration = AsrModels.defaultConfiguration()
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly
        preprocessorConfiguration.allowLowPrecisionAccumulationOnGPU = true
        var decoder = try MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.decoderFile), configuration: configuration)
        var joint = try MLModel(contentsOf: directory.appendingPathComponent(jointFileName), configuration: configuration)
        if let remapping {
            decoder = ParakeetRemappedDecoderModel(base: decoder, remapping: remapping)
            joint = ParakeetRemappedJointModel(base: joint, remapping: remapping)
        }
        return try AsrModels(
            encoder: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.encoderFile), configuration: configuration),
            preprocessor: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.preprocessorFile), configuration: preprocessorConfiguration),
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: model.asrModelVersion
        )
    }
}

// MARK: - Token Remapping

/// FluidAudio fixes the blank token at the end of the stock vocabulary (8,192 for v3) and also
/// primes the decoder with it. A fine-tune that adds tokens moves its blank behind them (8,225
/// for the Greek v3 fine-tune), so FluidAudio would read the first added token as the blank.
/// The model's IDs are therefore shifted for FluidAudio: its blank becomes FluidAudio's blank,
/// and the added tokens follow it.
struct ParakeetTokenRemapping: Hashable, Sendable {
    let fluidBlank: Int
    let modelBlank: Int

    init?(fluidBlank: Int, modelBlank: Int) {
        guard modelBlank > fluidBlank else { return nil }
        self.fluidBlank = fluidBlank
        self.modelBlank = modelBlank
    }

    func fluidId(forModelId id: Int) -> Int {
        if id == modelBlank { return fluidBlank }
        return id >= fluidBlank ? id + 1 : id
    }

    func modelId(forFluidId id: Int) -> Int {
        if id == fluidBlank { return modelBlank }
        return id > fluidBlank ? id - 1 : id
    }
}

/// Feeds the decoder the model's ID for the token FluidAudio passes in `targets`.
final class ParakeetRemappedDecoderModel: MLModel, @unchecked Sendable {
    let base: MLModel
    let remapping: ParakeetTokenRemapping

    init(base: MLModel, remapping: ParakeetTokenRemapping) {
        self.base = base
        self.remapping = remapping
        super.init()
    }

    override var modelDescription: MLModelDescription { base.modelDescription }
    override var configuration: MLModelConfiguration { base.configuration }

    override func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
        try prediction(from: input, options: MLPredictionOptions())
    }

    override func prediction(from input: MLFeatureProvider, options: MLPredictionOptions) throws -> MLFeatureProvider {
        guard let targets = input.featureValue(for: "targets")?.multiArrayValue else {
            return try base.prediction(from: input, options: options)
        }
        let remapped = try MLMultiArray(shape: targets.shape, dataType: .int32)
        for index in 0..<targets.count {
            remapped[index] = NSNumber(value: remapping.modelId(forFluidId: targets[index].intValue))
        }
        var features: [String: MLFeatureValue] = [:]
        for name in input.featureNames {
            features[name] = input.featureValue(for: name)
        }
        features["targets"] = MLFeatureValue(multiArray: remapped)
        return try base.prediction(from: MLDictionaryFeatureProvider(dictionary: features), options: options)
    }
}

/// Reports the joint network's chosen and top-K token IDs as FluidAudio's IDs.
final class ParakeetRemappedJointModel: MLModel, @unchecked Sendable {
    let base: MLModel
    let remapping: ParakeetTokenRemapping

    init(base: MLModel, remapping: ParakeetTokenRemapping) {
        self.base = base
        self.remapping = remapping
        super.init()
    }

    override var modelDescription: MLModelDescription { base.modelDescription }
    override var configuration: MLModelConfiguration { base.configuration }

    override func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider {
        try prediction(from: input, options: MLPredictionOptions())
    }

    override func prediction(from input: MLFeatureProvider, options: MLPredictionOptions) throws -> MLFeatureProvider {
        let output = try base.prediction(from: input, options: options)
        for name in ["token_id", "top_k_ids"] {
            guard let ids = output.featureValue(for: name)?.multiArrayValue else { continue }
            // FluidAudio may read the reused output buffer itself, so the IDs change in place.
            for index in 0..<ids.count {
                ids[index] = NSNumber(value: remapping.fluidId(forModelId: ids[index].intValue))
            }
        }
        return output
    }
}
