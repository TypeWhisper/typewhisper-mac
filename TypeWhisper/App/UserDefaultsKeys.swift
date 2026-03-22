import Foundation

/// Central registry for all UserDefaults keys used throughout the app.
/// Prevents typo-induced bugs and makes keys discoverable via autocomplete.
enum UserDefaultsKeys {
    // MARK: - Dictation
    static let audioDuckingEnabled = "audioDuckingEnabled"
    static let audioDuckingLevel = "audioDuckingLevel"
    static let soundFeedbackEnabled = "soundFeedbackEnabled"
    static let indicatorStyle = "indicatorStyle"

    // MARK: - Hotkey (JSON-encoded UnifiedHotkey per slot)
    static let hybridHotkey = "hybridHotkey"
    static let pttHotkey = "pttHotkey"
    static let toggleHotkey = "toggleHotkey"
    static let promptPaletteHotkey = "promptPaletteHotkey"

    // MARK: - Model / Engine
    static let selectedEngine = "selectedEngine"
    static let selectedModelId = "selectedModelId"
    static let loadedModelIds = "loadedModelIds"
    static let modelAutoUnloadSeconds = "modelAutoUnloadSeconds"

    // MARK: - Settings
    static let selectedLanguage = "selectedLanguage"
    static let selectedTask = "selectedTask"
    static let translationEnabled = "translationEnabled"
    static let translationTargetLanguage = "translationTargetLanguage"
    static let preferredAppLanguage = "preferredAppLanguage"

    // MARK: - API Server
    static let apiServerEnabled = "apiServerEnabled"
    static let apiServerPort = "apiServerPort"

    // MARK: - Audio Device
    static let selectedInputDeviceUID = "selectedInputDeviceUID"

    // MARK: - Home / Setup
    static let setupWizardCompleted = "setupWizardCompleted"
    static let setupWizardCurrentStep = "setupWizardCurrentStep"

    // MARK: - Dictionary
    static let activatedTermPacks = "activatedTermPacks"

    // MARK: - History
    static let historyRetentionDays = "historyRetentionDays"
    static let saveAudioWithHistory = "saveAudioWithHistory"

    // MARK: - Notch Indicator
    static let overlayPosition = "overlayPosition"
    static let notchIndicatorVisibility = "notchIndicatorVisibility"
    static let notchIndicatorLeftContent = "notchIndicatorLeftContent"
    static let notchIndicatorRightContent = "notchIndicatorRightContent"
    static let notchIndicatorDisplay = "notchIndicatorDisplay"

    // MARK: - Appearance
    static let showMenuBarIcon = "showMenuBarIcon"
    static let menuBarIconHiddenAlertShown = "menuBarIconHiddenAlertShown"

    // MARK: - Memory
    static let memoryEnabled = "memoryEnabled"
    static let memoryExtractionProvider = "memoryExtractionProvider"
    static let memoryExtractionModel = "memoryExtractionModel"
    static let memoryMinTextLength = "memoryMinTextLength"
    static let memoryExtractionPrompt = "memoryExtractionPrompt"

    // MARK: - Plugin Registry
    static let pluginRegistryLastFetch = "pluginRegistryLastFetch"

    // MARK: - Watch Folder
    static let watchFolderBookmark = "watchFolderBookmark"
    static let watchFolderOutputBookmark = "watchFolderOutputBookmark"
    static let watchFolderOutputFormat = "watchFolderOutputFormat"
    static let watchFolderDeleteSource = "watchFolderDeleteSource"
    static let watchFolderAutoStart = "watchFolderAutoStart"
    static let watchFolderLanguage = "watchFolderLanguage"
    static let watchFolderEngine = "watchFolderEngine"
    static let watchFolderModel = "watchFolderModel"
}
