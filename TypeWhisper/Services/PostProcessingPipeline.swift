import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PostProcessingPipeline")

func isPostProcessingCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

struct PostProcessingResult {
    let text: String
    let appliedSteps: [String]
    let fallback: PostProcessingFallback?
}

struct PostProcessingFallback: Equatable, Sendable {
    let failedStep: String
    let reason: String
}

@MainActor
final class PostProcessingPipeline {
    private let snippetService: SnippetService
    private let dictionaryService: DictionaryService
    private let appFormatterService: AppFormatterService?
    private let speechPunctuationService: SpeechPunctuationService
    private let punctuationStrategyResolver: PunctuationStrategyResolver

    init(
        snippetService: SnippetService,
        dictionaryService: DictionaryService,
        appFormatterService: AppFormatterService? = nil,
        speechPunctuationService: SpeechPunctuationService = SpeechPunctuationService(),
        punctuationStrategyResolver: PunctuationStrategyResolver
    ) {
        self.snippetService = snippetService
        self.dictionaryService = dictionaryService
        self.appFormatterService = appFormatterService
        self.speechPunctuationService = speechPunctuationService
        self.punctuationStrategyResolver = punctuationStrategyResolver
    }

    func process(
        text: String,
        context: PostProcessingContext,
        dictationContext: DictationRuntimeContext? = nil,
        llmHandler: ((String) async throws -> String)? = nil,
        outputFormat: String? = nil,
        llmStepName: String? = nil,
        normalizeNumbers: Bool? = nil,
        llmFailureFallbackText: String? = nil
    ) async throws -> PostProcessingResult {
        // Collect plugin processors with their priorities
        let plugins = PluginManager.shared.postProcessors
        let steps = orderedSteps(
            includesLLMStep: llmHandler != nil,
            outputFormat: outputFormat,
            plugins: plugins
        )

        var result = text
        var appliedSteps: [String] = []

        func stepName(for id: Int) -> String {
            switch id {
            case -6: return "Number Normalization"
            case -4: return "Formatting"
            case -5: return "Speech Punctuation"
            case -1: return llmStepName ?? "Prompt"
            case -2: return "Snippets"
            case -3: return "Corrections"
            default: return plugins[id].processorName
            }
        }

        for step in steps {
            let before = result
            let name = stepName(for: step.id)
            let stepStart = ContinuousClock.now
            do {
                switch step.id {
                case -1:
                    result = try await llmHandler!(result)
                case let id where id < 0:
                    result = applyBuiltInStep(
                        id,
                        to: result,
                        context: context,
                        dictationContext: dictationContext,
                        outputFormat: outputFormat,
                        normalizeNumbers: normalizeNumbers
                    )
                default:
                    result = try await plugins[step.id].process(text: result, context: context)
                }
                let changed = result != before
                logger.info("Post-processing step '\(name)' finished in \(ContinuousClock.now - stepStart), changed: \(changed)")
                if changed {
                    appliedSteps.append(name)
                }
            } catch {
                logger.error("Post-processing step '\(name)' failed after \(ContinuousClock.now - stepStart): \(error.localizedDescription)")
                if step.id == -1 {
                    if Task.isCancelled || isPostProcessingCancellation(error) {
                        throw CancellationError()
                    }

                    if let llmFailureFallbackText {
                        logger.warning("Using raw transcription fallback after post-processing step '\(name)' failed")
                        return PostProcessingResult(
                            text: llmFailureFallbackText,
                            appliedSteps: [],
                            fallback: PostProcessingFallback(
                                failedStep: name,
                                reason: error.localizedDescription
                            )
                        )
                    }

                    throw error
                }
            }
        }

        return PostProcessingResult(text: result, appliedSteps: appliedSteps, fallback: nil)
    }

    /// Whether an installed post-processor plugin can run before the LLM step. Its
    /// output for a partial transcript can't be reproduced ahead of the final pass.
    var hasPluginStepsBeforeLLMStep: Bool {
        PluginManager.shared.postProcessors.contains { $0.priority <= Self.llmStepPriority }
    }

