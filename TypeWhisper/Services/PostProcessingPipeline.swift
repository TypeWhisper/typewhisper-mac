import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PostProcessingPipeline")

@MainActor
final class PostProcessingPipeline {
    private let snippetService: SnippetService
    private let dictionaryService: DictionaryService

    init(snippetService: SnippetService, dictionaryService: DictionaryService) {
        self.snippetService = snippetService
        self.dictionaryService = dictionaryService
    }

    func process(
        text: String,
        context: PostProcessingContext,
        llmHandler: ((String) async throws -> String)? = nil
    ) async throws -> String {
        // Collect plugin processors with their priorities
        let plugins = PluginManager.shared.postProcessors

        // Build priority-ordered step list: (priority, id)
        // IDs: -1 = LLM, -2 = snippets, -3 = dictionary, 0+ = plugin index
        var steps: [(priority: Int, id: Int)] = []

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
                case -1: name = "LLM/Translation"
                case -2: name = "Snippets"
                case -3: name = "Dictionary"
                default: name = plugins[step.id].processorName
                }
                logger.error("Post-processor '\(name)' failed: \(error.localizedDescription)")
                if step.id == -1 {
                    if error is CancellationError { throw error }
                    logger.warning("LLM processing failed, using raw text: \(error.localizedDescription)")
                }
            }
        }

        return result
    }
}
