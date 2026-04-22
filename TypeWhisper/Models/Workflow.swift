import Foundation
import SwiftData
import TypeWhisperPluginSDK

enum WorkflowTemplate: String, CaseIterable, Codable, Sendable {
    case cleanedText
    case translation
    case emailReply
    case meetingNotes
    case checklist
    case json
    case summary
    case custom

    static var catalog: [WorkflowTemplateDefinition] {
        allCases.map(\.definition)
    }

    var definition: WorkflowTemplateDefinition {
        switch self {
        case .cleanedText:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Cleaned Text", de: "Bereinigter Text"),
                description: localizedAppText(
                    "Clean up dictated text for readability and punctuation.",
                    de: "Bereinigt diktierten Text fuer bessere Lesbarkeit und Zeichensetzung."
                ),
                systemImage: "text.badge.checkmark"
            )
        case .translation:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Translation", de: "Uebersetzung"),
                description: localizedAppText(
                    "Translate dictated text into the target language.",
                    de: "Uebersetzt diktierten Text in die Zielsprache."
                ),
                systemImage: "globe"
            )
        case .emailReply:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Email Reply", de: "E-Mail-Antwort"),
                description: localizedAppText(
                    "Turn dictated notes into a reply email.",
                    de: "Formt diktierte Notizen in eine Antwort-E-Mail um."
                ),
                systemImage: "envelope"
            )
        case .meetingNotes:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Meeting Notes", de: "Meeting Notes"),
                description: localizedAppText(
                    "Structure dictated notes into a meeting summary.",
                    de: "Strukturiert diktierte Notizen zu einer Meeting-Zusammenfassung."
                ),
                systemImage: "doc.text.magnifyingglass"
            )
        case .checklist:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Checklist", de: "Checkliste"),
                description: localizedAppText(
                    "Extract action items into a checklist.",
                    de: "Extrahiert Aufgaben in eine Checkliste."
                ),
                systemImage: "checklist"
            )
        case .json:
            WorkflowTemplateDefinition(
                template: self,
                name: "JSON",
                description: localizedAppText(
                    "Extract structured data as JSON.",
                    de: "Extrahiert strukturierte Daten als JSON."
                ),
                systemImage: "curlybraces"
            )
        case .summary:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Summary", de: "Zusammenfassung"),
                description: localizedAppText(
                    "Condense dictated text into a concise summary.",
                    de: "Verdichtet diktierten Text zu einer kompakten Zusammenfassung."
                ),
                systemImage: "text.alignleft"
            )
        case .custom:
            WorkflowTemplateDefinition(
                template: self,
                name: localizedAppText("Custom Workflow", de: "Eigener Workflow"),
                description: localizedAppText(
                    "Start with a flexible workflow draft.",
                    de: "Startet mit einem flexiblen Workflow-Entwurf."
                ),
                systemImage: "slider.horizontal.3"
            )
        }
    }
}

struct WorkflowTemplateDefinition: Identifiable, Equatable, Sendable {
    let template: WorkflowTemplate
    let name: String
    let description: String
    let systemImage: String

    var id: WorkflowTemplate { template }
}

enum WorkflowTriggerKind: String, CaseIterable, Codable, Sendable {
    case app
    case website
    case hotkey
}

struct WorkflowTrigger: Codable, Equatable, Sendable {
    let kind: WorkflowTriggerKind
    var appBundleIdentifiers: [String]
    var websitePatterns: [String]
    var hotkeys: [UnifiedHotkey]

    init(
        kind: WorkflowTriggerKind,
        appBundleIdentifiers: [String] = [],
        websitePatterns: [String] = [],
        hotkeys: [UnifiedHotkey] = []
    ) {
        self.kind = kind
        self.appBundleIdentifiers = appBundleIdentifiers
        self.websitePatterns = websitePatterns
        self.hotkeys = hotkeys
    }

    static func app(_ bundleIdentifier: String) -> WorkflowTrigger {
        apps([bundleIdentifier])
    }

    static func apps(_ bundleIdentifiers: [String]) -> WorkflowTrigger {
        WorkflowTrigger(kind: .app, appBundleIdentifiers: bundleIdentifiers)
    }

    static func website(_ pattern: String) -> WorkflowTrigger {
        websites([pattern])
    }

    static func websites(_ patterns: [String]) -> WorkflowTrigger {
        WorkflowTrigger(kind: .website, websitePatterns: patterns)
    }

    static func hotkey(_ hotkey: UnifiedHotkey) -> WorkflowTrigger {
        hotkeys([hotkey])
    }

    static func hotkeys(_ hotkeys: [UnifiedHotkey]) -> WorkflowTrigger {
        WorkflowTrigger(kind: .hotkey, hotkeys: hotkeys)
    }

    var appBundleIdentifier: String? {
        appBundleIdentifiers.first
    }

