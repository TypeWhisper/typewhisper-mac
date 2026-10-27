import CryptoKit
import Foundation

/// A llama.cpp release build from github.com/ggml-org/llama.cpp.
///
/// Raising the runtime means replacing `pinned` with the new build tag, archive size and
/// SHA-256. The download URL, the install directory and the cleanup of older builds all
/// derive from it, so a new build installs next to the old one and replaces it only after
/// it was verified and extracted.
struct LlamaCppRuntimeRelease: Equatable, Sendable {
    /// Release tag, for example `b11669`.
    let build: String
    /// Version reported by `llama-server --version`, shown in the settings.
    let version: String
    let archiveSize: Int64
    let archiveSHA256: String

    /// llama.cpp v0.7.0 (build b11669, macOS arm64 with Metal).
    static let pinned = LlamaCppRuntimeRelease(
        build: "b11669",
        version: "0.7.0",
        archiveSize: 12_191_582,
        archiveSHA256: "dbed55493d72bc1ba2babc8770d669c2289b5bc4ee9fb2a4dfc158d45b7d13fd"
    )

    var archiveName: String { "llama-\(build)-bin-macos-arm64.tar.gz" }

    var archiveURL: URL {
        URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(build)/\(archiveName)")!
    }

    /// The top-level directory inside the release archive.
    var archiveRootName: String { "llama-\(build)" }
}

/// The runtime in the plugin data directory: `Runtime/llama-<build>/llama-server` plus the
/// dylibs it loads through `@loader_path`.
struct LlamaCppRuntimeInstallation: Sendable {
    static let serverExecutableName = "llama-server"
    static let licenseFileName = "LICENSE"
    private static let markerFileName = ".typewhisper-installed"

    let runtimesDirectory: URL
    let release: LlamaCppRuntimeRelease

    init(runtimesDirectory: URL, release: LlamaCppRuntimeRelease = .pinned) {
        self.runtimesDirectory = runtimesDirectory
        self.release = release
    }

    var directory: URL {
        runtimesDirectory.appendingPathComponent(release.archiveRootName, isDirectory: true)
    }

    var serverExecutableURL: URL {
        directory.appendingPathComponent(Self.serverExecutableName)
    }

    private var markerURL: URL {
        directory.appendingPathComponent(Self.markerFileName)
    }

    /// Installed when the marker written after a verified extraction names this archive.
    var isInstalled: Bool {
        guard LlamaCppFileChecks.isNonEmptyFile(serverExecutableURL),
              let marker = try? String(contentsOf: markerURL, encoding: .utf8) else {
            return false
        }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == release.archiveSHA256
    }

    /// Bytes the installation still has to download.
    var missingDownloadBytes: Int64 {
        isInstalled ? 0 : release.archiveSize
    }

    /// Downloads, verifies and extracts the pinned archive, then removes other builds.
    func install(
        session: URLSession,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        if isInstalled {
            removeOtherBuilds()
            progressHandler(1)
            return
        }
        try FileManager.default.createDirectory(at: runtimesDirectory, withIntermediateDirectories: true)
        removeInterruptedInstallFiles()

        let (temporaryArchive, response) = try await session.download(from: release.archiveURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporaryArchive)
            throw LlamaCppPluginError.runtimeDownloadFailed
        }
        let ownedArchive = runtimesDirectory.appendingPathComponent(
            ".download-\(UUID().uuidString)-\(release.archiveName)"
        )
        try FileManager.default.moveItem(at: temporaryArchive, to: ownedArchive)
        defer { try? FileManager.default.removeItem(at: ownedArchive) }
        progressHandler(0.7)

        do {
            try await LlamaCppFileChecks.verify(
                ownedArchive,
                expectedSize: release.archiveSize,
                expectedSHA256: release.archiveSHA256
            )
        } catch LlamaCppPluginError.verificationFailed {
            throw LlamaCppPluginError.verificationFailed(release.archiveName)
        }
        progressHandler(0.8)

        let stagingDirectory = runtimesDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        try await Self.extract(ownedArchive, to: stagingDirectory)

        let extractedDirectory = stagingDirectory.appendingPathComponent(release.archiveRootName, isDirectory: true)
        let extractedServer = extractedDirectory.appendingPathComponent(Self.serverExecutableName)
        guard LlamaCppFileChecks.isNonEmptyFile(extractedServer) else {
            throw LlamaCppPluginError.invalidRuntimeArchive
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extractedServer.path)
        try release.archiveSHA256.write(
            to: extractedDirectory.appendingPathComponent(Self.markerFileName),
            atomically: true,
            encoding: .utf8
        )

        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.moveItem(at: extractedDirectory, to: directory)
        removeOtherBuilds()
        progressHandler(1)
    }

    /// Deletes runtimes of other builds, for example the previous pin after an update.
    func removeOtherBuilds() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("llama-") && entry.lastPathComponent != release.archiveRootName {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Removes archives and staging folders that an interrupted install left behind.
    func removeInterruptedInstallFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runtimesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries
        where entry.lastPathComponent.hasPrefix(".download-") || entry.lastPathComponent.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func extract(_ archive: URL, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xzf", archive.path, "-C", destination.path]
                process.standardOutput = FileHandle.nullDevice
                let errorPipe = Pipe()
                process.standardError = errorPipe
                do {
                    try process.run()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorData, encoding: .utf8) ?? "tar failed"
                        continuation.resume(throwing: LlamaCppPluginError.runtimeExtractionFailed(message))
                        return
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum LlamaCppFileChecks {
    static func isNonEmptyFile(_ url: URL) -> Bool {
        fileSize(of: url).map { $0 > 0 } ?? false
    }

    static func fileSize(of url: URL) -> Int64? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Checks size and SHA-256 off the calling executor; multi-gigabyte models take seconds.
    static func verify(_ file: URL, expectedSize: Int64, expectedSHA256: String) async throws {
        try await Task.detached(priority: .utility) {
            guard fileSize(of: file) == expectedSize else {
                throw LlamaCppPluginError.verificationFailed(file.lastPathComponent)
            }
            guard try sha256(of: file) == expectedSHA256.lowercased() else {
                throw LlamaCppPluginError.verificationFailed(file.lastPathComponent)
            }
        }.value
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the file starts with the GGUF magic bytes.
    static func hasGGUFHeader(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}
