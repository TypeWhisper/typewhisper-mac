import Foundation

/// Optional capability; existing transcription engines remain binary compatible.
public protocol PluginCustomModelImporting: TranscriptionEnginePlugin {
    var supportedImportModelTypes: Set<String> { get }
    @MainActor func importModel(_ candidate: PluginModelImportCandidate, token: String?) async throws -> PluginModelInfo
}

public enum PluginModelImportError: LocalizedError, Equatable {
    case invalidSource
    case invalidModel(String)
    case unsupportedArchitecture(String)
    case missingEngine(String)
    case duplicate
    case http(Int)
    case busy

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return String(localized: "Choose a model folder or enter a Hugging Face model URL (https://huggingface.co/owner/model).")
        case .invalidModel(let detail):
            return String(localized: "This model cannot be imported: \(detail)")
        case .unsupportedArchitecture(let type):
            return String(localized: "The model architecture ‘\(type)’ is not supported by the installed engines. Importing its files cannot add a new engine.")
        case .missingEngine(let name):
            return String(localized: "Install or enable the \(name) plugin in Integrations to import this model.")
        case .duplicate:
            return String(localized: "This model has already been imported.")
        case .http(let status):
            return String(localized: "Hugging Face returned HTTP \(status). For private or gated models, provide a token with access to the model.")
        case .busy:
            return String(localized: "A model operation is already in progress. Wait for it to finish.")
        }
    }
}

public enum PluginModelImportSource: Sendable, Equatable {
    case folder(URL)
    case huggingFace(String)

    public static func huggingFaceInput(_ input: String) throws -> Self {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository: String
        if input.contains("://") {
            guard let url = URLComponents(string: input), url.scheme == "https",
                  url.host == "huggingface.co", url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, url.fragment == nil else {
                throw PluginModelImportError.invalidSource
            }
            repository = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            repository = input
        }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".."
                && part.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        }) else { throw PluginModelImportError.invalidSource }
        return .huggingFace(repository)
    }
}

/// A lightweight inspection performed before downloading any weights.
public struct PluginModelImportCandidate: Sendable {
    public let source: PluginModelImportSource
    public let modelType: String
    public let displayName: String
    public let revision: String?
    let files: [String]

    public var suggestedPluginName: String? {
        switch modelType {
        case "canary": "Canary ASR"
        case "qwen3_asr": "Qwen3 ASR"
        case "granite_speech": "Granite Speech"
        case "voxtral_realtime": "Voxtral"
        default: nil
        }
    }

    public static func inspect(
        _ source: PluginModelImportSource,
        token: String? = nil,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async throws -> Self {
        switch source {
        case .folder(let folder):
            guard folder.isFileURL else { throw PluginModelImportError.invalidSource }
            let config = try readConfig(in: folder)
            return Self(source: source, modelType: try modelType(config),
                        displayName: folder.lastPathComponent, revision: nil, files: [])
        case .huggingFace(let repository):
            guard try PluginModelImportSource.huggingFaceInput(repository) == source else {
                throw PluginModelImportError.invalidSource
            }
            let (metadata, response) = try await fetch(request("https://huggingface.co/api/models/\(repository)", token: token))
            try checkResponse(response)
            struct Repository: Decodable {
                struct File: Decodable { let rfilename: String }
                let sha: String
                let siblings: [File]
            }
            let repo = try JSONDecoder().decode(Repository.self, from: metadata)
            guard repo.sha.range(of: #"^[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil else {
                throw PluginModelImportError.invalidModel("Invalid repository revision")
            }
            let (config, configResponse) = try await fetch(request(
                "https://huggingface.co/\(repository)/resolve/\(repo.sha)/config.json", token: token
            ))
            try checkResponse(configResponse)
            return Self(source: source, modelType: try modelType(config),
                        displayName: repository.split(separator: "/").last.map(String.init) ?? repository,
                        revision: repo.sha, files: repo.siblings.map(\.rfilename))
        }
    }

    static func readConfig(in directory: URL) throws -> Data {
        let url = directory.appendingPathComponent("config.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 4 * 1024 * 1024 else {
            throw PluginModelImportError.invalidModel("Missing or invalid config.json")
        }
        return try Data(contentsOf: url)
    }

    static func modelType(_ config: Data) throws -> String {
        guard config.count <= 4 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let type = json["model_type"] as? String, !type.isEmpty else {
            throw PluginModelImportError.invalidModel("config.json must declare model_type")
        }
        return type
    }

    static func request(_ url: String, token: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 60
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func checkResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else { throw PluginModelImportError.http(response.statusCode) }
    }
}

@_spi(FirstPartyPlugins)
public struct PluginCustomModelStore: Sendable {
    public struct Model: Codable, Sendable, Identifiable {
        public let id: String
        public let displayName: String
        public let modelType: String
        public let origin: String
        public let revision: String?
        public let bytes: Int64

        public var sizeDescription: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    public let directory: URL
    private static let metadataName = "typewhisper-import.json"
    // Only data files consumed by local engines. Never import or execute repository code.
    private static let extensions: Set<String> = ["safetensors", "json", "txt", "model", "tiktoken", "wav"]

    public init(directory: URL) { self.directory = directory }

    public func models() -> [Model] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.compactMap { child in
            guard Self.isModelID(child.lastPathComponent),
                  let data = try? Data(contentsOf: child.appendingPathComponent(Self.metadataName)),
                  let model = try? JSONDecoder().decode(Model.self, from: data),
                  model.id == child.lastPathComponent else { return nil }
            return model
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func modelDirectory(for id: String) -> URL? {
        guard Self.isModelID(id) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: true)
    }

