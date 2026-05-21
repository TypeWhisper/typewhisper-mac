import Foundation
import OnnxRuntimeBindings

final class SupertonicONNXSynthesizer: SupertonicSynthesizing, @unchecked Sendable {
    private let textToSpeech: SupertonicTextToSpeech
    private let voiceStylesDirectory: URL
    private let inferenceLock = NSLock()

    init(modelDirectory: URL) throws {
        let onnxDirectory = modelDirectory.appendingPathComponent("onnx", isDirectory: true)
        let environment = try ORTEnv(loggingLevel: .warning)
        self.textToSpeech = try SupertonicTextToSpeech.load(onnxDirectory: onnxDirectory, environment: environment)
        self.voiceStylesDirectory = modelDirectory.appendingPathComponent("voice_styles", isDirectory: true)
    }

    func synthesize(
        text: String,
        language: String,
        voiceId: String,
        quality: SupertonicQuality,
        speed: Double
    ) throws -> SupertonicSynthesisOutput {
        let style = try SupertonicStyle.load(
            from: voiceStylesDirectory.appendingPathComponent("\(voiceId).json")
        )

        inferenceLock.lock()
        defer { inferenceLock.unlock() }

        let result = try textToSpeech.call(
            text,
            language,
            style,
            quality.totalSteps,
            speed: Float(speed),
            silenceDuration: 0.3
        )
        return SupertonicSynthesisOutput(samples: result.wav, sampleRate: textToSpeech.sampleRate)
    }
}

private struct SupertonicConfig: Decodable {
    struct AEConfig: Decodable {
        let sampleRate: Int
        let baseChunkSize: Int

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case baseChunkSize = "base_chunk_size"
        }
    }

    struct TTLConfig: Decodable {
        let chunkCompressFactor: Int
        let latentDim: Int

        enum CodingKeys: String, CodingKey {
            case chunkCompressFactor = "chunk_compress_factor"
            case latentDim = "latent_dim"
        }
    }

    let ae: AEConfig
    let ttl: TTLConfig
}

private struct SupertonicVoiceStyleData: Decodable {
    struct Component: Decodable {
        let data: [[[Float]]]
        let dims: [Int]
    }

    let styleTTL: Component
    let styleDP: Component

    enum CodingKeys: String, CodingKey {
        case styleTTL = "style_ttl"
        case styleDP = "style_dp"
    }
}

private final class SupertonicUnicodeProcessor {
    private let indexer: [Int64]

    init(indexerPath: URL) throws {
        let data = try Data(contentsOf: indexerPath)
        self.indexer = try JSONDecoder().decode([Int64].self, from: data)
    }

    func call(_ textList: [String], _ languageList: [String]) -> (textIds: [[Int64]], textMask: [[[Float]]]) {
        let processedTexts = textList.enumerated().map { index, text in
            supertonicPreprocessText(text, language: languageList[index])
        }
        let lengths = processedTexts.map { $0.unicodeScalars.count }
        let maxLength = lengths.max() ?? 0

        let textIds = processedTexts.map { text in
            var row = Array(repeating: Int64(0), count: maxLength)
            for (index, value) in text.unicodeScalars.map({ Int($0.value) }).enumerated() {
                row[index] = value < indexer.count ? indexer[value] : -1
            }
            return row
        }

        return (textIds, supertonicLengthToMask(lengths, maxLength: maxLength))
    }
}

private struct SupertonicStyle {
    let ttl: ORTValue
    let dp: ORTValue

    static func load(from url: URL) throws -> SupertonicStyle {
        let data = try Data(contentsOf: url)
        let styleData = try JSONDecoder().decode(SupertonicVoiceStyleData.self, from: data)

        guard styleData.styleTTL.dims.count == 3,
              styleData.styleDP.dims.count == 3 else {
            throw SupertonicPluginError.incompleteModelAssets
        }

        let ttlDims = styleData.styleTTL.dims
        let dpDims = styleData.styleDP.dims
        let ttlFlat = styleData.styleTTL.data.flatMap { $0.flatMap { $0 } }
        let dpFlat = styleData.styleDP.data.flatMap { $0.flatMap { $0 } }

        let ttlShape: [NSNumber] = ttlDims.map { NSNumber(value: $0) }
        let dpShape: [NSNumber] = dpDims.map { NSNumber(value: $0) }

        return SupertonicStyle(
            ttl: try SupertonicORT.tensor(values: ttlFlat, elementType: .float, shape: ttlShape),
            dp: try SupertonicORT.tensor(values: dpFlat, elementType: .float, shape: dpShape)
        )
    }
}

