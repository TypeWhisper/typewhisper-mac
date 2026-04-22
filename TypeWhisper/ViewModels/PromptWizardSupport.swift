import Foundation
import TypeWhisperPluginSDK

enum PromptWizardStep: Int, CaseIterable {
    case goal
    case response
    case review
}

enum PromptWizardGoal: String, CaseIterable, Equatable {
    case translate
    case rewrite
    case replyEmail
    case extract
    case structure
    case custom
}

enum PromptWizardTranslationMode: Equatable {
    case direct(targetLanguage: String)
    case alternatingPair(primaryLanguage: String, secondaryLanguage: String)
}

enum PromptWizardTone: String, CaseIterable, Equatable {
    case neutral
    case formal
    case friendly
    case concise
    case clear
    case professional
}

enum PromptWizardResponseLength: String, CaseIterable, Equatable {
    case short
    case medium
    case detailed
}

enum PromptWizardLanguageMode: Equatable {
    case sameAsInput
    case target(String)
}

enum PromptWizardReplyMode: String, CaseIterable, Equatable {
    case reply
    case email
}

enum PromptWizardExtractFormat: String, CaseIterable, Equatable {
    case checklist
    case json
    case table
    case keyPoints
}

enum PromptWizardStructureFormat: String, CaseIterable, Equatable {
    case bulletList
    case meetingNotes
    case table
    case json
}

enum PromptWizardRewriteFormat: String, CaseIterable, Equatable {
    case paragraph
    case list
}

struct PromptWizardDraft: Equatable {
    var goal: PromptWizardGoal
    var name: String
    var icon: String
    var isEnabled: Bool
    var translationMode: PromptWizardTranslationMode?
    var preserveFormatting: Bool
    var tone: PromptWizardTone
    var responseLength: PromptWizardResponseLength
    var languageMode: PromptWizardLanguageMode
    var replyMode: PromptWizardReplyMode
    var extractFormat: PromptWizardExtractFormat
    var structureFormat: PromptWizardStructureFormat
    var rewriteFormat: PromptWizardRewriteFormat
    var includeHeadings: Bool
    var customGoal: String
    var customOutputHint: String
    var providerId: String?
    var cloudModel: String
    var temperatureMode: PluginLLMTemperatureMode
    var temperatureValue: Double?
    var targetActionPluginId: String?

    init(goal: PromptWizardGoal) {
        self.goal = goal
        self.name = ""
        self.icon = goal.defaultIcon
        self.isEnabled = true
        self.translationMode = nil
        self.preserveFormatting = false
        self.tone = .neutral
        self.responseLength = .medium
        self.languageMode = .sameAsInput
        self.replyMode = .reply
        self.extractFormat = .checklist
        self.structureFormat = .bulletList
        self.rewriteFormat = .paragraph
        self.includeHeadings = true
        self.customGoal = ""
        self.customOutputHint = ""
        self.providerId = nil
        self.cloudModel = ""
        self.temperatureMode = .inheritProviderSetting
        self.temperatureValue = nil
        self.targetActionPluginId = nil
    }
}

extension PromptWizardGoal {
    var defaultIcon: String {
        switch self {
        case .translate:
            return "globe"
        case .rewrite:
            return "wand.and.stars"
        case .replyEmail:
            return "arrowshape.turn.up.left"
        case .extract:
            return "checklist"
        case .structure:
            return "list.bullet"
        case .custom:
            return "sparkles"
        }
    }

    var title: String {
        switch self {
        case .translate:
            return localizedAppText("Translate", de: "Übersetzen")
        case .rewrite:
            return localizedAppText("Rewrite", de: "Umschreiben")
        case .replyEmail:
            return localizedAppText("Reply / Email", de: "Antwort / E-Mail")
        case .extract:
            return localizedAppText("Extract", de: "Extrahieren")
        case .structure:
            return localizedAppText("Structure / Format", de: "Struktur / Format")
        case .custom:
            return localizedAppText("Custom", de: "Benutzerdefiniert")
        }
    }

