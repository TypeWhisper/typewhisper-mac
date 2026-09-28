import Foundation
import XCTest
@_spi(FirstPartyPlugins) @testable import TypeWhisperPluginSDK

final class PluginDownloadDiskSpaceTests: XCTestCase {
    private let gigabyte: Int64 = 1_000_000_000
    private let destination = URL(fileURLWithPath: "/Volumes/Models/PluginData/models")

    func testReservesWhenDownloadAndHeadroomFit() throws {
        let ledger = makeLedger(availableBytes: 3 * gigabyte)

        let reservation = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Qwen3 1.7B (6-bit)",
            headroomBytes: 100_000_000
        )

        XCTAssertNotNil(reservation)
        XCTAssertEqual(ledger.activeReservationCount, 1)
        reservation?.release()
        XCTAssertEqual(ledger.activeReservationCount, 0)
    }

    func testThrowsRequiredAndAvailableBytesWhenSpaceIsShort() {
        let ledger = makeLedger(availableBytes: gigabyte, volumeName: "Macintosh HD")

        XCTAssertThrowsError(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Large v3",
            headroomBytes: 100_000_000
        )) { error in
            XCTAssertEqual(error as? PluginInsufficientDiskSpaceError, PluginInsufficientDiskSpaceError(
                modelName: "Large v3",
                requiredBytes: 2_100_000_000,
                availableBytes: gigabyte,
                volumeName: "Macintosh HD"
            ))
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Large v3"), message)
            XCTAssertTrue(message.contains(PluginInsufficientDiskSpaceError.format(2_100_000_000)), message)
            XCTAssertTrue(message.contains(PluginInsufficientDiskSpaceError.format(gigabyte)), message)
            XCTAssertTrue(message.contains("Macintosh HD"), message)
            XCTAssertFalse(message.contains("Other model downloads"), message)
        }
        XCTAssertEqual(ledger.activeReservationCount, 0)
    }

    func testParallelDownloadsOnTheSameVolumeShareFreeSpace() throws {
        let ledger = makeLedger(availableBytes: 3 * gigabyte)
        let first = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "First",
            headroomBytes: 0
        )

        XCTAssertThrowsError(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Second",
            headroomBytes: 0
        )) { error in
            let spaceError = error as? PluginInsufficientDiskSpaceError
            XCTAssertEqual(spaceError?.availableBytes, gigabyte)
            XCTAssertEqual(spaceError?.reservedByOtherDownloadsBytes, 2 * gigabyte)
        }

        first?.release()
        XCTAssertNotNil(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Second",
            headroomBytes: 0
        ))
    }

    func testBytesAlreadyWrittenByAParallelDownloadAreNotChargedTwice() throws {
        let tracked = URL(fileURLWithPath: "/Volumes/Models/PluginData/models/models--org--first")
        let sizes = DirectorySizes()
        // The first download has written 1.5 GB of its 2 GB. The volume's free
        // space already reflects those bytes.
        let ledger = PluginDiskSpaceLedger(
            volumeProvider: { _ in
                PluginDiskSpaceVolume(identifier: "/Volumes/Models", name: "Models", availableBytes: 3 * self.gigabyte)
            },
            directorySize: { sizes.value(for: $0) }
        )
        let first = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: tracked,
            modelName: "First",
            headroomBytes: 0
        )
        sizes.set(1_500_000_000, for: tracked)

        XCTAssertNotNil(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Second",
            headroomBytes: 0
        ))
        first?.release()
    }

    func testDownloadsOnOtherVolumesDoNotReduceSpace() throws {
        let ledger = PluginDiskSpaceLedger(
            volumeProvider: { url in
                let identifier = url.path.hasPrefix("/Volumes/External") ? "/Volumes/External" : "/"
                return PluginDiskSpaceVolume(identifier: identifier, name: nil, availableBytes: 3 * self.gigabyte)
            },
            directorySize: { _ in 0 }
        )
        let internalReservation = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: URL(fileURLWithPath: "/Users/test/models"),
            trackedDirectory: nil,
            modelName: "Internal",
            headroomBytes: 0
        )

        XCTAssertNotNil(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: URL(fileURLWithPath: "/Volumes/External/models"),
            trackedDirectory: nil,
            modelName: "External",
            headroomBytes: 0
        ))
        internalReservation?.release()
    }

    func testHeadroomStaysReservedWhenADownloadWritesMoreThanExpected() throws {
        let tracked = URL(fileURLWithPath: "/Volumes/Models/PluginData/models/models--org--first")
        let sizes = DirectorySizes()
        let ledger = PluginDiskSpaceLedger(
            volumeProvider: { _ in
                PluginDiskSpaceVolume(identifier: "/Volumes/Models", name: nil, availableBytes: 3 * self.gigabyte)
            },
            directorySize: { sizes.value(for: $0) }
        )
        let first = try ledger.reserve(
            downloadBytes: gigabyte,
            destination: destination,
            trackedDirectory: tracked,
            modelName: "First",
            headroomBytes: 500_000_000
        )
        // Temporary copies made the first download write twice its size.
        sizes.set(2 * gigabyte, for: tracked)

        XCTAssertThrowsError(try ledger.reserve(
            downloadBytes: 2_600_000_000,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Second",
            headroomBytes: 0
        )) { error in
            XCTAssertEqual((error as? PluginInsufficientDiskSpaceError)?.reservedByOtherDownloadsBytes, 500_000_000)
        }
        first?.release()
    }

    func testMissingBytesCountsOnlyListedFilesAndResumablePartials() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDownloadDiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ bytes: Int, to relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }
        try write(100, to: "Decoder.mlmodelc/weights/weight.bin")
        try write(300, to: "Encoder.mlmodelc/weights/weight.bin.partial")
        // Another encoder precision the selected download does not reuse.
        try write(5_000, to: "Encoder_v2.mlmodelc/weights/weight.bin")
        let files = [
            PluginHuggingFaceDownloadSize.RemoteFile(path: "Decoder.mlmodelc/weights/weight.bin", size: 100),
            PluginHuggingFaceDownloadSize.RemoteFile(path: "Encoder.mlmodelc/weights/weight.bin", size: 1_000),
            PluginHuggingFaceDownloadSize.RemoteFile(path: "parakeet_vocab.json", size: 20),
        ]

        XCTAssertEqual(PluginHuggingFaceDownloadSize.missingBytes(of: files, in: root), 720)
    }

    func testStagingOnAnotherVolumeNeedsRoomForTheLargestFile() throws {
        let ledger = PluginDiskSpaceLedger(
            volumeProvider: { url in
                url.path.hasPrefix("/Volumes/External")
                    ? PluginDiskSpaceVolume(identifier: "/Volumes/External", name: "External", availableBytes: 10 * self.gigabyte)
                    : PluginDiskSpaceVolume(identifier: "/", name: "Macintosh HD", availableBytes: self.gigabyte)
            },
            directorySize: { _ in 0 }
        )

        XCTAssertThrowsError(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: URL(fileURLWithPath: "/Volumes/External/models"),
            trackedDirectory: nil,
            stagingDirectory: URL(fileURLWithPath: "/private/var/folders/tmp"),
            stagingBytes: 1_500_000_000,
            modelName: "Large",
            headroomBytes: 0
        )) { error in
            let spaceError = error as? PluginInsufficientDiskSpaceError
            XCTAssertEqual(spaceError?.volumeName, "Macintosh HD")
            XCTAssertEqual(spaceError?.requiredBytes, 1_500_000_000)
        }
        XCTAssertEqual(ledger.activeReservationCount, 0)

        let reservation = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: URL(fileURLWithPath: "/Volumes/External/models"),
            trackedDirectory: nil,
            stagingDirectory: URL(fileURLWithPath: "/private/var/folders/tmp"),
            stagingBytes: 500_000_000,
            modelName: "Large",
            headroomBytes: 0
        )
        XCTAssertEqual(ledger.activeReservationCount, 2)
        reservation?.release()
        XCTAssertEqual(ledger.activeReservationCount, 0)
    }

    func testStagingOnTheSameVolumeIsNotCountedTwice() throws {
        let ledger = makeLedger(availableBytes: 3 * gigabyte)

        let reservation = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            stagingDirectory: URL(fileURLWithPath: "/tmp"),
            stagingBytes: 2 * gigabyte,
            modelName: "Model",
            headroomBytes: 0
        )

        XCTAssertNotNil(reservation)
        XCTAssertEqual(ledger.activeReservationCount, 1)
    }

    func testSharedTrackedDirectoryKeepsFullReservations() throws {
        let tracked = URL(fileURLWithPath: "/Volumes/Models/PluginData/models")
        let sizes = DirectorySizes()
        let ledger = PluginDiskSpaceLedger(
            volumeProvider: { _ in
                PluginDiskSpaceVolume(identifier: "/Volumes/Models", name: nil, availableBytes: 5 * self.gigabyte)
            },
            directorySize: { sizes.value(for: $0) }
        )
        let first = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: tracked,
            trackedDirectory: tracked,
            modelName: "First",
            headroomBytes: 0
        )
        let second = try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: tracked,
            trackedDirectory: tracked.appendingPathComponent("models--org--second"),
            modelName: "Second",
            headroomBytes: 0
        )
        // Growth in the shared directory cannot be attributed to either download.
        sizes.set(2 * gigabyte, for: tracked)

        XCTAssertThrowsError(try ledger.reserve(
            downloadBytes: 2 * gigabyte,
            destination: tracked,
            trackedDirectory: nil,
            modelName: "Third",
            headroomBytes: 0
        )) { error in
            XCTAssertEqual((error as? PluginInsufficientDiskSpaceError)?.reservedByOtherDownloadsBytes, 4 * gigabyte)
        }

        // The nested download finished; its files must not count as progress
        // for the download that tracks the parent directory.
        second?.release()
        XCTAssertThrowsError(try ledger.reserve(
            downloadBytes: 3_500_000_000,
            destination: tracked,
            trackedDirectory: nil,
            modelName: "Third",
            headroomBytes: 0
        )) { error in
            XCTAssertEqual((error as? PluginInsufficientDiskSpaceError)?.reservedByOtherDownloadsBytes, 2 * gigabyte)
        }
        first?.release()
    }

    func testSymlinkAliasesOfATrackedDirectoryOverlap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDownloadDiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: models)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(PluginDiskSpaceLedger.directoriesOverlap(
            models.appendingPathComponent("models--org--model"),
            alias.appendingPathComponent("models--org--model/blobs")
        ))
        XCTAssertFalse(PluginDiskSpaceLedger.directoriesOverlap(
            models.appendingPathComponent("models--org--first"),
            alias.appendingPathComponent("models--org--second")
        ))
    }

    func testUnknownVolumeCapacityDoesNotBlockDownloads() throws {
        let ledger = PluginDiskSpaceLedger(volumeProvider: { _ in nil }, directorySize: { _ in 0 })

        XCTAssertNil(try ledger.reserve(
            downloadBytes: 50 * gigabyte,
            destination: destination,
            trackedDirectory: nil,
            modelName: "Unknown",
            headroomBytes: 0
        ))
    }

    func testVolumeLookupUsesNearestExistingAncestorAndResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDownloadDiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        let direct = try XCTUnwrap(PluginDiskSpaceVolume.containing(target))
        let throughMissingChildOfLink = try XCTUnwrap(
            PluginDiskSpaceVolume.containing(link.appendingPathComponent("models/not-yet-created"))
        )

        XCTAssertEqual(throughMissingChildOfLink.identifier, direct.identifier)
        XCTAssertGreaterThan(direct.availableBytes, 0)
    }

    func testDirectorySizeCountsNestedFilesAndIgnoresSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDownloadDiskSpaceTests-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 10).write(to: root.appendingPathComponent("config.json"))
        try Data(count: 25).write(to: nested.appendingPathComponent("weights.incomplete"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.json"),
            withDestinationURL: root.appendingPathComponent("config.json")
        )

        XCTAssertEqual(PluginDownloadDiskSpace.directorySize(root), 35)
        XCTAssertEqual(PluginDownloadDiskSpace.directorySize(root.appendingPathComponent("missing")), 0)
    }

    // MARK: - Hugging Face size lookup

    func testHuggingFaceSizeSumsMatchingFilesAcrossPages() async throws {
        let requests = RequestLog()
        let total = try await PluginHuggingFaceDownloadSize.totalBytes(
            repositoryID: "mlx-community/Qwen3-ASR-1.7B-6bit",
            matching: ["*.safetensors", "*.json"],
            token: "hf_test",
            dataFetcher: { request in
                requests.append(request)
                let url = try XCTUnwrap(request.url)
                if url.query?.contains("cursor=2") == true {
                    return (
                        Data(#"[{"type":"file","path":"model-2.safetensors","size":700}]"#.utf8),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                let next = "https://huggingface.co/api/models/mlx-community/Qwen3-ASR-1.7B-6bit/tree/main?recursive=true&cursor=2"
                return (
                    Data(#"""
                    [
                      {"type":"directory","path":"nested","size":0},
                      {"type":"file","path":"config.json","size":100},
                      {"type":"file","path":"model-1.safetensors","size":900},
                      {"type":"file","path":"README.md","size":5000}
                    ]
                    """#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Link": "<\(next)>; rel=\"next\"",
                    ])!
                )
            }
        )

        XCTAssertEqual(total, 1_700)
        let first = try XCTUnwrap(requests.all.first)
        XCTAssertEqual(
            first.url?.absoluteString,
            "https://huggingface.co/api/models/mlx-community/Qwen3-ASR-1.7B-6bit/tree/main?recursive=true"
        )
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer hf_test")
        XCTAssertEqual(requests.all.count, 2)
    }

    func testHuggingFaceSizeCanBeLimitedToAFolder() async throws {
        let requests = RequestLog()
        let total = try await PluginHuggingFaceDownloadSize.totalBytes(
            repositoryID: "argmaxinc/whisperkit-coreml",
            path: "openai_whisper-large-v3",
            dataFetcher: { request in
                requests.append(request)
                return (
                    Data(#"[{"type":"file","path":"openai_whisper-large-v3/AudioEncoder.mlmodelc/weights/weight.bin","size":42}]"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        XCTAssertEqual(total, 42)
        XCTAssertEqual(
            requests.all.first?.url?.absoluteString,
            "https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-large-v3?recursive=true"
        )
    }

    func testHuggingFaceSizeRejectsHTTPErrors() async {
        do {
            _ = try await PluginHuggingFaceDownloadSize.totalBytes(
                repositoryID: "org/private",
                dataFetcher: { request in
                    (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
                }
            )
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error as? PluginHuggingFaceDownloadSize.LookupError, .http(401))
        }
    }

    func testFailedSizeLookupSkipsTheCheck() async throws {
        let reservation = try await PluginDownloadDiskSpace.reserveHuggingFaceDownload(
            repositoryID: "org/model",
            destination: destination,
            modelName: "Model",
            dataFetcher: { _ in throw URLError(.notConnectedToInternet) }
        )

        XCTAssertNil(reservation)
    }

    func testGlobMatchingFollowsSwiftHuggingFaceSnapshotFiltering() {
        XCTAssertTrue(PluginHuggingFaceDownloadSize.matches("Encoder.mlmodelc/weights/weight.bin", patterns: ["Encoder.mlmodelc/*"]))
        XCTAssertTrue(PluginHuggingFaceDownloadSize.matches("nested/model.safetensors", patterns: ["*.safetensors"]))
        XCTAssertFalse(PluginHuggingFaceDownloadSize.matches("EncoderInt4.mlmodelc/weights/weight.bin", patterns: ["Encoder.mlmodelc/*"]))
        XCTAssertTrue(PluginHuggingFaceDownloadSize.matches("anything", patterns: []))
    }

    // MARK: - Helpers

    private func makeLedger(availableBytes: Int64, volumeName: String? = nil) -> PluginDiskSpaceLedger {
        PluginDiskSpaceLedger(
            volumeProvider: { _ in
                PluginDiskSpaceVolume(identifier: "/Volumes/Models", name: volumeName, availableBytes: availableBytes)
            },
            directorySize: { _ in 0 }
        )
    }
}

private final class DirectorySizes: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [URL: Int64] = [:]

    func set(_ size: Int64, for url: URL) {
        lock.withLock { sizes[url] = size }
    }

    func value(for url: URL) -> Int64 {
        lock.withLock { sizes[url] ?? 0 }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var all: [URLRequest] {
        lock.withLock { requests }
    }
}
