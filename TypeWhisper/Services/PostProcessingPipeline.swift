import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PostProcessingPipeline")

struct PostProcessingResult {
    let text: String
    let appliedSteps: [String]
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
        llmStepName: String? = nil
    ) async throws -> PostProcessingResult {
        // Collect plugin processors with their priorities
        let plugins = PluginManager.shared.postProcessors

        // Build priority-ordered step list: (priority, id)
        // IDs: -1 = LLM, -2 = snippets, -3 = dictionary, -4 = app formatter, -5 = punctuation, 0+ = plugin index
        var steps: [(priority: Int, id: Int)] = []

        // App formatter at priority 150 (before LLM at 300)
        let formattingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled)
        if formattingEnabled, outputFormat != nil, appFormatterService != nil {
            steps.append((150, -4))
        }

        steps.append((200, -5))

        if llmHandler != nil {
            steps.append((300, -1))
        }
        for (index, plugin) in plugins.enumerated() {
            steps.append((plugin.priority, index))
        }
        steps.append((500, -2))
        steps.append((600, -3))
        steps.sort { $0.priority < $1.priority }

        var result = text
        var appliedSteps: [String] = []
        for step in steps {
            let before = result
            do {
                switch step.id {
                case -4:
                    result = appFormatterService!.format(
                        text: result,
                        bundleId: context.bundleIdentifier,
                        outputFormat: outputFormat
                    )
                case -5:
                    if let resolvedStrategy = punctuationStrategyResolver.resolve(
                        engineId: dictationContext?.engineId,
                        modelId: dictationContext?.modelId,
                        configuredLanguage: dictationContext?.configuredLanguage,
                        detectedLanguage: dictationContext?.detectedLanguage ?? context.language
                    ) {
                        switch resolvedStrategy.strategy {
                        case .nativeOnly:
                            break
                        case .automatic:
                            result = speechPunctuationService.normalize(
                                text: result,
                                language: resolvedStrategy.languageCode,
                                mode: .selectiveFallback
                            )
                        case .fallbackOnly:
                            result = speechPunctuationService.normalize(
                                text: result,
                                language: resolvedStrategy.languageCode,
                                mode: .fullFallback
                            )
                        }
                    }
                case -1:
                    result = try await llmHandler!(result)
                case -2:
                    result = snippetService.applySnippets(to: result)
                case -3:
                    result = dictionaryService.applyCorrections(to: result)
                default:
                    result = try await plugins[step.id].process(text: result, context: context)
                }
                if result != before {
                    let name: String
                    switch step.id {
                    case -4: name = "Formatting"
                    case -5: name = "Speech Punctuation"
                    case -1: name = llmStepName ?? "Prompt"
                    case -2: name = "Snippets"
                    case -3: name = "Corrections"
                    default: name = plugins[step.id].processorName
                    }
                    appliedSteps.append(name)
                }
            } catch {
                let name: String
                switch step.id {
                case -4: name = "AppFormatter"
                case -5: name = "SpeechPunctuation"
                case -1: name = "LLM/Translation"
                case -2: name = "Snippets"
                case -3: name = "Dictionary"
                default: name = plugins[step.id].processorName
                }
                logger.error("Post-processor '\(name)' failed: \(error.localizedDescription)")
                // Only re-throw for LLM step
                if step.id == -1 {
                    throw error
                }
            }
        }

        return PostProcessingResult(text: result, appliedSteps: appliedSteps)
    }
}