    var description: String {
        switch self {
        case .translate:
            return localizedAppText("Translate text into one language or toggle between a pair.", de: "Text in eine Sprache übersetzen oder zwischen einem Sprachpaar wechseln.")
        case .rewrite:
            return localizedAppText("Improve wording, tone, and readability without changing the meaning.", de: "Formulierung, Ton und Lesbarkeit verbessern, ohne die Bedeutung zu ändern.")
        case .replyEmail:
            return localizedAppText("Draft a reply or a full email from the input.", de: "Aus dem Input eine Antwort oder vollständige E-Mail erstellen.")
        case .extract:
            return localizedAppText("Pull out action items, JSON, tables, or key facts.", de: "Action Items, JSON, Tabellen oder Kerndaten herausziehen.")
        case .structure:
            return localizedAppText("Reformat text into lists, meeting notes, tables, or JSON.", de: "Text in Listen, Meeting Notes, Tabellen oder JSON umformatieren.")
        case .custom:
            return localizedAppText("Describe your own task and let the wizard scaffold the prompt.", de: "Beschreibe deine eigene Aufgabe und lass den Wizard den Prompt vorbereiten.")
        }
    }

    var example: String {
        switch self {
        case .translate:
            return localizedAppText("Example: EN <-> DE translation with formatting preserved.", de: "Beispiel: EN <-> DE Übersetzung mit erhaltener Formatierung.")
        case .rewrite:
            return localizedAppText("Example: make rough notes sound concise and clear.", de: "Beispiel: rohe Notizen knapp und klar formulieren.")
        case .replyEmail:
            return localizedAppText("Example: write a friendly short reply to an incoming message.", de: "Beispiel: eine kurze freundliche Antwort auf eine Nachricht formulieren.")
        case .extract:
            return localizedAppText("Example: extract JSON payloads or action items from meeting notes.", de: "Beispiel: JSON-Daten oder Action Items aus Meeting Notes extrahieren.")
        case .structure:
            return localizedAppText("Example: turn raw notes into meeting notes or a table.", de: "Beispiel: rohe Notizen in Meeting Notes oder eine Tabelle umwandeln.")
        case .custom:
            return localizedAppText("Example: summarize bugs for Slack in a strict bullet format.", de: "Beispiel: Bugs für Slack in einem strikten Bullet-Format zusammenfassen.")
        }
    }
}

extension PromptWizardGoal {
    var tintName: String {
        switch self {
        case .translate: return "blue"
        case .rewrite: return "purple"
        case .replyEmail: return "green"
        case .extract: return "orange"
        case .structure: return "teal"
        case .custom: return "accent"
        }
    }

    var promptWizardGoalSummary: String {
        switch self {
        case .translate:
            return localizedAppText("Translate text into one target language or switch between a language pair.", de: "Übersetze Text in eine Zielsprache oder wechsle zwischen einem Sprachpaar.")
        case .rewrite:
            return localizedAppText("Improve wording and tone while keeping the original meaning intact.", de: "Verbessere Formulierung und Ton, ohne die ursprüngliche Bedeutung zu verändern.")
        case .replyEmail:
            return localizedAppText("Draft a reply or complete email from the incoming text.", de: "Erstelle aus dem eingehenden Text eine Antwort oder vollständige E-Mail.")
        case .extract:
            return localizedAppText("Pull structured output like JSON, tables, action items, or key facts from the input.", de: "Ziehe strukturierte Ausgaben wie JSON, Tabellen, Action Items oder Kernfakten aus dem Input.")
        case .structure:
            return localizedAppText("Reformat loose input into a reliable structure such as lists, meeting notes, tables, or JSON.", de: "Forme losen Input in eine verlässliche Struktur wie Listen, Meeting Notes, Tabellen oder JSON um.")
        case .custom:
            return localizedAppText("Describe your own task and let the wizard scaffold the prompt for you.", de: "Beschreibe deine eigene Aufgabe und lass den Wizard den Prompt für dich vorbereiten.")
        }
    }
}

