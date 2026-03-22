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
                name: String(localized: "preset.translate"),
                prompt: "Translate the following text to English. If it's already in English, translate it to German. Only return the translation, nothing else.",
                icon: "globe",
                isPreset: true,
                sortOrder: 0
            ),
            PromptAction(
                name: String(localized: "preset.writeEmail"),
                prompt: "Turn the following text into a well-structured, professional email. Respond in the same language as the input text. Only return the email text.",
                icon: "envelope",
                isPreset: true,
                sortOrder: 1
            ),
            PromptAction(
                name: String(localized: "preset.formatAsList"),
                prompt: "Format the following text as a clean bullet-point list. Respond in the same language as the input text. Only return the formatted list.",
                icon: "list.bullet",
                isPreset: true,
                sortOrder: 2
            ),
            PromptAction(
                name: String(localized: "preset.actionItems"),
                prompt: "Extract all action items, tasks, and to-dos from the following text. Format them as a checklist. Respond in the same language as the input text. Only return the checklist.",
                icon: "checklist",
                isPreset: true,
                sortOrder: 3
            ),
            PromptAction(
                name: String(localized: "preset.reply"),
                prompt: "Write a concise, friendly reply to the following message. Respond in the same language as the input text. Only return the reply.",
                icon: "arrowshape.turn.up.left",
                isPreset: true,
                sortOrder: 4
            ),
            PromptAction(
                name: String(localized: "preset.createTable"),
                prompt: "Convert the following text into a well-formatted Markdown table. Extract key information and organize it into appropriate columns. Respond in the same language as the input text. Only return the table, nothing else.",
                icon: "tablecells",
                isPreset: true,
                sortOrder: 5
            ),
            PromptAction(
                name: String(localized: "preset.draftEmail"),
                prompt: "Draft a complete, professional email from the following notes. Include an appropriate subject line, greeting, body paragraphs, and closing. Respond in the same language as the input text. Only return the email.",
                icon: "envelope.badge",
                isPreset: true,
                sortOrder: 6
            ),
            PromptAction(
                name: String(localized: "preset.jsonData"),
                prompt: "Extract structured data from the following text and format it as valid, well-indented JSON. Use descriptive keys and appropriate data types. Only return the JSON, nothing else.",
                icon: "curlybraces",
                isPreset: true,
                sortOrder: 7
            ),
            PromptAction(
                name: String(localized: "preset.meetingNotes"),
                prompt: "Structure the following text as professional meeting notes. Include sections for: Attendees (if mentioned), Key Discussion Points, Decisions Made, and Action Items with owners. Use Markdown formatting. Respond in the same language as the input text.",
                icon: "doc.text.magnifyingglass",
                isPreset: true,
                sortOrder: 8
            ),
        ]
    }
}
