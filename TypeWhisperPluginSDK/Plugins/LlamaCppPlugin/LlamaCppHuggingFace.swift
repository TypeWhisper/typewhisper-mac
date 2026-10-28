import Foundation
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK

/// What the user typed to add a Hugging Face model: `owner/repo`, `owner/repo:Q4_K_M`,
/// `hf.co/owner/repo:Q4_K_M`, or a huggingface.co URL of a repository or `.gguf` file.
struct LlamaCppHuggingFaceReference: Equatable, Sendable {
    let repositoryId: String
    var revision: String?
    var filePath: String?
    var quantization: String?

    private static let namePattern = #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
    private static let tokenPattern = #"^[A-Za-z0-9._-]+$"#

    static func parse(_ rawInput: String) throws -> Self {
        var input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = input.lowercased()
        if lowered.hasPrefix("https://") {
            input.removeFirst("https://".count)
        } else if lowered.contains("://") {
            throw LlamaCppPluginError.invalidHuggingFaceReference
        }
        for host in ["www.huggingface.co/", "huggingface.co/", "hf.co/"] where input.lowercased().hasPrefix(host) {
            input.removeFirst(host.count)
            break
        }
        if let end = input.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            input = String(input[..<end])
        }

        let parts = input.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { throw LlamaCppPluginError.invalidHuggingFaceReference }

        let owner = parts[0]
        var name = parts[1]
        var reference = LlamaCppHuggingFaceReference(repositoryId: "")
        if parts.count == 2, let colon = name.lastIndex(of: ":") {
            reference.quantization = String(name[name.index(after: colon)...])
            name = String(name[..<colon])
        } else if parts.count > 2 {
            guard ["tree", "blob", "resolve"].contains(parts[2]), parts.count >= 4 else {
                throw LlamaCppPluginError.invalidHuggingFaceReference
            }
            reference.revision = parts[3]
            if parts[2] != "tree", parts.count >= 5 {
                let path = parts[4...].joined(separator: "/")
                reference.filePath = path.removingPercentEncoding ?? path
            }
        }

        guard matches(owner, namePattern), matches(name, namePattern),
              owner != "..", name != "..",
              reference.quantization.map({ !$0.isEmpty && matches($0, tokenPattern) }) ?? true,
              reference.revision.map({ matches($0, tokenPattern) }) ?? true,
              reference.filePath.map({ !$0.contains("..") && LlamaCppGGUFFileName.isGGUF($0) }) ?? true else {
            throw LlamaCppPluginError.invalidHuggingFaceReference
        }
        return LlamaCppHuggingFaceReference(
            repositoryId: "\(owner)/\(name)",
            revision: reference.revision,
            filePath: reference.filePath,
            quantization: reference.quantization
        )
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The GGUF files of one repository revision, pinned to its commit SHA.
struct LlamaCppHuggingFaceLookupResult: Equatable, Sendable {
    let repositoryId: String
    let revision: String
    /// Single-file model weights, sorted by size.
    let models: [LlamaCppRemoteFile]
    /// Multimodal projectors (`mmproj-*.gguf`) found next to the weights.
    let projectors: [LlamaCppRemoteFile]
    /// Weights matching the file or quantization the user named, or the only file.
    let preselectedPath: String?
    /// Models split into several files, which this plugin cannot load yet.
    let skippedSplitModelCount: Int
}

enum LlamaCppHuggingFaceLookup {
    static let defaultHost = URL(string: "https://huggingface.co")!

    private struct ModelInfo: Decodable {
        let sha: String?
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64
        }

        let type: String
        let path: String
        let lfs: LFS?
    }

