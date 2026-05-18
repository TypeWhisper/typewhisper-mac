import Foundation
import TypeWhisperPluginSDK

enum SupertonicModelLicense {
    static let id = "Supertone/supertonic-3"
    static let revision = "openrail-m-2022-08-18"
    static let licenseName = "OpenRAIL-M"
    static let url = URL(string: "https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE")!
}

enum SupertonicPluginError: LocalizedError, Equatable {
    case notConfigured
    case licenseNotAccepted
    case incompleteModelAssets
    case invalidDownloadResponse
    case playbackUnavailable
    case emptyText

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supertonic model assets are not downloaded."
        case .licenseNotAccepted:
            return "Accept the Supertonic 3 model license before downloading model assets."
        case .incompleteModelAssets:
            return "The downloaded Supertonic model cache is incomplete."
        case .invalidDownloadResponse:
            return "Supertonic model download returned an invalid response."
        case .playbackUnavailable:
            return "Supertonic audio playback could not be started."
        case .emptyText:
            return "TTS text is empty."
        }
    }
}

struct SupertonicLanguageResolver {
    static let supportedLanguageCodes: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es",
        "et", "fi", "fr", "hi", "hr", "hu", "id", "it", "lt", "lv",
        "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]

    static func normalizedLanguageCode(for language: String?) -> String {
        guard let language else { return "en" }
        let primary = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)

        guard let primary, supportedLanguageCodes.contains(primary) else {
            return "en"
        }
        return primary
    }
}

struct SupertonicModelAssetManager: Sendable {
    static let repositoryId = "Supertone/supertonic-3"
    static let modelSubdirectory = "models/supertonic-3"
    static let requiredRelativePaths = [
        "onnx/tts.json",
        "onnx/unicode_indexer.json",
        "onnx/duration_predictor.onnx",
        "onnx/text_encoder.onnx",
        "onnx/vector_estimator.onnx",
        "onnx/vocoder.onnx",
        "voice_styles/M1.json",
        "voice_styles/F1.json",
    ]

    let rootDirectory: URL

    var modelDirectory: URL {
        rootDirectory.appendingPathComponent(Self.modelSubdirectory, isDirectory: true)
    }

    var onnxDirectory: URL {
        modelDirectory.appendingPathComponent("onnx", isDirectory: true)
    }

    var voiceStylesDirectory: URL {
        modelDirectory.appendingPathComponent("voice_styles", isDirectory: true)
    }

    func hasDownloadedModel() -> Bool {
        Self.requiredRelativePaths.allSatisfy { relativePath in
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent(relativePath).path)
        }
    }

    func availableVoices() -> [PluginVoiceInfo] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: voiceStylesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return Self.defaultVoices
        }

        let voices = contents
            .filter { $0.pathExtension == "json" }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                return PluginVoiceInfo(id: id, displayName: id)
            }
            .sorted { (lhs: PluginVoiceInfo, rhs: PluginVoiceInfo) in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        return voices.isEmpty ? Self.defaultVoices : voices
    }

    func install(files: [String: Data], licenseAccepted: Bool) throws {
        guard licenseAccepted else { throw SupertonicPluginError.licenseNotAccepted }
        guard Self.requiredRelativePaths.allSatisfy({ files[$0] != nil }) else {
            throw SupertonicPluginError.incompleteModelAssets
        }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let stagingDirectory = rootDirectory.appendingPathComponent(
            ".supertonic-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            for (relativePath, data) in files {
                guard Self.isSafeRelativePath(relativePath) else {
                    throw SupertonicPluginError.invalidDownloadResponse
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
                throw SupertonicPluginError.incompleteModelAssets
            }

            try replaceModelDirectory(with: stagingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func download(
        token: String?,
        licenseAccepted: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard licenseAccepted else { throw SupertonicPluginError.licenseNotAccepted }
        let paths = try await remoteAssetPaths(token: token)
        guard !paths.isEmpty else { throw SupertonicPluginError.incompleteModelAssets }

        var files: [String: Data] = [:]
        for (index, path) in paths.enumerated() {
            files[path] = try await fetchData(path: path, token: token)
            progress(Double(index + 1) / Double(paths.count))
        }
        try install(files: files, licenseAccepted: true)
    }

    func deleteModelFiles() throws {
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            try FileManager.default.removeItem(at: modelDirectory)
        }
    }

    private func remoteAssetPaths(token: String?) async throws -> [String] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(Self.repositoryId)/tree/main")
        components?.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = components?.url else { throw SupertonicPluginError.invalidDownloadResponse }

        var request = URLRequest(url: url)
        if let token = PluginHuggingFaceTokenHelper.normalizedToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SupertonicPluginError.invalidDownloadResponse
        }

        let entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data)
        let paths = entries
            .map(\.path)
            .filter { $0.hasPrefix("onnx/") || ($0.hasPrefix("voice_styles/") && $0.hasSuffix(".json")) }
            .filter(Self.isSafeRelativePath)
            .sorted()

        guard Self.requiredRelativePaths.allSatisfy({ paths.contains($0) }) else {
            throw SupertonicPluginError.incompleteModelAssets
        }
        return paths
    }

    private func fetchData(path: String, token: String?) async throws -> Data {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/\(Self.repositoryId)/resolve/main/\(encodedPath)") else {
            throw SupertonicPluginError.invalidDownloadResponse
        }

        var request = URLRequest(url: url)
        if let token = PluginHuggingFaceTokenHelper.normalizedToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SupertonicPluginError.invalidDownloadResponse
        }
        return data
    }

    private func replaceModelDirectory(with stagingDirectory: URL) throws {
        let finalDirectory = modelDirectory
        let finalParent = finalDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: finalParent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: finalDirectory.path) {
            let backupDirectory = rootDirectory.appendingPathComponent(
                ".supertonic-backup-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: finalDirectory, to: backupDirectory)
            do {
                try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
                try? FileManager.default.removeItem(at: backupDirectory)
            } catch {
                try? FileManager.default.moveItem(at: backupDirectory, to: finalDirectory)
                throw error
            }
        } else {
            try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }

    private static var defaultVoices: [PluginVoiceInfo] {
        ["M1", "M2", "M3", "M4", "M5", "F1", "F2", "F3", "F4", "F5"]
            .map { PluginVoiceInfo(id: $0, displayName: $0) }
    }
}

private struct HuggingFaceTreeEntry: Decodable {
    let path: String
}
