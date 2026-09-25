import Foundation
import TypeWhisperPluginSDK
import os.log

private let workflowTextProcessingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "WorkflowTextProcessingService"
)

/// The provider route a workflow LLM request resolved to when it was built.
struct WorkflowLLMProviderResolution: Equatable, Sendable {
    struct Attempt: Equatable, Sendable {
        let providerId: String
        let modelId: String?
        let effortId: String?
    }

    /// The workflow's provider override, or the inherited global fallback list, in order.
    let attempts: [Attempt]
    /// Whether any attempt runs on an on-device model.
    let isLocal: Bool
}

/// A fully resolved workflow LLM request. Segmented post-processing sends every
/// segment with the same request, and compares requests to decide whether results
/// computed during recording still match the configuration at stop.
struct WorkflowLLMRequest: Equatable, Sendable {
    let systemPrompt: String
    let providerId: String?
    let cloudModel: String?
    let temperatureDirective: PluginLLMTemperatureDirective
    let effortId: String?
    /// Snapshot of the provider settings the request inherits, so a change to the
    /// global LLM fallback list also changes the request identity.
    var providerResolution: WorkflowLLMProviderResolution? = nil
}

@MainActor
struct WorkflowTextProcessingService {
    typealias PromptProcessor = (
        _ prompt: String,
        _ text: String,
        _ providerId: String?,
        _ cloudModel: String?,
        _ temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String

    typealias EffortPromptProcessor = (
        _ prompt: String,
        _ text: String,
        _ providerId: String?,
        _ cloudModel: String?,
        _ temperatureDirective: PluginLLMTemperatureDirective,
        _ effortId: String?
    ) async throws -> String

    typealias AppleTranslator = (
        _ text: String,
        _ targetLanguageCode: String,
        _ sourceLanguageCode: String?
    ) async throws -> String

    typealias ProviderResolver = (
        _ providerId: String?,
        _ cloudModel: String?,
        _ effortId: String?
    ) -> WorkflowLLMProviderResolution
    private let promptProcessor: PromptProcessor
    private let effortPromptProcessor: EffortPromptProcessor?
    private let appleTranslator: AppleTranslator?
    private let providerResolver: ProviderResolver?

    init(
        promptProcessor: @escaping PromptProcessor,
        appleTranslator: AppleTranslator?,
        providerResolver: ProviderResolver? = nil
    ) {
        self.promptProcessor = promptProcessor
        self.effortPromptProcessor = nil
        self.appleTranslator = appleTranslator
        self.providerResolver = providerResolver
    }

    init(promptProcessingService: PromptProcessingService, translationService: AnyObject?, workflowService _: WorkflowService? = nil) {
        self.promptProcessor = { prompt, text, providerId, cloudModel, temperatureDirective in
            try await promptProcessingService.processWorkflow(
                prompt: prompt,
                text: text,
                providerOverride: providerId,
                cloudModelOverride: cloudModel,
                temperatureDirective: temperatureDirective
            )
        }
        self.effortPromptProcessor = { prompt, text, providerId, cloudModel, temperatureDirective, effortId in
            try await promptProcessingService.processWorkflow(
                prompt: prompt,
                text: text,
                providerOverride: providerId,
                cloudModelOverride: cloudModel,
                temperatureDirective: temperatureDirective,
                effortOverride: effortId
            )
        }
        self.providerResolver = { providerId, cloudModel, effortId in
            promptProcessingService.workflowProviderResolution(
                providerOverride: providerId,
                cloudModelOverride: cloudModel,
                effortOverride: effortId
            )
        }

        #if canImport(Translation)
        if #available(macOS 15, *), let translationService = translationService as? TranslationService {
            self.appleTranslator = { text, targetLanguageCode, sourceLanguageCode in
                let targetLanguage = Locale.Language(identifier: targetLanguageCode)
                let sourceLanguage = sourceLanguageCode.map { Locale.Language(identifier: $0) }
                return try await translationService.translate(
                    text: text,
                    to: targetLanguage,
                    source: sourceLanguage
                )
            }
        } else {
            self.appleTranslator = nil
        }
        #else
        self.appleTranslator = nil
        #endif
    }

