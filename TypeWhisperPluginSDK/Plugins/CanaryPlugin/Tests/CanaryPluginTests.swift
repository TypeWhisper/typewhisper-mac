import XCTest
import MLX
#if SWIFT_PACKAGE
@testable import CanaryPlugin
#else
@testable import TypeWhisper
#endif

final class CanaryPluginTests: XCTestCase {
    func testNemoSubsamplingConvolutionsUseMLXLayout() {
        let weights = [
            "encoder.pre_encode.conv.0.weight": MLXArray.zeros([8, 1, 3, 3]),
            "encoder.pre_encode.conv.2.weight": MLXArray.zeros([8, 1, 3, 3]),
            "encoder.pre_encode.conv.3.weight": MLXArray.zeros([8, 8, 1, 1]),
        ]
        let converted = CanaryPlugin.sanitizeCanaryWeights(weights)
        XCTAssertEqual(converted["encoder.conformer.pre_encode.conv0.weight"]?.shape, [8, 3, 3, 1])
        XCTAssertEqual(converted["encoder.conformer.pre_encode.depthwise_layers.0.weight"]?.shape, [8, 3, 3, 1])
        XCTAssertEqual(converted["encoder.conformer.pre_encode.pointwise_layers.0.weight"]?.shape, [8, 1, 1, 8])
    }

    func testNativeWeightsAreNotTransposedAgain() {
        let converted = CanaryPlugin.sanitizeCanaryWeights([
            "decoder.blocks.0.placeholder": MLXArray.zeros([1]),
            "encoder.conformer.pre_encode.pointwise_layers.0.weight": MLXArray.zeros([8, 1, 1, 8]),
        ])
        XCTAssertEqual(converted["encoder.conformer.pre_encode.pointwise_layers.0.weight"]?.shape, [8, 1, 1, 8])
    }

    func testOnlyKnownDerivedPreprocessingBuffersAreExcluded() {
        XCTAssertTrue(CanaryPlugin.isDerivedPreprocessingBuffer("preprocessor.featurizer.fb"))
        XCTAssertTrue(CanaryPlugin.isDerivedPreprocessingBuffer("preprocessor.featurizer.window"))
        XCTAssertFalse(CanaryPlugin.isDerivedPreprocessingBuffer("preprocessor.learned.weight"))
        XCTAssertFalse(CanaryPlugin.isDerivedPreprocessingBuffer("encoder.layers.0.weight"))
    }

    func testCanaryRequiresExplicitSourceLanguage() throws {
        XCTAssertEqual(try CanaryPlugin.sourceLanguage("el"), "el")
        XCTAssertEqual(try CanaryPlugin.sourceLanguage("EN"), "en")
        XCTAssertThrowsError(try CanaryPlugin.sourceLanguage(nil))
        XCTAssertThrowsError(try CanaryPlugin.sourceLanguage("auto"))
        XCTAssertThrowsError(try CanaryPlugin.sourceLanguage("xx"))
    }

    func testGreekFinalSigmaIsRestoredOnlyForGreek() {
        XCTAssertEqual(CanaryPlugin.normalizeTranscript("  τησ εποχήσ.  ", language: "el"), "της εποχής.")
        XCTAssertEqual(CanaryPlugin.normalizeTranscript("τησ εποχήσ.", language: "en"), "τησ εποχήσ.")
    }
}