extension PromptWizardStep {
    var title: String {
        switch self {
        case .goal:
            return localizedAppText("What should it do?", de: "Was soll es tun?")
        case .response:
            return localizedAppText("How should it respond?", de: "Wie soll es antworten?")
        case .review:
            return localizedAppText("Review & Advanced", de: "Review & Erweitert")
        }
    }
}

extension PromptWizardTranslationMode {
    var primaryLanguage: String? {
        switch self {
        case .direct(let targetLanguage):
            return targetLanguage
        case .alternatingPair(let primaryLanguage, _):
            return primaryLanguage
        }
    }

    var secondaryLanguage: String? {
        switch self {
        case .direct:
            return nil
        case .alternatingPair(_, let secondaryLanguage):
            return secondaryLanguage
        }
    }
}

extension PromptWizardLanguageMode {
    var targetLanguageCode: String? {
        switch self {
        case .sameAsInput:
            return nil
        case .target(let language):
            return language
        }
    }
}

enum PromptWizardComposer {
    static func compose(from draft: PromptWizardDraft) -> String {
        switch draft.goal {
        case .translate:
            return composeTranslatePrompt(from: draft)
        case .rewrite:
            return composeRewritePrompt(from: draft)
        case .replyEmail:
            return composeReplyPrompt(from: draft)
        case .extract:
            return composeExtractPrompt(from: draft)
        case .structure:
            return composeStructurePrompt(from: draft)
        case .custom:
            return composeCustomPrompt(from: draft)
        }
    }

    static func reviewSummary(for draft: PromptWizardDraft) -> String {
        switch draft.goal {
        case .translate:
            return translateSummary(for: draft)
        case .rewrite:
            return rewriteSummary(for: draft)
        case .replyEmail:
            return replySummary(for: draft)
        case .extract:
            return extractSummary(for: draft)
        case .structure:
            return structureSummary(for: draft)
        case .custom:
            return customSummary(for: draft)
        }
    }

    private static func composeTranslatePrompt(from draft: PromptWizardDraft) -> String {
        var parts: [String] = []

        switch draft.translationMode {
        case .alternatingPair(let primary, let secondary):
            parts.append("Translate the following text to \(languageName(for: primary)).")
            parts.append("If it's already in \(languageName(for: primary)), translate it to \(languageName(for: secondary)).")
        case .direct(let targetLanguage):
            parts.append("Translate the following text to \(languageName(for: targetLanguage)).")
        case nil:
            parts.append("Translate the following text.")
        }

        if draft.preserveFormatting {
            parts.append("Preserve the original formatting when possible.")
        }

        parts.append("Only return the translation, nothing else.")
        return parts.joined(separator: " ")
    }

    private static func composeRewritePrompt(from draft: PromptWizardDraft) -> String {
        var parts = ["Rewrite the following text"]

        if draft.tone != .neutral {
            parts[0] += " in a \(draft.tone.rawValue) tone"
        }

        switch draft.languageMode {
        case .sameAsInput:
            parts.append("Respond in the same language as the input text.")
        case .target(let language):
            parts.append("Respond in \(languageName(for: language)).")
        }

        switch draft.rewriteFormat {
        case .paragraph:
            parts.append("Return a polished paragraph.")
        case .list:
            parts.append("Return a clean bullet-point list.")
        }

        parts.append("Only return the rewritten text.")
        return parts.joined(separator: " ")
    }

    private static func composeReplyPrompt(from draft: PromptWizardDraft) -> String {
        let noun = draft.replyMode == .email ? "email" : "reply"
        let length = lengthDescriptor(for: draft.responseLength)
        let tone = draft.tone == .neutral ? "" : "\(draft.tone.rawValue), "
        var parts = ["Write a \(length)\(tone)\(noun) to the following message."]

        switch draft.languageMode {
        case .sameAsInput:
            parts.append("Respond in the same language as the input text.")
        case .target(let language):
            parts.append("Respond in \(languageName(for: language)).")
        }

        if draft.replyMode == .email {
            parts.append("Only return the email text.")
        } else {
            parts.append("Only return the reply.")
        }

        return parts.joined(separator: " ")
    }

