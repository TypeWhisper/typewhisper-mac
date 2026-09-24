import Foundation
import Darwin
import XCTest
@_spi(FirstPartyPlugins) @testable import TypeWhisperPluginSDK

final class PluginCustomModelImportTests: XCTestCase, @unchecked Sendable {
    private let requirements = PluginHuggingFaceModelStore.Requirements(
        requiredFiles: ["config.json", "tokenizer.json"], weightFileExtensions: ["safetensors"])

    private func fixture(type: String = "qwen3_asr") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"\(type)\"}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
        let header = Data(#"{"weight":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        var size = UInt64(header.count).littleEndian
        var weights = withUnsafeBytes(of: &size) { Data($0) }
        weights.append(header)
        weights.append(Data(repeating: 0, count: 4))
        try weights.write(to: folder.appendingPathComponent("model.safetensors"))
        return folder
    }

    private func store() -> PluginCustomModelStore {
        PluginCustomModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testExplicitRecoveryRemovesAbandonedStagesWithoutRemovingActiveImport() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let (active, lease) = try store.createStagingDirectory()
        let abandoned = store.directory.appendingPathComponent(".import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: abandoned.appendingPathComponent("partial.safetensors"))
        let reopened = PluginCustomModelStore(directory: store.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: abandoned.path))
        try reopened.recoverAbandonedImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        close(lease) // Simulate the OS releasing the lease after process termination.
        try reopened.recoverAbandonedImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
    }

