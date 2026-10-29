import Foundation
import Darwin

/// Optional capability; existing transcription engines remain binary compatible.
public protocol PluginCustomModelImporting: TranscriptionEnginePlugin {
    var supportedImportModelTypes: Set<String> { get }
    @MainActor func importModel(_ candidate: PluginModelImportCandidate, token: String?) async throws -> PluginModelInfo
}

/// Optional capability for engines whose models have no Hugging Face `config.json`, such as
/// Core ML conversions. The import sheet asks the plugin to inspect the source instead.
public protocol PluginCustomModelImportInspecting: PluginCustomModelImporting {
    /// Checks the source before any weights are downloaded and names the files to import.
    func inspectImportSource(_ source: PluginModelImportSource, token: String?) async throws -> PluginModelImportCandidate
    /// Shown below the folder picker: which files the folder must contain.
    var importFolderDescription: String { get }
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

    /// For inspections done by the plugin (`PluginCustomModelImportInspecting`). `files` lists the
    /// repository paths a Hugging Face import may download; folder imports leave it empty.
    public init(source: PluginModelImportSource, modelType: String, displayName: String, revision: String?, files: [String]) {
        self.source = source
        self.modelType = modelType
        self.displayName = displayName
        self.revision = revision
        self.files = files
    }

    /// Repository paths of a Hugging Face candidate, including files inside model folders.
    public var repositoryFiles: [String] { files }

