import Foundation
import os

private let apiLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "APIHandlers")

final class APIHandlers: @unchecked Sendable {
    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService
    private let translationService: AnyObject? // TranslationService (macOS 15+)
    private let historyService: HistoryService
    private let profileService: ProfileService
    private let dictionaryService: DictionaryService
    private let dictationViewModel: DictationViewModel

    init(
        modelManager: ModelManagerService,
        audioFileService: AudioFileService,
        translationService: AnyObject?,
        historyService: HistoryService,
        profileService: ProfileService,
        dictionaryService: DictionaryService,
        dictationViewModel: DictationViewModel
    ) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.translationService = translationService
        self.historyService = historyService
        self.profileService = profileService
        self.dictionaryService = dictionaryService
        self.dictationViewModel = dictationViewModel
    }

    func register(on router: APIRouter) {
        router.register("POST", "/v1/transcribe", handler: handleTranscribe)
        router.register("GET", "/v1/status", handler: handleStatus)
        router.register("GET", "/v1/models", handler: handleModels)
        router.register("GET", "/v1/history", handler: handleGetHistory)
        router.register("DELETE", "/v1/history", handler: handleDeleteHistory)
        router.register("GET", "/v1/rules", handler: handleGetRules)
        router.register("PUT", "/v1/rules/toggle", handler: handleToggleRule)
        router.register("GET", "/v1/profiles", handler: handleGetRules)
        router.register("PUT", "/v1/profiles/toggle", handler: handleToggleRule)
        router.register("POST", "/v1/dictation/start", handler: handleStartDictation)
        router.register("POST", "/v1/dictation/stop", handler: handleStopDictation)
        router.register("GET", "/v1/dictation/status", handler: handleDictationStatus)
        router.register("GET", "/v1/dictation/transcription", handler: handleDictationTranscription)
        router.register("GET", "/v1/dictionary/terms", handler: handleGetDictionaryTerms)
        router.register("PUT", "/v1/dictionary/terms", handler: handlePutDictionaryTerms)
        router.register("DELETE", "/v1/dictionary/terms", handler: handleDeleteDictionaryTerms)
    }

    // MARK: - POST /v1/transcribe

    private func handleTranscribe(_ request: HTTPRequest) async -> HTTPResponse {
        // Note: Don't pre-check isModelReady here - let transcribe() handle auto-restore
        // for models that were auto-unloaded but can be re-loaded.
        let hasEngine = await modelManager.selectedProviderId != nil
        guard hasEngine else {
            return .error(status: 503, message: "No engine selected. Select an engine in TypeWhisper first.")
        }

        let audioData: Data
        var fileExtension = "wav"
        var language: String?
        var languageHints: [String] = []
        var task: TranscriptionTask = .transcribe
        var targetLanguage: String?
        var responseFormat = "json"
        var requestPrompt: String?

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

            languageHints = parts
                .filter { $0.name == "language_hint" }
                .compactMap { String(data: $0.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

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

            if let formatPart = parts.first(where: { $0.name == "response_format" }),
               let val = String(data: formatPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                responseFormat = val
            }

            if let promptPart = parts.first(where: { $0.name == "prompt" }),
               let val = String(data: promptPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                requestPrompt = val
            }
        } else if !request.body.isEmpty {
            audioData = request.body
            fileExtension = extensionFromMIME(contentType)
            language = request.headers["x-language"]
            languageHints = request.headers["x-language-hints"]?
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            if let taskStr = request.headers["x-task"], let parsed = TranscriptionTask(rawValue: taskStr) {
                task = parsed
            }
            targetLanguage = request.headers["x-target-language"]
            if let format = request.headers["x-response-format"], !format.isEmpty {
                responseFormat = format
            }
            if let prompt = request.headers["x-prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                requestPrompt = prompt
            }
        } else {
            return .error(status: 400, message: "No audio data provided")
        }

        guard !audioData.isEmpty else {
            return .error(status: 400, message: "Empty audio data")
        }

        if language != nil, !languageHints.isEmpty {
            return .error(status: 400, message: "Use either 'language' or 'language_hint', not both")
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(fileExtension)")

        do {
            try audioData.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let samples = try await audioFileService.loadAudioSamples(from: tempURL)
            let dictionaryPrompt = await MainActor.run { dictionaryService.getTermsForPrompt() }
            let prompt = mergedPrompt(requestPrompt: requestPrompt, dictionaryPrompt: dictionaryPrompt)
            let languageSelection: LanguageSelection
            if !languageHints.isEmpty {
                languageSelection = LanguageSelection.auto.withSelectedCodes(languageHints, nilBehavior: .auto)
            } else if let language {
                languageSelection = .exact(language)
            } else {
                languageSelection = .auto
            }
            let result = try await modelManager.transcribe(
                audioSamples: samples,
                languageSelection: languageSelection,
                task: task,
                prompt: prompt
            )

            var finalText = result.text
            if let targetCode = targetLanguage {
                #if canImport(Translation)
                if #available(macOS 15, *), let ts = translationService as? TranslationService {
                    if let targetNormalized = TranslationService.normalizedLanguageIdentifier(from: targetCode) {
                        if targetCode.caseInsensitiveCompare(targetNormalized) != .orderedSame {
                            apiLogger.info("API translation target normalized \(targetCode, privacy: .public) -> \(targetNormalized, privacy: .public)")
                        }
                        let target = Locale.Language(identifier: targetNormalized)
                        let sourceRaw = result.detectedLanguage
                        let sourceNormalized = TranslationService.normalizedLanguageIdentifier(from: sourceRaw)
                        if let sourceRaw {
                            if let sourceNormalized {
                                if sourceRaw.caseInsensitiveCompare(sourceNormalized) != .orderedSame {
                                    apiLogger.info("API translation source normalized \(sourceRaw, privacy: .public) -> \(sourceNormalized, privacy: .public)")
                                }
                            } else {
                                apiLogger.warning("API translation source language \(sourceRaw, privacy: .public) invalid, using auto source")
                            }
                        }
                        let sourceLanguage = sourceNormalized.map { Locale.Language(identifier: $0) }
                        finalText = try await ts.translate(
                            text: finalText,
                            to: target,
                            source: sourceLanguage
                        )
                    } else {
                        apiLogger.error("API translation target language invalid: \(targetCode, privacy: .public)")
                    }
                } else {
                    return .error(status: 501, message: "Translation requires macOS 15 or later")
                }
                #else
                return .error(status: 501, message: "Translation requires macOS 15 or later")
                #endif
            }

            let modelId = await modelManager.selectedModelId

            if responseFormat == "verbose_json" {
                struct SegmentEntry: Encodable {
                    let start: Double
                    let end: Double
                    let text: String
                }

                struct VerboseResponse: Encodable {
                    let text: String
                    let language: String?
                    let duration: Double
                    let processing_time: Double
                    let engine: String
                    let model: String?
                    let segments: [SegmentEntry]
                }

                let segments = result.segments.map {
                    SegmentEntry(start: $0.start, end: $0.end, text: $0.text)
                }

                return .json(VerboseResponse(
                    text: finalText,
                    language: result.detectedLanguage,
                    duration: result.duration,
                    processing_time: result.processingTime,
                    engine: result.engineUsed,
                    model: modelId,
                    segments: segments
                ))
            } else {
                struct TranscribeResponse: Encodable {
                    let text: String
                    let language: String?
                    let duration: Double
                    let processing_time: Double
                    let engine: String
                    let model: String?
                }

                return .json(TranscribeResponse(
                    text: finalText,
                    language: result.detectedLanguage,
                    duration: result.duration,
                    processing_time: result.processingTime,
                    engine: result.engineUsed,
                    model: modelId
                ))
            }
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func mergedPrompt(requestPrompt: String?, dictionaryPrompt: String?) -> String? {
        let components = [requestPrompt, dictionaryPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "\n")
    }

    // MARK: - GET /v1/status

    private func handleStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let providerId = await modelManager.selectedProviderId
        let modelId = await modelManager.selectedModelId
        let isReady = await modelManager.isModelReady
        let supportsStreaming = await modelManager.supportsStreaming
        let supportsTranslation = await modelManager.supportsTranslation

        struct StatusResponse: Encodable {
            let status: String
            let engine: String?
            let model: String?
            let supports_streaming: Bool
            let supports_translation: Bool
        }

        let response = StatusResponse(
            status: isReady ? "ready" : "no_model",
            engine: providerId,
            model: modelId,
            supports_streaming: supportsStreaming,
            supports_translation: supportsTranslation
        )
        return .json(response)
    }

    // MARK: - GET /v1/models

    @MainActor
    private func handleModels(_ request: HTTPRequest) async -> HTTPResponse {
        struct ModelEntry: Encodable {
            let id: String
            let engine: String
            let name: String
            let size_description: String
            let language_count: Int
            let status: String
            let selected: Bool
            let downloaded: Bool?
            let loaded: Bool?
        }

        let selectedProviderId = modelManager.selectedProviderId
        var models: [ModelEntry] = []

        for engine in PluginManager.shared.transcriptionEngines {
            let isSelected = engine.providerId == selectedProviderId
            for model in engine.availableModels {
                models.append(ModelEntry(
                    id: model.id,
                    engine: engine.providerId,
                    name: model.displayName,
                    size_description: model.sizeDescription,
                    language_count: model.languageCount,
                    status: engine.isConfigured ? "ready" : "not_configured",
                    selected: isSelected && engine.selectedModelId == model.id,
                    downloaded: model.downloaded,
                    loaded: model.loaded
                ))
            }
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

    // MARK: - /v1/dictionary/terms

    private func handleGetDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DictionaryTermsResponse: Encodable {
            let terms: [String]
            let count: Int
        }

        return await MainActor.run {
            let terms = dictionaryService.enabledTerms()
            return .json(DictionaryTermsResponse(terms: terms, count: terms.count))
        }
    }

    private func handlePutDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DictionaryTermsRequest: Decodable {
            let terms: [String]
            let replace: Bool?
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DictionaryTermsRequest
        do {
            payload = try JSONDecoder().decode(DictionaryTermsRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        struct DictionaryTermsResponse: Encodable {
            let terms: [String]
            let count: Int
        }

        return await MainActor.run {
            dictionaryService.setTerms(payload.terms, replaceExisting: payload.replace ?? false)
            let terms = dictionaryService.enabledTerms()
            return .json(DictionaryTermsResponse(terms: terms, count: terms.count))
        }
    }

    private func handleDeleteDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DeleteResponse: Encodable {
            let deleted: Bool
            let count: Int
        }

        return await MainActor.run {
            dictionaryService.removeAllTerms()
            return .json(DeleteResponse(deleted: true, count: 0))
        }
    }

    // MARK: - GET /v1/rules

    private func handleGetRules(_ request: HTTPRequest) async -> HTTPResponse {
        let profileService = self.profileService
        return await MainActor.run {
            struct RuleEntry: Encodable {
                let id: String
                let name: String
                let is_enabled: Bool
                let priority: Int
                let bundle_identifiers: [String]
                let url_patterns: [String]
                let input_language: String?
                let language_mode: String
                let language_hints: [String]
                let translation_target_language: String?
            }

            struct RulesResponse: Encodable {
                let rules: [RuleEntry]
                let profiles: [RuleEntry]
            }

            let entries = profileService.profiles.map { profile in
                let selection = profile.inputLanguageSelection
                let legacyInputLanguage: String?
                switch selection {
                case .auto:
                    legacyInputLanguage = "auto"
                case .exact(let code):
                    legacyInputLanguage = code
                case .inheritGlobal, .hints:
                    legacyInputLanguage = nil
                }

                return RuleEntry(
                    id: profile.id.uuidString,
                    name: profile.name,
                    is_enabled: profile.isEnabled,
                    priority: profile.priority,
                    bundle_identifiers: profile.bundleIdentifiers,
                    url_patterns: profile.urlPatterns,
                    input_language: legacyInputLanguage,
                    language_mode: selection.mode.rawValue,
                    language_hints: selection.selectedCodes,
                    translation_target_language: profile.translationTargetLanguage
                )
            }

            return .json(RulesResponse(rules: entries, profiles: entries))
        }
    }

    // MARK: - PUT /v1/rules/toggle

    private func handleToggleRule(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let profileService = self.profileService
        return await MainActor.run {
            guard let profile = profileService.profiles.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Rule not found")
            }

            profileService.toggleProfile(profile)

            struct ToggleResponse: Encodable {
                let id: String
                let name: String
                let rule_name: String
                let profile_name: String
                let is_enabled: Bool
            }

            return .json(ToggleResponse(
                id: profile.id.uuidString,
                name: profile.name,
                rule_name: profile.name,
                profile_name: profile.name,
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

            let id = dictationViewModel.apiStartRecording()
            if let session = dictationViewModel.apiDictationSession(id: id), session.status == .failed {
                return .error(status: 409, message: session.error ?? "Failed to start dictation")
            }

            struct StartResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StartResponse(id: id.uuidString, status: "recording"))
        }
    }

    // MARK: - POST /v1/dictation/stop

    private func handleStopDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard dictationViewModel.isRecording else {
                return .error(status: 409, message: "Not recording")
            }
            guard let id = dictationViewModel.apiStopRecording() else {
                return .error(status: 500, message: "Missing active dictation session")
            }

            struct StopResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StopResponse(id: id.uuidString, status: "stopped"))
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

    // MARK: - GET /v1/dictation/transcription

    private func handleDictationTranscription(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard let session = dictationViewModel.apiDictationSession(id: uuid) else {
                return .error(status: 404, message: "Dictation session not found")
            }

            struct DictationTranscriptionPayload: Encodable {
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

            struct DictationTranscriptionResponse: Encodable {
                let id: String
                let status: String
                let transcription: DictationTranscriptionPayload?
                let error: String?
            }

            let transcription = session.transcription.map {
                DictationTranscriptionPayload(
                    text: $0.text,
                    raw_text: $0.rawText,
                    timestamp: $0.timestamp,
                    app_name: $0.appName,
                    app_bundle_id: $0.appBundleIdentifier,
                    app_url: $0.appURL,
                    duration: $0.duration,
                    language: $0.language,
                    engine: $0.engine,
                    model: $0.model,
                    words_count: $0.wordsCount
                )
            }

            return .json(DictationTranscriptionResponse(
                id: session.id.uuidString,
                status: session.status.rawValue,
                transcription: transcription,
                error: session.error
            ))
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
