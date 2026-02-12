import Foundation

final class APIHandlers: Sendable {
    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService

    init(modelManager: ModelManagerService, audioFileService: AudioFileService) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
    }

    func register(on router: APIRouter) {
        router.register("POST", "/v1/transcribe", handler: handleTranscribe)
        router.register("GET", "/v1/status", handler: handleStatus)
        router.register("GET", "/v1/models", handler: handleModels)
    }

    // MARK: - POST /v1/transcribe

    private func handleTranscribe(_ request: HTTPRequest) async -> HTTPResponse {
        let isReady = await modelManager.activeEngine != nil
        guard isReady else {
            return .error(status: 503, message: "No model loaded. Load a model in TypeWhisper first.")
        }

        let audioData: Data
        var fileExtension = "wav"
        var language: String?
        var task: TranscriptionTask = .transcribe

        let contentType = request.headers["content-type"] ?? ""

        if contentType.contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            let parts = HTTPRequestParser.parseMultipart(body: request.body, boundary: boundary)

            guard let filePart = parts.first(where: { $0.name == "file" }) else {
                return .error(status: 400, message: "Missing 'file' part in multipart form data")
            }

            audioData = filePart.data

            if let fn = filePart.filename, let ext = fn.split(separator: ".").last {
                fileExtension = String(ext).lowercased()
            } else if let ct = filePart.contentType {
                fileExtension = extensionFromMIME(ct)
            }

            if let langPart = parts.first(where: { $0.name == "language" }),
               let val = String(data: langPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                language = val
            }

            if let taskPart = parts.first(where: { $0.name == "task" }),
               let val = String(data: taskPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = TranscriptionTask(rawValue: val) {
                task = parsed
            }
        } else if !request.body.isEmpty {
            audioData = request.body
            fileExtension = extensionFromMIME(contentType)
            language = request.headers["x-language"]
            if let taskStr = request.headers["x-task"], let parsed = TranscriptionTask(rawValue: taskStr) {
                task = parsed
            }
        } else {
            return .error(status: 400, message: "No audio data provided")
        }

        guard !audioData.isEmpty else {
            return .error(status: 400, message: "Empty audio data")
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(fileExtension)")

        do {
            try audioData.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let samples = try await audioFileService.loadAudioSamples(from: tempURL)
            let result = try await modelManager.transcribe(audioSamples: samples, language: language, task: task)

            struct TranscribeResponse: Encodable {
                let text: String
                let language: String?
                let duration: Double
                let processing_time: Double
                let engine: String
                let model: String?
            }

            let modelId = await modelManager.selectedModelId
            let response = TranscribeResponse(
                text: result.text,
                language: result.detectedLanguage,
                duration: result.duration,
                processing_time: result.processingTime,
                engine: result.engineUsed.rawValue,
                model: modelId
            )
            return .json(response)
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GET /v1/status

    private func handleStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let engine = await modelManager.selectedEngine
        let modelId = await modelManager.selectedModelId
        let isReady = await modelManager.activeEngine != nil

        struct StatusResponse: Encodable {
            let status: String
            let engine: String
            let model: String?
            let supports_streaming: Bool
            let supports_translation: Bool
        }

        let response = StatusResponse(
            status: isReady ? "ready" : "no_model",
            engine: engine.rawValue,
            model: modelId,
            supports_streaming: engine.supportsStreaming,
            supports_translation: engine.supportsTranslation
        )
        return .json(response)
    }

    // MARK: - GET /v1/models

    private func handleModels(_ request: HTTPRequest) async -> HTTPResponse {
        let statuses = await modelManager.modelStatuses
        let selectedId = await modelManager.selectedModelId

        struct ModelEntry: Encodable {
            let id: String
            let engine: String
            let name: String
            let size_description: String
            let language_count: Int
            let status: String
            let selected: Bool
        }

        let models = ModelInfo.allModels.map { model in
            let status = statuses[model.id] ?? .notDownloaded
            let statusStr: String
            switch status {
            case .notDownloaded: statusStr = "not_downloaded"
            case .downloading: statusStr = "downloading"
            case .loading: statusStr = "loading"
            case .ready: statusStr = "ready"
            case .error: statusStr = "error"
            }

            return ModelEntry(
                id: model.id,
                engine: model.engineType.rawValue,
                name: model.displayName,
                size_description: model.sizeDescription,
                language_count: model.languageCount,
                status: statusStr,
                selected: model.id == selectedId
            )
        }

        struct ModelsResponse: Encodable { let models: [ModelEntry] }
        return .json(ModelsResponse(models: models))
    }

    // MARK: - Helpers

    private func extractBoundary(from contentType: String) -> String? {
        for part in contentType.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                    boundary = String(boundary.dropFirst().dropLast())
                }
                return boundary
            }
        }
        return nil
    }

    private func extensionFromMIME(_ mime: String) -> String {
        let lower = mime.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("wav") || lower.contains("wave") { return "wav" }
        if lower.contains("mp3") || lower.contains("mpeg") { return "mp3" }
        if lower.contains("m4a") || lower.contains("mp4") { return "m4a" }
        if lower.contains("flac") { return "flac" }
        if lower.contains("ogg") { return "ogg" }
        if lower.contains("aac") { return "aac" }
        return "wav"
    }
}
