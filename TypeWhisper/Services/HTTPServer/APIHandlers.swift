import Foundation

final class APIHandlers: @unchecked Sendable {
    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService
    private let translationService: TranslationService
    private let historyService: HistoryService
    private let profileService: ProfileService
    private let dictationViewModel: DictationViewModel

    init(modelManager: ModelManagerService, audioFileService: AudioFileService, translationService: TranslationService, historyService: HistoryService, profileService: ProfileService, dictationViewModel: DictationViewModel) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.translationService = translationService
        self.historyService = historyService
        self.profileService = profileService
        self.dictationViewModel = dictationViewModel
    }

    func register(on router: APIRouter) {
        router.register("POST", "/v1/transcribe", handler: handleTranscribe)
        router.register("GET", "/v1/status", handler: handleStatus)
        router.register("GET", "/v1/models", handler: handleModels)
        router.register("GET", "/v1/history", handler: handleGetHistory)
        router.register("DELETE", "/v1/history", handler: handleDeleteHistory)
        router.register("GET", "/v1/profiles", handler: handleGetProfiles)
        router.register("PUT", "/v1/profiles/toggle", handler: handleToggleProfile)
        router.register("POST", "/v1/dictation/start", handler: handleStartDictation)
        router.register("POST", "/v1/dictation/stop", handler: handleStopDictation)
        router.register("GET", "/v1/dictation/status", handler: handleDictationStatus)
    }

    // MARK: - POST /v1/transcribe

    private func handleTranscribe(_ request: HTTPRequest) async -> HTTPResponse {
        let isReady = await modelManager.isEngineLoaded
        guard isReady else {
            return .error(status: 503, message: "No model loaded. Load a model in TypeWhisper first.")
        }

        let audioData: Data
        var fileExtension = "wav"
        var language: String?
        var task: TranscriptionTask = .transcribe
        var targetLanguage: String?

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

            if let targetPart = parts.first(where: { $0.name == "target_language" }),
               let val = String(data: targetPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                targetLanguage = val
            }
        } else if !request.body.isEmpty {
            audioData = request.body
            fileExtension = extensionFromMIME(contentType)
            language = request.headers["x-language"]
            if let taskStr = request.headers["x-task"], let parsed = TranscriptionTask(rawValue: taskStr) {
                task = parsed
            }
            targetLanguage = request.headers["x-target-language"]
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

            var finalText = result.text
            if let targetCode = targetLanguage {
                let target = Locale.Language(identifier: targetCode)
                finalText = try await translationService.translate(text: finalText, to: target)
            }

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
                text: finalText,
                language: result.detectedLanguage,
                duration: result.duration,
                processing_time: result.processingTime,
                engine: result.engineUsed,
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
        let isReady = await modelManager.isEngineLoaded

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
            case .loading(_): statusStr = "loading"
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

    // MARK: - GET /v1/history

    private func handleGetHistory(_ request: HTTPRequest) async -> HTTPResponse {
        let query = request.queryParams["q"]
        let limit = min(Int(request.queryParams["limit"] ?? "") ?? 50, 200)
        let offset = max(Int(request.queryParams["offset"] ?? "") ?? 0, 0)

        let historyService = self.historyService
        return await MainActor.run {
            let allRecords: [TranscriptionRecord]
            if let query, !query.isEmpty {
                allRecords = historyService.searchRecords(query: query)
            } else {
                allRecords = historyService.records
            }

            let total = allRecords.count
            let sliceEnd = min(offset + limit, total)
            let sliceStart = min(offset, total)
            let page = Array(allRecords[sliceStart..<sliceEnd])

            struct HistoryEntry: Encodable {
                let id: String
                let text: String
                let raw_text: String
                let timestamp: Date
                let app_name: String?
                let app_bundle_id: String?
                let app_url: String?
                let duration: Double
                let language: String?
                let engine: String
                let model: String?
                let words_count: Int
            }

            struct HistoryResponse: Encodable {
                let entries: [HistoryEntry]
                let total: Int
                let limit: Int
                let offset: Int
            }

            let entries = page.map { record in
                HistoryEntry(
                    id: record.id.uuidString,
                    text: record.finalText,
                    raw_text: record.rawText,
                    timestamp: record.timestamp,
                    app_name: record.appName,
                    app_bundle_id: record.appBundleIdentifier,
                    app_url: record.appURL,
                    duration: record.durationSeconds,
                    language: record.language,
                    engine: record.engineUsed,
                    model: record.modelUsed,
                    words_count: record.wordsCount
                )
            }

            return .json(HistoryResponse(entries: entries, total: total, limit: limit, offset: offset))
        }
    }

    // MARK: - DELETE /v1/history

    private func handleDeleteHistory(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let historyService = self.historyService
        return await MainActor.run {
            guard let record = historyService.records.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "History entry not found")
            }

            historyService.deleteRecord(record)
            return .json(["deleted": true])
        }
    }

    // MARK: - GET /v1/profiles

    private func handleGetProfiles(_ request: HTTPRequest) async -> HTTPResponse {
        let profileService = self.profileService
        return await MainActor.run {
            struct ProfileEntry: Encodable {
                let id: String
                let name: String
                let is_enabled: Bool
                let priority: Int
                let bundle_identifiers: [String]
                let url_patterns: [String]
                let input_language: String?
                let translation_target_language: String?
            }

            struct ProfilesResponse: Encodable {
                let profiles: [ProfileEntry]
            }

            let entries = profileService.profiles.map { profile in
                ProfileEntry(
                    id: profile.id.uuidString,
                    name: profile.name,
                    is_enabled: profile.isEnabled,
                    priority: profile.priority,
                    bundle_identifiers: profile.bundleIdentifiers,
                    url_patterns: profile.urlPatterns,
                    input_language: profile.inputLanguage,
                    translation_target_language: profile.translationTargetLanguage
                )
            }

            return .json(ProfilesResponse(profiles: entries))
        }
    }

    // MARK: - PUT /v1/profiles/toggle

    private func handleToggleProfile(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let profileService = self.profileService
        return await MainActor.run {
            guard let profile = profileService.profiles.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Profile not found")
            }

            profileService.toggleProfile(profile)

            struct ToggleResponse: Encodable {
                let id: String
                let name: String
                let is_enabled: Bool
            }

            return .json(ToggleResponse(
                id: profile.id.uuidString,
                name: profile.name,
                is_enabled: profile.isEnabled
            ))
        }
    }

    // MARK: - POST /v1/dictation/start

    private func handleStartDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard !dictationViewModel.isRecording else {
                return .error(status: 409, message: "Already recording")
            }
            dictationViewModel.apiStartRecording()

            struct StartResponse: Encodable { let status: String }
            return .json(StartResponse(status: "recording"))
        }
    }

    // MARK: - POST /v1/dictation/stop

    private func handleStopDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard dictationViewModel.isRecording else {
                return .error(status: 409, message: "Not recording")
            }
            dictationViewModel.apiStopRecording()

            struct StopResponse: Encodable { let status: String }
            return .json(StopResponse(status: "stopped"))
        }
    }

    // MARK: - GET /v1/dictation/status

    private func handleDictationStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            struct DictationStatusResponse: Encodable { let is_recording: Bool }
            return .json(DictationStatusResponse(is_recording: dictationViewModel.isRecording))
        }
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