private final class SupertonicTextToSpeech {
    let sampleRate: Int

    private let config: SupertonicConfig
    private let textProcessor: SupertonicUnicodeProcessor
    private let durationPredictor: ORTSession
    private let textEncoder: ORTSession
    private let vectorEstimator: ORTSession
    private let vocoder: ORTSession

    init(
        config: SupertonicConfig,
        textProcessor: SupertonicUnicodeProcessor,
        durationPredictor: ORTSession,
        textEncoder: ORTSession,
        vectorEstimator: ORTSession,
        vocoder: ORTSession
    ) {
        self.config = config
        self.textProcessor = textProcessor
        self.durationPredictor = durationPredictor
        self.textEncoder = textEncoder
        self.vectorEstimator = vectorEstimator
        self.vocoder = vocoder
        self.sampleRate = config.ae.sampleRate
    }

    static func load(onnxDirectory: URL, environment: ORTEnv) throws -> SupertonicTextToSpeech {
        let configData = try Data(contentsOf: onnxDirectory.appendingPathComponent("tts.json"))
        let config = try JSONDecoder().decode(SupertonicConfig.self, from: configData)
        let sessionOptions = try ORTSessionOptions()

        return try SupertonicTextToSpeech(
            config: config,
            textProcessor: SupertonicUnicodeProcessor(
                indexerPath: onnxDirectory.appendingPathComponent("unicode_indexer.json")
            ),
            durationPredictor: ORTSession(
                env: environment,
                modelPath: onnxDirectory.appendingPathComponent("duration_predictor.onnx").path,
                sessionOptions: sessionOptions
            ),
            textEncoder: ORTSession(
                env: environment,
                modelPath: onnxDirectory.appendingPathComponent("text_encoder.onnx").path,
                sessionOptions: sessionOptions
            ),
            vectorEstimator: ORTSession(
                env: environment,
                modelPath: onnxDirectory.appendingPathComponent("vector_estimator.onnx").path,
                sessionOptions: sessionOptions
            ),
            vocoder: ORTSession(
                env: environment,
                modelPath: onnxDirectory.appendingPathComponent("vocoder.onnx").path,
                sessionOptions: sessionOptions
            )
        )
    }

    func call(
        _ text: String,
        _ language: String,
        _ style: SupertonicStyle,
        _ totalSteps: Int,
        speed: Float = 1.05,
        silenceDuration: Float = 0.3
    ) throws -> (wav: [Float], duration: Float) {
        let chunkLength = (language == "ko" || language == "ja") ? 120 : 300
        let chunks = supertonicChunkText(text, maxLength: chunkLength)
        let languageList = Array(repeating: language, count: chunks.count)

        var combinedWav: [Float] = []
        var combinedDuration: Float = 0

        for (index, chunk) in chunks.enumerated() {
            let result = try infer([chunk], [languageList[index]], style, totalSteps, speed: speed)
            let duration = result.duration[0]
            let wavLength = min(Int(Float(sampleRate) * duration), result.wav.count)
            let wavChunk = Array(result.wav.prefix(wavLength))

            if index > 0 {
                let silenceLength = Int(silenceDuration * Float(sampleRate))
                combinedWav.append(contentsOf: [Float](repeating: 0, count: silenceLength))
                combinedDuration += silenceDuration
            }

            combinedWav.append(contentsOf: wavChunk)
            combinedDuration += duration
        }

        return (combinedWav, combinedDuration)
    }

