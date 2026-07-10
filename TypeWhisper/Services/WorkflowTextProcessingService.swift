import Foundation
import TypeWhisperPluginSDK
import os.log

private let workflowTextProcessingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "WorkflowTextProcessingService"
)

@MainActor
struct WorkflowTextProcessingService {
    typealias PromptProcessor = (
        _ prompt: String,
        _ text: String,
        _ providerId: String?,
        _ cloudModel: String?,
        _ temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String

    typealias AppleTranslator = (
        _ text: String,
        _ targetLanguageCode: String,
        _ sourceLanguageCode: String?
    ) async throws -> String
    private let promptProcessor: PromptProcessor
    private let appleTranslator: AppleTranslator?

    init(
        promptProcessor: @escaping PromptProcessor,
        appleTranslator: AppleTranslator?
    ) {
        self.promptProcessor = promptProcessor
        self.appleTranslator = appleTranslator
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
        if workflow.usesAppleTranslate {
            return try await processAppleTranslate(
                workflow: workflow,
                text: text,
                fallbackTranslationTarget: fallbackTranslationTarget,
                detectedLanguage: detectedLanguage,
                configuredLanguage: configuredLanguage
            )
        }

        guard let systemPrompt = workflow.systemPrompt(
            fallbackTranslationTarget: fallbackTranslationTarget,
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage,
            resolvedOutputFormat: resolvedOutputFormat
        ) else {
            return text
        }

        let behavior = workflow.behavior
        return try await promptProcessor(
            systemPrompt,
            text,
            Self.trimmedOrNil(behavior.providerId),
            Self.trimmedOrNil(behavior.cloudModel),
            behavior.temperatureDirective
        )
    }

    func canProcess(
        workflow: Workflow,
        fallbackTranslationTarget: String? = nil,
        detectedLanguage: String? = nil,
        configuredLanguage: String? = nil,
        resolvedOutputFormat: String? = nil
    ) -> Bool {
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
