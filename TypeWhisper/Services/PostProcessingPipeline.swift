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

    init(snippetService: SnippetService, dictionaryService: DictionaryService, appFormatterService: AppFormatterService? = nil) {
        self.snippetService = snippetService
        self.dictionaryService = dictionaryService
        self.appFormatterService = appFormatterService
    }

    func process(
        text: String,
        context: PostProcessingContext,
        llmHandler: ((String) async throws -> String)? = nil,
        outputFormat: String? = nil,
        llmStepName: String? = nil
    ) async throws -> PostProcessingResult {
        // Collect plugin processors with their priorities
        let plugins = PluginManager.shared.postProcessors

        // Build priority-ordered step list: (priority, id)
        // IDs: -1 = LLM, -2 = snippets, -3 = dictionary, -4 = app formatter, 0+ = plugin index
        var steps: [(priority: Int, id: Int)] = []

        // App formatter at priority 150 (before LLM at 300)
        let formattingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled)
        if formattingEnabled, outputFormat != nil, appFormatterService != nil {
            steps.append((150, -4))
        }

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

        func stepName(for id: Int) -> String {
            switch id {
            case -4: return "Formatting"
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
                case -4:
                    result = appFormatterService!.format(
                        text: result,
                        bundleId: context.bundleIdentifier,
                        outputFormat: outputFormat
                    )
                case -1:
                    result = try await llmHandler!(result)
                case -2:
                    result = snippetService.applySnippets(to: result)
                case -3:
                    result = dictionaryService.applyCorrections(to: result)
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
                // Only re-throw for LLM step
                if step.id == -1 {
                    throw error
                }
            }
        }

        return PostProcessingResult(text: result, appliedSteps: appliedSteps)
    }
}
