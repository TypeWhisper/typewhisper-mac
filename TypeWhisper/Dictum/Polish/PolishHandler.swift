import Foundation

/// 润色使用的 AI 模型链。生产环境由 `PromptProcessingService` 实现，按顺序尝试已配置的供应商。
@MainActor
protocol PolishModelProcessing: AnyObject {
    func polish(prompt: String, text: String) async throws -> String
}

extension PromptProcessingService: PolishModelProcessing {
    func polish(prompt: String, text: String) async throws -> String {
        try await processWorkflow(prompt: prompt, text: text, providerOverride: nil, cloudModelOverride: nil,
                                  temperatureDirective: .custom(0.2))
    }
}

/// 把一次听写的润色强度、应用风格和词典变成后处理步骤。
@MainActor
enum PolishHandler {
    typealias Handler = (String) async throws -> String

    /// 模型失败时步骤抛出错误，调用方插入的原文不带署名。
    static func make(
        processor: any PolishModelProcessing,
        level: PolishLevel,
        style: ResolvedStyle,
        vocabulary: [String],
        target: PolishRequest.Target,
        onModelRun: (@Sendable () -> Void)? = nil
    ) -> Handler {
        { text in
            onModelRun?()
            let request = PolishRequest(rawTranscript: text, level: level, style: style, vocabulary: vocabulary, target: target)
            let polished = try await processor.polish(prompt: request.systemPrompt, text: request.userContent)
            return style.appendingSignOff(to: polished)
        }
    }
}