    func process(
        workflow: Workflow,
        text: String,
        fallbackTranslationTarget: String? = nil,
        detectedLanguage: String? = nil,
        configuredLanguage: String? = nil,
        resolvedOutputFormat: String? = nil
    ) async throws -> String {
        if workflow.usesInlineCommands {
            let behavior = workflow.behavior
            let prompt = Self.inlineCommandSystemPrompt(
                fineTuning: behavior.fineTuning,
                outputInstruction: workflow.outputInstruction(resolvedOutputFormat: resolvedOutputFormat)
            )
            if let effortPromptProcessor {
                return try await effortPromptProcessor(
                    prompt,
                    text,
                    Self.trimmedOrNil(behavior.providerId),
                    Self.trimmedOrNil(behavior.cloudModel),
                    behavior.temperatureDirective,
                    Self.trimmedOrNil(behavior.effortId)
                )
            }
            return try await promptProcessor(
                prompt,
                text,
                Self.trimmedOrNil(behavior.providerId),
                Self.trimmedOrNil(behavior.cloudModel),
                behavior.temperatureDirective
            )
        }

        if workflow.usesAppleTranslate {
            return try await processAppleTranslate(
                workflow: workflow,
                text: text,
                fallbackTranslationTarget: fallbackTranslationTarget,
                detectedLanguage: detectedLanguage,
                configuredLanguage: configuredLanguage
            )
        }

        guard let request = Self.promptRequest(
            workflow: workflow,
            fallbackTranslationTarget: fallbackTranslationTarget,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            resolvedOutputFormat: resolvedOutputFormat
        ) else {
            return text
        }

        return try await process(request: request, text: text)
    }

    /// Sends `text` through the same provider path as whole-text workflow processing,
    /// including per-workflow overrides and the global LLM fallback list.
    func process(request: WorkflowLLMRequest, text: String) async throws -> String {
        if let effortPromptProcessor {
            return try await effortPromptProcessor(
                request.systemPrompt,
                text,
                request.providerId,
                request.cloudModel,
                request.temperatureDirective,
                request.effortId
            )
        }
        return try await promptProcessor(
            request.systemPrompt,
            text,
            request.providerId,
            request.cloudModel,
            request.temperatureDirective
        )
    }

    /// The prompt request used for segmented processing, or nil when the workflow
    /// has no segmentable LLM step (see `Workflow.supportsSegmentedPostProcessing`)
    /// or the resolved output format is not plain text.
    /// The request includes the provider settings it currently resolves to.
    func segmentedPromptRequest(
        workflow: Workflow,
        fallbackTranslationTarget: String? = nil,
        detectedLanguage: String? = nil,
        configuredLanguage: String? = nil,
        resolvedOutputFormat: String? = nil
    ) -> WorkflowLLMRequest? {
        guard workflow.supportsSegmentedPostProcessing,
              workflow.outputFormatAllowsSegmentation(resolvedOutputFormat: resolvedOutputFormat),
              var request = Self.promptRequest(
                  workflow: workflow,
                  fallbackTranslationTarget: fallbackTranslationTarget,
                  detectedLanguage: detectedLanguage,
                  configuredLanguage: configuredLanguage,
                  resolvedOutputFormat: resolvedOutputFormat
              ) else {
            return nil
        }
        request.providerResolution = providerResolver?(request.providerId, request.cloudModel, request.effortId)
        return request
    }

    private static func promptRequest(
        workflow: Workflow,
        fallbackTranslationTarget: String?,
        detectedLanguage: String?,
        configuredLanguage: String?,
        resolvedOutputFormat: String?
    ) -> WorkflowLLMRequest? {
        guard let systemPrompt = workflow.systemPrompt(
            fallbackTranslationTarget: fallbackTranslationTarget,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            resolvedOutputFormat: resolvedOutputFormat
        ) else {
            return nil
        }

        let behavior = workflow.behavior
        return WorkflowLLMRequest(
            systemPrompt: systemPrompt,
            providerId: trimmedOrNil(behavior.providerId),
            cloudModel: trimmedOrNil(behavior.cloudModel),
            temperatureDirective: behavior.temperatureDirective,
            effortId: trimmedOrNil(behavior.effortId)
        )
    }

    func canProcess(
        workflow: Workflow,
        fallbackTranslationTarget: String? = nil,
        detectedLanguage: String? = nil,
        configuredLanguage: String? = nil,
        resolvedOutputFormat: String? = nil
    ) -> Bool {
        if workflow.usesInlineCommands {
            return true
        }

        if workflow.usesAppleTranslate {
            return true
        }

        return workflow.systemPrompt(
            fallbackTranslationTarget: fallbackTranslationTarget,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            resolvedOutputFormat: resolvedOutputFormat
        ) != nil
    }

