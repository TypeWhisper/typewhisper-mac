import XCTest
import TypeWhisperPluginSDK
#if SWIFT_PACKAGE
@testable import GigaAMPlugin
#else
@testable import TypeWhisper
#endif

final class GigaAMPluginTests: XCTestCase {
    func testPluginOnlyOffersRussian() {
        let plugin = GigaAMPlugin()
        XCTAssertEqual(plugin.providerId, "gigaam")
        XCTAssertEqual(plugin.supportedLanguages, ["ru"])
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(GigaAMPlugin.availableModels.map(\.repoId), ["istupakov/gigaam-v3-onnx"])
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
    /// downloaded model files and GIGAAM_AUDIO to a 16 kHz mono 16-bit WAV file.
    func testTranscribesRealAudioWhenModelIsAvailable() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["GIGAAM_MODEL_DIR"], let audioPath = environment["GIGAAM_AUDIO"] else {
            throw XCTSkip("Set GIGAAM_MODEL_DIR and GIGAAM_AUDIO to run the model")
        }
        let runtime = try GigaAMRuntime(
            modelDirectory: URL(fileURLWithPath: modelPath),
            preprocessorURL: try XCTUnwrap(GigaAMPlugin.preprocessorURL)
        )
        let samples = try Self.pcmSamples(Data(contentsOf: URL(fileURLWithPath: audioPath)))
        let start = Date()
        let text = try runtime.transcribe(samples)
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