    private static func composeExtractPrompt(from draft: PromptWizardDraft) -> String {
        switch draft.extractFormat {
        case .checklist:
            return "Extract all action items, tasks, and to-dos from the following text. Format them as a checklist. Only return the checklist."
        case .json:
            return "Extract structured data from the following text and format it as valid, well-indented JSON. Use descriptive keys and appropriate data types. Only return the JSON, nothing else."
        case .table:
            return "Extract key information from the following text and format it as a well-structured Markdown table. Only return the table, nothing else."
        case .keyPoints:
            return "Extract the key points from the following text and return them as a concise bullet-point list. Only return the key points."
        }
    }

    private static func composeStructurePrompt(from draft: PromptWizardDraft) -> String {
        switch draft.structureFormat {
        case .bulletList:
            if draft.includeHeadings {
                return "Format the following text as a clean bullet-point list with short section headings where helpful. Respond in the same language as the input text. Only return the formatted list."
            }
            return "Format the following text as a clean bullet-point list. Respond in the same language as the input text. Only return the formatted list."
        case .meetingNotes:
            return "Structure the following text as professional meeting notes. Include sections for: Attendees (if mentioned), Key Discussion Points, Decisions Made, and Action Items with owners. Use Markdown formatting. Respond in the same language as the input text."
        case .table:
            if draft.includeHeadings {
                return "Convert the following text into a well-formatted Markdown table. Add a short heading if it improves readability. Extract key information and organize it into appropriate columns. Respond in the same language as the input text. Only return the table, nothing else."
            }
            return "Convert the following text into a well-formatted Markdown table. Extract key information and organize it into appropriate columns. Respond in the same language as the input text. Only return the table, nothing else."
        case .json:
            if draft.includeHeadings {
                return "Structure the following text as valid, well-indented JSON. Use descriptive top-level keys and preserve the original meaning. Only return the JSON."
            }
            return "Structure the following text as valid, well-indented JSON. Use descriptive keys and preserve the original meaning. Only return the JSON."
        }
    }

    private static func composeCustomPrompt(from draft: PromptWizardDraft) -> String {
        let trimmedGoal = draft.customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGoal.isEmpty {
            return "Help with the following text. Only return the final result."
        }

        var parts = ["\(trimmedGoal)."]
        if draft.tone != .neutral {
            parts.append("Use a \(draft.tone.rawValue) tone.")
        }
        switch draft.languageMode {
        case .sameAsInput:
            parts.append("Respond in the same language as the input text.")
        case .target(let language):
            parts.append("Respond in \(languageName(for: language)).")
        }
        let outputHint = draft.customOutputHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outputHint.isEmpty {
            parts.append(outputHint.hasSuffix(".") ? outputHint : outputHint + ".")
        }
        parts.append("Only return the final result.")
        return parts.joined(separator: " ")
    }

    private static func translateSummary(for draft: PromptWizardDraft) -> String {
        switch draft.translationMode {
        case .alternatingPair(let primary, let secondary):
            return "Translate between \(languageName(for: primary)) and \(languageName(for: secondary))."
        case .direct(let targetLanguage):
            return "Translate into \(languageName(for: targetLanguage))."
        case nil:
            return "Translate the input text."
        }
    }

    private static func rewriteSummary(for draft: PromptWizardDraft) -> String {
        let tone = draft.tone == .neutral ? "clear" : draft.tone.rawValue
        return "Rewrite the text in a \(tone) tone."
    }

    private static func replySummary(for draft: PromptWizardDraft) -> String {
        let length = lengthDescriptor(for: draft.responseLength)
        let tone = draft.tone == .neutral ? "clear" : draft.tone.rawValue
        let noun = draft.replyMode == .email ? "email" : "reply"
        let language = languageSummary(for: draft.languageMode)
        return "Write a \(length), \(tone) \(noun) \(language)."
    }

