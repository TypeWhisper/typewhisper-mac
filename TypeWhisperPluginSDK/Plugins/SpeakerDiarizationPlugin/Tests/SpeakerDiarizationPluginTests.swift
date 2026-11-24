import FluidAudio
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

    /// Automatic detection put both people of a 56-minute call into one
    /// speaker and left 16 seconds in a second one, which doesn't count
    /// towards a minimum of two.
    func testOnlySpeakersWithAShareOfTheSpeechCountTowardsAMinimum() {
        let merged = [
            PluginSpeakerTurn(speakerLabel: "S1", start: 0, end: 2_385),
            PluginSpeakerTurn(speakerLabel: "S2", start: 2_385, end: 2_401),
        ]
        XCTAssertEqual(SpeakerDiarizationPlugin.speakersWithShare(of: merged), 1)

        let call = [
            PluginSpeakerTurn(speakerLabel: "S1", start: 0, end: 60),
            PluginSpeakerTurn(speakerLabel: "S2", start: 60, end: 75),
            PluginSpeakerTurn(speakerLabel: "S1", start: 75, end: 120),
        ]
        XCTAssertEqual(SpeakerDiarizationPlugin.speakersWithShare(of: call), 2)
        XCTAssertEqual(SpeakerDiarizationPlugin.speakersWithShare(of: []), 0)
    }

    /// The second pass asks for at least the speakers the first one found:
    /// a meeting where the user and one other person speak little keeps
    /// three speakers instead of merging two of them.
    func testTheSecondPassKeepsEverySpeakerTheFirstFound() {
        let merged = [
            PluginSpeakerTurn(speakerLabel: "S1", start: 0, end: 2_385),
            PluginSpeakerTurn(speakerLabel: "S2", start: 2_385, end: 2_401),
        ]
        XCTAssertEqual(SpeakerDiarizationPlugin.speakerCountForSecondPass(after: merged, minimum: 2), 2)

        let meeting = [
            PluginSpeakerTurn(speakerLabel: "S1", start: 0, end: 85),
            PluginSpeakerTurn(speakerLabel: "S2", start: 85, end: 92.5),
            PluginSpeakerTurn(speakerLabel: "S3", start: 92.5, end: 100),
        ]
        XCTAssertEqual(SpeakerDiarizationPlugin.speakerCountForSecondPass(after: meeting, minimum: 2), 3)

        let call = [
            PluginSpeakerTurn(speakerLabel: "S1", start: 0, end: 60),
            PluginSpeakerTurn(speakerLabel: "S2", start: 60, end: 100),
        ]
        XCTAssertNil(SpeakerDiarizationPlugin.speakerCountForSecondPass(after: call, minimum: 2))

        // Nine speakers can't be detected again with a fixed count; they stay.
        let crowd = [PluginSpeakerTurn(speakerLabel: "S1", start: 0, end: 92)]
            + (2...9).map { PluginSpeakerTurn(speakerLabel: "S\($0)", start: Double(90 + $0), end: Double(91 + $0)) }
        XCTAssertNil(SpeakerDiarizationPlugin.speakerCountForSecondPass(after: crowd, minimum: 2))
    }

    func testAMinimumSpeakerCountNeedsTheModelsToo() async throws {
        let host = try PluginTestHostServices()
        let plugin = SpeakerDiarizationPlugin()
        plugin.activate(host: host)
        let request = PluginDiarizationRequest(audioURL: URL(fileURLWithPath: "/dev/null"), duration: 1)

        do {
            _ = try await plugin.diarize(request, minimumSpeakerCount: 2) { _ in }
            XCTFail("Expected missing models")
        } catch let error as PluginDiarizationError {
            XCTAssertEqual(error, .modelsNotInstalled)
        }
    }

    /// FluidAudio's defaults (a window every two seconds, Fb 0.8) merged the
    /// two people of short table recordings into one speaker (#1966).
    func testDiarizerUsesOneSecondWindowsAndALowerSpeakerPrior() {
        let automatic = SpeakerDiarizationPlugin.diarizerConfig(speakerCount: nil)
        XCTAssertEqual(automatic.segmentation.stepRatio, 0.1)
        XCTAssertEqual(automatic.samplesPerStep, 16_000)
        XCTAssertEqual(automatic.clustering.threshold, 0.7)
        XCTAssertEqual(automatic.clustering.warmStartFa, 0.07)
        XCTAssertEqual(automatic.clustering.warmStartFb, 0.6)
        XCTAssertNil(automatic.clustering.numSpeakers)

        let fixed = SpeakerDiarizationPlugin.diarizerConfig(speakerCount: 2)
        XCTAssertEqual(fixed.segmentation.stepRatio, 0.1)
        XCTAssertEqual(fixed.clustering.warmStartFb, 0.3)
        XCTAssertEqual(fixed.clustering.numSpeakers, 2)
        XCTAssertNoThrow(try automatic.validate())
        XCTAssertNoThrow(try fixed.validate())
    }

    func testTurnsLeaveOutSegmentsWithoutSpeakerEvidence() {
        func segment(_ speaker: String, _ start: Float, _ end: Float, quality: Float) -> TimedSpeakerSegment {
            TimedSpeakerSegment(
                speakerId: speaker,
                embedding: [],
                startTimeSeconds: start,
                endTimeSeconds: end,
                qualityScore: quality
            )
        }

        let turns = SpeakerDiarizationPlugin.turns(from: [
            segment("S1", 0, 4, quality: 1),
            segment("S2", 5, 60, quality: 1),
            // A reply nothing voted for; the diarizer gave it to S1 as a tie-break.
            segment("S1", 60.5, 62, quality: 0),
            segment("S2", 62.5, 90, quality: 0.9),
        ])

        XCTAssertEqual(turns.map(\.speakerLabel), ["S1", "S2", "S2"])
        XCTAssertEqual(turns.map(\.start), [0, 5, 62.5])
        XCTAssertEqual(turns.map(\.end), [4, 60, 90])
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
        XCTAssertEqual(result.speakerEmbeddingModel, SpeakerDiarizationPlugin.speakerEmbeddingModel)
        if let expected = environment["TW_DIARIZATION_SPEAKERS"].flatMap(Int.init) {
            XCTAssertEqual(speakers.count, expected)
        }

        try await plugin.deleteDiarizationModels()
        XCTAssertFalse(plugin.areDiarizationModelsInstalled)
    }
}