    /// The commit a Hugging Face repository is at and the paths of its files.
    public static func huggingFaceRepositoryFiles(
        _ repository: String,
        token: String? = nil,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await Self.fetchMetadata($0, session: .shared, limit: 4 * 1024 * 1024) }
    ) async throws -> (revision: String, files: [String]) {
        guard try PluginModelImportSource.huggingFaceInput(repository) == .huggingFace(repository) else {
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
        return (repo.sha, repo.siblings.map(\.rfilename))
    }

    public var suggestedPluginName: String? {
        switch modelType {
        case "canary": "Canary ASR"
        case "qwen3_asr": "Qwen3 ASR"
        case "granite_speech": "Granite Speech"
        case "voxtral_realtime": "Voxtral"
        case "parakeet_tdt_coreml": "Parakeet"
        default: nil
        }
    }

    public static func inspect(
        _ source: PluginModelImportSource,
        token: String? = nil,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await Self.fetchMetadata($0, session: .shared, limit: 4 * 1024 * 1024) }
    ) async throws -> Self {
        switch source {
        case .folder(let folder):
            guard folder.isFileURL else { throw PluginModelImportError.invalidSource }
            let config = try readConfig(in: folder)
            return Self(source: source, modelType: try modelType(config),
                        displayName: folder.lastPathComponent, revision: nil, files: [])
        case .huggingFace(let repository):
            let repo = try await huggingFaceRepositoryFiles(repository, token: token, fetch: fetch)
            let (config, configResponse) = try await fetch(request(
                "https://huggingface.co/\(repository)/resolve/\(repo.revision)/config.json", token: token
            ))
            try checkResponse(configResponse)
            return Self(source: source, modelType: try modelType(config),
                        displayName: repository.split(separator: "/").last.map(String.init) ?? repository,
                        revision: repo.revision, files: repo.files)
        }
    }

    @usableFromInline
    static func fetchMetadata(_ request: URLRequest, session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try checkResponse(response)
        guard response.expectedContentLength <= limit else {
            throw PluginModelImportError.invalidModel("Model metadata exceeds the 4 MiB limit")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else {
                throw PluginModelImportError.invalidModel("Model metadata exceeds the 4 MiB limit")
            }
            data.append(byte)
        }
        return (data, response)
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
    private static let pendingName = ".pending-validation"
    // Only data files consumed by local engines. Never import or execute repository code.
    private static let extensions: Set<String> = ["safetensors", "json", "txt", "model", "tiktoken", "wav"]

    public init(directory: URL) { self.directory = directory }

    /// Run once off the UI executor when activating a plugin. Store construction
    /// and model-list reads stay free of blocking recovery work.
    public func recoverAbandonedImports() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try withStagingLock(createDirectory: false) { cleanupAbandonedStaging() }
    }

    // A short store lock makes stage creation and recovery atomic across processes.
    // Each import holds its own lease until completion; the OS releases it on crash.
    private func withStagingLock<T>(createDirectory: Bool = true, _ body: () throws -> T) throws -> T {
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fd = open(directory.appendingPathComponent(".staging.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return try body()
    }

    private func cleanupAbandonedStaging() {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for child in children {
            let isStage = child.lastPathComponent.hasPrefix(".import-")
                && UUID(uuidString: String(child.lastPathComponent.dropFirst(8))) != nil
            let isPending = Self.isModelID(child.lastPathComponent)
                && FileManager.default.fileExists(atPath: child.appendingPathComponent(Self.pendingName).path)
            guard isStage || isPending,
                  let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let fd = open(child.appendingPathComponent(".lease").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    func createStagingDirectory() throws -> (URL, Int32) {
        try withStagingLock {
            cleanupAbandonedStaging()
            let staging = directory.appendingPathComponent(".import-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let fd = open(staging.appendingPathComponent(".lease").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else {
                try? FileManager.default.removeItem(at: staging)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                close(fd)
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            return (staging, fd)
        }
    }

    public func models() -> [Model] { storedModels(includePending: false) }

    private func storedModels(includePending: Bool) -> [Model] {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.compactMap { child in
            guard Self.isModelID(child.lastPathComponent),
                  includePending || !FileManager.default.fileExists(atPath: child.appendingPathComponent(Self.pendingName).path),
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

    /// Keep a leased, hidden import until file checks and native validation both succeed.
    public func add(
        _ candidate: PluginModelImportCandidate,
        supportedTypes: Set<String>,
        requirements: PluginHuggingFaceModelStore.Requirements,
        token: String? = nil,
        download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse) = { request in
            try await URLSession.shared.download(for: request)
        },
        validation: @escaping @Sendable (Model) async throws -> Void = { _ in }
    ) async throws -> Model {
        try await addModel(candidate, supportedTypes: supportedTypes, validation: validation, populate: { staging in
            switch candidate.source {
            case .folder(let source):
                try copyModelFiles(from: source, to: staging)
            case .huggingFace(let repo):
                guard let revision = candidate.revision else { throw PluginModelImportError.invalidSource }
                for file in candidate.files where Self.isImportableFile(file) {
                    try await Self.downloadFile(file, repository: repo, revision: revision, into: staging,
                                                token: token, download: download)
                }
            }
        }, check: { staging in
            let type = try PluginModelImportCandidate.modelType(PluginModelImportCandidate.readConfig(in: staging))
            guard type == candidate.modelType, supportedTypes.contains(type) else {
                throw PluginModelImportError.unsupportedArchitecture(type)
            }
            try validateFiles(in: staging, requirements: requirements)
            return type
        })
    }

    /// Model folders the store copies as a whole, for engines that load Core ML models.
    public static let modelBundleExtensions: Set<String> = ["mlmodelc", "mlpackage"]

    /// Imports exactly `entries`: names at the top of the model folder or repository, each a
    /// data file or a Core ML model folder (`modelBundleExtensions`). Unlike the variant above,
    /// no `config.json` is needed; the plugin identified the model while inspecting the source,
    /// and `validation` loads it before the import completes.
    public func add(
        _ candidate: PluginModelImportCandidate,
        supportedTypes: Set<String>,
        entries: Set<String>,
        token: String? = nil,
        download: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse) = { request in
            try await URLSession.shared.download(for: request)
        },
        validation: @escaping @Sendable (Model) async throws -> Void = { _ in }
    ) async throws -> Model {
        guard !entries.isEmpty, entries.allSatisfy(Self.isImportableEntry) else {
            throw PluginModelImportError.invalidModel("Unsupported model files")
        }
        return try await addModel(candidate, supportedTypes: supportedTypes, validation: validation, populate: { staging in
            switch candidate.source {
            case .folder(let source):
                for entry in entries.sorted() {
                    try copyEntry(source.appendingPathComponent(entry), to: staging.appendingPathComponent(entry))
                }
            case .huggingFace(let repo):
                guard let revision = candidate.revision else { throw PluginModelImportError.invalidSource }
                for file in candidate.files where Self.isImportablePath(file, entries: entries) {
                    try await Self.downloadFile(file, repository: repo, revision: revision, into: staging,
                                                token: token, download: download)
                }
            }
        }, check: { staging in
            for entry in entries {
                let url = staging.appendingPathComponent(entry)
                let isBundle = Self.modelBundleExtensions.contains(url.pathExtension.lowercased())
                guard isBundle ? Self.containsFiles(url) : (Self.regularFileSize(url) ?? 0) > 0 else {
                    throw PluginModelImportError.invalidModel("Missing or empty \(entry)")
                }
            }
            return candidate.modelType
        })
    }

    private func addModel(
        _ candidate: PluginModelImportCandidate,
        supportedTypes: Set<String>,
        validation: @escaping @Sendable (Model) async throws -> Void,
        populate: (URL) async throws -> Void,
        check: (URL) throws -> String
    ) async throws -> Model {
        guard supportedTypes.contains(candidate.modelType) else {
            throw PluginModelImportError.unsupportedArchitecture(candidate.modelType)
        }
        let origin: String
        switch candidate.source {
        case .folder(let url): origin = url.resolvingSymlinksInPath().path
        case .huggingFace(let repo): origin = "https://huggingface.co/\(repo)"
        }
        let id = "custom-" + UUID().uuidString.lowercased()
        let (staging, lease) = try createStagingDirectory()
        defer {
            try? FileManager.default.removeItem(at: staging)
            close(lease)
        }
        // Stage creation recovers abandoned pending imports before duplicate
        // detection, while active native validations retain their leases.
        guard !storedModels(includePending: true).contains(where: { $0.origin == origin && $0.revision == candidate.revision }) else {
            throw PluginModelImportError.duplicate
        }

        try await populate(staging)
        try Task.checkCancellation()
        let type = try check(staging)
        let bytes = Self.totalFileSize(in: staging)
        let model = Model(id: id, displayName: candidate.displayName, modelType: type,
                          origin: origin, revision: candidate.revision, bytes: bytes)
        try JSONEncoder().encode(model).write(to: staging.appendingPathComponent(Self.metadataName), options: .atomic)
        try Task.checkCancellation()
        try Data().write(to: staging.appendingPathComponent(Self.pendingName))
        let destination = directory.appendingPathComponent(id)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        try withStagingLock(createDirectory: false) {
            try Task.checkCancellation()
            guard !storedModels(includePending: true).contains(where: { $0.origin == origin && $0.revision == candidate.revision }) else {
                throw PluginModelImportError.duplicate
            }
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        try await validation(model)
        // Recovery must not observe a pending marker and then acquire the lease
        // after this model has already committed successfully.
        try withStagingLock(createDirectory: false) {
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: destination.appendingPathComponent(Self.pendingName))
            completed = true
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(".lease"))
        }
        return model
    }

    private static func downloadFile(
        _ file: String, repository: String, revision: String, into staging: URL, token: String?,
        download: @Sendable (URLRequest) async throws -> (URL, URLResponse)
    ) async throws {
        try Task.checkCancellation()
        let (temporary, response) = try await download(PluginModelImportCandidate.request(
            "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)", token: token
        ))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try PluginModelImportCandidate.checkResponse(response)
        let destination = staging.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// A name at the top of the model: a data file or a Core ML model folder.
    static func isImportableEntry(_ name: String) -> Bool {
        isImportableFile(name)
            || (isSafePathComponent(name) && modelBundleExtensions.contains((name as NSString).pathExtension.lowercased()))
    }

    /// A repository path inside one of `entries`. Paths inside a model folder may nest a few
    /// levels (`Encoder.mlmodelc/weights/weight.bin`); every component must be a plain name.
    static func isImportablePath(_ path: String, entries: Set<String>) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = components.first, entries.contains(first), components.count <= 8,
              components.allSatisfy(isSafePathComponent) else { return false }
        if components.count == 1 { return isImportableFile(first) }
        return modelBundleExtensions.contains((first as NSString).pathExtension.lowercased())
    }

    private static func isSafePathComponent(_ name: String) -> Bool {
        !name.hasPrefix(".") && name != metadataName
            && name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    /// Copies a data file, or a Core ML model folder with every regular file inside it.
    /// Symlinked files (as in Hugging Face snapshots) are copied as the files they point to.
    private func copyEntry(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let resolved = source.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        guard Self.modelBundleExtensions.contains(source.pathExtension.lowercased()) else {
            guard values.isRegularFile == true else {
                throw PluginModelImportError.invalidModel("Missing \(source.lastPathComponent)")
            }
            try Self.copyFile(from: resolved, to: destination)
            return
        }
        guard values.isDirectory == true else {
            throw PluginModelImportError.invalidModel("Missing \(source.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(
            at: resolved, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        ) else { throw CocoaError(.fileReadUnknown) }
        let base = resolved.standardizedFileURL.pathComponents.count
        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let relative = Array(item.standardizedFileURL.pathComponents.dropFirst(base))
            guard !relative.isEmpty, relative.count < 8, relative.allSatisfy(Self.isSafePathComponent) else {
                enumerator.skipDescendants()
                continue
            }
            let target = relative.reduce(destination) { $0.appendingPathComponent($1) }
            let itemValues = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if itemValues.isDirectory == true, itemValues.isSymbolicLink != true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let file = item.resolvingSymlinksInPath()
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try Self.copyFile(from: file, to: target)
        }
    }

    private static func containsFiles(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let item as URL in enumerator where (regularFileSize(item) ?? 0) > 0 { return true }
        return false
    }

    private static func regularFileSize(_ url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        return values.fileSize
    }

    static func totalFileSize(in folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }
        var bytes: Int64 = 0
        for case let item as URL in enumerator { bytes += Int64(regularFileSize(item) ?? 0) }
        return bytes
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
            try Self.copyFile(from: resolved, to: destination.appendingPathComponent(file.lastPathComponent))
        }
    }

    // Keep cancellation latency bounded even when copying multi-GB shards from
    // another volume, where copyItem cannot use a fast APFS clone.
    static func copyFile(
        from source: URL, to destination: URL,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        try checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while true {
            let copied = try autoreleasepool {
                try checkCancellation()
                guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                try output.write(contentsOf: data)
                return true
            }
            if !copied { break }
        }
        try checkCancellation()
        completed = true
    }

    private func validateFiles(in folder: URL, requirements: PluginHuggingFaceModelStore.Requirements) throws {
        guard PluginHuggingFaceModelStore(modelsDirectory: folder).isUsableModelDirectory(folder, requirements: requirements) else {
            throw PluginModelImportError.invalidModel("Missing model weights or tokenizer files")
        }
        let index = folder.appendingPathComponent("model.safetensors.index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            struct Index: Decodable { let weight_map: [String: String] }
            let handle = try FileHandle(forReadingFrom: index)
            defer { try? handle.close() }
            let limit = 16 * 1024 * 1024
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard !data.isEmpty, data.count <= limit else {
                throw PluginModelImportError.invalidModel("Weight index exceeds the 16 MiB limit or is empty")
            }
            let shards = try JSONDecoder().decode(Index.self, from: data).weight_map.values
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
