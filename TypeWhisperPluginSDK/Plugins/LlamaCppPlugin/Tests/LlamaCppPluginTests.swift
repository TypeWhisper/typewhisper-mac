import CryptoKit
import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest

@testable import LlamaCppPlugin

// MARK: - Hugging Face references

final class LlamaCppHuggingFaceReferenceTests: XCTestCase {
    func testParsesRepositoryForms() throws {
        XCTAssertEqual(
            try LlamaCppHuggingFaceReference.parse(" unsloth/Qwen3.5-2B-GGUF "),
            LlamaCppHuggingFaceReference(repositoryId: "unsloth/Qwen3.5-2B-GGUF")
        )
        XCTAssertEqual(
            try LlamaCppHuggingFaceReference.parse("unsloth/Qwen3.5-2B-GGUF:Q4_K_M"),
            LlamaCppHuggingFaceReference(repositoryId: "unsloth/Qwen3.5-2B-GGUF", quantization: "Q4_K_M")
        )
        XCTAssertEqual(
            try LlamaCppHuggingFaceReference.parse("hf.co/LiquidAI/LFM2.5-2.6B-GGUF:Q8_0"),
            LlamaCppHuggingFaceReference(repositoryId: "LiquidAI/LFM2.5-2.6B-GGUF", quantization: "Q8_0")
        )
        XCTAssertEqual(
            try LlamaCppHuggingFaceReference.parse("https://huggingface.co/unsloth/Qwen3.5-2B-GGUF"),
            LlamaCppHuggingFaceReference(repositoryId: "unsloth/Qwen3.5-2B-GGUF")
        )
    }

    func testParsesFileLinks() throws {
        let blob = try LlamaCppHuggingFaceReference.parse(
            "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/blob/main/Qwen3.5-2B-Q4_K_M.gguf"
        )
        XCTAssertEqual(blob.repositoryId, "unsloth/Qwen3.5-2B-GGUF")
        XCTAssertEqual(blob.revision, "main")
        XCTAssertEqual(blob.filePath, "Qwen3.5-2B-Q4_K_M.gguf")

        let resolve = try LlamaCppHuggingFaceReference.parse(
            "https://huggingface.co/owner/repo-GGUF/resolve/0314792d7f1f7e229411f620751375812bb9faf2/sub/dir/model%20q4.gguf?download=true"
        )
        XCTAssertEqual(resolve.revision, "0314792d7f1f7e229411f620751375812bb9faf2")
        XCTAssertEqual(resolve.filePath, "sub/dir/model q4.gguf")

        let tree = try LlamaCppHuggingFaceReference.parse("https://huggingface.co/owner/repo/tree/main")
        XCTAssertEqual(tree.revision, "main")
        XCTAssertNil(tree.filePath)
    }

    func testRejectsInvalidInput() {
        for input in [
            "",
            "just-a-name",
            "http://huggingface.co/owner/repo",
            "ftp://owner/repo",
            "owner/repo:",
            "owner/repo:Q4 K",
            "../repo",
            "owner/repo/blob/main/../../etc/passwd.gguf",
            "owner/repo/blob/main/readme.md",
            "owner/repo/discussions/1",
        ] {
            XCTAssertThrowsError(try LlamaCppHuggingFaceReference.parse(input), input) { error in
                XCTAssertEqual(error as? LlamaCppPluginError, .invalidHuggingFaceReference, input)
            }
        }
    }
}

// MARK: - Hugging Face lookup

final class LlamaCppHuggingFaceLookupTests: XCTestCase {
    private static let sha = "f6d5376be1edb4d416d56da11e5397a961aca8ae"
    private static let checksum = String(repeating: "a", count: 64)

