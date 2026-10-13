import Foundation
import TypeWhisperPluginSDK

@MainActor
enum HistoryRetranscriptionEnvironment {
    private struct WorkflowConfiguration: Codable {
        let template: WorkflowTemplate
        let behavior: WorkflowBehavior
        let output: WorkflowOutput
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
                    || container.modelManagerService.hasProtectedEngineUse
            },
            loadAudio: { url in
                try await container.audioFileService.loadAudioSamples(from: url)
            },
            canRetrieveAudio: { container.cloudFolderSyncController.canRetrieveHistoryAudio($0) },
            retrieveAudio: { try await container.cloudFolderSyncController.retrieveHistoryAudio($0) }
        )
    }

    static func isLocal(_ engine: any TranscriptionEnginePlugin) -> Bool {
        // Parakeet and WhisperKit restore local assets but do not expose cache deletion.
        engine is any PluginDownloadedModelManaging || engine is any PassiveModelRestoreProviding
            || engine.providerId == AppleSpeechModelSelection.providerId
    }

    static func plan(
        _ request: HistoryRetranscriptionService.Request, container: ServiceContainer
    ) throws -> HistoryRetranscriptionService.Plan {
        let manager = container.modelManagerService
        guard let engine = PluginManager.shared?.transcriptionEngine(for: request.engineID),
              manager.canPrepareForTranscription(engine) else { throw HistoryRetranscriptionError.unavailable }
        let modelID = request.modelID ?? engine.selectedModelId
        if let modelID {
            guard engine.transcriptionModels.contains(where: { $0.id == modelID }) else {
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
            guard let source = container.workflowService.workflows.first(where: { $0.id == id && $0.isEnabled }) else {
                throw HistoryRetranscriptionError.unavailable
            }
            let copy = Workflow(
                id: source.id, name: source.name, template: source.template,
                trigger: WorkflowTrigger(kind: .manual), behavior: source.behavior, output: source.output
            )
            if !copy.usesAppleTranslate, copy.template != .dictation || copy.usesInlineCommands {
                let route = container.promptProcessingService.workflowProviderResolution(
                    providerOverride: copy.behavior.providerId,
                    cloudModelOverride: copy.behavior.cloudModel,
                    effortOverride: copy.behavior.effortId
                )
                guard let first = route.attempts.first,
                      let provider = PluginManager.shared?.llmProvider(for: first.providerId), provider.isAvailable else {
                    throw HistoryRetranscriptionError.unavailable
                }
                // A comparison uses the displayed provider, never an undisclosed cloud fallback.
                var behavior = copy.behavior
                behavior.providerId = first.providerId
                behavior.cloudModel = first.modelId
                behavior.effortId = first.effortId
                copy.behavior = behavior
                if !PromptProcessingService.isLocalLLMProvider(provider) {
                    cloudProviders.append(String(format: String(localized: "history.retranscribe.textProvider"), provider.llmProviderDisplayName))
                }
            }
            if copy.usesAppleTranslate, copy.translationTargetLanguage == nil {
                throw HistoryRetranscriptionError.unavailable
            }
            workflow = copy
        }
        let frozenWorkflow = workflow
        let configuration = try frozenWorkflow.map {
            try JSONEncoder().encode(WorkflowConfiguration(template: $0.template, behavior: $0.behavior, output: $0.output))
        }
        let dictionaryPrompt = container.dictionaryService.getTermsForPrompt(providerId: request.engineID)
        let dictionaryHints = container.dictionaryService.getTermHints(providerId: request.engineID)
        let workflowProcessor = WorkflowTextProcessingService(
            promptProcessingService: container.promptProcessingService,
            translationService: container.translationService
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
                var final = container.dictionaryService.applyCorrections(to: [raw]).first ?? raw
                var steps = final == raw ? [] : ["Corrections"]
                if let frozenWorkflow {
                    let beforeWorkflow = final
                    final = try await workflowProcessor.process(
                        workflow: frozenWorkflow, text: final,
                        detectedLanguage: result.detectedLanguage, configuredLanguage: request.language
                    )
                    if final != beforeWorkflow { steps.append(frozenWorkflow.name) }
                }
                try Task.checkCancellation()
                final = final.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !final.isEmpty else { throw HistoryRetranscriptionError.emptyResult }
                var version = HistoryTranscriptionVersion(
                    rawText: raw, finalText: final, engineID: result.engineUsed,
                    engineName: engineName, modelID: modelID, modelName: modelName,
                    language: result.detectedLanguage, requestedLanguage: request.language,
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