    private static func extractSummary(for draft: PromptWizardDraft) -> String {
        switch draft.extractFormat {
        case .checklist:
            return "Extract action items as a checklist."
        case .json:
            return "Extract structured data as JSON."
        case .table:
            return "Extract key information as a table."
        case .keyPoints:
            return "Extract the key points as a list."
        }
    }

    private static func structureSummary(for draft: PromptWizardDraft) -> String {
        switch draft.structureFormat {
        case .bulletList:
            return "Format the input as a bullet list."
        case .meetingNotes:
            return "Format the input as meeting notes."
        case .table:
            return "Format the input as a table."
        case .json:
            return "Format the input as JSON."
        }
    }

    private static func customSummary(for draft: PromptWizardDraft) -> String {
        let trimmedGoal = draft.customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedGoal.isEmpty ? "Custom prompt." : trimmedGoal + "."
    }

    private static func lengthDescriptor(for length: PromptWizardResponseLength) -> String {
        switch length {
        case .short:
            return "short"
        case .medium:
            return "balanced"
        case .detailed:
            return "detailed"
        }
    }

    private static func languageSummary(for mode: PromptWizardLanguageMode) -> String {
        switch mode {
        case .sameAsInput:
            return "in the same language as the input"
        case .target(let language):
            return "in \(languageName(for: language))"
        }
    }

    static func languageNameForDisplay(_ code: String) -> String {
        switch code.lowercased() {
        case "en", "english":
            return "English"
        case "de", "german":
            return "German"
        default:
            return code
        }
    }

    private static func languageName(for code: String) -> String {
        languageNameForDisplay(code)
    }
}

enum PromptWizardInferenceService {
    static func infer(from action: PromptAction) -> PromptWizardDraft {
        let prompt = action.prompt.lowercased()
        let goal = inferGoal(from: prompt)
        var draft = PromptWizardDraft(goal: goal)
        draft.name = action.name
        draft.icon = action.icon
        draft.isEnabled = action.isEnabled
        draft.providerId = action.providerType
        draft.cloudModel = action.cloudModel ?? ""
        draft.temperatureMode = action.temperatureMode
        draft.temperatureValue = action.temperatureValue
        draft.targetActionPluginId = action.targetActionPluginId

        if prompt.contains("translate") {
            if prompt.contains("to english"), prompt.contains("to german") {
                draft.translationMode = .alternatingPair(primaryLanguage: "en", secondaryLanguage: "de")
            } else if let targetLanguage = firstMatchedLanguage(in: prompt) {
                draft.translationMode = .direct(targetLanguage: targetLanguage)
            }
            draft.preserveFormatting = prompt.contains("preserve the original formatting")
        }

        if prompt.contains("same language as the input") {
            draft.languageMode = .sameAsInput
        } else if let targetLanguage = firstMatchedLanguage(in: prompt) {
            draft.languageMode = .target(targetLanguage)
        }

        if prompt.contains("friendly") {
            draft.tone = .friendly
        } else if prompt.contains("professional") {
            draft.tone = .professional
        } else if prompt.contains("formal") {
            draft.tone = .formal
        } else if prompt.contains("concise") {
            draft.tone = .concise
        } else if prompt.contains("clear") {
            draft.tone = .clear
        }

        if prompt.contains("concise") || prompt.contains("short") {
            draft.responseLength = .short
        } else if prompt.contains("detailed") || prompt.contains("complete") {
            draft.responseLength = .detailed
        }

        if prompt.contains("reply") {
            draft.replyMode = .reply
        } else if prompt.contains("email") {
            draft.replyMode = .email
        }

        if prompt.contains("json") {
            draft.extractFormat = .json
            draft.structureFormat = .json
        } else if prompt.contains("checklist") || prompt.contains("action items") || prompt.contains("to-dos") {
            draft.extractFormat = .checklist
        } else if prompt.contains("table") {
            draft.extractFormat = .table
            draft.structureFormat = .table
        } else if prompt.contains("key points") {
            draft.extractFormat = .keyPoints
        }

        if prompt.contains("meeting notes") {
            draft.structureFormat = .meetingNotes
        } else if prompt.contains("bullet-point list") || prompt.contains("bullet point list") {
            draft.structureFormat = .bulletList
            draft.rewriteFormat = .list
        }

        if goal == .custom {
            draft.customGoal = action.prompt
        }

        return draft
    }