    func testNativeValidationRemainsHiddenAndLeasedUntilSuccess() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let model = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements,
            validation: { model in
                XCTAssertTrue(store.models().isEmpty)
                let pending = try XCTUnwrap(store.modelDirectory(for: model.id))
                XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent(".pending-validation").path))
                try PluginCustomModelStore(directory: store.directory).recoverAbandonedImports()
                XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
            })
        XCTAssertEqual(store.models().map(\.id), [model.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.modelDirectory(for: model.id)!.appendingPathComponent(".pending-validation").path))
    }

    func testNativeValidationFailureRemovesPendingModel() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements,
                validation: { _ in throw CancellationError() })
            XCTFail("Accepted failed native validation")
        } catch is CancellationError {}
        XCTAssertTrue(store.models().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [".staging.lock"])
    }

    func testRecoveryRemovesPendingFinalDirectoryAfterLeaseIsReleased() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let (stage, lease) = try store.createStagingDirectory()
        let id = "custom-" + UUID().uuidString.lowercased()
        let pending = try XCTUnwrap(store.modelDirectory(for: id))
        try JSONSerialization.data(withJSONObject: [
            "id": id, "displayName": "Interrupted", "modelType": "qwen3_asr", "origin": "fixture", "bytes": 0,
        ]).write(to: stage.appendingPathComponent("typewhisper-import.json"))
        try Data().write(to: stage.appendingPathComponent(".pending-validation"))
        try FileManager.default.moveItem(at: stage, to: pending)
        XCTAssertTrue(store.models().isEmpty)
        try store.recoverAbandonedImports()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        close(lease) // The OS releases this lease on process termination.
        try store.recoverAbandonedImports()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testImmediateRetryRecoversAbandonedPendingDuplicateButPreservesActiveLease() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let (stage, lease) = try store.createStagingDirectory()
        var leaseOpen = true
        defer { if leaseOpen { close(lease) } }
        let id = "custom-" + UUID().uuidString.lowercased()
        let pending = try XCTUnwrap(store.modelDirectory(for: id))
        try JSONSerialization.data(withJSONObject: [
            "id": id, "displayName": "Interrupted", "modelType": "qwen3_asr",
            "origin": source.resolvingSymlinksInPath().path, "bytes": 0,
        ]).write(to: stage.appendingPathComponent("typewhisper-import.json"))
        try Data().write(to: stage.appendingPathComponent(".pending-validation"))
        try FileManager.default.moveItem(at: stage, to: pending)
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted a duplicate while native validation is still active")
        } catch { XCTAssertEqual(error as? PluginModelImportError, .duplicate) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        close(lease)
        leaseOpen = false // Simulate a crash, without activation recovery running yet.
        let reopened = PluginCustomModelStore(directory: store.directory)
        let imported = try await reopened.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(reopened.models().map(\.id), [imported.id])
    }

    func testRemoteMetadataLimitRejectsOversizedContentLength() async throws {
        try await assertMetadataRejected(path: "declared")
    }

    func testRemoteMetadataLimitRejectsChunkedBodyWhileReading() async throws {
        try await assertMetadataRejected(path: "chunked")
    }

    func testRemoteMetadataWithinLimitIsReturned() async throws {
        let session = metadataSession()
        defer { session.invalidateAndCancel() }
        let (data, _) = try await PluginModelImportCandidate.fetchMetadata(
            URLRequest(url: URL(string: "https://metadata.test/valid")!), session: session, limit: 16)
        XCTAssertEqual(data, Data(repeating: 42, count: 16))
    }

    private func metadataSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImportMetadataURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func assertMetadataRejected(path: String) async throws {
        let session = metadataSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await PluginModelImportCandidate.fetchMetadata(
                URLRequest(url: URL(string: "https://metadata.test/" + path)!), session: session, limit: 16)
            XCTFail("Oversized metadata must be rejected")
        } catch PluginModelImportError.invalidModel { }
    }

    func testLargeFileCopyCancellationRemovesPartialDestination() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.safetensors")
        let destination = folder.appendingPathComponent("copy.safetensors")
        let contents = Data(repeating: 42, count: 3 * 1024 * 1024)
        try contents.write(to: source)
        var checks = 0
        XCTAssertThrowsError(try PluginCustomModelStore.copyFile(from: source, to: destination) {
            checks += 1
            if checks == 3 {
                XCTAssertEqual(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, 1024 * 1024)
                throw CancellationError()
            }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    func testAcceptsRepositoryIDAndURLButRejectsOtherHostsAndPaths() throws {
        XCTAssertEqual(try PluginModelImportSource.huggingFaceInput(" owner/model "), .huggingFace("owner/model"))
        XCTAssertEqual(try PluginModelImportSource.huggingFaceInput("https://huggingface.co/owner/model/"), .huggingFace("owner/model"))
        for input in ["https://evil.test/owner/model", "http://huggingface.co/owner/model", "https://huggingface.co@evil.test/a/b",
                      "https://huggingface.co/owner/model/tree/main", "a/../b", "../model", "a//b", "a/b?x=y",
                      "https://huggingface.co/a/b?download=true", "https://huggingface.co/a%2Fb/c", "file:///tmp/model"] {
            XCTAssertThrowsError(try PluginModelImportSource.huggingFaceInput(input), input)
        }
    }

    func testLocalImportPersistsAndRemovalPreservesSource() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let model = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
        let reopened = PluginCustomModelStore(directory: store.directory)
        XCTAssertEqual(reopened.models().map(\.id), [model.id])
        XCTAssertEqual(reopened.models().first?.modelType, "qwen3_asr")
        let imported = try XCTUnwrap(reopened.modelDirectory(for: model.id))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent("model.safetensors")),
                       try Data(contentsOf: source.appendingPathComponent("model.safetensors")))
        try reopened.remove(model.id)
        XCTAssertTrue(reopened.models().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("model.safetensors").path))
        XCTAssertNil(reopened.modelDirectory(for: "../../original"))
        XCTAssertThrowsError(try reopened.remove("../original"))
    }

    func testUnsupportedCanaryIsRejectedWithoutImportingFiles() async throws {
        let source = try fixture(type: "canary")
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        XCTAssertEqual(candidate.suggestedPluginName, "Canary ASR")
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted Canary in the Qwen engine")
        } catch { XCTAssertEqual(error as? PluginModelImportError, .unsupportedArchitecture("canary")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testMissingTokenizerDoesNotPublishOrLeaveStagingDirectory() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.removeItem(at: source.appendingPathComponent("tokenizer.json"))
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted incomplete model")
        } catch { XCTAssertTrue(error is PluginModelImportError) }
        XCTAssertTrue(store.models().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [".staging.lock"])
    }

    func testWeightIndexAcceptsValidShardsButRejectsOversizedJSON() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let index = source.appendingPathComponent("model.safetensors.index.json")
        let json = Data(#"{"weight_map":{"weight":"model.safetensors"}}"#.utf8)
        try json.write(to: index)
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let imported = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
        try store.remove(imported.id)

        // Whitespace keeps this valid JSON: rejection must be the size bound,
        // not a decoding failure that would also occur without the guard.
        var oversized = json
        oversized.append(Data(repeating: 32, count: 16 * 1024 * 1024))
        try oversized.write(to: index)
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted oversized weight index")
        } catch PluginModelImportError.invalidModel(let message) {
            XCTAssertTrue(message.contains("16 MiB"))
        }
        XCTAssertTrue(store.models().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [".staging.lock"])
    }

    func testMissingWeightShardIsRejected() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        try Data(#"{"weight_map":{"weight":"missing.safetensors"}}"#.utf8)
            .write(to: source.appendingPathComponent("model.safetensors.index.json"))
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted missing shard")
        } catch { XCTAssertTrue(error is PluginModelImportError) }
        XCTAssertTrue(store.models().isEmpty)
    }

    func testLFSPointersAreNotAcceptedAsWeights() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:123\nsize 123".utf8)
            .write(to: source.appendingPathComponent("model.safetensors"))
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted Git LFS pointer")
        } catch { XCTAssertTrue(error is PluginModelImportError) }
        XCTAssertTrue(store.models().isEmpty)
    }

    func testConfigIsRecheckedAfterInspection() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        try Data(#"{"model_type":"canary"}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted changed architecture")
        } catch { XCTAssertEqual(error as? PluginModelImportError, .unsupportedArchitecture("canary")) }
        XCTAssertTrue(store.models().isEmpty)
    }

    func testCopiesSymlinkedWeightsAndExcludesExecutableCode() async throws {
        let source = try fixture()
        let store = store()
        let blob = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: store.directory)
            try? FileManager.default.removeItem(at: blob)
        }
        try FileManager.default.moveItem(at: source.appendingPathComponent("model.safetensors"), to: blob)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("model.safetensors"), withDestinationURL: blob)
        try Data("raise RuntimeError('must never run')".utf8).write(to: source.appendingPathComponent("model.py"))
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let model = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
        let imported = try XCTUnwrap(store.modelDirectory(for: model.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.appendingPathComponent("model.py").path))
        try FileManager.default.removeItem(at: blob)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.appendingPathComponent("model.safetensors").path))
    }

    func testDuplicateImportDoesNotCreateSecondCopy() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Imported duplicate")
        } catch { XCTAssertEqual(error as? PluginModelImportError, .duplicate) }
        XCTAssertEqual(store.models().count, 1)
    }

    func testCancelledImportDoesNotPublishModel() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        let requirements = requirements
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
        }
        do { _ = try await task.value; XCTFail("Published cancelled import") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.models().isEmpty)
    }

    func testRemoteInspectionPinsConfigToCommitAndUsesToken() async throws {
        let sha = String(repeating: "a", count: 40)
        let candidate = try await PluginModelImportCandidate.inspect(.huggingFace("owner/model"), token: "secret") { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let url = try XCTUnwrap(request.url)
            let data: Data
            if url.path == "/api/models/owner/model" {
                data = Data("{\"sha\":\"\(sha)\",\"siblings\":[{\"rfilename\":\"config.json\"}]}".utf8)
            } else {
                XCTAssertEqual(url.path, "/owner/model/resolve/\(sha)/config.json")
                data = Data(#"{"model_type":"qwen3_asr"}"#.utf8)
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(candidate.revision, sha)
        XCTAssertEqual(candidate.modelType, "qwen3_asr")
        XCTAssertEqual(candidate.suggestedPluginName, "Qwen3 ASR")
    }

    func testRemoteAuthorizationFailureIsActionable() async {
        do {
            _ = try await PluginModelImportCandidate.inspect(.huggingFace("owner/model")) { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("Accepted unauthorized response")
        } catch { XCTAssertEqual(error as? PluginModelImportError, .http(401)) }
    }
    func testTruncatedTensorPayloadIsRejected() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let weights = source.appendingPathComponent("model.safetensors")
        var data = try Data(contentsOf: weights)
        data.removeLast(2)
        try data.write(to: weights)
        let candidate = try await PluginModelImportCandidate.inspect(.folder(source))
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements)
            XCTFail("Accepted truncated tensor")
        } catch { XCTAssertTrue(error is PluginModelImportError) }
        XCTAssertTrue(store.models().isEmpty)
    }

    private func remoteCandidate() async throws -> PluginModelImportCandidate {
        try await PluginModelImportCandidate.inspect(.huggingFace("owner/model")) { request in
            let data: Data
            if request.url!.path.hasPrefix("/api/") {
                let files = ["config.json", "tokenizer.json", "model.safetensors", "model.py", "../escape.json", "subdir/config.json"]
                data = try JSONSerialization.data(withJSONObject: [
                    "sha": String(repeating: "a", count: 40), "siblings": files.map { ["rfilename": $0] }
                ])
            } else { data = Data(#"{"model_type":"qwen3_asr"}"#.utf8) }
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testConcurrentImportsPublishOnlyOneCopyOfSameRevision() async throws {
        let source = try fixture()
        let store = store()
        let requirements = requirements
        let candidate = try await remoteCandidate()
        let barrier = ImportDownloadBarrier()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    let independentStore = PluginCustomModelStore(directory: store.directory)
                    do {
                        _ = try await independentStore.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements) { request in
                            let url = request.url!
                            // Both imports must pass the early duplicate check before
                            // either can finish downloading and publish its model.
                            if url.lastPathComponent == "config.json" { await barrier.meet() }
                            let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try FileManager.default.copyItem(at: source.appendingPathComponent(url.lastPathComponent), to: downloaded)
                            return (downloaded, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                        }
                        return 1
                    } catch PluginModelImportError.duplicate {
                        return 0
                    } catch {
                        XCTFail("Unexpected import error: \(error)")
                        return -1
                    }
                }
            }
            var outcomes: [Int] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted()
        }
        XCTAssertEqual(outcomes, [0, 1])
        XCTAssertEqual(store.models().count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            .contains { $0.hasPrefix(".import-") })
    }

    func testRemoteImportDownloadsOnlyDataAtPinnedRevision() async throws {
        let source = try fixture()
        let store = store()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await remoteCandidate()
        let model = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements, token: "secret") { request in
            let url = request.url!
            XCTAssertTrue(url.path.hasPrefix("/owner/model/resolve/" + String(repeating: "a", count: 40) + "/"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertTrue(["config.json", "tokenizer.json", "model.safetensors"].contains(url.lastPathComponent))
            let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source.appendingPathComponent(url.lastPathComponent), to: downloaded)
            return (downloaded, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(model.origin, "https://huggingface.co/owner/model")
        XCTAssertEqual(model.revision, String(repeating: "a", count: 40))
        XCTAssertEqual(store.models().map(\.id), [model.id])
    }

    func testDownloadFailureRollsBackFilesAlreadyDownloaded() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let candidate = try await remoteCandidate()
        do {
            _ = try await store.add(candidate, supportedTypes: ["qwen3_asr"], requirements: requirements) { request in
                if request.url!.lastPathComponent != "config.json" { throw URLError(.networkConnectionLost) }
                let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try Data(#"{"model_type":"qwen3_asr"}"#.utf8).write(to: downloaded)
                return (downloaded, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            XCTFail("Accepted interrupted download")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertTrue(store.models().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [".staging.lock"])
    }

}

private final class ImportMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let headers = path == "declared" ? ["Content-Length": "17"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // An oversized Content-Length is rejected even when the body is tiny.
        let count = path == "declared" ? 1 : path == "valid" ? 16 : 17
        client?.urlProtocol(self, didLoad: Data(repeating: 42, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor ImportDownloadBarrier {
    private var waiting: CheckedContinuation<Void, Never>?
    func meet() async {
        if let waiting {
            self.waiting = nil
            waiting.resume()
        } else {
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