    private static func tree(_ entries: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: entries)
    }

    private static func file(_ path: String, size: Int64, lfs: Bool = true) -> [String: Any] {
        var entry: [String: Any] = ["type": "file", "path": path, "oid": "abc", "size": size]
        if lfs {
            entry["lfs"] = ["oid": checksum, "size": size, "pointerSize": 134]
        }
        return entry
    }

    private func fetcher(
        treeData: Data,
        infoStatus: Int = 200,
        recorder: RequestRecorder? = nil
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            recorder?.record(request)
            let url = request.url!
            if url.path.contains("/revision/") {
                let body = infoStatus == 200 ? Data(#"{"sha":"\#(Self.sha)"}"#.utf8) : Data()
                return (body, HTTPURLResponse(url: url, statusCode: infoStatus, httpVersion: nil, headerFields: nil)!)
            }
            return (treeData, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testListsSingleFileModelsAndPinsTheCommit() async throws {
        let recorder = RequestRecorder()
        let result = try await LlamaCppHuggingFaceLookup.lookUp(
            LlamaCppHuggingFaceReference(repositoryId: "owner/repo-GGUF", quantization: "Q4_K_M"),
            token: "hf_secret",
            dataFetcher: fetcher(
                treeData: Self.tree([
                    Self.file("model-Q8_0.gguf", size: 2_000),
                    Self.file("model-Q4_K_M.gguf", size: 1_000),
                    Self.file("mmproj-model-F16.gguf", size: 500),
                    Self.file("big/model-Q4_K_M-00001-of-00002.gguf", size: 9_000),
                    Self.file("big/model-Q4_K_M-00002-of-00002.gguf", size: 9_000),
                    Self.file("tiny.gguf", size: 10, lfs: false),
                    Self.file("README.md", size: 100, lfs: false),
                    ["type": "directory", "path": "big"],
                ]),
                recorder: recorder
            )
        )

        XCTAssertEqual(result.revision, Self.sha)
        XCTAssertEqual(result.models.map(\.path), ["model-Q4_K_M.gguf", "model-Q8_0.gguf"])
        XCTAssertEqual(result.projectors.map(\.path), ["mmproj-model-F16.gguf"])
        XCTAssertEqual(result.preselectedPath, "model-Q4_K_M.gguf")
        XCTAssertEqual(result.skippedSplitModelCount, 1)
        XCTAssertTrue(result.models.allSatisfy { $0.revision == Self.sha && $0.sha256 == Self.checksum })

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/models/owner/repo-GGUF/revision/main")
        XCTAssertEqual(requests[1].url?.path, "/api/models/owner/repo-GGUF/tree/\(Self.sha)")
        XCTAssertEqual(requests[1].url?.query, "recursive=true")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer hf_secret" })
    }

    func testPreselectionPrefersTheNamedFileAndExactQuantization() throws {
        let files = ["m-Q4_K_M.gguf", "m-IQ4_K_M_L.gguf", "m-Q4_K_M_L.gguf"].map {
            LlamaCppRemoteFile(repositoryId: "o/r", revision: Self.sha, path: $0, size: 1, sha256: Self.checksum)
        }
        XCTAssertEqual(
            try LlamaCppHuggingFaceLookup.preselectedPath(
                in: files,
                for: LlamaCppHuggingFaceReference(repositoryId: "o/r", quantization: "q4_k_m")
            ),
            "m-Q4_K_M.gguf"
        )
        XCTAssertEqual(
            try LlamaCppHuggingFaceLookup.preselectedPath(
                in: files,
                for: LlamaCppHuggingFaceReference(repositoryId: "o/r", filePath: "m-Q4_K_M_L.gguf")
            ),
            "m-Q4_K_M_L.gguf"
        )
        XCTAssertNil(try LlamaCppHuggingFaceLookup.preselectedPath(in: files, for: .init(repositoryId: "o/r")))
        XCTAssertThrowsError(
            try LlamaCppHuggingFaceLookup.preselectedPath(in: files, for: .init(repositoryId: "o/r", quantization: "Q2_K"))
        ) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .quantizationNotFound("Q2_K"))
        }
        XCTAssertThrowsError(
            try LlamaCppHuggingFaceLookup.preselectedPath(in: files, for: .init(repositoryId: "o/r", filePath: "mmproj-x.gguf"))
        ) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .projectorIsNotAModel)
        }
    }

    func testReportsMissingAccessAndEmptyRepositories() async {
        let reference = LlamaCppHuggingFaceReference(repositoryId: "owner/private")
        do {
            _ = try await LlamaCppHuggingFaceLookup.lookUp(
                reference,
                token: nil,
                dataFetcher: fetcher(treeData: Self.tree([]), infoStatus: 401)
            )
            XCTFail("Expected access error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .huggingFaceAccessDenied("owner/private"))
        }

        do {
            _ = try await LlamaCppHuggingFaceLookup.lookUp(
                reference,
                token: nil,
                dataFetcher: fetcher(treeData: Self.tree([Self.file("README.md", size: 1, lfs: false)]))
            )
            XCTFail("Expected empty repository error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .noGGUFFiles("owner/private"))
        }

        do {
            _ = try await LlamaCppHuggingFaceLookup.lookUp(
                reference,
                token: nil,
                dataFetcher: fetcher(treeData: Self.tree([Self.file("m-00001-of-00002.gguf", size: 5)]))
            )
            XCTFail("Expected split model error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .onlySplitGGUFFiles("owner/private"))
        }
    }
}

// MARK: - Server and chat

final class LlamaCppServerTests: XCTestCase {
    func testLaunchArgumentsKeepTheServerLocalAndPassTheProjectorOnlyWhenSet() {
        var options = LlamaCppServerLaunchOptions(
            modelURL: URL(fileURLWithPath: "/models/a model.gguf"),
            threads: 4
        )
        let arguments = options.arguments(port: 4321)
        XCTAssertEqual(Self.value(after: "--model", in: arguments), "/models/a model.gguf")
        XCTAssertEqual(Self.value(after: "--host", in: arguments), "127.0.0.1")
        XCTAssertEqual(Self.value(after: "--port", in: arguments), "4321")
        XCTAssertEqual(Self.value(after: "--alias", in: arguments), LlamaCppServerLaunchOptions.modelAlias)
        XCTAssertEqual(Self.value(after: "--ctx-size", in: arguments), "8192")
        XCTAssertEqual(Self.value(after: "--parallel", in: arguments), "1")
        XCTAssertEqual(Self.value(after: "--reasoning", in: arguments), "off")
        XCTAssertEqual(Self.value(after: "--threads", in: arguments), "4")
        XCTAssertTrue(arguments.contains("--offline"))
        XCTAssertTrue(arguments.contains("--no-ui"))
        XCTAssertFalse(arguments.contains("--mmproj"))
        XCTAssertFalse(arguments.joined(separator: " ").contains("api-key"))

        options.projectorURL = URL(fileURLWithPath: "/models/mmproj-audio.gguf")
        XCTAssertEqual(Self.value(after: "--mmproj", in: options.arguments(port: 1)), "/models/mmproj-audio.gguf")
    }

    func testEnvironmentDropsInheritedLlamaVariablesAndCarriesTheKey() {
        let environment = LlamaCppServerLaunchOptions.environment(
            apiKey: "secret",
            inheriting: ["PATH": "/usr/bin", "LLAMA_ARG_CTX_SIZE": "4", "LLAMA_API_KEY": "old"]
        )
        XCTAssertEqual(environment, ["PATH": "/usr/bin", "LLAMA_API_KEY": "secret"])
    }

    func testChatRequestUsesSystemAndUserTurnsWithoutThinking() throws {
        let request = LlamaCppChatClient.makeRequest(systemPrompt: "Fix it.", userText: "hello", temperature: 0.2)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, LlamaCppServerLaunchOptions.modelAlias)
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        XCTAssertEqual((json["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "Fix it."], ["role": "user", "content": "hello"]])
    }

    func testParsesAnswersAndServerErrors() throws {
        XCTAssertEqual(
            try LlamaCppChatClient.parse(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"Done."}}]}"#.utf8),
                statusCode: 200
            ),
            "Done."
        )
        XCTAssertThrowsError(
            try LlamaCppChatClient.parse(
                data: Data(#"{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error"}}"#.utf8),
                statusCode: 400
            )
        ) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .inputTooLong)
        }
        XCTAssertThrowsError(
            try LlamaCppChatClient.parse(data: Data(#"{"error":{"message":"Invalid API Key"}}"#.utf8), statusCode: 401)
        ) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .serverRequestFailed(401, "Invalid API Key"))
        }
        XCTAssertThrowsError(
            try LlamaCppChatClient.parse(data: Data(#"{"choices":[]}"#.utf8), statusCode: 200)
        ) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .emptyResponse)
        }
    }

    func testFinalOutputDropsReasoning() {
        XCTAssertEqual(LlamaCppPlugin.finalPromptOutput("  <think>plan</think>\n\nResult  "), "Result")
        XCTAssertEqual(LlamaCppPlugin.finalPromptOutput("plan only</think>Result"), "Result")
        XCTAssertEqual(LlamaCppPlugin.finalPromptOutput("Result<think>unfinished"), "Result")
        XCTAssertEqual(LlamaCppPlugin.finalPromptOutput("Plain text."), "Plain text.")
    }

    func testServerErrorsNameTheLastErrorLine() {
        let output = """
            load_model: loading model '/x.gguf'
            llama_model_load: error loading model: unknown model architecture: 'lfm3audio'
            srv load_model: failed to load model
            main: exiting due to model loading error
            """
        XCTAssertEqual(
            LlamaCppPluginError.lastErrorLine(in: output),
            "main: exiting due to model loading error"
        )
        XCTAssertNil(LlamaCppPluginError.lastErrorLine(in: "all good\n"))
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

// MARK: - Catalog and files

final class LlamaCppCatalogTests: XCTestCase {
    func testCatalogEntriesArePinnedAndUnique() {
        let models = LlamaCppModelCatalog.models
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        for model in models {
            XCTAssertTrue(LlamaCppModelIdentifier.isValid(model.id), model.id)
            let weights = try? XCTUnwrap(model.weights)
            XCTAssertEqual(weights?.revision.count, 40, model.id)
            XCTAssertNotNil(weights?.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression), model.id)
            XCTAssertEqual(weights?.size, model.fileSize, model.id)
            XCTAssertEqual(weights?.fileName, model.fileName, model.id)
            XCTAssertNotNil(model.minimumMemoryGB, model.id)
        }
    }

    func testRecommendationFollowsInstalledMemory() {
        XCTAssertEqual(LlamaCppModelCatalog.recommendedModel(forMemoryGB: 4)?.id, "gemma-4-e2b-it-q4")
        XCTAssertEqual(LlamaCppModelCatalog.recommendedModel(forMemoryGB: 8)?.id, "gemma-4-e2b-it-q4")
        XCTAssertEqual(LlamaCppModelCatalog.recommendedModel(forMemoryGB: 16)?.id, "gemma-4-e4b-it-q4")
        XCTAssertEqual(LlamaCppModelCatalog.recommendedModel(forMemoryGB: 128)?.id, "gemma-4-e4b-it-q4")
    }

    func testPinnedRuntimeDerivesItsDownloadAndFolder() {
        let release = LlamaCppRuntimeRelease.pinned
        XCTAssertEqual(
            release.archiveURL.absoluteString,
            "https://github.com/ggml-org/llama.cpp/releases/download/\(release.build)/llama-\(release.build)-bin-macos-arm64.tar.gz"
        )
        XCTAssertEqual(release.archiveRootName, "llama-\(release.build)")
        XCTAssertNotNil(release.archiveSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
    }

    func testIdentifiersAreSafeAndUnique() {
        XCTAssertEqual(LlamaCppModelIdentifier.slug("unsloth/Qwen3.5-2B-GGUF-Qwen3.5-2B-Q4_K_M"), "unsloth-qwen3.5-2b-gguf-qwen3.5-2b-q4_k_m")
        for name in ["../../Ünïcode..", "a/../../b", "owner/repo:tag", String(repeating: "x", count: 300)] {
            let slug = LlamaCppModelIdentifier.slug(name)
            XCTAssertFalse(slug.contains(".."), name)
            XCTAssertFalse(slug.contains("/"), name)
            XCTAssertTrue(slug.unicodeScalars.allSatisfy(\.isASCII), name)
            XCTAssertLessThanOrEqual(slug.count, 100, name)
            XCTAssertTrue(LlamaCppModelIdentifier.isValid("hf-\(slug)"), name)
        }
        XCTAssertEqual(
            LlamaCppModelIdentifier.unique(prefix: "hf", name: "o/r", existingIds: ["hf-o-r", "hf-o-r-2"]),
            "hf-o-r-3"
        )
        XCTAssertTrue(LlamaCppModelIdentifier.isValid("hf-o-r-3"))
        XCTAssertFalse(LlamaCppModelIdentifier.isValid("../x"))
        XCTAssertFalse(LlamaCppModelIdentifier.isValid("Upper"))
    }

    func testVerificationMarkerNoticesChangedFiles() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.gguf")
        try Data("GGUFabcd".utf8).write(to: file)

        XCTAssertFalse(LlamaCppVerificationMarker.isVerified(file, expectedSize: 8, expectedSHA256: nil))
        try LlamaCppVerificationMarker.write(for: file, sha256: "ab")
        XCTAssertTrue(LlamaCppVerificationMarker.isVerified(file, expectedSize: 8, expectedSHA256: "AB"))
        XCTAssertFalse(LlamaCppVerificationMarker.isVerified(file, expectedSize: 8, expectedSHA256: "cd"))
        XCTAssertFalse(LlamaCppVerificationMarker.isVerified(file, expectedSize: 9, expectedSHA256: nil))

        try Data("GGUFabcdef".utf8).write(to: file)
        XCTAssertFalse(LlamaCppVerificationMarker.isVerified(file, expectedSize: 10, expectedSHA256: nil))
    }

    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LlamaCppPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

// MARK: - Runtime installation

final class LlamaCppRuntimeInstallationTests: XCTestCase {
    override func tearDown() {
        ArchiveURLProtocol.response = nil
        super.tearDown()
    }

    func testInstallsAVerifiedArchiveAndRemovesOlderBuilds() async throws {
        let directory = try LlamaCppCatalogTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Self.makeArchive(build: "b2", in: directory)
        let release = LlamaCppRuntimeRelease(
            build: "b2",
            version: "test",
            archiveSize: Int64(archive.count),
            archiveSHA256: SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        )
        let runtimes = directory.appendingPathComponent("Runtime", isDirectory: true)
        let oldBuild = runtimes.appendingPathComponent("llama-b1", isDirectory: true)
        try FileManager.default.createDirectory(at: oldBuild, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: runtimes.appendingPathComponent(".staging-left-over", isDirectory: true),
            withIntermediateDirectories: true
        )

        ArchiveURLProtocol.response = (200, archive)
        let installation = LlamaCppRuntimeInstallation(runtimesDirectory: runtimes, release: release)
        XCTAssertFalse(installation.isInstalled)
        XCTAssertEqual(installation.missingDownloadBytes, Int64(archive.count))

        try await installation.install(session: Self.session()) { _ in }

        XCTAssertTrue(installation.isInstalled)
        XCTAssertEqual(installation.missingDownloadBytes, 0)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installation.serverExecutableURL.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: runtimes.path).sorted()
        XCTAssertEqual(remaining, ["llama-b2"])
    }

    func testRejectsAnArchiveWithAnotherChecksum() async throws {
        let directory = try LlamaCppCatalogTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try Self.makeArchive(build: "b3", in: directory)
        let release = LlamaCppRuntimeRelease(
            build: "b3",
            version: "test",
            archiveSize: Int64(archive.count),
            archiveSHA256: String(repeating: "0", count: 64)
        )
        let runtimes = directory.appendingPathComponent("Runtime", isDirectory: true)
        ArchiveURLProtocol.response = (200, archive)
        let installation = LlamaCppRuntimeInstallation(runtimesDirectory: runtimes, release: release)

        do {
            try await installation.install(session: Self.session()) { _ in }
            XCTFail("Expected a checksum error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .verificationFailed("llama-b3-bin-macos-arm64.tar.gz"))
        }
        XCTAssertFalse(installation.isInstalled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtimes.path), [])
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArchiveURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeArchive(build: String, in directory: URL) throws -> Data {
        let source = directory.appendingPathComponent("source-\(build)", isDirectory: true)
        let root = source.appendingPathComponent("llama-\(build)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("llama-server"))
        try Data("MIT".utf8).write(to: root.appendingPathComponent("LICENSE"))
        let archiveURL = directory.appendingPathComponent("\(build).tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", archiveURL.path, "-C", source.path, "llama-\(build)"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: archiveURL)
    }
}

private final class ArchiveURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: Data)?

    // swiftlint:disable static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        guard let url = request.url, let response = Self.response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(response.body.count)]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}

// MARK: - Plugin

@MainActor
final class LlamaCppPluginModelManagementTests: XCTestCase {
    private var host: PluginTestHostServices!
    private var plugin: LlamaCppPlugin!

    override func setUp() async throws {
        try await super.setUp()
        host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        plugin = LlamaCppPlugin()
        plugin.activate(host: host)
    }

    override func tearDown() async throws {
        plugin.deactivate()
        host.cleanup()
        plugin = nil
        host = nil
        try await super.tearDown()
    }

    private static let remoteFile = LlamaCppRemoteFile(
        repositoryId: "owner/Tiny-GGUF",
        revision: String(repeating: "1", count: 40),
        path: "Tiny-Q4_K_M.gguf",
        size: 42,
        sha256: String(repeating: "b", count: 64)
    )

    func testActivationSelectsTheRecommendedModel() {
        XCTAssertEqual(plugin.selectedLLMModelId, LlamaCppModelCatalog.recommendedModel()?.id)
        XCTAssertFalse(plugin.isAvailable)
        XCTAssertEqual(plugin.supportedModels.count, 0)
        XCTAssertFalse(plugin.requiresExternalCredentials)
        XCTAssertEqual(plugin.providerId, "Local LLM (llama.cpp)")
    }

    func testHuggingFaceModelsPersistAndRejectDuplicates() throws {
        let model = try plugin.addHuggingFaceModel(Self.remoteFile)
        XCTAssertEqual(model.origin, .huggingFace)
        XCTAssertEqual(model.displayName, "Tiny-Q4_K_M")
        XCTAssertTrue(model.id.hasPrefix("hf-"))
        XCTAssertTrue(LlamaCppModelIdentifier.isValid(model.id))
        XCTAssertFalse(plugin.isModelDownloaded(model))

        XCTAssertThrowsError(try plugin.addHuggingFaceModel(Self.remoteFile)) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .duplicateModel)
        }

        let reloaded = LlamaCppPlugin()
        reloaded.activate(host: host)
        XCTAssertEqual(reloaded.customModels, [model])
        XCTAssertEqual(reloaded.modelDefinition(for: model.id), model)
        reloaded.deactivate()
    }

    func testProjectorsAndSplitFilesCannotBeAddedAsModels() {
        let projector = LlamaCppRemoteFile(
            repositoryId: "o/r", revision: String(repeating: "1", count: 40),
            path: "mmproj-Model-F16.gguf", size: 1, sha256: String(repeating: "c", count: 64)
        )
        XCTAssertThrowsError(try plugin.addHuggingFaceModel(projector)) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .projectorIsNotAModel)
        }
        let split = LlamaCppRemoteFile(
            repositoryId: "o/r", revision: String(repeating: "1", count: 40),
            path: "Model-00001-of-00002.gguf", size: 1, sha256: String(repeating: "c", count: 64)
        )
        XCTAssertThrowsError(try plugin.addHuggingFaceModel(split)) { error in
            XCTAssertEqual(error as? LlamaCppPluginError, .splitFileUnsupported)
        }
    }

    func testImportCopiesAGGUFFileAndRemoveDeletesIt() async throws {
        let source = try LlamaCppCatalogTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("My Model Q4.gguf")
        try Data("GGUF-test-weights".utf8).write(to: file)

        let model = try await plugin.importModelFile(file)
        XCTAssertEqual(model.origin, .importedFile)
        XCTAssertEqual(model.displayName, "My Model Q4")
        XCTAssertEqual(model.fileSize, 17)
        XCTAssertTrue(plugin.isModelDownloaded(model))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The original stays where it was")
        XCTAssertEqual(try Data(contentsOf: plugin.weightsURL(for: model)), try Data(contentsOf: file))
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])

        do {
            _ = try await plugin.importModelFile(file)
            XCTFail("Expected duplicate error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .duplicateModel)
        }

        try plugin.removeModel(model)
        XCTAssertTrue(plugin.customModels.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.modelDirectory(for: model).path))
    }

    func testImportRejectsFilesThatAreNotGGUFModels() async throws {
        let source = try LlamaCppCatalogTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let cases: [(String, Data, LlamaCppPluginError)] = [
            ("weights.gguf", Data("NOPE".utf8), .notAGGUFFile),
            ("weights.bin", Data("GGUF".utf8), .notAGGUFFile),
            ("mmproj-audio.gguf", Data("GGUF".utf8), .projectorIsNotAModel),
            ("big-00001-of-00003.gguf", Data("GGUF".utf8), .splitFileUnsupported),
        ]
        for (name, data, expected) in cases {
            let file = source.appendingPathComponent(name)
            try data.write(to: file)
            do {
                _ = try await plugin.importModelFile(file)
                XCTFail("Expected \(expected) for \(name)")
            } catch {
                XCTAssertEqual(error as? LlamaCppPluginError, expected, name)
            }
        }
        XCTAssertTrue(plugin.customModels.isEmpty)
    }

    func testLoadingRespectsAnOrganizationThatRefusesDownloads() async throws {
        host.modelDownloadRefusal = "Your organization does not allow model downloads."
        let model = try XCTUnwrap(LlamaCppModelCatalog.models.first)

        do {
            try await plugin.loadModel(model)
            XCTFail("Expected the download to be refused")
        } catch {
            XCTAssertTrue(error is PluginModelDownloadRefusedError, "\(error)")
        }
        XCTAssertEqual(plugin.modelState, .error("Your organization does not allow model downloads."))
        XCTAssertFalse(plugin.isAvailable)
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugin.runtime.directory.path))
    }

    func testPromptsWithoutALoadedModelExplainWhatToDo() async {
        do {
            _ = try await plugin.process(systemPrompt: "Fix.", userText: "text", model: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .modelNotLoaded)
        }
        do {
            _ = try await plugin.process(systemPrompt: "Fix.", userText: "  \n", model: nil)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? LlamaCppPluginError, .noInputText)
        }
    }

    func testRestoreWithoutAPersistedModelStaysIdle() {
        plugin.triggerRestoreModel()
        XCTAssertEqual(plugin.modelState, .notLoaded)
    }
}

