import Foundation
import TypeWhisperPluginSDK

enum SenseVoiceModelLicense {
    static let id = "FunAudioLLM/SenseVoiceSmall"
    static let revision = "model-license-2024-07-17"
    static let licenseName = "SenseVoiceSmall model license"
    static let url = URL(string: "https://huggingface.co/FunAudioLLM/SenseVoiceSmall/blob/main/model-license")!
}

enum SenseVoicePluginError: LocalizedError, Equatable {
    case notConfigured
    case licenseNotAccepted
    case runtimeUnavailable
    case incompleteModelAssets
    case invalidDownloadResponse
    case invalidArchive
    case unsupportedTranslation
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "SenseVoice model assets are not downloaded."
        case .licenseNotAccepted:
            "Accept the SenseVoiceSmall model license before downloading model assets."
        case .runtimeUnavailable:
            "Sherpa-ONNX runtime is not available for SenseVoice."
        case .incompleteModelAssets:
            "The downloaded SenseVoice model cache is incomplete."
        case .invalidDownloadResponse:
            "SenseVoice model download returned an invalid response."
        case .invalidArchive:
            "SenseVoice model archive could not be extracted."
        case .unsupportedTranslation:
            "SenseVoice does not support translation."
        case .transcriptionFailed(let detail):
            "SenseVoice transcription failed: \(detail)"
        }
    }
}

struct SenseVoiceLanguageResolver {
    static let supportedLanguageCodes = ["zh", "en", "ja", "ko", "yue"]

    static func runtimeLanguage(for language: String?) -> String {
        guard let language else { return "auto" }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)

        guard let normalized else { return "auto" }
        return supportedLanguageCodes.contains(normalized) ? normalized : "auto"
    }
}

struct SenseVoiceModelAssetManager: Sendable {
    static let modelId = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
    static let displayName = "SenseVoice Small int8"
    static let sizeDescription = "~155 MB"
    static let releaseURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelId).tar.bz2"
    )!

    static let modelSubdirectory = "models/sensevoice/\(modelId)"
    static let requiredRelativePaths = [
        "model.int8.onnx",
        "tokens.txt",
    ]

    let rootDirectory: URL

    var modelDirectory: URL {
        rootDirectory.appendingPathComponent(Self.modelSubdirectory, isDirectory: true)
    }

    var archiveName: String {
        Self.modelId + ".tar.bz2"
    }

    func hasDownloadedModel() -> Bool {
        Self.requiredRelativePaths.allSatisfy { relativePath in
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(relativePath).path)
        }
    }

    func deleteModelFiles() throws {
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
    }

    func install(files: [String: Data], licenseAccepted: Bool) throws {
        guard licenseAccepted else { throw SenseVoicePluginError.licenseNotAccepted }
        guard Self.requiredRelativePaths.allSatisfy({ files[$0] != nil }) else {
            throw SenseVoicePluginError.incompleteModelAssets
        }

        let stagingDirectory = rootDirectory.appendingPathComponent(
            ".sensevoice-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            for (relativePath, data) in files {
                guard Self.isSafeRelativePath(relativePath) else {
                    throw SenseVoicePluginError.invalidDownloadResponse
                }
                let destination = stagingDirectory.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
            }

            guard Self.requiredRelativePaths.allSatisfy({
                FileManager.default.fileExists(atPath: stagingDirectory.appendingPathComponent($0).path)
            }) else {
                throw SenseVoicePluginError.incompleteModelAssets
            }

            try replaceModelDirectory(with: stagingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func download(
        licenseAccepted: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard licenseAccepted else { throw SenseVoicePluginError.licenseNotAccepted }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let temporaryDirectory = rootDirectory.appendingPathComponent(
            ".sensevoice-download-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let archiveURL = try await downloadArchive(to: temporaryDirectory, progress: progress)
        progress(0.75)

        let extractedDirectory = try extractArchive(archiveURL, into: temporaryDirectory)
        progress(0.90)

        guard Self.requiredRelativePaths.allSatisfy({
            FileManager.default.fileExists(atPath: extractedDirectory.appendingPathComponent($0).path)
        }) else {
            throw SenseVoicePluginError.incompleteModelAssets
        }

        try replaceModelDirectory(with: extractedDirectory)
        progress(1.0)
    }

    private func downloadArchive(
        to temporaryDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: Self.releaseURL)
        request.timeoutInterval = 600

        progress(0.05)
        let (temporaryFile, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SenseVoicePluginError.invalidDownloadResponse
        }

        let archiveURL = temporaryDirectory.appendingPathComponent(archiveName)
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }
        try FileManager.default.moveItem(at: temporaryFile, to: archiveURL)
        progress(0.70)
        return archiveURL
    }

    private func extractArchive(_ archiveURL: URL, into temporaryDirectory: URL) throws -> URL {
        let extractionDirectory = temporaryDirectory.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["xjf", archiveURL.path, "-C", extractionDirectory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SenseVoicePluginError.invalidArchive
        }

        let extractedRoot = extractionDirectory.appendingPathComponent(Self.modelId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extractedRoot.path) else {
            throw SenseVoicePluginError.invalidArchive
        }
        return extractedRoot
    }

    private func replaceModelDirectory(with stagingDirectory: URL) throws {
        let destination = modelDirectory
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagingDirectory, to: destination)
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("..") else {
            return false
        }
        return path.split(separator: "/").allSatisfy { !$0.isEmpty }
    }
}