    private static func inferGoal(from prompt: String) -> PromptWizardGoal {
        if prompt.contains("translate") {
            return .translate
        }
        if prompt.contains("reply") || prompt.contains("email") {
            return .replyEmail
        }
        if prompt.contains("json") || prompt.contains("checklist") || prompt.contains("action items") {
            return .extract
        }
        if prompt.contains("meeting notes") || prompt.contains("markdown table") || prompt.contains("bullet-point list") {
            return .structure
        }
        if prompt.contains("rewrite") || prompt.contains("rephrase") {
            return .rewrite
        }
        return .custom
    }

    private static func firstMatchedLanguage(in prompt: String) -> String? {
        if prompt.contains("english") { return "en" }
        if prompt.contains("german") { return "de" }
        return nil
    }
}

enum PromptWizardNameSuggester {
    static func suggestedName(for draft: PromptWizardDraft) -> String {
        switch draft.goal {
        case .translate:
            switch draft.translationMode {
            case .direct(let targetLanguage):
                return localizedAppText(
                    "Translate to \(displayName(for: targetLanguage))",
                    de: "Nach \(displayName(for: targetLanguage)) übersetzen"
                )
            case .alternatingPair(let primaryLanguage, let secondaryLanguage):
                return localizedAppText(
                    "Translate \(displayName(for: primaryLanguage)) / \(displayName(for: secondaryLanguage))",
                    de: "\(displayName(for: primaryLanguage)) / \(displayName(for: secondaryLanguage)) übersetzen"
                )
            case nil:
                return localizedAppText("Translate", de: "Übersetzen")
            }
        case .rewrite:
            switch draft.tone {
            case .formal:
                return localizedAppText("Formal Rewrite", de: "Formal umschreiben")
            case .friendly:
                return localizedAppText("Friendly Rewrite", de: "Freundlich umschreiben")
            case .concise:
                return localizedAppText("Concise Rewrite", de: "Knapp umschreiben")
            case .clear:
                return localizedAppText("Clear Rewrite", de: "Klar umschreiben")
            case .professional:
                return localizedAppText("Professional Rewrite", de: "Professionell umschreiben")
            case .neutral:
                return localizedAppText("Rewrite", de: "Umschreiben")
            }
        case .replyEmail:
            switch draft.replyMode {
            case .reply:
                return localizedAppText("Reply", de: "Antwort")
            case .email:
                return localizedAppText("Email Draft", de: "E-Mail-Entwurf")
            }
        case .extract:
            switch draft.extractFormat {
            case .checklist:
                return localizedAppText("Action Items", de: "Action Items")
            case .json:
                return localizedAppText("Extract JSON", de: "JSON extrahieren")
            case .table:
                return localizedAppText("Extract Table", de: "Tabelle extrahieren")
            case .keyPoints:
                return localizedAppText("Key Points", de: "Kernpunkte")
            }
        case .structure:
            switch draft.structureFormat {
            case .bulletList:
                return localizedAppText("Format as List", de: "Als Liste formatieren")
            case .meetingNotes:
                return localizedAppText("Meeting Notes", de: "Meeting Notes")
            case .table:
                return localizedAppText("Create Table", de: "Tabelle erstellen")
            case .json:
                return localizedAppText("Structure JSON", de: "JSON strukturieren")
            }
        case .custom:
            let trimmedGoal = draft.customGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedGoal.isEmpty {
                return localizedAppText("Custom Prompt", de: "Benutzerdefinierter Prompt")
            }
            let compact = trimmedGoal.replacingOccurrences(of: "\n", with: " ")
            if compact.count <= 36 {
                return compact
            }
            let endIndex = compact.index(compact.startIndex, offsetBy: 36)
            return String(compact[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func displayName(for languageCode: String) -> String {
        PromptWizardComposer.languageNameForDisplay(languageCode)
    }
}