// MARK: - Live check

/// Starts the real `llama-server` with a downloaded GGUF model. Skipped unless
/// `TYPEWHISPER_LLAMACPP_LIVE_RUNTIME` names an extracted llama.cpp build folder and
/// `TYPEWHISPER_LLAMACPP_LIVE_MODEL` a GGUF chat model.
final class LlamaCppLiveServerTests: XCTestCase {
    func testCleansUpADictationWithTheRealServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let runtimePath = environment["TYPEWHISPER_LLAMACPP_LIVE_RUNTIME"],
              let modelPath = environment["TYPEWHISPER_LLAMACPP_LIVE_MODEL"] else {
            throw XCTSkip("Set TYPEWHISPER_LLAMACPP_LIVE_RUNTIME and TYPEWHISPER_LLAMACPP_LIVE_MODEL to run")
        }
        let server = LlamaCppServer()
        defer { server.stop() }
        try await server.start(
            executableURL: URL(fileURLWithPath: runtimePath).appendingPathComponent("llama-server"),
            options: LlamaCppServerLaunchOptions(modelURL: URL(fileURLWithPath: modelPath))
        )
        let session = try XCTUnwrap(server.session)

        let output = try await LlamaCppChatClient.complete(
            LlamaCppChatClient.makeRequest(
                systemPrompt: "Fix punctuation and capitalization of the dictated text. Return only the corrected text.",
                userText: "hello world this is a test",
                temperature: 0
            ),
            session: session
        )
        XCTAssertFalse(LlamaCppPlugin.finalPromptOutput(output).isEmpty)
        XCTAssertFalse(output.contains("<think>"))

