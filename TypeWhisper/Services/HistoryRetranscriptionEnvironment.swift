import Foundation
import TypeWhisperPluginSDK

@MainActor
enum HistoryRetranscriptionEnvironment {
    private struct WorkflowConfiguration: Codable {
        let template: WorkflowTemplate
        let behavior: WorkflowBehavior
        let output: WorkflowOutput
    }

    /// The shared segment processor can return before cancelled providers stop.
    /// A comparison must keep its engine lease until those requests finish.
    @MainActor
    private final class WorkflowRequests {
        private var activeCount = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func run(_ operation: @MainActor () async throws -> String) async throws -> String {
            try Task.checkCancellation()
            activeCount += 1
            defer {
                activeCount -= 1
                if activeCount == 0 {
                    let completed = waiters
                    waiters.removeAll()
                    for waiter in completed { waiter.resume() }
                }
            }
            return try await operation()
        }

        func waitUntilIdle() async {
            guard activeCount > 0 else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
    static func makeService(_ container: ServiceContainer) -> HistoryRetranscriptionService {
        HistoryRetranscriptionService(
            history: container.historyService,
            planBuilder: { try plan($0, container: container) },
            isBusy: {
                container.dictationViewModel.state != .idle
                    || container.audioRecorderViewModel.state != .idle
                    || container.audioRecorderViewModel.isTranscribing
                    || container.audioRecorderViewModel.retranscribingRecordingURL != nil
                    || container.fileTranscriptionViewModel.batchState == .processing
                    || container.speakerTranscriptionViewModel.batchState == .processing
                    || isBackgroundTranscriptionBusy(manager: container.modelManagerService, watchFolder: container.watchFolderService)
            },
            loadAudio: { url in
                try await container.audioFileService.loadAudioSamples(from: url)
            },
            canRetrieveAudio: { container.cloudFolderSyncController.canRetrieveHistoryAudio($0) },
            retrieveAudio: { try await container.cloudFolderSyncController.retrieveHistoryAudio($0) }
        )
    }

    static func isBackgroundTranscriptionBusy(manager: ModelManagerService, watchFolder: WatchFolderService) -> Bool {
        watchFolder.currentlyProcessing != nil || manager.hasProtectedEngineUse
    }

    static func isLocal(_ engine: any TranscriptionEnginePlugin) -> Bool {
        // Parakeet and WhisperKit restore local assets but do not expose cache deletion.
        engine is any PluginDownloadedModelManaging || engine is any PassiveModelRestoreProviding
            || engine.providerId == AppleSpeechModelSelection.providerId
    }

    static func plan(
        _ request: HistoryRetranscriptionService.Request, container: ServiceContainer
    ) throws -> HistoryRetranscriptionService.Plan {
        try plan(
            request, manager: container.modelManagerService, dictionary: container.dictionaryService,
            workflows: container.workflowService.workflows,
            promptProcessing: container.promptProcessingService, translationService: container.translationService
        )
    }

    static func plan(
        _ request: HistoryRetranscriptionService.Request, manager: ModelManagerService,
        dictionary: DictionaryService, workflows: [Workflow],
        promptProcessing: PromptProcessingService, translationService: AnyObject? = nil
    ) throws -> HistoryRetranscriptionService.Plan {
        guard let engine = PluginManager.shared?.transcriptionEngine(for: request.engineID),
              manager.canPrepareForTranscription(engine) else { throw HistoryRetranscriptionError.unavailable }
        let modelID = request.modelID ?? engine.selectedModelId
        if let modelID {
            guard models(for: engine).contains(where: { $0.id == modelID }) else {
                throw HistoryRetranscriptionError.unavailable
            }
            // The SDK cannot restore a nil model selection. Do not change that preference.
            guard engine.selectedModelId != nil else { throw HistoryRetranscriptionError.unavailable }
        }
        let modelName = manager.resolvedModelDisplayName(engineOverrideId: request.engineID, cloudModelOverride: modelID)
        let engineName = engine.providerDisplayName
        var cloudProviders = isLocal(engine) ? [] : [String(format: String(localized: "history.retranscribe.audioProvider"), engineName)]
        var workflow: Workflow?
        if let id = request.workflowID {
            guard let source = workflows.first(where: { $0.id == id && $0.isEnabled }) else {
                throw HistoryRetranscriptionError.unavailable
            }
            let copy = Workflow(
                id: source.id, name: source.name, template: source.template,
                trigger: WorkflowTrigger(kind: .manual), behavior: source.behavior, output: source.output
            )
            if !copy.usesAppleTranslate, copy.template != .dictation || copy.usesInlineCommands {
                let route = promptProcessing.workflowProviderResolution(
                    providerOverride: copy.behavior.providerId,
                    cloudModelOverride: copy.behavior.cloudModel,
                    effortOverride: copy.behavior.effortId
                )
                guard let first = route.attempts.first,
                      promptProcessing.isProviderReady(first.providerId) else {
                    throw HistoryRetranscriptionError.unavailable
                }
                // A comparison uses the displayed provider, never an undisclosed cloud fallback.
                var behavior = copy.behavior
                behavior.providerId = first.providerId
                behavior.cloudModel = first.modelId
                behavior.effortId = first.effortId
                copy.behavior = behavior
                if let provider = PluginManager.shared?.llmProvider(for: first.providerId),
                   !PromptProcessingService.isLocalLLMProvider(provider) {
                    cloudProviders.append(String(format: String(localized: "history.retranscribe.textProvider"), provider.llmProviderDisplayName))
                }
            }
            if copy.usesAppleTranslate {
                guard WorkflowTranslationLanguageNormalizer.normalizedLanguageIdentifier(
                    from: copy.translationTargetLanguage
                ) != nil else {
                    throw HistoryRetranscriptionError.unavailable
                }
                #if canImport(Translation)
                guard #available(macOS 15, *), translationService is TranslationService else {
                    throw HistoryRetranscriptionError.unavailable
                }
                #else
                throw HistoryRetranscriptionError.unavailable
                #endif
            }
            workflow = copy
        }
        let frozenWorkflow = workflow
        let resolvedOutputFormat = WorkflowOutputFormatResolver.resolvedFormat(
            storedFormat: frozenWorkflow?.output.format,
            bundleIdentifier: request.appBundleIdentifier, url: request.appURL
        )
        let configuration = try frozenWorkflow.map {
            try JSONEncoder().encode(WorkflowConfiguration(template: $0.template, behavior: $0.behavior, output: $0.output))
        }
        let dictionaryPrompt = dictionary.getTermsForPrompt(providerId: request.engineID)
        let dictionaryHints = dictionary.getTermHints(providerId: request.engineID)
        let vocabulary = dictionary.vocabularyForPrompt()
        let workflowProcessor = WorkflowTextProcessingService(
            promptProcessingService: promptProcessing,
            translationService: translationService,
            vocabularyProvider: { vocabulary }
        )
        return HistoryRetranscriptionService.Plan(
            requiresCloudConfirmation: !cloudProviders.isEmpty,
            cloudProviders: cloudProviders,
            run: { samples in
                guard PluginManager.shared?.transcriptionEngine(for: request.engineID) === engine else {
                    throw HistoryRetranscriptionError.unavailable
                }
                let result = try await transcribe(
                    samples: samples, request: request, modelID: modelID,
                    workflow: frozenWorkflow, manager: manager,
                    dictionaryPrompt: dictionaryPrompt, dictionaryHints: dictionaryHints
                )
                try Task.checkCancellation()
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { throw HistoryRetranscriptionError.emptyResult }
                var final = dictionary.previewCorrections(to: raw, includeRegex: frozenWorkflow == nil)
                var steps = final == raw ? [] : ["Corrections"]
                if let frozenWorkflow {
                    let beforeWorkflow = final
                    let segmentedRequest = frozenWorkflow.usesSegmentedPostProcessing
                        ? workflowProcessor.segmentedPromptRequest(
                            workflow: frozenWorkflow, detectedLanguage: result.detectedLanguage,
                            configuredLanguage: request.language, resolvedOutputFormat: resolvedOutputFormat
                        ) : nil
                    if let segmentedRequest {
                        let policy = WorkflowSegmentationPolicy.default.forLLMProvider(
                            isLocal: segmentedRequest.providerResolution?.isLocal
                                ?? promptProcessing.workflowUsesLocalLLMProvider(providerOverride: segmentedRequest.providerId)
                        )
                        let requests = WorkflowRequests()
                        do {
                            let outcome = try await WorkflowSegmentedPostProcessor(policy: policy).process(
                                text: beforeWorkflow, incrementalSession: nil, incrementalRequest: nil,
                                segmentProcessor: { segment in
                                    try await requests.run {
                                        try await workflowProcessor.process(request: segmentedRequest, text: segment)
                                    }
                                },
                                wholeTextProcessor: {
                                    await requests.waitUntilIdle()
                                    try Task.checkCancellation()
                                    return try await workflowProcessor.process(request: segmentedRequest, text: beforeWorkflow)
                                }
                            )
                            final = outcome.text
                        } catch {
                            await requests.waitUntilIdle()
                            throw error
                        }
                    } else {
                        final = try await workflowProcessor.process(
                            workflow: frozenWorkflow, text: beforeWorkflow,
                            detectedLanguage: result.detectedLanguage, configuredLanguage: request.language,
                            resolvedOutputFormat: resolvedOutputFormat
                        )
                    }
                    if final != beforeWorkflow { steps.append(frozenWorkflow.name) }
                    let beforeCorrections = final
                    final = dictionary.previewCorrections(to: final)
                    if final != beforeCorrections { steps.append("Corrections") }
                }
                try Task.checkCancellation()
                final = final.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !final.isEmpty else { throw HistoryRetranscriptionError.emptyResult }
                var version = HistoryTranscriptionVersion(
                    rawText: raw, finalText: final, engineID: result.engineUsed,
                    engineName: engineName, modelID: modelID, modelName: modelName,
                    language: result.detectedLanguage ?? request.language, requestedLanguage: request.language,
                    workflowID: frozenWorkflow?.id, workflowName: frozenWorkflow?.name,
                    workflowConfiguration: configuration, workflowRecorded: true,
                    pipelineSteps: steps.isEmpty ? nil : String(data: try JSONEncoder().encode(steps), encoding: .utf8)
                )
                // Timing belongs to raw STT text. A rewritten result must not display stale alignment.
                if raw == final {
                    if !result.words.isEmpty { version.speakerWordsData = try JSONEncoder().encode(result.words) }
                    let timedText = TimedTextEntry.map(
                        textParts: result.segments.map { ($0.text, $0.start, $0.end) }, in: raw
                    )
                    if !timedText.isEmpty {
                        version.timedTextData = try JSONEncoder().encode(timedText)
                        version.timedTextGranularityRaw = TimedTextGranularity.segment.rawValue
                    }
                    if let transcript = SpeakerTranscriptBuilder.providerTranscript(from: result.segments, engine: result.engineUsed) {
                        version.speakerTranscriptData = try JSONEncoder().encode(transcript)
                        version.speakerTranscriptStateRaw = SpeakerTranscriptState.ready.rawValue
                    }
                }
                return version
            }
        )
    }

