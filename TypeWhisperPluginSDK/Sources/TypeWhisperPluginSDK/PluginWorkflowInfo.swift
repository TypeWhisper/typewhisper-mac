import Foundation

public enum PluginWorkflowTemplate: String, Codable, CaseIterable, Sendable, Equatable {
    case cleanedText
    case translation
    case emailReply
    case meetingNotes
    case checklist
    case json
    case summary
    case dictation
    case custom
}

public enum PluginWorkflowTriggerKind: String, Codable, CaseIterable, Sendable, Equatable {
    case app
    case website
    case hotkey
    case global
    case manual
}

public enum PluginWorkflowHotkeyBehavior: String, Codable, CaseIterable, Sendable, Equatable {
    case startDictation
    case processSelectedText
}

public struct PluginWorkflowHotkey: Codable, Sendable, Equatable {
    public let keyCode: UInt16
    public let modifierFlags: UInt
    public let isFn: Bool
    public let isDoubleTap: Bool
    public let modifierKeyCodes: [UInt16]
    public let mouseButton: UInt16?

    public init(
        keyCode: UInt16,
        modifierFlags: UInt,
        isFn: Bool,
        isDoubleTap: Bool = false,
        modifierKeyCodes: [UInt16] = [],
        mouseButton: UInt16? = nil
    ) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isFn = isFn
        self.isDoubleTap = isDoubleTap
        self.modifierKeyCodes = modifierKeyCodes
        self.mouseButton = mouseButton
    }
}

public struct PluginWorkflowTrigger: Codable, Sendable, Equatable {
    public let kind: PluginWorkflowTriggerKind
    public let appBundleIdentifiers: [String]
    public let websitePatterns: [String]
    public let hotkeys: [PluginWorkflowHotkey]
    public let hotkeyBehavior: PluginWorkflowHotkeyBehavior

    public init(
        kind: PluginWorkflowTriggerKind,
        appBundleIdentifiers: [String] = [],
        websitePatterns: [String] = [],
        hotkeys: [PluginWorkflowHotkey] = [],
        hotkeyBehavior: PluginWorkflowHotkeyBehavior = .startDictation
    ) {
        self.kind = kind
        self.appBundleIdentifiers = appBundleIdentifiers
        self.websitePatterns = websitePatterns
        self.hotkeys = hotkeys
        self.hotkeyBehavior = hotkeyBehavior
    }
}

public struct PluginWorkflowBehavior: Codable, Sendable, Equatable {
    public let settings: [String: String]
    public let fineTuning: String
    public let providerId: String?
    public let cloudModel: String?
    public let temperatureMode: PluginLLMTemperatureMode
    public let temperatureValue: Double?

    public init(
        settings: [String: String] = [:],
        fineTuning: String = "",
        providerId: String? = nil,
        cloudModel: String? = nil,
        temperatureMode: PluginLLMTemperatureMode = .inheritProviderSetting,
        temperatureValue: Double? = nil
    ) {
        self.settings = settings
        self.fineTuning = fineTuning
        self.providerId = providerId
        self.cloudModel = cloudModel
        self.temperatureMode = temperatureMode
        self.temperatureValue = temperatureValue
    }

    public var temperatureDirective: PluginLLMTemperatureDirective {
        PluginLLMTemperatureDirective(mode: temperatureMode, value: temperatureValue)
    }
}

public struct PluginWorkflowOutput: Codable, Sendable, Equatable {
    public let format: String?
    public let autoEnter: Bool
    public let targetActionPluginId: String?

    public init(
        format: String? = nil,
        autoEnter: Bool = false,
        targetActionPluginId: String? = nil
    ) {
        self.format = format
        self.autoEnter = autoEnter
        self.targetActionPluginId = targetActionPluginId
    }
}

public struct PluginWorkflowInfo: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let sortOrder: Int
    public let template: PluginWorkflowTemplate
    public let trigger: PluginWorkflowTrigger
    public let behavior: PluginWorkflowBehavior
    public let output: PluginWorkflowOutput
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        name: String,
        isEnabled: Bool,
        sortOrder: Int,
        template: PluginWorkflowTemplate,
        trigger: PluginWorkflowTrigger,
        behavior: PluginWorkflowBehavior,
        output: PluginWorkflowOutput,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.template = template
        self.trigger = trigger
        self.behavior = behavior
        self.output = output
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