    private func processAppleTranslate(
        workflow: Workflow,
        text: String,
        fallbackTranslationTarget: String?,
        detectedLanguage: String?,
        configuredLanguage: String?
    ) async throws -> String {
        guard let appleTranslator else {
            workflowTextProcessingLogger.warning("Apple Translate workflow requested but TranslationService is unavailable")
            return text
        }

        let targetRaw = workflow.translationTargetLanguage ?? fallbackTranslationTarget
        guard let targetLanguageCode = WorkflowTranslationLanguageNormalizer.normalizedLanguageIdentifier(from: targetRaw) else {
            workflowTextProcessingLogger.error("Apple Translate target language invalid")
            return text
        }

        let sourceRaw = detectedLanguage ?? configuredLanguage
        let sourceLanguageCode = WorkflowTranslationLanguageNormalizer.normalizedLanguageIdentifier(from: sourceRaw)

        return try await appleTranslator(text, targetLanguageCode, sourceLanguageCode)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// System prompt for inline command detection, carried over from the legacy
    /// per-profile behavior (#87): a single LLM pass that removes a spoken
    /// transformation instruction from the dictation and applies it.
    private static func inlineCommandSystemPrompt(
        fineTuning: String,
        outputInstruction: String
    ) -> String {
        var prompt = """
        The user dictated text that may contain a spoken transformation instruction (e.g., "write this as an email", "summarize this", "mach daraus Stichpunkte"). \
        If found, remove the instruction and apply the transformation. If not found, return the text unchanged. \
        Return ONLY the final text - no explanations, prefixes, or quotes. The instruction can be in any language and anywhere in the text.
        """
        let trimmedFineTuning = fineTuning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFineTuning.isEmpty {
            prompt += "\nAlso apply this style context: \(trimmedFineTuning)"
        }
        prompt += outputInstruction
        return prompt
    }
}

enum WorkflowTranslationLanguageNormalizer {
    nonisolated static func normalizedLanguageIdentifier(from rawIdentifier: String?) -> String? {
        normalizeLanguageIdentifier(rawIdentifier)
    }

    nonisolated private static func normalizeLanguageIdentifier(_ rawIdentifier: String?) -> String? {
        guard var raw = rawIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        raw = raw.replacingOccurrences(of: "_", with: "-")

        let scriptSpecific = ["zh-Hans", "zh-Hant"]
        if let exact = scriptSpecific.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact
        }

        let foldedRaw = foldLanguageToken(raw)
        if foldedRaw == "auto" { return nil }

        let primary = raw.split(separator: "-").first.map(String.init) ?? raw
        let primaryLower = primary.lowercased()
        if isoLanguageCodes.contains(primaryLower) {
            return primaryLower
        }

        return languageAliasMap[foldedRaw]
    }

    nonisolated private static func foldLanguageToken(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    nonisolated private static let languageAliasMap: [String: String] = {
        var map: [String: String] = [:]
        let helperLocales = [
            Locale(identifier: "en_US"),
            Locale(identifier: "de_DE"),
            Locale.current,
        ]

        for code in isoLanguageCodes {
            map[foldLanguageToken(code)] = code

            for locale in helperLocales {
                if let localized = locale.localizedString(forIdentifier: code) {
                    map[foldLanguageToken(localized)] = code
                }
            }

            if let autonym = Locale(identifier: code).localizedString(forIdentifier: code) {
                map[foldLanguageToken(autonym)] = code
            }
        }

        map[foldLanguageToken("german")] = "de"
        map[foldLanguageToken("deutsch")] = "de"
        map[foldLanguageToken("english")] = "en"
        map[foldLanguageToken("englisch")] = "en"
        map[foldLanguageToken("spanish")] = "es"
        map[foldLanguageToken("spanisch")] = "es"
        map[foldLanguageToken("espanol")] = "es"
        map[foldLanguageToken("español")] = "es"
        map[foldLanguageToken("chinese simplified")] = "zh-Hans"
        map[foldLanguageToken("simplified chinese")] = "zh-Hans"
        map[foldLanguageToken("chinese traditional")] = "zh-Hant"
        map[foldLanguageToken("traditional chinese")] = "zh-Hant"

        return map
    }()

    nonisolated private static var isoLanguageCodes: [String] {
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
    }
}