    /// Include cached models when a local engine only advertises its loaded model.
    static func models(for engine: any TranscriptionEnginePlugin) -> [PluginModelInfo] {
        guard isLocal(engine) else { return engine.modelCatalog }
        let loaded = engine.transcriptionModels
        let downloaded = (engine as? any PluginDownloadedModelManaging)?.downloadedModels ?? []
        let installedIDs = Set((loaded + downloaded).map(\.id))
        var models = engine.modelCatalog.filter {
            installedIDs.contains($0.id) || $0.downloaded == true || $0.loaded == true
        }
        for model in loaded + downloaded where !models.contains(where: { $0.id == model.id }) {
            models.append(model)
        }
        return models
    }

    static func supportedLanguage(
        _ language: String?, modelID: String?, engine: (any TranscriptionEnginePlugin)?
    ) -> String? {
        guard let language, engine?.supportedLanguages(forModel: modelID).contains(language) == true else { return nil }
        return language
    }

    static func transcribe(
        samples: [Float], request: HistoryRetranscriptionService.Request, modelID: String?,
        workflow: Workflow?, manager: ModelManagerService,
        dictionaryPrompt: String?, dictionaryHints: [PluginDictionaryTermHint]
    ) async throws -> TranscriptionResult {
        try await manager.transcribe(
            audioSamples: samples, language: request.language, task: .transcribe,
            engineOverrideId: request.engineID, cloudModelOverride: modelID,
            prompt: dictionaryPrompt, dictionaryTermHints: dictionaryHints,
            normalizeNumbers: workflow?.output.numberNormalizationMode.overrideValue
        )
    }
}
