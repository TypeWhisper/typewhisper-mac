import CryptoKit
import Foundation
import HuggingFace
import TypeWhisperPluginSDK

struct CohereLocalModelAssets: Sendable {
    static let modelRepositoryId = "cstr/cohere-transcribe-03-2026-GGUF"
    static let modelRevision = "2242638d5dfecc6f1dbe6c3a8713b97deb2e150f"

    static let vadRepositoryId = "ggml-org/whisper-vad"
    static let vadRevision = "9ffd54a1e1ee413ddf265af9913beaf518d1639b"
    static let vadFileName = "ggml-silero-v6.2.0.bin"
    static let vadSize = Int64(885_098)
    static let vadSHA256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

    static let crispAsrVersion = "0.8.24"
    static let runtimeArchiveName = "crispasr-macos.tar.gz"
    static let runtimeArchiveSize = Int64(15_656_391)
    static let runtimeArchiveSHA256 = "78397afd5aef2dbd6fa73f8d60800dd4d5725589fb4b04800efd2fb3ff88930c"
    static let runtimeArchiveURL = URL(
        string: "https://github.com/CrispStrobe/CrispASR/releases/download/v\(crispAsrVersion)/\(runtimeArchiveName)"
    )!

    static let sharedRequiredRelativePaths = [
        "Auxiliary/\(vadFileName)",
        "Runtime/crispasr-macos/crispasr",
        "Runtime/crispasr-macos/libc2pa_c.dylib",
    ]
    static let sharedDirectoryName = "cohere-transcribe-03-2026"
    static let legacySharedDirectoryName = "cohere-transcribe-03-2026-q5_0"

    let pluginDataDirectory: URL
    let model: CohereLocalModelDefinition

    var modelsRootDirectory: URL {
        pluginDataDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    var rootDirectory: URL {
        modelsRootDirectory.appendingPathComponent(
            Self.sharedDirectoryName,
            isDirectory: true
        )
    }

    var legacyRootDirectory: URL {
        modelsRootDirectory.appendingPathComponent(
            Self.legacySharedDirectoryName,
            isDirectory: true
        )
    }

    var modelFileURL: URL {
        rootDirectory.appendingPathComponent(model.fileName)
    }

    var auxiliaryDirectory: URL {
        rootDirectory.appendingPathComponent("Auxiliary", isDirectory: true)
    }

    var vadModelURL: URL {
        auxiliaryDirectory.appendingPathComponent(Self.vadFileName)
    }

    var runtimeRootDirectory: URL {
        rootDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    var runtimeDirectory: URL {
        runtimeRootDirectory.appendingPathComponent("crispasr-macos", isDirectory: true)
    }

    var runtimeExecutableURL: URL {
        runtimeDirectory.appendingPathComponent("crispasr")
    }

    var runtimeLibraryURL: URL {
        runtimeDirectory.appendingPathComponent("libc2pa_c.dylib")
    }

    var cacheDirectory: URL {
        rootDirectory.appendingPathComponent("Cache", isDirectory: true)
    }

    var isInstalled: Bool {
        migrateLegacyRootIfNeeded()
        return ([model.fileName] + Self.sharedRequiredRelativePaths).allSatisfy { relativePath in
            let url = rootDirectory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                return false
            }
            return size.int64Value > 0
        }
    }

    func download(
        bearerToken: String? = nil,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        migrateLegacyRootIfNeeded()
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )

        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        let client = HubClient(
            session: session,
            host: HubClient.defaultHost,
            userAgent: "TypeWhisper-CohereLocal/0.1.0",
            bearerToken: PluginHuggingFaceTokenHelper.normalizedToken(bearerToken),
            cache: nil
        )

        if !isNonEmptyFile(modelFileURL) {
            guard let repositoryId = Repo.ID(rawValue: Self.modelRepositoryId) else {
                throw CohereLocalPluginError.invalidRepositoryIdentifier
            }
            _ = try await client.downloadSnapshot(
                of: repositoryId,
                to: rootDirectory,
                revision: Self.modelRevision,
                matching: [model.fileName],
                maxConcurrentDownloads: 1,
                progressHandler: { @MainActor progress in
                    progressHandler(progress.fractionCompleted * 0.98)
                }
            )
        }
        try verifyOrDiscard(
            modelFileURL,
            expectedSize: model.fileSize,
            expectedSHA256: model.sha256
        )
        progressHandler(0.98)

        if !isNonEmptyFile(vadModelURL) {
            guard let repositoryId = Repo.ID(rawValue: Self.vadRepositoryId) else {
                throw CohereLocalPluginError.invalidRepositoryIdentifier
            }
            try FileManager.default.createDirectory(
                at: auxiliaryDirectory,
                withIntermediateDirectories: true
            )
            _ = try await client.downloadSnapshot(
                of: repositoryId,
                to: auxiliaryDirectory,
                revision: Self.vadRevision,
                matching: [Self.vadFileName],
                maxConcurrentDownloads: 1
            )
        }
        try verifyOrDiscard(
            vadModelURL,
            expectedSize: Self.vadSize,
            expectedSHA256: Self.vadSHA256
        )
        progressHandler(0.99)

        if !isRuntimeInstalled {
            try await downloadAndInstallRuntime(using: session)
        }
        progressHandler(1)

        guard isInstalled else {
            throw CohereLocalPluginError.incompleteModelDownload
        }
    }

