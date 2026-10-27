import Foundation

// MARK: - Model definitions

/// A file pinned to an immutable Hugging Face revision and checked by size and SHA-256.
struct LlamaCppRemoteFile: Codable, Equatable, Hashable, Sendable {
    let repositoryId: String
    /// Commit SHA, so the file cannot change after it was added.
    let revision: String
    /// Path inside the repository.
    let path: String
    let size: Int64
    let sha256: String

    var fileName: String { (path as NSString).lastPathComponent }
}

enum LlamaCppModelOrigin: String, Codable, Sendable {
    case catalog
    case huggingFace
    case importedFile
}

enum LlamaCppModelAvailability: Equatable, Sendable {
    case supported
    case experimental(warning: String)
}

struct LlamaCppModelDefinition: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let origin: LlamaCppModelOrigin
    /// File name of the weights inside the model directory.
    let fileName: String
    let fileSize: Int64
    /// Download source of the weights. Imported files have none.
    let weights: LlamaCppRemoteFile?
    /// Optional multimodal projector (`mmproj`) passed to llama-server with `--mmproj`,
    /// for example the audio encoder of an audio-capable model.
    var projector: LlamaCppRemoteFile?
    /// Installed memory a Mac needs, in GB as Apple advertises it. Unknown for custom models.
    var minimumMemoryGB: Int?
    /// Short guidance under the model name.
    var usageHint: String?
    /// Shown instead of the download button until the user chooses "Try anyway".
    var experimentalWarning: String?
    /// Whether the settings may recommend this model for the Mac's memory.
    var isRecommendationCandidate: Bool?

    var availability: LlamaCppModelAvailability {
        experimentalWarning.map { .experimental(warning: $0) } ?? .supported
    }

    var isCustom: Bool { origin != .catalog }

    /// Download bytes of the weights and the projector.
    var totalDownloadSize: Int64 {
        (weights?.size ?? 0) + (projector?.size ?? 0)
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSize + (projector?.size ?? 0), countStyle: .file)
    }

    /// Repository and file for custom Hugging Face models, the original file name for imports.
    var sourceDescription: String? {
        switch origin {
        case .catalog:
            return nil
        case .huggingFace:
            return weights.map { "\($0.repositoryId) · \($0.fileName)" }
        case .importedFile:
            return fileName
        }
    }
}

// MARK: - Catalog

enum LlamaCppModelCatalog {
    static let qwen35Warning = "Experimental. Uses less memory than Gemma 4 but translates and restructures text less reliably."
    static let lfm25Warning = "Experimental. Reasons before answering, so results take several seconds. LFM Open License: commercial use is free only below USD 10M annual revenue."
    static let largeModelWarning = "Experimental. A large download that answers more slowly than the smaller models."