    var websitePattern: String? {
        websitePatterns.first
    }

    var hotkey: UnifiedHotkey? {
        hotkeys.first
    }

    var hasValues: Bool {
        switch kind {
        case .app:
            !appBundleIdentifiers.isEmpty
        case .website:
            !websitePatterns.isEmpty
        case .hotkey:
            !hotkeys.isEmpty
        }
    }
}

struct WorkflowBehavior: Codable, Equatable, Sendable {
    var settings: [String: String]
    var fineTuning: String
    var providerId: String?
    var cloudModel: String?
    var temperatureModeRaw: String?
    var temperatureValue: Double?

    init(
        settings: [String: String] = [:],
        fineTuning: String = "",
        providerId: String? = nil,
        cloudModel: String? = nil,
        temperatureModeRaw: String? = nil,
        temperatureValue: Double? = nil
    ) {
        self.settings = settings
        self.fineTuning = fineTuning
        self.providerId = providerId
        self.cloudModel = cloudModel
        self.temperatureModeRaw = temperatureModeRaw
        self.temperatureValue = temperatureValue
    }

    var temperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: temperatureModeRaw ?? "") ?? .inheritProviderSetting
    }

    var temperatureDirective: PluginLLMTemperatureDirective {
        PluginLLMTemperatureDirective(mode: temperatureMode, value: temperatureValue)
    }
}

struct WorkflowOutput: Codable, Equatable, Sendable {
    var format: String?
    var autoEnter: Bool
    var targetActionPluginId: String?

    init(
        format: String? = nil,
        autoEnter: Bool = false,
        targetActionPluginId: String? = nil
    ) {
        self.format = format
        self.autoEnter = autoEnter
        self.targetActionPluginId = targetActionPluginId
    }
}

@Model
final class Workflow {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var sortOrder: Int
    var templateRaw: String
    var triggerKindRaw: String
    var triggerData: Data?
    var triggerAppBundleIdentifier: String?
    var triggerWebsitePattern: String?
    var triggerHotkeyData: Data?
    var behaviorData: Data?
    var outputData: Data?
    var createdAt: Date
    var updatedAt: Date

    var template: WorkflowTemplate {
        get { WorkflowTemplate(rawValue: templateRaw) ?? .custom }
        set { templateRaw = newValue.rawValue }
    }

    var trigger: WorkflowTrigger? {
        get {
            if let triggerData,
               let decodedTrigger = try? JSONDecoder().decode(WorkflowTrigger.self, from: triggerData),
               decodedTrigger.hasValues {
                return decodedTrigger
            }

            guard let kind = WorkflowTriggerKind(rawValue: triggerKindRaw) else { return nil }

            switch kind {
            case .app:
                guard let bundleIdentifier = triggerAppBundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
                return .app(bundleIdentifier)
            case .website:
                guard let pattern = triggerWebsitePattern, !pattern.isEmpty else { return nil }
                return .website(pattern)
            case .hotkey:
                guard let triggerHotkeyData,
                      let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: triggerHotkeyData) else {
                    return nil
                }
                return .hotkey(hotkey)
            }
        }
        set {
            guard let newValue else {
                triggerKindRaw = WorkflowTriggerKind.app.rawValue
                triggerData = nil
                triggerAppBundleIdentifier = nil
                triggerWebsitePattern = nil
                triggerHotkeyData = nil
                return
            }

            triggerKindRaw = newValue.kind.rawValue
            triggerData = Self.encode(newValue)

            switch newValue.kind {
            case .app:
                triggerAppBundleIdentifier = newValue.appBundleIdentifiers.first
                triggerWebsitePattern = nil
                triggerHotkeyData = nil
            case .website:
                triggerAppBundleIdentifier = nil
                triggerWebsitePattern = newValue.websitePatterns.first
                triggerHotkeyData = nil
            case .hotkey:
                triggerAppBundleIdentifier = nil
                triggerWebsitePattern = nil
                triggerHotkeyData = newValue.hotkeys.first.flatMap { try? JSONEncoder().encode($0) }
            }
        }
    }

    var behavior: WorkflowBehavior {
        get { Self.decode(behaviorData, defaultValue: WorkflowBehavior()) }
        set { behaviorData = Self.encode(newValue) }
    }

    var output: WorkflowOutput {
        get { Self.decode(outputData, defaultValue: WorkflowOutput()) }
        set { outputData = Self.encode(newValue) }
    }

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        template: WorkflowTemplate,
        trigger: WorkflowTrigger,
        behavior: WorkflowBehavior = WorkflowBehavior(),
        output: WorkflowOutput = WorkflowOutput(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.templateRaw = template.rawValue
        self.triggerKindRaw = trigger.kind.rawValue
        self.triggerData = nil
        self.triggerAppBundleIdentifier = nil
        self.triggerWebsitePattern = nil
        self.triggerHotkeyData = nil
        self.behaviorData = Self.encode(behavior)
        self.outputData = Self.encode(output)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trigger = trigger
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<Value: Decodable>(_ data: Data?, defaultValue: Value) -> Value {
        guard let data, let decoded = try? JSONDecoder().decode(Value.self, from: data) else {
            return defaultValue
        }
        return decoded
    }
}