    private func infer(
        _ textList: [String],
        _ languageList: [String],
        _ style: SupertonicStyle,
        _ totalSteps: Int,
        speed: Float
    ) throws -> (wav: [Float], duration: [Float]) {
        let batchSize = textList.count
        let (textIds, textMask) = textProcessor.call(textList, languageList)

        let textIdsFlat = textIds.flatMap { $0 }
        let textMaskFlat = textMask.flatMap { $0.flatMap { $0 } }

        let textIdsValue = try SupertonicORT.tensor(
            values: textIdsFlat,
            elementType: .int64,
            shape: [NSNumber(value: batchSize), NSNumber(value: textIds[0].count)]
        )
        let textMaskValue = try SupertonicORT.tensor(
            values: textMaskFlat,
            elementType: .float,
            shape: [NSNumber(value: batchSize), 1, NSNumber(value: textMask[0][0].count)]
        )

        let durationOutputs = try durationPredictor.run(
            withInputs: ["text_ids": textIdsValue, "style_dp": style.dp, "text_mask": textMaskValue],
            outputNames: ["duration"],
            runOptions: nil
        )
        guard let durationValue = durationOutputs["duration"] else {
            throw SupertonicPluginError.invalidDownloadResponse
        }
        var duration = try SupertonicORT.floatArray(from: durationValue)
        for index in duration.indices {
            duration[index] /= speed
        }

        let textEncoderOutputs = try textEncoder.run(
            withInputs: ["text_ids": textIdsValue, "style_ttl": style.ttl, "text_mask": textMaskValue],
            outputNames: ["text_emb"],
            runOptions: nil
        )
        guard let textEmbeddings = textEncoderOutputs["text_emb"] else {
            throw SupertonicPluginError.invalidDownloadResponse
        }

        var (noisyLatent, latentMask) = supertonicSampleNoisyLatent(
            duration: duration,
            sampleRate: sampleRate,
            baseChunkSize: config.ae.baseChunkSize,
            chunkCompress: config.ttl.chunkCompressFactor,
            latentDim: config.ttl.latentDim
        )

        let totalStepValue = try SupertonicORT.tensor(
            values: Array(repeating: Float(totalSteps), count: batchSize),
            elementType: .float,
            shape: [NSNumber(value: batchSize)]
        )

        for step in 0..<totalSteps {
            let currentStepValue = try SupertonicORT.tensor(
                values: Array(repeating: Float(step), count: batchSize),
                elementType: .float,
                shape: [NSNumber(value: batchSize)]
            )
            let latentValue = try SupertonicORT.tensor(
                values: noisyLatent.flatMap { $0.flatMap { $0 } },
                elementType: .float,
                shape: [
                    NSNumber(value: batchSize),
                    NSNumber(value: noisyLatent[0].count),
                    NSNumber(value: noisyLatent[0][0].count),
                ]
            )
            let latentMaskValue = try SupertonicORT.tensor(
                values: latentMask.flatMap { $0.flatMap { $0 } },
                elementType: .float,
                shape: [NSNumber(value: batchSize), 1, NSNumber(value: latentMask[0][0].count)]
            )

            let vectorOutputs = try vectorEstimator.run(
                withInputs: [
                    "noisy_latent": latentValue,
                    "text_emb": textEmbeddings,
                    "style_ttl": style.ttl,
                    "latent_mask": latentMaskValue,
                    "text_mask": textMaskValue,
                    "current_step": currentStepValue,
                    "total_step": totalStepValue,
                ],
                outputNames: ["denoised_latent"],
                runOptions: nil
            )
            guard let denoisedValue = vectorOutputs["denoised_latent"] else {
                throw SupertonicPluginError.invalidDownloadResponse
            }
            noisyLatent = SupertonicORT.reshape3D(
                try SupertonicORT.floatArray(from: denoisedValue),
                batchSize: batchSize,
                rows: noisyLatent[0].count,
                columns: noisyLatent[0][0].count
            )
        }

        let finalLatentValue = try SupertonicORT.tensor(
            values: noisyLatent.flatMap { $0.flatMap { $0 } },
            elementType: .float,
            shape: [
                NSNumber(value: batchSize),
                NSNumber(value: noisyLatent[0].count),
                NSNumber(value: noisyLatent[0][0].count),
            ]
        )
        let vocoderOutputs = try vocoder.run(
            withInputs: ["latent": finalLatentValue],
            outputNames: ["wav_tts"],
            runOptions: nil
        )
        guard let wavValue = vocoderOutputs["wav_tts"] else {
            throw SupertonicPluginError.invalidDownloadResponse
        }

        return (try SupertonicORT.floatArray(from: wavValue), duration)
    }
}

private enum SupertonicORT {
    static func tensor<T>(
        values: [T],
        elementType: ORTTensorElementDataType,
        shape: [NSNumber]
    ) throws -> ORTValue {
        var mutableValues = values
        let data = mutableValues.withUnsafeMutableBytes { bytes in
            NSMutableData(bytes: bytes.baseAddress, length: bytes.count)
        }
        return try ORTValue(tensorData: data, elementType: elementType, shape: shape)
    }