    /// The same GGUF files, revisions and checksums as the Local LLM plugin for Windows.
    static let models: [LlamaCppModelDefinition] = [
        catalogModel(
            id: "gemma-4-e2b-it-q4",
            displayName: "Gemma 4 E2B (Q4_K_M)",
            repositoryId: "unsloth/gemma-4-E2B-it-GGUF",
            revision: "0314792d7f1f7e229411f620751375812bb9faf2",
            path: "gemma-4-E2B-it-Q4_K_M.gguf",
            size: 3_106_738_272,
            sha256: "740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8",
            minimumMemoryGB: 8,
            usageHint: "Fastest. Good for cleanup and short texts, less reliable with inline commands and notes.",
            isRecommendationCandidate: true
        ),
        catalogModel(
            id: "gemma-4-e4b-it-q4",
            displayName: "Gemma 4 E4B (Q4_K_M)",
            repositoryId: "unsloth/gemma-4-E4B-it-GGUF",
            revision: "bfc15c382204943c3a8fff0c750b94ae2364d7a3",
            path: "gemma-4-E4B-it-Q4_K_M.gguf",
            size: 4_977_171_584,
            sha256: "85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87",
            minimumMemoryGB: 16,
            usageHint: "Balanced speed and quality for every workflow.",
            isRecommendationCandidate: true
        ),
        catalogModel(
            id: "gemma-4-e4b-it-q8",
            displayName: "Gemma 4 E4B (Q8_0)",
            repositoryId: "unsloth/gemma-4-E4B-it-GGUF",
            revision: "bfc15c382204943c3a8fff0c750b94ae2364d7a3",
            path: "gemma-4-E4B-it-Q8_0.gguf",
            size: 8_192_953_472,
            sha256: "f8854aa4480df62585a279e7ca0a881554fc18a41c59c4f62642d16a2ae47012",
            minimumMemoryGB: 16,
            usageHint: "Slightly more accurate than the Q4_K_M version, but needs more memory and runs slower."
        ),
        catalogModel(
            id: "gemma-4-26b-a4b-it-q4",
            displayName: "Gemma 4 26B-A4B (Q4_K_M, MoE)",
            repositoryId: "unsloth/gemma-4-26B-A4B-it-GGUF",
            revision: "c099eb48e663fd284577b04978a94ffccb261841",
            path: "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf",
            size: 16_947_541_728,
            sha256: "f2c28b3dc4776931ac6f879e11f203dec637ea0f14267a86ec8f6165f63f293f",
            minimumMemoryGB: 32,
            experimentalWarning: largeModelWarning
        ),
        catalogModel(
            id: "qwen3.5-2b-q4",
            displayName: "Qwen3.5 2B (Q4_K_M)",
            repositoryId: "unsloth/Qwen3.5-2B-GGUF",
            revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae",
            path: "Qwen3.5-2B-Q4_K_M.gguf",
            size: 1_280_835_840,
            sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
            minimumMemoryGB: 8,
            experimentalWarning: qwen35Warning
        ),
        catalogModel(
            id: "lfm2.5-2.6b-q4",
            displayName: "LFM2.5 2.6B (Q4_K_M)",
            repositoryId: "LiquidAI/LFM2.5-2.6B-GGUF",
            revision: "e7caca5d835a3901a8e0d63e94009429bafafdfc",
            path: "LFM2.5-2.6B-Q4_K_M.gguf",
            size: 1_674_455_040,
            sha256: "02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed",
            minimumMemoryGB: 8,
            experimentalWarning: lfm25Warning
        ),
    ]

    static func model(for id: String?) -> LlamaCppModelDefinition? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// Installed memory of this Mac in GB, rounded the way Apple advertises it.
    static var hostMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    /// The largest recommendation candidate this Mac has enough memory for; the smallest
    /// candidate on Macs below every requirement.
    static func recommendedModel(forMemoryGB memoryGB: Int = hostMemoryGB) -> LlamaCppModelDefinition? {
        let candidates = models.filter { $0.isRecommendationCandidate == true }
        let fitting = candidates.filter { ($0.minimumMemoryGB ?? 0) <= memoryGB }
        return fitting.max { ($0.minimumMemoryGB ?? 0) < ($1.minimumMemoryGB ?? 0) }
            ?? candidates.min { ($0.minimumMemoryGB ?? 0) < ($1.minimumMemoryGB ?? 0) }
    }

    private static func catalogModel(
        id: String,
        displayName: String,
        repositoryId: String,
        revision: String,
        path: String,
        size: Int64,
        sha256: String,
        minimumMemoryGB: Int,
        usageHint: String? = nil,
        experimentalWarning: String? = nil,
        isRecommendationCandidate: Bool = false
    ) -> LlamaCppModelDefinition {
        LlamaCppModelDefinition(
            id: id,
            displayName: displayName,
            origin: .catalog,
            fileName: (path as NSString).lastPathComponent,
            fileSize: size,
            weights: LlamaCppRemoteFile(
                repositoryId: repositoryId,
                revision: revision,
                path: path,
                size: size,
                sha256: sha256
            ),
            projector: nil,
            minimumMemoryGB: minimumMemoryGB,
            usageHint: usageHint,
            experimentalWarning: experimentalWarning,
            isRecommendationCandidate: isRecommendationCandidate
        )
    }
}

