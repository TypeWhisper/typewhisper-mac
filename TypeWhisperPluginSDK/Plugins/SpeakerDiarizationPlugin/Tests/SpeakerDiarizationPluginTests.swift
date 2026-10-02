import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import SpeakerDiarizationPlugin

final class SpeakerDiarizationPluginTests: XCTestCase {
    func testModelsAreNotInstalledBeforeDownload() throws {
        let host = try PluginTestHostServices()
        let plugin = SpeakerDiarizationPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.areDiarizationModelsInstalled)
    }

    func testDiarizeWithoutModelsReportsMissingModels() async throws {
        let host = try PluginTestHostServices()
        let plugin = SpeakerDiarizationPlugin()
        plugin.activate(host: host)
        let request = PluginDiarizationRequest(audioURL: URL(fileURLWithPath: "/dev/null"), duration: 1)

        do {
            _ = try await plugin.diarize(request) { _ in }
            XCTFail("Expected missing models")
        } catch let error as PluginDiarizationError {
            XCTAssertEqual(error, .modelsNotInstalled)
        }
    }

    func testUnsupportedSpeakerCountIsRejected() async throws {
        let host = try PluginTestHostServices()
        let plugin = SpeakerDiarizationPlugin()
        plugin.activate(host: host)
        let request = PluginDiarizationRequest(
            audioURL: URL(fileURLWithPath: "/dev/null"),
            duration: 1,
            speakerCount: 1
        )

        do {
            _ = try await plugin.diarize(request) { _ in }
            XCTFail("Expected unsupported speaker count")
        } catch let error as PluginDiarizationError {
            XCTAssertEqual(error, .unsupportedSpeakerCount(1))
        }
    }

    func testModelsExistFindsRequiredFilesInNestedFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("speaker-diarization-coreml/offline", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        for name in ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: nested.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertFalse(SpeakerDiarizationPlugin.modelsExist(in: root))

        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent("PldaRho.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: nested.appendingPathComponent("plda-parameters.json"))
        XCTAssertTrue(SpeakerDiarizationPlugin.modelsExist(in: root))
    }

    /// Opt-in: downloads the models and diarizes a real file.
    /// `TW_DIARIZATION_AUDIO=/path/to/file TW_DIARIZATION_SPEAKERS=2 swift test --filter testDiarizesARealRecording`
    func testDiarizesARealRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TW_DIARIZATION_AUDIO"] else {
            throw XCTSkip("Set TW_DIARIZATION_AUDIO to run the diarization check")
        }
        let host = try PluginTestHostServices()
        let plugin = SpeakerDiarizationPlugin()
        plugin.activate(host: host)

        try await plugin.prepareDiarizationModels { _ in }
        XCTAssertTrue(plugin.areDiarizationModelsInstalled)

        let start = Date()
        let result = try await plugin.diarize(
            PluginDiarizationRequest(audioURL: URL(fileURLWithPath: path), duration: 0)
        ) { _ in }
        let speakers = Set(result.turns.map(\.speakerLabel))
        print("Diarized \(speakers.count) speakers, \(result.turns.count) turns in \(Date().timeIntervalSince(start)) s")
        for turn in result.turns {
            print(String(format: "  %@  %6.2f – %6.2f", turn.speakerLabel, turn.start, turn.end))
        }

        XCTAssertEqual(result.engine, SpeakerDiarizationPlugin.engineIdentifier)
        XCTAssertEqual(Set(result.speakerEmbeddings.keys), speakers)
        if let expected = environment["TW_DIARIZATION_SPEAKERS"].flatMap(Int.init) {
            XCTAssertEqual(speakers.count, expected)
        }

        try await plugin.deleteDiarizationModels()
        XCTAssertFalse(plugin.areDiarizationModelsInstalled)
    }
}
