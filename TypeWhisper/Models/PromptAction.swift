import Foundation
import SwiftData

@Model
final class PromptAction {
    var id: UUID
    var name: String
    var prompt: String
    var icon: String
    var isPreset: Bool
    var isEnabled: Bool
    var sortOrder: Int
    var hotkeyKeyCode: Int?
    var hotkeyModifiers: Int?
    var providerType: String?
    var cloudModel: String?
    var targetActionPluginId: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        icon: String = "sparkles",
        isPreset: Bool = false,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        hotkeyKeyCode: Int? = nil,
        hotkeyModifiers: Int? = nil,
        providerType: String? = nil,
        cloudModel: String? = nil,
        targetActionPluginId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.icon = icon
        self.isPreset = isPreset
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
        self.providerType = providerType
        self.cloudModel = cloudModel
        self.targetActionPluginId = targetActionPluginId
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static var presets: [PromptAction] {
        [
            PromptAction(
                name: String(localized: "preset.smartDictation"),
                prompt: """
                You are a dictation assistant. Your job is to take raw dictated speech and produce clean, well-formatted text.

                Rules:
                - Remove filler words, stutters, false starts, and self-corrections
                - Fix grammar and punctuation while preserving the user's word choices
                - Match the tone and style of the surrounding text if provided
                - Match the language of the surrounding text or application context
                - If the surrounding text is in a different language than the dictation, treat the dictation as instructions and write in the surrounding text's language
                - Do not add content that wasn't dictated
                - Do not use em dashes
                - Only return the formatted text, nothing else
                """,
                icon: "sparkles",
                isPreset: true,
                sortOrder: 0
            ),
            PromptAction(
                name: String(localized: "preset.translate"),
                prompt: "Translate the following text to English. If it's already in English, translate it to German. Only return the translation, nothing else.",
                icon: "globe",
                isPreset: true,
                sortOrder: 1
            ),
            PromptAction(
                name: String(localized: "preset.writeEmail"),
                prompt: "Turn the following text into a well-structured, professional email. Respond in the same language as the input text. Only return the email text.",
                icon: "envelope",
                isPreset: true,
                sortOrder: 2
            ),
            PromptAction(
                name: String(localized: "preset.formatAsList"),
                prompt: "Format the following text as a clean bullet-point list. Respond in the same language as the input text. Only return the formatted list.",
                icon: "list.bullet",
                isPreset: true,
                sortOrder: 3
            ),
            PromptAction(
                name: String(localized: "preset.actionItems"),
                prompt: "Extract all action items, tasks, and to-dos from the following text. Format them as a checklist. Respond in the same language as the input text. Only return the checklist.",
                icon: "checklist",
                isPreset: true,
                sortOrder: 4
            ),
            PromptAction(
                name: String(localized: "preset.reply"),
                prompt: "Write a concise, friendly reply to the following message. Respond in the same language as the input text. Only return the reply.",
                icon: "arrowshape.turn.up.left",
                isPreset: true,
                sortOrder: 5
            ),
        ]
    }
}
