import Foundation
import XCTest
@testable import ParakeetPlugin
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting

final class ParakeetModelImportTests: XCTestCase {
    func testLayoutAcceptsMobiusConverterOutput() throws {
        // The folder FluidInference's mobius converter writes for Parakeet TDT v3.
        let layout = try ParakeetModelImport.layout(of: [
            "metadata.json", "parakeet_preprocessor.mlpackage", "parakeet_encoder.mlpackage",
            "parakeet_mel_encoder.mlpackage", "parakeet_decoder.mlpackage", "parakeet_joint.mlpackage",
            "parakeet_joint_decision.mlpackage", "parakeet_joint_decision_single_step.mlpackage",
        ])

        XCTAssertEqual(layout.models[.joint], "parakeet_joint_decision_single_step.mlpackage")
        XCTAssertNil(layout.vocabulary)
        XCTAssertEqual(layout.entries, [
            "metadata.json", "parakeet_preprocessor.mlpackage", "parakeet_encoder.mlpackage",
            "parakeet_decoder.mlpackage", "parakeet_joint_decision_single_step.mlpackage",
        ])
    }

    func testLayoutPrefersFluidAudioModelsAndReportsMissingOnes() throws {
        let layout = try ParakeetModelImport.layout(of: ParakeetModelImport.topLevelNames([
            "Preprocessor.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin", "Decoder.mlmodelc/model.mil",
            "JointDecision.mlmodelc/model.mil", "JointDecisionv3.mlmodelc/model.mil", "parakeet_vocab.json", "config.json",
        ]))
        XCTAssertEqual(layout.models[.joint], "JointDecisionv3.mlmodelc")
        XCTAssertEqual(layout.vocabulary, "parakeet_vocab.json")

        XCTAssertThrowsError(try ParakeetModelImport.layout(of: ["Encoder.mlmodelc", "parakeet_vocab.json"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("decoder"), error.localizedDescription)
        }
    }

    func testVocabularyFormatsDropTheBlankAndUseSpaces() throws {
        let text = try ParakeetModelImport.parseVocabulary(Data("<unk> 0\n▁the 1\nς 2\n<blk> 3\n".utf8), fileName: "vocab.txt")
        XCTAssertEqual(text, [0: "<unk>", 1: " the", 2: "ς"])
        let dictionary = try ParakeetModelImport.parseVocabulary(Data(#"{"0":"<unk>","1":"▁a"}"#.utf8), fileName: "vocab.json")
        XCTAssertEqual(dictionary, [0: "<unk>", 1: " a"])
        let array = try ParakeetModelImport.parseVocabulary(Data(#"["<unk>","b"]"#.utf8), fileName: "vocab.json")
        XCTAssertEqual(array, [0: "<unk>", 1: "b"])
        XCTAssertThrowsError(try ParakeetModelImport.parseVocabulary(Data("a 0\nb 2\n".utf8), fileName: "vocab.txt"))
    }

    func testRemappingMovesTheBlankOfAnExtendedVocabularyToFluidAudios() throws {
        // The Greek v3 fine-tune adds 33 tokens, so its blank is 8225 instead of 8192.
        let remapping = try XCTUnwrap(ParakeetTokenRemapping(fluidBlank: 8192, modelBlank: 8225))
        XCTAssertEqual(remapping.fluidId(forModelId: 8225), 8192)
        XCTAssertEqual(remapping.fluidId(forModelId: 8192), 8193)
        XCTAssertEqual(remapping.fluidId(forModelId: 8224), 8225)
        XCTAssertEqual(remapping.fluidId(forModelId: 42), 42)
        for id in [0, 42, 8191, 8192, 8200, 8224, 8225] {
            XCTAssertEqual(remapping.modelId(forFluidId: remapping.fluidId(forModelId: id)), id)
        }
        XCTAssertNil(ParakeetTokenRemapping(fluidBlank: 8192, modelBlank: 8192))
    }

    func testExtendedVocabularyWithoutVocabularyFileFailsBeforeCompiling() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"vocab_size": 8225}"#.utf8).write(to: folder.appendingPathComponent("metadata.json"))
        let layout = try ParakeetModelImport.layout(of: [
            "metadata.json", "parakeet_preprocessor.mlpackage", "parakeet_encoder.mlpackage",
            "parakeet_decoder.mlpackage", "parakeet_joint_decision_single_step.mlpackage",
        ])

        XCTAssertThrowsError(try ParakeetModelImport.checkVocabulary(in: folder, layout: layout))
        XCTAssertThrowsError(
            try ParakeetModelImport.checkVocabulary(converterMetadata: nil, layout: layout),
            "Without metadata the stock vocabulary size is unknown"
        )
        try Data("a 0\nb 1\n".utf8).write(to: folder.appendingPathComponent("vocab.txt"))
        let withVocabulary = try ParakeetModelImport.layout(of: layout.entries.union(["vocab.txt"]))
        XCTAssertThrowsError(try ParakeetModelImport.checkVocabulary(in: folder, layout: withVocabulary)) { error in
            XCTAssertTrue(error.localizedDescription.contains("8225"), error.localizedDescription)
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("vocab.txt"))
        try Data(#"{"vocab_size": 8192}"#.utf8).write(to: folder.appendingPathComponent("metadata.json"))
        XCTAssertNoThrow(try ParakeetModelImport.checkVocabulary(in: folder, layout: layout))
        try Data(#"{"vocab_size": 8225}"#.utf8).write(to: folder.appendingPathComponent("metadata.json"))

        do {
            _ = try await ParakeetModelImport.prepare(
                directory: folder, layout: layout,
                stockVocabulary: { size in
                    XCTAssertEqual(size, 8225)
                    return nil
                },
                compile: { _ in
                    XCTFail("Compiled a model without a usable vocabulary")
                    throw CancellationError()
                }
            )
            XCTFail("Imported a model without its vocabulary")
        } catch let error as PluginModelImportError {
            XCTAssertTrue(error.localizedDescription.contains("vocab.txt"), error.localizedDescription)
        }
    }

    /// An import only selects and loads its model while no newer choice was made since it began.
    func testModelChoicesSinceAnImportBeganChangeTheGeneration() throws {
        let host = try PluginTestHostServices(defaults: [:], shouldRestoreLoadedModelsPassively: false)
        let plugin = ParakeetPlugin()
        plugin.restoresModelOnActivate = false
        plugin.asrModelLoadOverrideForTests = { _ in }
        plugin.activate(host: host)
        addTeardownBlock { plugin.deactivate() }

        var generation = plugin.modelChoiceGeneration
        plugin.unloadModel(clearPersistence: false)
        XCTAssertEqual(plugin.modelChoiceGeneration, generation, "Internal unloads keep the user's choice")
        plugin.selectModel("parakeet-tdt-0.6b-v3")
        XCTAssertGreaterThan(plugin.modelChoiceGeneration, generation)
        generation = plugin.modelChoiceGeneration
        plugin.unloadModel()
        XCTAssertGreaterThan(plugin.modelChoiceGeneration, generation)
    }
}