        var unauthorized = URLRequest(url: session.baseURL.appending(path: "v1/models"))
        unauthorized.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: unauthorized)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)

        server.stop()
        XCTAssertNil(server.session)
    }
}

/// Runs the whole plugin path with real downloads: llama.cpp from GitHub, a GGUF model from
/// Hugging Face, the server, a prompt, auto-unload and the reload. Skipped unless
/// `TYPEWHISPER_LLAMACPP_LIVE_HF` names a repository with quantization, for example
/// `unsloth/Qwen3-0.6B-GGUF:Q4_K_M`.
@MainActor
final class LlamaCppLiveDownloadTests: XCTestCase {
    func testAddsDownloadsLoadsAndReloadsAHuggingFaceModel() async throws {
        guard let input = ProcessInfo.processInfo.environment["TYPEWHISPER_LLAMACPP_LIVE_HF"] else {
            throw XCTSkip("Set TYPEWHISPER_LLAMACPP_LIVE_HF to run")
        }
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = LlamaCppPlugin()
        plugin.activate(host: host)
        defer {
            plugin.deactivate()
            host.cleanup()
        }

        let lookup = try await plugin.lookUpHuggingFaceModels(input)
        let path = try XCTUnwrap(lookup.preselectedPath)
        let file = try XCTUnwrap(lookup.models.first { $0.path == path })
        let model = try plugin.addHuggingFaceModel(file)

        try await plugin.loadModel(model)
        XCTAssertEqual(plugin.modelState, .ready(model.id))
        XCTAssertTrue(plugin.isAvailable)
        XCTAssertTrue(plugin.runtime.isInstalled)
        XCTAssertTrue(plugin.isModelDownloaded(model))
        XCTAssertEqual(plugin.supportedModels.map(\.id), [model.id])

        let output = try await plugin.process(
            systemPrompt: "Fix punctuation and capitalization of the dictated text. Return only the corrected text.",
            userText: "hello world this is a test",
            model: nil
        )
        XCTAssertFalse(output.isEmpty)
        XCTAssertFalse(output.contains("<think>"), output)

        plugin.triggerAutoUnload()
        XCTAssertFalse(plugin.isAvailable)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, model.id)

        plugin.triggerRestoreModel()
        XCTAssertEqual(plugin.modelState, .loading, "Restoring needs no download")
        for _ in 0..<600 where !plugin.isAvailable {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(plugin.isAvailable)
    }
}
