import Foundation

/// Central registry for all UserDefaults keys used throughout the app.
/// Prevents typo-induced bugs and makes keys discoverable via autocomplete.
enum UserDefaultsKeys {
    // MARK: - Dictation
    static let whisperModeEnabled = "whisperModeEnabled"
    static let audioDuckingEnabled = "audioDuckingEnabled"
    static let audioDuckingLevel = "audioDuckingLevel"
    static let mediaPauseEnabled = "mediaPauseEnabled"
    static let soundFeedbackEnabled = "soundFeedbackEnabled"
    static let silencePauseEnabled = "silencePauseEnabled"
    static let silenceAutoStopDuration = "silenceAutoStopDuration"
    static let silenceThreshold = "silenceThreshold"
    static let overlayPosition = "overlayPosition"

    // MARK: - Hotkey (JSON-encoded UnifiedHotkey per slot)
    static let hybridHotkey = "hybridHotkey"
    static let pttHotkey = "pttHotkey"
    static let toggleHotkey = "toggleHotkey"
    static let promptPaletteHotkey = "promptPaletteHotkey"

    // MARK: - Model / Engine
    static let selectedEngine = "selectedEngine"
    static let selectedModelId = "selectedModelId"
    static let loadedModelIds = "loadedModelIds"

    // MARK: - Settings
    static let selectedLanguage = "selectedLanguage"
    static let selectedTask = "selectedTask"
    static let translationEnabled = "translationEnabled"
    static let translationTargetLanguage = "translationTargetLanguage"
    static let defaultPromptActionId = "defaultPromptActionId"
    static let preferredAppLanguage = "preferredAppLanguage"

    // MARK: - API Server
    static let apiServerEnabled = "apiServerEnabled"
    static let apiServerPort = "apiServerPort"

    // MARK: - Audio Device
    static let selectedInputDeviceUID = "selectedInputDeviceUID"

    // MARK: - Home / Setup
    static let setupWizardCompleted = "setupWizardCompleted"

    // MARK: - Dictionary
    static let activatedTermPacks = "activatedTermPacks"

    // MARK: - Prompt Palette
    static let promptDisplayDuration = "promptDisplayDuration"

    // MARK: - History
    static let historyRetentionDays = "historyRetentionDays"

    // MARK: - Notch Indicator
    static let notchIndicatorVisibility = "notchIndicatorVisibility"
    static let notchIndicatorLeftContent = "notchIndicatorLeftContent"
    static let notchIndicatorRightContent = "notchIndicatorRightContent"
}
