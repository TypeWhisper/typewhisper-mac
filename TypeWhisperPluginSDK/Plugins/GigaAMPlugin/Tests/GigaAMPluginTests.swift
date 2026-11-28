import XCTest
import TypeWhisperPluginSDK
#if SWIFT_PACKAGE
@testable import GigaAMPlugin
#else
@testable import TypeWhisper
#endif

final class GigaAMPluginTests: XCTestCase {
    func testSupportedLanguagesFollowModelSelection() {
        let plugin = GigaAMPlugin()
        XCTAssertEqual(plugin.providerId, "gigaam")
        XCTAssertEqual(plugin.supportedLanguages, ["ru"])
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.availableModels.map(\.languageCount), [1, 2, 21])
        plugin.selectModel("gigaam-v4-rnnt")
        XCTAssertEqual(plugin.supportedLanguages, ["ru", "en"])
        plugin.selectModel("gigaam-multilingual-v2-rnnt")
        XCTAssertEqual(plugin.supportedLanguages.count, 21)
        XCTAssertTrue(plugin.supportedLanguages.contains("de"))
        plugin.selectModel("gigaam-v3-e2e-rnnt")
        XCTAssertEqual(plugin.supportedLanguages, ["ru"])
    }

    func testLanguageVectorUsesExportedSlotsAndFallsBackToDetection() {
        let cases: [(String?, Int)] = [(nil, 0), ("zh", 0), ("ru", 1), ("en-US", 2), ("de", 16), ("tt", 21)]
        for (language, slot) in cases {
            var expected = [Float](repeating: 0, count: 32)
            expected[slot] = 1
            XCTAssertEqual(GigaAMModelFiles.multilingualV2.languageVector(for: language), expected)
        }
        XCTAssertNil(GigaAMModelFiles.v3.languageVector(for: "ru"))
        XCTAssertNil(GigaAMModelFiles.v4.languageVector(for: "en"))
    }

    func testFirstHeadTokensSkipEmptySteps() throws {
        // Three steps, two heads, one item: the first head emitted 5, nothing, 7.
        XCTAssertEqual(try GigaAMRuntime.firstHeadTokens([5, 9, -1, 8, 7, -1], shape: [3, 2, 1]), [5, 7])
        XCTAssertThrowsError(try GigaAMRuntime.firstHeadTokens([5, 9], shape: [1, 1, 2]))
        XCTAssertThrowsError(try GigaAMRuntime.firstHeadTokens([5], shape: [1, 2, 1]))
    }

    func testPreprocessorShipsWithThePlugin() throws {
        let url = try XCTUnwrap(GigaAMPlugin.preprocessorURL)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 10_000)
    }

    func testVocabularyJoinsWordPiecesAndPunctuation() throws {
        let vocabulary = try GigaAMVocabulary(text: """
        <unk> 0
        . 1
        , 2
        ▁ 3
        ▁При 4
        вет 5
        ▁мир 6
        ▁— 7
        ▁« 8
        » 9
        <blk> 10
        """)
        XCTAssertEqual(vocabulary.blankID, 10)
        XCTAssertEqual(vocabulary.text(for: [4, 5, 2, 6, 1]), "Привет, мир.")
        XCTAssertEqual(vocabulary.text(for: [4, 5, 7, 6]), "Привет — мир")
        XCTAssertEqual(vocabulary.text(for: [4, 5, 8, 6, 9, 1]), "Привет «мир».")
        XCTAssertEqual(vocabulary.text(for: [3, 6, 3, 1]), "мир.")
    }

    func testVocabularyRejectsFilesWithoutBlank() {
        XCTAssertThrowsError(try GigaAMVocabulary(text: "a 0\nb 1"))
        XCTAssertThrowsError(try GigaAMVocabulary(text: "broken"))
    }

    func testShortAudioIsPaddedToOneSecond() {
        XCTAssertEqual(GigaAMRuntime.paddedToMinimumDuration([0.5]).count, 16_000)
        XCTAssertEqual(GigaAMRuntime.paddedToMinimumDuration([Float](repeating: 0, count: 20_000)).count, 20_000)
    }

    func testArgmaxPicksTheFirstMaximum() {
        XCTAssertEqual(GigaAMRuntime.argmax([0.1, 0.9, 0.3, 0.9]), 1)
    }

    func testChunkAfterMidSentenceCutStartsLowercase() {
        let progress = GigaAMTranscriptProgress()
        XCTAssertEqual(progress.continuing("Спустя десять лет"), "Спустя десять лет")
        _ = progress.append("Спустя десять лет")
        XCTAssertEqual(progress.continuing("Эта истина верна."), "эта истина верна.")
        _ = progress.append("эта истина верна.")
        XCTAssertEqual(progress.continuing("Новое предложение."), "Новое предложение.")
        XCTAssertEqual(progress.continuing("США подписали"), "США подписали")
    }

    func testTranscriptProgressJoinsChunks() {
        let progress = GigaAMTranscriptProgress()
        XCTAssertEqual(progress.append("Первая часть."), "Первая часть.")
        XCTAssertEqual(progress.append(""), "Первая часть.")
        XCTAssertEqual(progress.append("Вторая часть."), "Первая часть. Вторая часть.")
    }

    /// Opt-in check against the real model: set GIGAAM_MODEL_DIR to a directory with the
    /// downloaded model files, GIGAAM_AUDIO to a 16 kHz mono 16-bit WAV file, and
    /// optionally GIGAAM_MODEL to the model's file prefix and GIGAAM_LANGUAGE to a language code.
    func testTranscribesRealAudioWhenModelIsAvailable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["GIGAAM_MODEL_DIR"], let audioPath = environment["GIGAAM_AUDIO"] else {
            throw XCTSkip("Set GIGAAM_MODEL_DIR and GIGAAM_AUDIO to run the model")
        }
        let runtime = try GigaAMRuntime(
            modelDirectory: URL(fileURLWithPath: modelPath),
            files: try XCTUnwrap(GigaAMModelFiles(rawValue: environment["GIGAAM_MODEL"] ?? GigaAMModelFiles.v3.rawValue)),
            preprocessorURL: try XCTUnwrap(GigaAMPlugin.preprocessorURL)
        )
        let samples = try Self.pcmSamples(Data(contentsOf: URL(fileURLWithPath: audioPath)))
        let start = Date()
        let text = try runtime.transcribe(samples, language: environment["GIGAAM_LANGUAGE"])
        print("GIGAAM_MS \(Int(Date().timeIntervalSince(start) * 1000))")
        print("GIGAAM_TRANSCRIPT \(text)")
        XCTAssertFalse(text.isEmpty)
    }

    /// 16-bit PCM samples from the "data" chunk of a RIFF/WAVE file.
    private static func pcmSamples(_ data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8
                | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            if id == "data" {
                let end = min(bytes.count, offset + 8 + size)
                return stride(from: offset + 8, to: end - 1, by: 2).map {
                    Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32_768
                }
            }
            offset += 8 + size + (size & 1)
        }
        throw XCTSkip("No data chunk in WAV file")
    }
}