    func deleteModelFiles(allModels: [CohereLocalModelDefinition]) throws {
        migrateLegacyRootIfNeeded()
        if FileManager.default.fileExists(atPath: modelFileURL.path) {
            try FileManager.default.removeItem(at: modelFileURL)
        }

        let hasAnotherModel = allModels.contains { candidate in
            candidate.id != model.id
                && isNonEmptyFile(rootDirectory.appendingPathComponent(candidate.fileName))
        }
        if !hasAnotherModel, FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }

    private var isRuntimeInstalled: Bool {
        isNonEmptyFile(runtimeExecutableURL) && isNonEmptyFile(runtimeLibraryURL)
    }

    private func downloadAndInstallRuntime(using session: URLSession) async throws {
        let (temporaryArchive, response) = try await session.download(
            from: Self.runtimeArchiveURL
        )
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CohereLocalPluginError.runtimeDownloadFailed
        }

        try FileManager.default.createDirectory(
            at: runtimeRootDirectory,
            withIntermediateDirectories: true
        )
        let ownedArchive = runtimeRootDirectory.appendingPathComponent(
            ".download-\(UUID().uuidString)-\(Self.runtimeArchiveName)"
        )
        try FileManager.default.moveItem(at: temporaryArchive, to: ownedArchive)
        defer { try? FileManager.default.removeItem(at: ownedArchive) }

        try verify(
            ownedArchive,
            expectedSize: Self.runtimeArchiveSize,
            expectedSHA256: Self.runtimeArchiveSHA256
        )

        let stagingDirectory = runtimeRootDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        try await extractRuntimeArchive(
            ownedArchive,
            to: stagingDirectory
        )

        let extractedDirectory = stagingDirectory.appendingPathComponent(
            "crispasr-macos",
            isDirectory: true
        )
        let extractedExecutable = extractedDirectory.appendingPathComponent("crispasr")
        let extractedLibrary = extractedDirectory.appendingPathComponent("libc2pa_c.dylib")
        guard isNonEmptyFile(extractedExecutable), isNonEmptyFile(extractedLibrary) else {
            throw CohereLocalPluginError.invalidRuntimeArchive
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: extractedExecutable.path
        )
        if FileManager.default.fileExists(atPath: runtimeDirectory.path) {
            try FileManager.default.removeItem(at: runtimeDirectory)
        }
        try FileManager.default.moveItem(
            at: extractedDirectory,
            to: runtimeDirectory
        )
    }

    private func extractRuntimeArchive(_ archive: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = [
                    "-xzf",
                    archive.path,
                    "-C",
                    destination.path,
                ]
                process.standardOutput = FileHandle.nullDevice
                let errorPipe = Pipe()
                process.standardError = errorPipe

                do {
                    try process.run()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorData, encoding: .utf8)
                            ?? "Unknown tar error"
                        continuation.resume(
                            throwing: CohereLocalPluginError.runtimeExtractionFailed(message)
                        )
                        return
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func verifyOrDiscard(
        _ file: URL,
        expectedSize: Int64,
        expectedSHA256: String
    ) throws {
        do {
            try verify(
                file,
                expectedSize: expectedSize,
                expectedSHA256: expectedSHA256
            )
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private func verify(
        _ file: URL,
        expectedSize: Int64,
        expectedSHA256: String
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value == expectedSize else {
            throw CohereLocalPluginError.assetVerificationFailed(file.lastPathComponent)
        }
        guard try sha256(of: file) == expectedSHA256 else {
            throw CohereLocalPluginError.assetVerificationFailed(file.lastPathComponent)
        }
    }

    private func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isNonEmptyFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private func migrateLegacyRootIfNeeded() {
        guard !FileManager.default.fileExists(atPath: rootDirectory.path),
              FileManager.default.fileExists(atPath: legacyRootDirectory.path) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: modelsRootDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.moveItem(
            at: legacyRootDirectory,
            to: rootDirectory
        )
    }
}
