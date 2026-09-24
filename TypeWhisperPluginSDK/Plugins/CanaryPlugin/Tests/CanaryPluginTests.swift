import XCTest
import MLX
import TypeWhisperPluginSDK
#if SWIFT_PACKAGE
@testable import CanaryPlugin
#else
@testable import TypeWhisper
#endif

final class CanaryPluginTests: XCTestCase {
    #if !SWIFT_PACKAGE
    // These native MLX layout checks run in the Xcode app-test target, which
    // bundles Metal resources. MLX initializes its Metal device even when
    // creating a CPU stream; the SwiftPM CLI test bundle has no metallib.
    @MainActor
    func testUnloadAndDeactivationClearCacheOnlyAfterInferenceIsIdle() async throws {
        let plugin = CanaryPlugin()
        let previousLimit = Memory.cacheLimit
        Memory.cacheLimit = 64 * 1024 * 1024
        defer { Memory.cacheLimit = previousLimit }
        for deactivate in [false, true] {
            let cleanup = try await PluginLocalInferenceGate.shared.withLock {
                Memory.clearCache()
                autoreleasepool {
                    let allocation = MLXArray.ones([4 * 1024 * 1024], stream: .gpu)
                    eval(allocation)
                }
                Stream.gpu.synchronize()
                XCTAssertGreaterThan(Memory.cacheMemory, 0)
                let task = await MainActor.run {
                    if deactivate { plugin.deactivate() } else { plugin.unloadModel() }
                    return plugin.runtimeCacheClearTask
                }
                XCTAssertNotNil(task)
                for _ in 0..<10 { await Task.yield() }
                XCTAssertGreaterThan(Memory.cacheMemory, 0, "Cleanup must wait for active inference")
                return task
            }
            await cleanup?.value
            XCTAssertEqual(Memory.cacheMemory, 0)
        }
    }

    func testNemoSubsamplingConvolutionsUseMLXLayout() {
        Stream.withNewDefaultStream(device: .cpu) {
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
    }

    func testNativeWeightsAreNotTransposedAgain() {
        Stream.withNewDefaultStream(device: .cpu) {
            let converted = CanaryPlugin.sanitizeCanaryWeights([
                "decoder.blocks.0.placeholder": MLXArray.zeros([1]),
                "encoder.conformer.pre_encode.pointwise_layers.0.weight": MLXArray.zeros([8, 1, 1, 8]),
            ])
            XCTAssertEqual(converted["encoder.conformer.pre_encode.pointwise_layers.0.weight"]?.shape, [8, 1, 1, 8])
        }
    }

    func testLongAudioUsesNearbySilenceAndPreservesEverySample() {
        Stream.withNewDefaultStream(device: .cpu) {
            var samples = [Float](repeating: 0.2, count: 24 * 16_000)
            let silence = (18 * 16_000)..<(19 * 16_000)
            samples.replaceSubrange(silence, with: repeatElement(Float(0), count: silence.count))
            let chunks = CanaryPlugin.transcriptionChunks(samples)
            XCTAssertEqual(chunks.count, 2)
            let boundary = chunks[0].size
            XCTAssertTrue(silence.contains(boundary), "Split must move from 20 seconds into the nearby pause")
            XCTAssertEqual(chunks.flatMap { $0.asArray(Float.self) }, samples)
        }
    }
    #endif

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

    func testSopheaLanguageCapabilitiesAndColdSelection() throws {
        let plugin = CanaryPlugin()
        let sophea = try XCTUnwrap(CanaryPlugin.availableModels.first)
        plugin.selectModel(sophea.id)
        XCTAssertEqual(plugin.supportedLanguages, ["el", "en"])
        XCTAssertNil(plugin.runtimeCacheClearTask, "Selecting an unloaded model must not initialize Metal")
        XCTAssertEqual(try CanaryPlugin.sourceLanguage("EL", supportedLanguages: plugin.supportedLanguages), "el")
        XCTAssertThrowsError(try CanaryPlugin.sourceLanguage("de", supportedLanguages: plugin.supportedLanguages))

        // Imported models without verified capability metadata retain the engine
        // language list; they must not inherit Sophea's bilingual restriction.
        plugin.selectModel("custom-unclassified")
        XCTAssertTrue(plugin.supportedLanguages.contains("de"))
        XCTAssertNil(plugin.runtimeCacheClearTask)
    }

    func testGreekFinalSigmaIsRestoredOnlyForGreek() {
        XCTAssertEqual(CanaryPlugin.normalizeTranscript("  τησ εποχήσ.  ", language: "el"), "της εποχής.")
        XCTAssertEqual(CanaryPlugin.normalizeTranscript("τησ εποχήσ.", language: "en"), "τησ εποχήσ.")
    }
}