    static func lookUp(
        _ reference: LlamaCppHuggingFaceReference,
        token: String?,
        host: URL = defaultHost,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async throws -> LlamaCppHuggingFaceLookupResult {
        let repository = reference.repositoryId
        let requestedRevision = reference.revision ?? "main"
        let infoURL = host
            .appending(path: "api/models/\(repository)/revision")
            .appending(component: requestedRevision)
        let info: ModelInfo = try await fetch(
            infoURL,
            repository: repository,
            token: token,
            dataFetcher: dataFetcher
        ).value
        guard let sha = info.sha, sha.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw LlamaCppPluginError.huggingFaceRequestFailed(0)
        }

        var treeComponents = URLComponents(
            url: host.appending(path: "api/models/\(repository)/tree").appending(component: sha),
            resolvingAgainstBaseURL: false
        )!
        treeComponents.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        // The tree listing returns 1,000 entries per page and names the next page in `Link`.
        var entries: [TreeEntry] = []
        var nextPageURL = treeComponents.url
        var pageCount = 0
        while let pageURL = nextPageURL, pageCount < maximumTreePages {
            let page: (value: [TreeEntry], response: URLResponse) = try await fetch(
                pageURL,
                repository: repository,
                token: token,
                dataFetcher: dataFetcher
            )
            entries += page.value
            pageCount += 1
            nextPageURL = nextPage(from: page.response, host: host)
        }

        var models: [LlamaCppRemoteFile] = []
        var projectors: [LlamaCppRemoteFile] = []
        var splitPaths = Set<String>()
        for entry in entries where entry.type == "file" && LlamaCppGGUFFileName.isGGUF(entry.path) {
            guard let lfs = entry.lfs,
                  lfs.oid.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  lfs.size > 0 else {
                continue
            }
            let file = LlamaCppRemoteFile(
                repositoryId: repository,
                revision: sha,
                path: entry.path,
                size: lfs.size,
                sha256: lfs.oid
            )
            if LlamaCppGGUFFileName.isProjector(entry.path) {
                projectors.append(file)
            } else if LlamaCppGGUFFileName.isSplitPart(entry.path) {
                splitPaths.insert(
                    entry.path.replacingOccurrences(
                        of: #"-\d{5}-of-\d{5}\.gguf$"#,
                        with: "",
                        options: [.regularExpression, .caseInsensitive]
                    )
                )
            } else {
                models.append(file)
            }
        }
        models.sort { $0.size == $1.size ? $0.path < $1.path : $0.size < $1.size }
        projectors.sort { $0.size == $1.size ? $0.path < $1.path : $0.size < $1.size }

        guard !models.isEmpty else {
            throw splitPaths.isEmpty
                ? LlamaCppPluginError.noGGUFFiles(repository)
                : LlamaCppPluginError.onlySplitGGUFFiles(repository)
        }

        return LlamaCppHuggingFaceLookupResult(
            repositoryId: repository,
            revision: sha,
            models: models,
            projectors: projectors,
            preselectedPath: try preselectedPath(in: models, for: reference),
            skippedSplitModelCount: splitPaths.count
        )
    }

    static func preselectedPath(
        in models: [LlamaCppRemoteFile],
        for reference: LlamaCppHuggingFaceReference
    ) throws -> String? {
        if let filePath = reference.filePath {
            if LlamaCppGGUFFileName.isProjector(filePath) {
                throw LlamaCppPluginError.projectorIsNotAModel
            }
            if LlamaCppGGUFFileName.isSplitPart(filePath) {
                throw LlamaCppPluginError.onlySplitGGUFFiles(reference.repositoryId)
            }
            guard models.contains(where: { $0.path == filePath }) else {
                throw LlamaCppPluginError.huggingFaceFileNotFound(filePath)
            }
            return filePath
        }
        if let quantization = reference.quantization?.lowercased() {
            let matching = models.filter { $0.fileName.lowercased().contains(quantization) }
            if let exact = matching.first(where: {
                LlamaCppGGUFFileName.stem($0.fileName).lowercased().hasSuffix(quantization)
            }) {
                return exact.path
            }
            guard let first = matching.first else {
                throw LlamaCppPluginError.quantizationNotFound(reference.quantization ?? quantization)
            }
            return first.path
        }
        return models.count == 1 ? models[0].path : nil
    }

    static let maximumTreePages = 50

    /// The `rel="next"` URL of a paginated response, only on the Hugging Face host so the
    /// token never goes elsewhere.
    static func nextPage(from response: URLResponse, host: URL) -> URL? {
        guard let link = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link") else { return nil }
        for part in link.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == #"rel="next""# }),
                  let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  let url = URL(string: String(target.dropFirst().dropLast())),
                  url.scheme == host.scheme, url.host == host.host, url.port == host.port else {
                continue
            }
            return url
        }
        return nil
    }

    private static func fetch<Response: Decodable>(
        _ url: URL,
        repository: String,
        token: String?,
        dataFetcher: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (value: Response, response: URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = PluginHuggingFaceTokenHelper.normalizedToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await dataFetcher(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            do {
                return (try JSONDecoder().decode(Response.self, from: data), response)
            } catch {
                throw LlamaCppPluginError.huggingFaceRequestFailed(status)
            }
        case 401, 403:
            // Hugging Face answers 401 for repositories that do not exist, too.
            throw LlamaCppPluginError.huggingFaceAccessDenied(repository)
        case 404:
            throw LlamaCppPluginError.huggingFaceRepositoryNotFound(repository)
        default:
            throw LlamaCppPluginError.huggingFaceRequestFailed(status)
        }
    }
}