    /// Applies the built-in steps that `process` runs before the LLM step, so text
    /// confirmed during recording can be prepared exactly like the final LLM input.
    /// Plugin post-processors are not applied; see `hasPluginStepsBeforeLLMStep`.
    func textBeforeLLMStep(
        _ text: String,
        context: PostProcessingContext,
        dictationContext: DictationRuntimeContext?,
        outputFormat: String?,
        normalizeNumbers: Bool?
    ) -> String {
        let steps = orderedSteps(includesLLMStep: false, outputFormat: outputFormat, plugins: [])
        var result = text
        for step in steps where step.priority < Self.llmStepPriority {
            result = applyBuiltInStep(
                step.id,
                to: result,
                context: context,
                dictationContext: dictationContext,
                outputFormat: outputFormat,
                normalizeNumbers: normalizeNumbers
            )
        }
        return result
    }

    private static let llmStepPriority = 300

    /// Builds the priority-ordered step list: (priority, id).
    /// IDs: -1 = LLM, -2 = snippets, -3 = dictionary, -4 = app formatter, -5 = punctuation, -6 = normalization, 0+ = plugin index
    private func orderedSteps(
        includesLLMStep: Bool,
        outputFormat: String?,
        plugins: [PostProcessorPlugin]
    ) -> [(priority: Int, id: Int)] {
        var steps: [(priority: Int, id: Int)] = []

        steps.append((100, -6))

        // App formatter at priority 150 (before LLM at 300)
        let formattingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled)
        if formattingEnabled, outputFormat != nil, appFormatterService != nil {
            steps.append((150, -4))
        }

        steps.append((200, -5))

        if includesLLMStep {
            steps.append((Self.llmStepPriority, -1))
        }
        for (index, plugin) in plugins.enumerated() {
            steps.append((plugin.priority, index))
        }
        steps.append((500, -2))
        steps.append((600, -3))
        steps.sort { $0.priority < $1.priority }
        return steps
    }

    private func applyBuiltInStep(
        _ id: Int,
        to text: String,
        context: PostProcessingContext,
        dictationContext: DictationRuntimeContext?,
        outputFormat: String?,
        normalizeNumbers: Bool?
    ) -> String {
        switch id {
        case -6:
            let languages = TranscriptionNormalizationService.normalizationLanguages(
                task: .transcribe,
                detectedLanguage: dictationContext?.detectedLanguage ?? context.language,
                configuredLanguage: dictationContext?.configuredLanguage ?? context.language,
                configuredLanguageCandidates: dictationContext?.configuredLanguageCandidates ?? []
            )
            return TranscriptionNormalizationService.normalizeText(
                text,
                languages: languages,
                normalizeNumbers: normalizeNumbers
            )
        case -4:
            return appFormatterService!.format(
                text: text,
                bundleId: context.bundleIdentifier,
                url: context.url,
                outputFormat: outputFormat
            )
        case -5:
            guard let resolvedStrategy = punctuationStrategyResolver.resolve(
                engineId: dictationContext?.engineId,
                modelId: dictationContext?.modelId,
                configuredLanguage: dictationContext?.configuredLanguage,
                detectedLanguage: dictationContext?.detectedLanguage ?? context.language
            ) else {
                return text
            }
            switch resolvedStrategy.strategy {
            case .nativeOnly:
                return text
            case .automatic:
                return speechPunctuationService.normalize(
                    text: text,
                    language: resolvedStrategy.languageCode,
                    mode: .selectiveFallback
                )
            case .fallbackOnly:
                return speechPunctuationService.normalize(
                    text: text,
                    language: resolvedStrategy.languageCode,
                    mode: .fullFallback
                )
            }
        case -2:
            return snippetService.applySnippets(to: text)
        case -3:
            return dictionaryService.applyCorrections(to: text)
        default:
            return text
        }
    }
}