    static func floatArray(from value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { pointer in
            Array(pointer.bindMemory(to: Float.self))
        }
    }

    static func reshape3D(
        _ values: [Float],
        batchSize: Int,
        rows: Int,
        columns: Int
    ) -> [[[Float]]] {
        var result: [[[Float]]] = []
        var index = 0

        for _ in 0..<batchSize {
            var batch: [[Float]] = []
            for _ in 0..<rows {
                let endIndex = index + columns
                batch.append(Array(values[index..<endIndex]))
                index = endIndex
            }
            result.append(batch)
        }

        return result
    }
}

private func supertonicPreprocessText(_ text: String, language: String) -> String {
    var text = text.decomposedStringWithCompatibilityMapping

    text = text.unicodeScalars.filter { scalar in
        let value = scalar.value
        return !((value >= 0x1F600 && value <= 0x1F64F)
            || (value >= 0x1F300 && value <= 0x1F5FF)
            || (value >= 0x1F680 && value <= 0x1F6FF)
            || (value >= 0x1F700 && value <= 0x1F77F)
            || (value >= 0x1F780 && value <= 0x1F7FF)
            || (value >= 0x1F800 && value <= 0x1F8FF)
            || (value >= 0x1F900 && value <= 0x1F9FF)
            || (value >= 0x1FA00 && value <= 0x1FA6F)
            || (value >= 0x1FA70 && value <= 0x1FAFF)
            || (value >= 0x2600 && value <= 0x26FF)
            || (value >= 0x2700 && value <= 0x27BF)
            || (value >= 0x1F1E6 && value <= 0x1F1FF))
    }.map { String($0) }.joined()

    let replacements: [String: String] = [
        "–": "-",
        "‑": "-",
        "—": "-",
        "_": " ",
        "\u{201C}": "\"",
        "\u{201D}": "\"",
        "\u{2018}": "'",
        "\u{2019}": "'",
        "´": "'",
        "`": "'",
        "[": " ",
        "]": " ",
        "|": " ",
        "/": " ",
        "#": " ",
        "→": " ",
        "←": " ",
        "♥": "",
        "☆": "",
        "♡": "",
        "©": "",
        "\\": "",
        "@": " at ",
        "e.g.,": "for example, ",
        "i.e.,": "that is, ",
    ]

    for (source, replacement) in replacements {
        text = text.replacingOccurrences(of: source, with: replacement)
    }

    for (source, replacement) in [
        " ,": ",",
        " .": ".",
        " !": "!",
        " ?": "?",
        " ;": ";",
        " :": ":",
        " '": "'",
    ] {
        text = text.replacingOccurrences(of: source, with: replacement)
    }

    while text.contains("\"\"") {
        text = text.replacingOccurrences(of: "\"\"", with: "\"")
    }
    while text.contains("''") {
        text = text.replacingOccurrences(of: "''", with: "'")
    }
    while text.contains("``") {
        text = text.replacingOccurrences(of: "``", with: "`")
    }

    if let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+") {
        let range = NSRange(text.startIndex..., in: text)
        text = whitespaceRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if !text.isEmpty,
       let punctuationRegex = try? NSRegularExpression(pattern: "[.!?;:,'\"\\u201C\\u201D\\u2018\\u2019)\\]}…。」』】〉》›»]$") {
        let range = NSRange(text.startIndex..., in: text)
        if punctuationRegex.firstMatch(in: text, range: range) == nil {
            text += "."
        }
    }

    let safeLanguage = SupertonicLanguageResolver.supportedLanguageCodes.contains(language) ? language : "en"
    return "<\(safeLanguage)>\(text)</\(safeLanguage)>"
}

private func supertonicLengthToMask(_ lengths: [Int], maxLength: Int? = nil) -> [[[Float]]] {
    let resolvedMaxLength = maxLength ?? (lengths.max() ?? 0)

    return lengths.map { length in
        var row = Array(repeating: Float(0), count: resolvedMaxLength)
        for index in 0..<min(length, resolvedMaxLength) {
            row[index] = 1
        }
        return [row]
    }
}