// MARK: - Custom models

/// Models the user added from Hugging Face or imported from a file, stored as JSON in the
/// plugin data directory.
struct LlamaCppCustomModelStore: Sendable {
    let fileURL: URL

    func load() -> [LlamaCppModelDefinition] {
        guard let data = try? Data(contentsOf: fileURL),
              let models = try? JSONDecoder().decode([LlamaCppModelDefinition].self, from: data) else {
            return []
        }
        return models.filter { $0.isCustom && LlamaCppModelIdentifier.isValid($0.id) }
    }

    func save(_ models: [LlamaCppModelDefinition]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(models.filter(\.isCustom)).write(to: fileURL, options: .atomic)
    }
}

enum LlamaCppModelIdentifier {
    /// Lowercase identifiers that are safe as directory names and in stored workflows.
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 120
            && id.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil
            && !id.contains("..")
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var lastWasSeparator = false
        for scalar in lowered.unicodeScalars {
            let character = Character(scalar)
            if scalar.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" {
                result.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator, !result.isEmpty {
                result.append("-")
                lastWasSeparator = true
            }
        }
        while result.contains("..") {
            result = result.replacingOccurrences(of: "..", with: ".")
        }
        result = String(result.prefix(100))
        while result.hasSuffix("-") || result.hasSuffix(".") { result.removeLast() }
        return result
    }

    /// A new identifier with `prefix` that does not collide with `existingIds`.
    static func unique(prefix: String, name: String, existingIds: Set<String>) -> String {
        let base = "\(prefix)-\(slug(name))"
        var candidate = base
        var counter = 2
        while existingIds.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}

// MARK: - File names

enum LlamaCppGGUFFileName {
    /// Projector files (`mmproj-*.gguf`) add audio or vision input to a model and cannot be
    /// loaded on their own.
    static func isProjector(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.lowercased().contains("mmproj")
    }

    /// Parts of a model split into several files, for example `model-00001-of-00003.gguf`.
    static func isSplitPart(_ path: String) -> Bool {
        path.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isGGUF(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".gguf")
    }

    static func stem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

// MARK: - Verification marker

/// Written next to a model file after its checksum matched, so later loads only compare
/// size and modification date instead of hashing gigabytes again.
struct LlamaCppVerificationMarker: Codable, Equatable {
    let size: Int64
    let modificationDate: Date
    let sha256: String?

    static func markerURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(fileURL.lastPathComponent).verified")
    }

    static func write(for fileURL: URL, sha256: String?) throws {
        guard let size = LlamaCppFileChecks.fileSize(of: fileURL),
              let modificationDate = LlamaCppFileChecks.modificationDate(of: fileURL) else {
            throw LlamaCppPluginError.verificationFailed(fileURL.lastPathComponent)
        }
        let marker = LlamaCppVerificationMarker(size: size, modificationDate: modificationDate, sha256: sha256)
        try JSONEncoder().encode(marker).write(to: markerURL(for: fileURL), options: .atomic)
    }

    /// Whether `fileURL` still is the file that was verified with `expectedSize` and `expectedSHA256`.
    static func isVerified(_ fileURL: URL, expectedSize: Int64, expectedSHA256: String?) -> Bool {
        guard let size = LlamaCppFileChecks.fileSize(of: fileURL),
              size == expectedSize,
              let modificationDate = LlamaCppFileChecks.modificationDate(of: fileURL),
              let data = try? Data(contentsOf: markerURL(for: fileURL)),
              let marker = try? JSONDecoder().decode(LlamaCppVerificationMarker.self, from: data) else {
            return false
        }
        guard marker.size == size,
              abs(marker.modificationDate.timeIntervalSince(modificationDate)) < 1 else {
            return false
        }
        if let expectedSHA256 {
            return marker.sha256?.lowercased() == expectedSHA256.lowercased()
        }
        return true
    }

    static func remove(for fileURL: URL) {
        try? FileManager.default.removeItem(at: markerURL(for: fileURL))
    }
}