    public func remove(_ id: String) throws {
        guard let path = modelDirectory(for: id) else { throw PluginModelImportError.invalidSource }
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    /// Stage a private copy and publish its metadata only when all required files are present.
    public func add(
        _ candidate: PluginModelImportCandidate,
        supportedTypes: Set<String>,
        requirements: PluginHuggingFaceModelStore.Requirements,
        token: String? = nil,
        download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse) = { request in
            try await URLSession.shared.download(for: request)
        }
    ) async throws -> Model {
        guard supportedTypes.contains(candidate.modelType) else {
            throw PluginModelImportError.unsupportedArchitecture(candidate.modelType)
        }
        let origin: String
        switch candidate.source {
        case .folder(let url): origin = url.resolvingSymlinksInPath().path
        case .huggingFace(let repo): origin = "https://huggingface.co/\(repo)"
        }
        guard !models().contains(where: { $0.origin == origin && $0.revision == candidate.revision }) else {
            throw PluginModelImportError.duplicate
        }
        let id = "custom-" + UUID().uuidString.lowercased()
        let staging = directory.appendingPathComponent(".import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        switch candidate.source {
        case .folder(let source):
            try copyModelFiles(from: source, to: staging)
        case .huggingFace(let repo):
            guard let revision = candidate.revision else { throw PluginModelImportError.invalidSource }
            for file in candidate.files where Self.isImportableFile(file) {
                try Task.checkCancellation()
                let (temporary, response) = try await download(PluginModelImportCandidate.request(
                    "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)", token: token
                ))
                defer { try? FileManager.default.removeItem(at: temporary) }
                try PluginModelImportCandidate.checkResponse(response)
                try FileManager.default.moveItem(at: temporary, to: staging.appendingPathComponent(file))
            }
        }
        try Task.checkCancellation()
        let type = try PluginModelImportCandidate.modelType(PluginModelImportCandidate.readConfig(in: staging))
        guard type == candidate.modelType, supportedTypes.contains(type) else {
            throw PluginModelImportError.unsupportedArchitecture(type)
        }
        try validateFiles(in: staging, requirements: requirements)
        let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        let model = Model(id: id, displayName: candidate.displayName, modelType: type,
                          origin: origin, revision: candidate.revision, bytes: bytes)
        try JSONEncoder().encode(model).write(to: staging.appendingPathComponent(Self.metadataName), options: .atomic)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: directory.appendingPathComponent(id))
        return model
    }

    private static func isModelID(_ id: String) -> Bool {
        id.hasPrefix("custom-") && UUID(uuidString: String(id.dropFirst(7))) != nil
    }

    private static func isImportableFile(_ name: String) -> Bool {
        // Loaders use files at the snapshot root. Do not follow arbitrary paths from repository metadata.
        !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
            && name != metadataName
            && name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
            && extensions.contains((name as NSString).pathExtension.lowercased())
    }

    private func copyModelFiles(from source: URL, to destination: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey]) {
            try Task.checkCancellation()
            guard Self.isImportableFile(file.lastPathComponent) else { continue }
            // Hugging Face snapshots commonly symlink files into their blob cache. Copy the resolved file.
            let resolved = file.resolvingSymlinksInPath()
            guard try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try FileManager.default.copyItem(at: resolved, to: destination.appendingPathComponent(file.lastPathComponent))
        }
    }

    private func validateFiles(in folder: URL, requirements: PluginHuggingFaceModelStore.Requirements) throws {
        guard PluginHuggingFaceModelStore(modelsDirectory: folder).isUsableModelDirectory(folder, requirements: requirements) else {
            throw PluginModelImportError.invalidModel("Missing model weights or tokenizer files")
        }
        let index = folder.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            struct Index: Decodable { let weight_map: [String: String] }
            let shards = try JSONDecoder().decode(Index.self, from: Data(contentsOf: index)).weight_map.values
            for shard in Set(shards) {
                guard Self.isImportableFile(shard), shard.hasSuffix(".safetensors"),
                      FileManager.default.fileExists(atPath: folder.appendingPathComponent(shard).path) else {
                    throw PluginModelImportError.invalidModel("Missing weight shard: \(shard)")
                }
            }
        }
        // Catch Git LFS pointer files and truncated downloads before they reach the MLX loader.
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            where file.pathExtension == "safetensors" {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            guard prefix.count == 8 else { throw PluginModelImportError.invalidModel("Invalid safetensors file") }
            let length = prefix.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard length > 0, length <= 16 * 1024 * 1024, length < UInt64(max(0, size - 8)),
                  let header = try handle.read(upToCount: Int(length)), header.count == Int(length),
                  let tensors = (try? JSONSerialization.jsonObject(with: header)) as? [String: Any] else {
                throw PluginModelImportError.invalidModel("Invalid or incomplete safetensors file: \(file.lastPathComponent)")
            }
            let payloadSize = size - 8 - Int(length)
            let weights = tensors.filter { $0.key != "__metadata__" }
            guard !weights.isEmpty, weights.values.allSatisfy({ value in
                guard let tensor = value as? [String: Any],
                      let offsets = tensor["data_offsets"] as? [Int], offsets.count == 2 else { return false }
                return offsets[0] >= 0 && offsets[1] >= offsets[0] && offsets[1] <= payloadSize
            }) else {
                throw PluginModelImportError.invalidModel("Invalid or truncated tensor data: \(file.lastPathComponent)")
            }
        }
    }
}