private func supertonicSampleNoisyLatent(
    duration: [Float],
    sampleRate: Int,
    baseChunkSize: Int,
    chunkCompress: Int,
    latentDim: Int
) -> (noisyLatent: [[[Float]]], latentMask: [[[Float]]]) {
    let batchSize = duration.count
    let maxDuration = duration.max() ?? 0
    let chunkSize = baseChunkSize * chunkCompress
    let latentLength = (Int(maxDuration * Float(sampleRate)) + chunkSize - 1) / chunkSize
    let latentDimension = latentDim * chunkCompress

    var noisyLatent: [[[Float]]] = []
    for _ in 0..<batchSize {
        var batch: [[Float]] = []
        for _ in 0..<latentDimension {
            var row: [Float] = []
            for _ in 0..<latentLength {
                let u1 = Float.random(in: 0.0001...1)
                let u2 = Float.random(in: 0...1)
                row.append(sqrt(-2 * log(u1)) * cos(2 * Float.pi * u2))
            }
            batch.append(row)
        }
        noisyLatent.append(batch)
    }

    let latentLengths = duration.map { (Int($0 * Float(sampleRate)) + chunkSize - 1) / chunkSize }
    let latentMask = supertonicLengthToMask(latentLengths, maxLength: latentLength)

    for batchIndex in 0..<batchSize {
        for dimension in 0..<latentDimension {
            for timeIndex in 0..<latentLength {
                noisyLatent[batchIndex][dimension][timeIndex] *= latentMask[batchIndex][0][timeIndex]
            }
        }
    }

    return (noisyLatent, latentMask)
}

private let supertonicMaxChunkLength = 300
private let supertonicAbbreviations: Set<String> = [
    "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.",
    "St.", "Ave.", "Rd.", "Blvd.", "Dept.", "Inc.", "Ltd.",
    "Co.", "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
]

private func supertonicChunkText(_ text: String, maxLength: Int = 0) -> [String] {
    let resolvedMaxLength = maxLength > 0 ? maxLength : supertonicMaxChunkLength
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmedText.isEmpty else { return [""] }

    let paragraphs = trimmedText
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var chunks: [String] = []
    for paragraph in paragraphs.isEmpty ? [trimmedText] : paragraphs {
        if paragraph.count <= resolvedMaxLength {
            chunks.append(paragraph)
            continue
        }

        let sentences = supertonicSplitSentences(paragraph)
        var current = ""
        var currentLength = 0

        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSentence.isEmpty else { continue }

            if trimmedSentence.count > resolvedMaxLength {
                if !current.isEmpty {
                    chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    currentLength = 0
                }
                chunks.append(contentsOf: supertonicSplitLongText(trimmedSentence, maxLength: resolvedMaxLength))
                continue
            }

            if currentLength + trimmedSentence.count + 1 > resolvedMaxLength, !current.isEmpty {
                chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                currentLength = 0
            }

            if !current.isEmpty {
                current += " "
                currentLength += 1
            }
            current += trimmedSentence
            currentLength += trimmedSentence.count
        }

        if !current.isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    return chunks.isEmpty ? [""] : chunks
}

private func supertonicSplitLongText(_ text: String, maxLength: Int) -> [String] {
    var chunks: [String] = []
    var current = ""
    var currentLength = 0

    for word in text.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }) {
        if currentLength + word.count + 1 > maxLength, !current.isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
            currentLength = 0
        }
        if !current.isEmpty {
            current += " "
            currentLength += 1
        }
        current += word
        currentLength += word.count
    }

    if !current.isEmpty {
        chunks.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return chunks
}

private func supertonicSplitSentences(_ text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: "([.!?])\\s+") else {
        return [text]
    }

    let range = NSRange(text.startIndex..., in: text)
    let matches = regex.matches(in: text, range: range)
    guard !matches.isEmpty else { return [text] }

    var sentences: [String] = []
    var lastEnd = text.startIndex

    for match in matches {
        guard let matchRange = Range(match.range, in: text),
              let punctuationRange = Range(NSRange(location: match.range.location, length: 1), in: text) else {
            continue
        }

        let beforePunctuation = String(text[lastEnd..<matchRange.lowerBound])
        let punctuation = String(text[punctuationRange])
        let combined = beforePunctuation.trimmingCharacters(in: .whitespaces) + punctuation

        guard !supertonicAbbreviations.contains(where: { combined.hasSuffix($0) }) else {
            continue
        }

        sentences.append(String(text[lastEnd..<matchRange.upperBound]))
        lastEnd = matchRange.upperBound
    }

    if lastEnd < text.endIndex {
        sentences.append(String(text[lastEnd...]))
    }

    return sentences.isEmpty ? [text] : sentences
}
