import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PostProcessingPipeline")

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
        outputFormat: String? = nil
    ) async throws -> String {
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
        for step in steps {
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
            } catch {
                let name: String
                switch step.id {
                case -4: name = "AppFormatter"
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

        return result
    }
}
