import Foundation

enum LlamaCppPluginError: LocalizedError, Equatable, Sendable {
    case noInputText
    case modelNotLoaded
    case runtimeDownloadFailed
    case invalidRuntimeArchive
    case runtimeExtractionFailed(String)
    case verificationFailed(String)
    case invalidRepositoryIdentifier(String)
    case localPortReservationFailed
    case serverExited(String)
    case serverStartupTimedOut(String)
    case serverRequestFailed(Int, String)
    case emptyResponse
    case inputTooLong
    case importedFileMissing(String)
    case notAGGUFFile
    case projectorIsNotAModel
    case splitFileUnsupported
    case duplicateModel
    case invalidHuggingFaceReference
    case huggingFaceAccessDenied(String)
    case huggingFaceRepositoryNotFound(String)
    case huggingFaceRequestFailed(Int)
    case huggingFaceFileNotFound(String)
    case noGGUFFiles(String)
    case onlySplitGGUFFiles(String)
    case quantizationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noInputText:
            return Self.localized("There is no text to process.")
        case .modelNotLoaded:
            return Self.localized("Load a local model in Integrations before using it for prompts.")
        case .runtimeDownloadFailed:
            return Self.localized("The llama.cpp runtime could not be downloaded. Check the internet connection and try again.")
        case .invalidRuntimeArchive:
            return Self.localized("The downloaded llama.cpp runtime is incomplete.")
        case .runtimeExtractionFailed(let detail):
            return Self.formatted("The llama.cpp runtime could not be unpacked: %@", detail)
        case .verificationFailed(let fileName):
            return Self.formatted("%@ does not match its expected size or checksum and was removed. Download it again.", fileName)
        case .invalidRepositoryIdentifier(let identifier):
            return Self.formatted("Invalid Hugging Face repository: %@", identifier)
        case .localPortReservationFailed:
            return Self.localized("No local port is available for the model server.")
        case .serverExited(let output):
            return Self.serverFailureMessage(Self.localized("The model server stopped while loading the model."), output: output)
        case .serverStartupTimedOut(let output):
            return Self.serverFailureMessage(Self.localized("The model did not finish loading within five minutes."), output: output)
        case .serverRequestFailed(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.formatted("The model server returned HTTP %@: %@", String(status), String(trimmed.prefix(300)))
        case .emptyResponse:
            return Self.localized("The model returned no text.")
        case .inputTooLong:
            return Self.localized("The text is too long for the model's context window.")
        case .importedFileMissing(let fileName):
            return Self.formatted("The imported model file %@ is missing. Remove the model and import it again.", fileName)
        case .notAGGUFFile:
            return Self.localized("Choose a GGUF model file (.gguf).")
        case .projectorIsNotAModel:
            return Self.localized("This is a multimodal projector (mmproj) file, not a language model. Choose the model file instead.")
        case .splitFileUnsupported:
            return Self.localized("Models split into several GGUF files are not supported yet. Choose a single-file model.")
        case .duplicateModel:
            return Self.localized("This model has already been added.")
        case .invalidHuggingFaceReference:
            return Self.localized("Enter a Hugging Face repository such as owner/model-GGUF, optionally with a quantization (owner/model-GGUF:Q4_K_M), or a huggingface.co link.")
        case .huggingFaceAccessDenied(let repository):
            return Self.formatted("Hugging Face did not grant access to %@. Check the name. For private or gated models, save a token with access in this plugin.", repository)
        case .huggingFaceRepositoryNotFound(let repository):
            return Self.formatted("The Hugging Face repository %@ was not found.", repository)
        case .huggingFaceRequestFailed(let status):
            return Self.formatted("Hugging Face could not be reached (HTTP %@). Try again later.", String(status))
        case .huggingFaceFileNotFound(let path):
            return Self.formatted("The file %@ was not found in this repository.", path)
        case .noGGUFFiles(let repository):
            return Self.formatted("%@ contains no GGUF model files.", repository)
        case .onlySplitGGUFFiles(let repository):
            return Self.formatted("%@ only contains models split into several GGUF files, which are not supported yet.", repository)
        case .quantizationNotFound(let quantization):
            return Self.formatted("No GGUF file with %@ was found in this repository.", quantization)
        }
    }

    /// Whether a failed load can be fixed by deleting the cached files and downloading again.
    var suggestsCacheReset: Bool {
        switch self {
        case .verificationFailed, .invalidRuntimeArchive:
            return true
        default:
            return false
        }
    }

    private static func serverFailureMessage(_ message: String, output: String) -> String {
        guard let detail = lastErrorLine(in: output) else { return message }
        return "\(message) \(detail)"
    }

    /// The most specific line of the server output, so the settings can show why loading failed.
    static func lastErrorLine(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let errorLine = lines.last { line in
            let lowered = line.lowercased()
            return lowered.contains("error") || lowered.contains("failed") || lowered.contains("unknown model architecture")
        }
        return errorLine.map { String($0.prefix(300)) }
    }

    private static func localized(_ key: String) -> String {
        Bundle(for: LlamaCppPlugin.self).localizedString(forKey: key, value: key, table: nil)
    }

    private static func formatted(_ key: String, _ arguments: String...) -> String {
        String(format: localized(key), arguments: arguments.map { $0 as CVarArg })
    }
}