extension WorkflowTriggerKind {
    var paletteLabel: String {
        switch self {
        case .app:
            localizedAppText("App", de: "App")
        case .website:
            localizedAppText("Website", de: "Website")
        case .hotkey:
            localizedAppText("Hotkey", de: "Hotkey")
        }
    }
}

extension Workflow {
    var definition: WorkflowTemplateDefinition {
        template.definition
    }

    var isManuallyRunnable: Bool {
        systemPrompt() != nil || output.targetActionPluginId != nil
    }

    func systemPrompt(
        fallbackTranslationTarget: String? = nil,
        detectedLanguage: String? = nil,
        configuredLanguage: String? = nil
    ) -> String? {
        let outputInstruction = workflowOutputInstruction(for: output)
        let settingsInstruction = workflowSettingsInstruction(for: behavior.settings)
        let fineTuningInstruction = workflowFineTuningInstruction(for: behavior.fineTuning)
        let languageHint = workflowLanguageHint(
            detectedLanguage: detectedLanguage,
            configuredLanguage: configuredLanguage
        )

        switch template {
        case .cleanedText:
            return """
            Clean up the dictated text for readability. Fix punctuation, grammar, and formatting while preserving the original meaning and language. Return only the cleaned text.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .translation:
            let targetLanguage = behavior.settings["targetLanguage"]
                ?? behavior.settings["target"]
                ?? fallbackTranslationTarget
                ?? "English"
            return """
            Translate the dictated text into \(targetLanguage). Preserve meaning, names, and domain-specific terminology unless the instruction explicitly says otherwise. Return only the translated text.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .emailReply:
            return """
            Turn the dictated text into a complete reply email. Use an appropriate greeting and closing, keep the same language as the source unless instructed otherwise, and return only the email body.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .meetingNotes:
            return """
            Restructure the dictated text into clear meeting notes with concise sections, decisions, and action items where applicable. Return only the final notes.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .checklist:
            return """
            Extract the actionable items from the dictated text and return them as a checklist. Keep the source language unless instructed otherwise.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .json:
            return """
            Extract structured information from the dictated text and return valid JSON only. Do not wrap the JSON in markdown fences.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .summary:
            return """
            Summarize the dictated text into a concise, accurate summary. Preserve important facts and keep the source language unless instructed otherwise. Return only the summary.
            \(languageHint)\(settingsInstruction)\(fineTuningInstruction)\(outputInstruction)
            """
        case .custom:
            let customInstruction = behavior.settings["instruction"]
                ?? behavior.settings["goal"]
                ?? behavior.settings["prompt"]
                ?? behavior.fineTuning
            let trimmedInstruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInstruction.isEmpty else {
                return nil
            }
            return """
            Apply the following workflow instruction to the dictated text and return only the final result:
            \(trimmedInstruction)
            \(languageHint)\(settingsInstruction)\(outputInstruction)
            """
        }
    }

    private func workflowSettingsInstruction(for settings: [String: String]) -> String {
        let relevantSettings = settings
            .filter { key, value in
                !["instruction", "goal", "prompt", "targetLanguage", "target"].contains(key)
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

        guard !relevantSettings.isEmpty else { return "" }
        let lines = relevantSettings.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        return "\nAdditional workflow settings:\n\(lines)"
    }

    private func workflowFineTuningInstruction(for fineTuning: String) -> String {
        let trimmed = fineTuning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\nFine-tuning:\n\(trimmed)"
    }

    private func workflowOutputInstruction(for output: WorkflowOutput) -> String {
        var lines: [String] = []
        if let format = output.format?.trimmingCharacters(in: .whitespacesAndNewlines), !format.isEmpty {
            lines.append("Return the result as \(format).")
        }
        if output.targetActionPluginId != nil {
            lines.append("Return only the transformed text result without commentary.")
        }
        guard !lines.isEmpty else { return "" }
        return "\nOutput requirements:\n" + lines.joined(separator: "\n")
    }

    private func workflowLanguageHint(detectedLanguage: String?, configuredLanguage: String?) -> String {
        if let detectedLanguage, !detectedLanguage.isEmpty {
            return "\nDetected source language: \(detectedLanguage)."
        }
        if let configuredLanguage, !configuredLanguage.isEmpty {
            return "\nConfigured source language: \(configuredLanguage)."
        }
        return ""
    }
}
