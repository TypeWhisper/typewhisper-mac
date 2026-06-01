import Foundation
import os

private let apiLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "APIHandlers")

final class APIHandlers: @unchecked Sendable {
    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService
    private let translationService: AnyObject? // TranslationService (macOS 15+)
    private let historyService: HistoryService
    private let workflowService: WorkflowService
    private let dictionaryService: DictionaryService
    private let dictationViewModel: DictationViewModel
    private let audioRecorderViewModel: AudioRecorderViewModel

    init(
        modelManager: ModelManagerService,
        audioFileService: AudioFileService,
        translationService: AnyObject?,
        historyService: HistoryService,
        workflowService: WorkflowService,
        dictionaryService: DictionaryService,
        dictationViewModel: DictationViewModel,
        audioRecorderViewModel: AudioRecorderViewModel
    ) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.translationService = translationService
        self.historyService = historyService
        self.workflowService = workflowService
        self.dictionaryService = dictionaryService
        self.dictationViewModel = dictationViewModel
        self.audioRecorderViewModel = audioRecorderViewModel
    }

    func register(on router: APIRouter) {
        router.register("POST", "/v1/transcribe", handler: handleTranscribe)
        router.register("POST", "/v1/transcribe/local-file", handler: handleTranscribeLocalFile)
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
        router.register("POST", "/v1/recorder/start", handler: handleStartRecorder)
        router.register("POST", "/v1/recorder/stop", handler: handleStopRecorder)
        router.register("GET", "/v1/recorder/status", handler: handleRecorderStatus)
        router.register("GET", "/v1/recorder/session", handler: handleRecorderSession)
        router.register("GET", "/v1/dictionary/terms", handler: handleGetDictionaryTerms)
        router.register("PUT", "/v1/dictionary/terms", handler: handlePutDictionaryTerms)
        router.register("DELETE", "/v1/dictionary/terms", handler: handleDeleteDictionaryTerms)
        router.register("GET", "/v1/dictionary/corrections", handler: handleGetDictionaryCorrections)
        router.register("PUT", "/v1/dictionary/corrections", handler: handlePutDictionaryCorrections)
        router.register("DELETE", "/v1/dictionary/corrections", handler: handleDeleteDictionaryCorrections)
    }

    // MARK: - POST /v1/transcribe

    private struct TranscribeOptions {
        var language: String? = nil
        var languageHints: [String] = []
        var task: TranscriptionTask = .transcribe
        var targetLanguage: String? = nil
        var responseFormat = "json"
        var requestPrompt: String? = nil
        var engineOverride: String? = nil
        var modelOverride: String? = nil
        var awaitDownload = false
        var normalizeNumbers: Bool? = nil
    }

    private struct LocalFileTranscribeRequest: Decodable {
        let path: String
        let language: String?
        let languageHints: [String]?
        let task: String?
        let targetLanguage: String?
        let responseFormat: String?
        let prompt: String?
        let engine: String?
        let model: String?
        let normalizeNumbers: Bool?

        enum CodingKeys: String, CodingKey {
            case path
            case language
            case languageHints = "language_hints"
            case task
            case targetLanguage = "target_language"
            case responseFormat = "response_format"
            case prompt
            case engine
            case model
            case normalizeNumbers = "normalize_numbers"
        }
    }

    private func handleTranscribe(_ request: HTTPRequest) async -> HTTPResponse {
        let audioData: Data
        var fileExtension = "wav"
        var options = TranscribeOptions(awaitDownload: request.queryParams["await_download"] == "1")

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
                options.language = val
            }

            options.languageHints = parts
                .filter { $0.name == "language_hint" }
                .compactMap { String(data: $0.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let taskPart = parts.first(where: { $0.name == "task" }),
               let val = String(data: taskPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = TranscriptionTask(rawValue: val) {
                options.task = parsed
            }

            if let targetPart = parts.first(where: { $0.name == "target_language" }),
               let val = String(data: targetPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.targetLanguage = val
            }

            if let formatPart = parts.first(where: { $0.name == "response_format" }),
               let val = String(data: formatPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.responseFormat = val
            }

            if let promptPart = parts.first(where: { $0.name == "prompt" }),
               let val = String(data: promptPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.requestPrompt = val
            }

            if let enginePart = parts.first(where: { $0.name == "engine" }),
               let val = String(data: enginePart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.engineOverride = val
            }

            if let modelPart = parts.first(where: { $0.name == "model" }),
               let val = String(data: modelPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.modelOverride = val
            }

            if let normalizePart = parts.first(where: { $0.name == "normalize_numbers" }),
               let val = String(data: normalizePart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                options.normalizeNumbers = Self.parseBoolean(val)
            }
        } else if !request.body.isEmpty {
            audioData = request.body
            fileExtension = extensionFromMIME(contentType)
            options.language = request.headers["x-language"]
            options.languageHints = request.headers["x-language-hints"]?
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            if let taskStr = request.headers["x-task"], let parsed = TranscriptionTask(rawValue: taskStr) {
                options.task = parsed
            }
            options.targetLanguage = request.headers["x-target-language"]
            if let format = request.headers["x-response-format"], !format.isEmpty {
                options.responseFormat = format
            }
            if let prompt = request.headers["x-prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                options.requestPrompt = prompt
            }
            if let engine = request.headers["x-engine"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !engine.isEmpty {
                options.engineOverride = engine
            }
            if let model = request.headers["x-model"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !model.isEmpty {
                options.modelOverride = model
            }
            if let normalizeNumbers = request.headers["x-normalize-numbers"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !normalizeNumbers.isEmpty {
                options.normalizeNumbers = Self.parseBoolean(normalizeNumbers)
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
            return await transcribeLoadedSamples(samples, options: options)
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func handleTranscribeLocalFile(_ request: HTTPRequest) async -> HTTPResponse {
        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: LocalFileTranscribeRequest
        do {
            payload = try JSONDecoder().decode(LocalFileTranscribeRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let fileURL = URL(fileURLWithPath: payload.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .error(status: 400, message: "File not found")
        }

        guard AudioFileService.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return .error(status: 400, message: "Unsupported audio format")
        }

        var options = TranscribeOptions(awaitDownload: request.queryParams["await_download"] == "1")
        options.language = payload.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.languageHints = payload.languageHints?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        if let task = payload.task.flatMap(TranscriptionTask.init(rawValue:)) {
            options.task = task
        }
        options.targetLanguage = payload.targetLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let responseFormat = payload.responseFormat?.trimmingCharacters(in: .whitespacesAndNewlines), !responseFormat.isEmpty {
            options.responseFormat = responseFormat
        }
        options.requestPrompt = payload.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.engineOverride = payload.engine?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.modelOverride = payload.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.normalizeNumbers = payload.normalizeNumbers

        do {
            let samples = try await audioFileService.loadAudioSamples(from: fileURL)
            return await transcribeLoadedSamples(samples, options: options)
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func transcribeLoadedSamples(_ samples: [Float], options: TranscribeOptions) async -> HTTPResponse {
        if options.language != nil, !options.languageHints.isEmpty {
            return .error(status: 400, message: "Use either 'language' or 'language_hint', not both")
        }

        let resolvedOverride: ResolvedOverride
        switch await resolveEngineModelOverride(
            engine: options.engineOverride,
            model: options.modelOverride,
            awaitDownload: options.awaitDownload
        ) {
        case .use(let value):
            resolvedOverride = value
        case .reject(let response):
            return response
        }

        if resolvedOverride.engineId == nil {
            let hasEngine = await modelManager.selectedProviderId != nil
            guard hasEngine else {
                return .error(status: 503, message: "No engine selected. Select an engine in TypeWhisper first.")
            }
        }

        do {
            let effectiveProviderId: String?
            if let engineId = resolvedOverride.engineId {
                effectiveProviderId = engineId
            } else {
                effectiveProviderId = await modelManager.selectedProviderId
            }
            let dictionaryPrompt = await MainActor.run {
                dictionaryService.getTermsForPrompt(providerId: effectiveProviderId)
            }
            let prompt = mergedPrompt(requestPrompt: options.requestPrompt, dictionaryPrompt: dictionaryPrompt)
            let languageSelection: LanguageSelection
            if !options.languageHints.isEmpty {
                languageSelection = LanguageSelection.auto.withSelectedCodes(options.languageHints, nilBehavior: .auto)
            } else if let language = options.language {
                languageSelection = .exact(language)
            } else {
                languageSelection = .auto
            }
            let result = try await modelManager.transcribe(
                audioSamples: samples,
                languageSelection: languageSelection,
                task: options.task,
                engineOverrideId: resolvedOverride.engineId,
                cloudModelOverride: resolvedOverride.modelId,
                prompt: prompt,
                normalizeNumbers: options.normalizeNumbers
            )

            var finalText = result.text
            if let targetCode = options.targetLanguage {
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

            let modelId = await resolveResponseModelId(
                override: resolvedOverride,
                engineUsed: result.engineUsed
            )

            if options.responseFormat == "verbose_json" {
                struct SegmentEntry: Encodable {
                    let start: Double
                    let end: Double
                    let text: String
                    let speaker: String?
                    let speakerConfidence: Double?

                    enum CodingKeys: String, CodingKey {
                        case start
                        case end
                        case text
                        case speaker
                        case speakerConfidence = "speaker_confidence"
                    }

                    func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(start, forKey: .start)
                        try container.encode(end, forKey: .end)
                        try container.encode(text, forKey: .text)
                        try container.encodeIfPresent(speaker, forKey: .speaker)
                        try container.encodeIfPresent(speakerConfidence, forKey: .speakerConfidence)
                    }
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
                    SegmentEntry(
                        start: $0.start,
                        end: $0.end,
                        text: $0.text,
                        speaker: $0.speakerLabel,
                        speakerConfidence: $0.speakerConfidence
                    )
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

    // MARK: - Engine/Model Override Resolution

    private struct ResolvedOverride {
        let engineId: String?
        let modelId: String?
    }

    private enum OverrideResolution {
        case use(ResolvedOverride)
        case reject(HTTPResponse)
    }

    /// Resolve per-request `engine` / `model` overrides against the full set of loaded
    /// transcription plugins. Implements the matrix from issue #317:
    ///
    /// - both nil -> use GUI selection
    /// - engine only -> use that engine's default model
    /// - model only -> infer engine by scanning the model catalog across all engines
    /// - both set   -> use as-is
    ///
    /// Also enforces configuration: an unconfigured engine returns 409 by default (to
    /// distinguish "typo" from "needs setup") unless the caller passed `?await_download=1`,
    /// in which case the usual `triggerRestoreModel` retry path is allowed to run.
    @MainActor
    private func resolveEngineModelOverride(
        engine: String?,
        model: String?,
        awaitDownload: Bool
    ) -> OverrideResolution {
        if engine == nil, model == nil {
            return .use(ResolvedOverride(engineId: nil, modelId: nil))
        }

        let engines = PluginManager.shared.transcriptionEngines

        let resolvedEngineId: String?
        if let engine {
            guard let match = engines.first(where: { $0.providerId == engine }) else {
                return .reject(.error(status: 400, message: "Unknown engine '\(engine)'"))
            }
            resolvedEngineId = match.providerId
        } else if let model {
            let matches = engines.filter { engine in
                engine.modelCatalog.contains(where: { $0.id == model })
            }
            if matches.isEmpty {
                return .reject(.error(status: 400, message: "Unknown model '\(model)'"))
            }
            if matches.count > 1 {
                let engineIds = matches.map { $0.providerId }.joined(separator: ", ")
                return .reject(.error(
                    status: 400,
                    message: "Ambiguous model id '\(model)' -- matches engines: \(engineIds). Specify 'engine' too."
                ))
            }
            resolvedEngineId = matches[0].providerId
        } else {
            resolvedEngineId = nil
        }

        if let engineId = resolvedEngineId,
           let model,
           let plugin = engines.first(where: { $0.providerId == engineId }) {
            let ids = Set(plugin.modelCatalog.map { $0.id })
            if !ids.isEmpty, !ids.contains(model) {
                return .reject(.error(
                    status: 400,
                    message: "Model '\(model)' is not offered by engine '\(engineId)'"
                ))
            }
        }

        if let engineId = resolvedEngineId,
           let plugin = engines.first(where: { $0.providerId == engineId }),
           !plugin.isConfigured,
           !awaitDownload {
            return .reject(.error(
                status: 409,
                message: "Engine '\(engineId)' is not configured (missing API key or downloaded weights). Pass ?await_download=1 to wait for restore."
            ))
        }

        return .use(ResolvedOverride(engineId: resolvedEngineId, modelId: model))
    }

    @MainActor
    private func resolveResponseModelId(override: ResolvedOverride, engineUsed: String) -> String? {
        if let modelId = override.modelId { return modelId }
        if let engineId = override.engineId,
           let plugin = PluginManager.shared.transcriptionEngine(for: engineId) {
            return plugin.selectedModelId
        }
        if let plugin = PluginManager.shared.transcriptionEngine(for: engineUsed) {
            return plugin.selectedModelId
        }
        return nil
    }

    private func mergedPrompt(requestPrompt: String?, dictionaryPrompt: String?) -> String? {
        let components = [requestPrompt, dictionaryPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "\n")
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        case "0", "false", "no", "off":
            false
        default:
            nil
        }
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
            for model in engine.modelCatalog {
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

        do {
            return try await MainActor.run {
                try dictionaryService.setAPITerms(payload.terms, replaceExisting: payload.replace ?? false)
                let terms = dictionaryService.enabledTerms()
                return .json(DictionaryTermsResponse(terms: terms, count: terms.count))
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    private func handleDeleteDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DeleteDictionaryTermRequest: Decodable {
            let term: String
        }

        struct DeleteResponse: Encodable {
            let deleted: Bool
            let count: Int
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DeleteDictionaryTermRequest
        do {
            payload = try JSONDecoder().decode(DeleteDictionaryTermRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let term = payload.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return .error(status: 400, message: "Missing or empty 'term'")
        }

        do {
            return try await MainActor.run {
                let deleted = try dictionaryService.deleteAPITerm(term)
                let terms = dictionaryService.enabledTerms()
                return .json(DeleteResponse(deleted: deleted, count: terms.count))
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    // MARK: - /v1/dictionary/corrections

    private struct DictionaryCorrectionEntry: Encodable {
        let original: String
        let replacement: String
        let caseSensitive: Bool
    }

    private struct DictionaryCorrectionsResponse: Encodable {
        let corrections: [DictionaryCorrectionEntry]
        let count: Int
    }

    private func handleGetDictionaryCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        await MainActor.run {
            dictionaryCorrectionsResponse()
        }
    }

    private func handlePutDictionaryCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct DictionaryCorrectionRequest: Decodable {
            let original: String
            let replacement: String
            let caseSensitive: Bool?
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DictionaryCorrectionRequest
        do {
            payload = try JSONDecoder().decode(DictionaryCorrectionRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let original = payload.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return .error(status: 400, message: "Missing or empty 'original'")
        }

        do {
            return try await MainActor.run {
                try dictionaryService.upsertAPICorrection(
                    original: original,
                    replacement: payload.replacement,
                    caseSensitive: payload.caseSensitive ?? false
                )
                return dictionaryCorrectionsResponse()
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    private func handleDeleteDictionaryCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct DeleteDictionaryCorrectionRequest: Decodable {
            let original: String
        }

        struct DeleteResponse: Encodable {
            let deleted: Bool
            let count: Int
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DeleteDictionaryCorrectionRequest
        do {
            payload = try JSONDecoder().decode(DeleteDictionaryCorrectionRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let original = payload.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return .error(status: 400, message: "Missing or empty 'original'")
        }

        do {
            return try await MainActor.run {
                let deleted = try dictionaryService.deleteAPICorrection(original: original)
                let count = dictionaryService.corrections.count
                return .json(DeleteResponse(deleted: deleted, count: count))
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func dictionaryCorrectionsResponse() -> HTTPResponse {
        let corrections = dictionaryService.corrections.map {
            DictionaryCorrectionEntry(
                original: $0.original,
                replacement: $0.replacement ?? "",
                caseSensitive: $0.caseSensitive
            )
        }
        return .json(DictionaryCorrectionsResponse(corrections: corrections, count: corrections.count))
    }

    // MARK: - GET /v1/rules

    private func handleGetRules(_ request: HTTPRequest) async -> HTTPResponse {
        let workflowService = self.workflowService
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

            let entries = workflowService.workflows.map { workflow in
                let selection = workflow.inputLanguageSelection
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
                    id: workflow.id.uuidString,
                    name: workflow.name,
                    is_enabled: workflow.isEnabled,
                    priority: workflow.sortOrder,
                    bundle_identifiers: workflow.trigger?.appBundleIdentifiers ?? [],
                    url_patterns: workflow.trigger?.websitePatterns ?? [],
                    input_language: legacyInputLanguage,
                    language_mode: selection.mode.rawValue,
                    language_hints: selection.selectedCodes,
                    translation_target_language: workflow.translationTargetLanguage
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

        let workflowService = self.workflowService
        return await MainActor.run {
            guard let workflow = workflowService.workflows.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Rule not found")
            }

            workflowService.toggleWorkflow(workflow)

            struct ToggleResponse: Encodable {
                let id: String
                let name: String
                let rule_name: String
                let profile_name: String
                let is_enabled: Bool
            }

            return .json(ToggleResponse(
                id: workflow.id.uuidString,
                name: workflow.name,
                rule_name: workflow.name,
                profile_name: workflow.name,
                is_enabled: workflow.isEnabled
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

    // MARK: - POST /v1/recorder/start

    private func handleStartRecorder(_ request: HTTPRequest) async -> HTTPResponse {
        let micEnabled: Bool?
        let systemAudioEnabled: Bool?
        do {
            micEnabled = try parseOptionalBooleanQuery(request, name: "mic")
            systemAudioEnabled = try parseOptionalBooleanQuery(request, name: "system_audio")
        } catch {
            return .error(status: 400, message: error.localizedDescription)
        }

        do {
            let id = try await audioRecorderViewModel.apiStartRecording(
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled
            )

            struct StartResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StartResponse(id: id.uuidString, status: "recording"))
        } catch AudioRecorderViewModel.RecorderAPIError.noSourceEnabled {
            return .error(status: 400, message: AudioRecorderViewModel.RecorderAPIError.noSourceEnabled.localizedDescription)
        } catch AudioRecorderViewModel.RecorderAPIError.alreadyRecording {
            return .error(status: 409, message: AudioRecorderViewModel.RecorderAPIError.alreadyRecording.localizedDescription)
        } catch AudioRecorderViewModel.RecorderAPIError.finalizing {
            return .error(status: 409, message: AudioRecorderViewModel.RecorderAPIError.finalizing.localizedDescription)
        } catch {
            return .error(status: 409, message: error.localizedDescription)
        }
    }

    // MARK: - POST /v1/recorder/stop

    private func handleStopRecorder(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let id = try await audioRecorderViewModel.apiStopRecording()

            struct StopResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StopResponse(id: id.uuidString, status: "finalizing"))
        } catch {
            return .error(status: 409, message: error.localizedDescription)
        }
    }

    // MARK: - GET /v1/recorder/status

    private func handleRecorderStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let recording = await audioRecorderViewModel.apiRecorderIsRecording

        struct RecorderStatusResponse: Encodable {
            let recording: Bool
        }
        return .json(RecorderStatusResponse(recording: recording))
    }

    // MARK: - GET /v1/recorder/session

    private func handleRecorderSession(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }
        guard let session = await audioRecorderViewModel.apiRecorderSession(id: uuid) else {
            return .error(status: 404, message: "Recorder session not found")
        }

        struct RecorderSessionResponse: Encodable {
            let id: String
            let status: String
            let text: String?
            let output_file: String?
            let error: String?
        }
        return .json(RecorderSessionResponse(
            id: session.id.uuidString,
            status: session.status.rawValue,
            text: session.text,
            output_file: session.outputFile,
            error: session.error
        ))
    }

    // MARK: - Helpers

    private enum BooleanQueryError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let name):
                "Invalid '\(name)' query parameter"
            }
        }
    }

    private func parseOptionalBooleanQuery(_ request: HTTPRequest, name: String) throws -> Bool? {
        guard let value = request.queryParams[name] else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            throw BooleanQueryError.invalid(name)
        }
    }

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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
