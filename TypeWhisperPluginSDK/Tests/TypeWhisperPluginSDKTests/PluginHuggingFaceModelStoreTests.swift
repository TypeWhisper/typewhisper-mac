import Foundation
import XCTest
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

final class PluginHuggingFaceModelStoreTests: XCTestCase {
    private let repositoryID = "typewhisper/test-model"
    private let commit = String(repeating: "a", count: 40)
    private let requirements = PluginHuggingFaceModelStore.Requirements(
        requiredFiles: ["config.json"],
        alternativeFileGroups: [["tokenizer.json"], ["vocab.json", "merges.txt"]],
        weightFileExtensions: ["safetensors"]
    )

    func testResolvesValidMainSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = try fixture.createUsableSnapshot(repositoryID: repositoryID, commit: commit)

        XCTAssertEqual(
            fixture.store.snapshotDirectory(for: repositoryID, requirements: requirements),
            snapshot
        )
    }

    func testRejectsMissingMalformedAndUnsafeRefs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try XCTUnwrap(fixture.store.repositoryCacheDirectory(for: repositoryID))
        try fixture.write("{}", to: repository.appendingPathComponent("snapshots/\(commit)/config.json"))
        try fixture.write("weights", to: repository.appendingPathComponent("snapshots/\(commit)/model.safetensors"))
        try fixture.write("{}", to: repository.appendingPathComponent("snapshots/\(commit)/tokenizer.json"))

        XCTAssertNil(fixture.store.snapshotDirectory(for: repositoryID, requirements: requirements))

        for invalidRef in ["short", String(repeating: "g", count: 40), "../\(String(repeating: "a", count: 37))"] {
            try fixture.write(invalidRef, to: repository.appendingPathComponent("refs/main"))
            XCTAssertNil(fixture.store.snapshotDirectory(for: repositoryID, requirements: requirements))
        }
    }

    func testRejectsMissingRequiredFilesAndEmptyWeights() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = try fixture.createUsableSnapshot(repositoryID: repositoryID, commit: commit)
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("config.json"))

        XCTAssertNil(fixture.store.snapshotDirectory(for: repositoryID, requirements: requirements))

        try fixture.write("{}", to: snapshot.appendingPathComponent("config.json"))
        try Data().write(to: snapshot.appendingPathComponent("model.safetensors"))
        XCTAssertNil(fixture.store.snapshotDirectory(for: repositoryID, requirements: requirements))
    }

    func testAcceptsAlternativeTokenizerFileGroup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = try fixture.createUsableSnapshot(repositoryID: repositoryID, commit: commit)
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("tokenizer.json"))
        try fixture.write("vocab", to: snapshot.appendingPathComponent("vocab.json"))
        try fixture.write("merges", to: snapshot.appendingPathComponent("merges.txt"))

        XCTAssertEqual(fixture.store.snapshotDirectory(for: repositoryID, requirements: requirements), snapshot)
    }

    func testCanonicalSnapshotTakesPrecedenceAndLegacyIsFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.modelsDirectory.appendingPathComponent("legacy/model", isDirectory: true)
        try fixture.createUsableModel(at: legacy, weightContents: "legacy")

        XCTAssertEqual(
            fixture.store.usableModelDirectory(
                for: repositoryID,
                legacyDirectories: [legacy],
                requirements: requirements
            ),
            legacy
        )

        let snapshot = try fixture.createUsableSnapshot(repositoryID: repositoryID, commit: commit)
        XCTAssertEqual(
            fixture.store.usableModelDirectory(
                for: repositoryID,
                legacyDirectories: [legacy],
                requirements: requirements
            ),
            snapshot
        )
    }

    func testMigrationRemovesOnlyEquivalentLegacyDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.createUsableSnapshot(repositoryID: repositoryID, commit: commit)
        let equivalent = fixture.modelsDirectory.appendingPathComponent("legacy/equivalent", isDirectory: true)
        let different = fixture.modelsDirectory.appendingPathComponent("legacy/different", isDirectory: true)
        try fixture.createUsableModel(at: equivalent)
        try fixture.createUsableModel(at: different, weightContents: "different-size")

        let removed = try fixture.store.removeRedundantLegacyDirectories(
            for: repositoryID,
            legacyDirectories: [equivalent, different],
            requirements: requirements
        )

        XCTAssertEqual(removed, [equivalent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: equivalent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: different.path))
    }

    func testMigrationKeepsLegacyForIncompleteSnapshotAndIgnoresReproducibleFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.modelsDirectory.appendingPathComponent("legacy/model", isDirectory: true)
        try fixture.createUsableModel(at: legacy)
        try fixture.write("generated", to: legacy.appendingPathComponent("generated-tokenizer.json"))

        XCTAssertTrue(
            try fixture.store.removeRedundantLegacyDirectories(
                for: repositoryID,
                legacyDirectories: [legacy],
                requirements: requirements,
                reproducibleRelativePaths: ["generated-tokenizer.json"]
            ).isEmpty
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))

        _ = try fixture.createUsableSnapshot(repositoryID: repositoryID, commit: commit)
        XCTAssertEqual(
            try fixture.store.removeRedundantLegacyDirectories(
                for: repositoryID,
                legacyDirectories: [legacy],
                requirements: requirements,
                reproducibleRelativePaths: ["generated-tokenizer.json"]
            ),
            [legacy]
        )
    }

    func testDeleteRemovesAllModelArtifactsAndPreservesSiblingModel() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = fixture.modelsDirectory.appendingPathComponent("mlx-audio/typewhisper_test-model")
        try fixture.createUsableModel(at: legacy)
        let repository = try XCTUnwrap(fixture.store.repositoryCacheDirectory(for: repositoryID))
        let metadata = try XCTUnwrap(fixture.store.repositoryMetadataDirectory(for: repositoryID))
        let locks = try XCTUnwrap(fixture.store.repositoryLockDirectory(for: repositoryID))
        let sibling = try XCTUnwrap(fixture.store.repositoryCacheDirectory(for: "typewhisper/sibling"))
        try fixture.write("repo", to: repository.appendingPathComponent("refs/main"))
        try fixture.write("metadata", to: metadata.appendingPathComponent("file"))
        try fixture.write("lock", to: locks.appendingPathComponent("file.lock"))
        try fixture.write("keep", to: sibling.appendingPathComponent("refs/main"))

        XCTAssertTrue(fixture.store.hasCachedModelFiles(for: repositoryID, legacyDirectories: [legacy]))
        try fixture.store.deleteModelFiles(
            for: repositoryID,
            legacyDirectories: [fixture.modelsDirectory, legacy]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: locks.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.modelsDirectory.path))
    }
}

private final class Fixture {
    let root: URL
    let modelsDirectory: URL
    let store: PluginHuggingFaceModelStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        modelsDirectory = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        store = PluginHuggingFaceModelStore(modelsDirectory: modelsDirectory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func createUsableSnapshot(repositoryID: String, commit: String) throws -> URL {
        let repository = try XCTUnwrap(store.repositoryCacheDirectory(for: repositoryID))
        let snapshot = repository.appendingPathComponent("snapshots/\(commit)", isDirectory: true)
        try createUsableModel(at: snapshot)
        try write(commit + "\n", to: repository.appendingPathComponent("refs/main"))
        return snapshot
    }

    func createUsableModel(at directory: URL, weightContents: String = "weights") throws {
        try write("{}", to: directory.appendingPathComponent("config.json"))
        try write("{}", to: directory.appendingPathComponent("tokenizer.json"))
        try write(weightContents, to: directory.appendingPathComponent("model.safetensors"))
    }

    func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
