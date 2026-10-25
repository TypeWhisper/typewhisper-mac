import Foundation

/// 翻译使用的 AI 模型链。生产环境由 `PromptProcessingService` 实现，按顺序尝试已配置的供应商。
@MainActor
protocol TranslationModelProcessing: AnyObject {
    var hasReadyModel: Bool { get }
    func translate(prompt: String, text: String) async throws -> String
}

extension PromptProcessingService: TranslationModelProcessing {
    var hasReadyModel: Bool { hasConfiguredPolishProvider }

    func translate(prompt: String, text: String) async throws -> String {
        try await processWorkflow(prompt: prompt, text: text, providerOverride: nil, cloudModelOverride: nil,
                                  temperatureDirective: .custom(0.2))
    }
}

/// 把一次翻译会话的语言对、应用风格和词典变成后处理步骤。
@MainActor
enum TranslationHandler {
    typealias Handler = (String) async throws -> String

    /// 没有语言对或没有可用的 AI 模型时返回 nil，调用方插入原话。
    static func make(
        pair: TranslationPair?,
        processor: any TranslationModelProcessing,
        style: ResolvedStyle,
        level: PolishLevel,
        vocabulary: [String],
        app: PolishRequest.Target,
        onModelRun: (@Sendable () -> Void)? = nil
    ) -> Handler? {
        guard let pair, processor.hasReadyModel else { return nil }
        return { text in
            onModelRun?()
            let request = TranslationRequest(
                rawTranscript: text, spokenLanguage: pair.spoken, targetLanguage: pair.target,
                level: level, style: style, vocabulary: vocabulary, target: app
            )
            let translated = try await processor.translate(prompt: request.systemPrompt, text: request.userContent)
            // 轻度档提示词不要求署名，补齐只覆盖模型漏写已要求署名的情况。
            return level == .light ? translated : style.appendingSignOff(to: translated)
        }
    }
}
