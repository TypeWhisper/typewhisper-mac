import Foundation
import Combine
import AppKit

func preferredAppLanguageCode() -> String {
    if let language = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage), !language.isEmpty {
        return language
    }

    if let preferred = Bundle.main.preferredLocalizations.first, !preferred.isEmpty {
        return preferred
    }

    return Locale.current.language.languageCode?.identifier ?? "en"
}

func localizedAppText(_ english: String, de german: String) -> String {
    preferredAppLanguageCode().hasPrefix("de") ? german : english
}

func localizedAppLanguageName(for code: String) -> String {
    guard code != "auto" else {
        return localizedAppText("Auto-Detect", de: "Automatisch erkennen")
    }

    let locale = Locale(identifier: preferredAppLanguageCode())
    return locale.localizedString(forIdentifier: code) ?? code
}

struct LocalizedAppLanguageOption: Equatable {
    let code: String
    let name: String
}

func localizedAppLanguageOptions(for codes: [String]) -> [LocalizedAppLanguageOption] {
    codes.map { code in
        LocalizedAppLanguageOption(code: code, name: localizedAppLanguageName(for: code))
    }
}

func localizedAppLanguageSearchTerms(for code: String, preferredDisplayName: String? = nil) -> [String] {
    var terms: [String] = []

    if let preferredDisplayName {
        appendLanguageSearchTerm(preferredDisplayName, to: &terms)
    }

    appendLanguageSearchTerm(code, to: &terms)
    appendLanguageSearchTerm(localizedAppLanguageName(for: code), to: &terms)

    let locales = [
        Locale.current,
        Locale(identifier: "en"),
        Locale(identifier: code)
    ]

    for locale in locales {
        appendLanguageSearchTerm(locale.localizedString(forIdentifier: code), to: &terms)
    }

    return terms
}

private func appendLanguageSearchTerm(_ value: String?, to terms: inout [String]) {
    guard let value else { return }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }

    terms.append(trimmed)
}

func localizedAppLanguageFlag(for code: String) -> String? {
    guard code != "auto" else { return nil }

    let components = NSLocale.components(fromLocaleIdentifier: code)
    let regionKey = NSLocale.Key.countryCode.rawValue
    let scriptKey = NSLocale.Key.scriptCode.rawValue
    let languageKey = NSLocale.Key.languageCode.rawValue

    if let region = components[regionKey]?.uppercased(),
       region.count == 2 {
        return emojiFlag(forRegionCode: region)
    }

    // Script-only variants like zh-Hans / zh-Hant should not get a country flag.
    if components[scriptKey] != nil {
        return nil
    }

    guard let languageCode = components[languageKey]?.lowercased() else {
        return nil
    }

    let inferredRegionByLanguage = [
        "ar": "SA",
        "cs": "CZ",
        "da": "DK",
        "de": "DE",
        "en": "US",
        "el": "GR",
        "es": "ES",
        "fi": "FI",
        "fr": "FR",
        "he": "IL",
        "hi": "IN",
        "hu": "HU",
        "id": "ID",
        "it": "IT",
        "ja": "JP",
        "ko": "KR",
        "nl": "NL",
        "no": "NO",
        "pl": "PL",
        "ro": "RO",
        "ru": "RU",
        "sv": "SE",
        "th": "TH",
        "tr": "TR",
        "uk": "UA",
        "vi": "VN",
        "zh": "CN"
    ]

    guard let inferredRegion = inferredRegionByLanguage[languageCode] else {
        return nil
    }

    return emojiFlag(forRegionCode: inferredRegion)
}

func localizedAppLanguageBadgeText(for code: String) -> String {
    let components = NSLocale.components(fromLocaleIdentifier: code)
    let languageKey = NSLocale.Key.languageCode.rawValue
    guard let languageCode = components[languageKey], !languageCode.isEmpty else {
        return code.uppercased()
    }

    if code.contains("-") {
        return code.uppercased()
    }

    return languageCode.uppercased()
}

private func emojiFlag(forRegionCode regionCode: String) -> String? {
    let normalized = regionCode.uppercased()
    guard normalized.count == 2 else { return nil }

    let base: UInt32 = 127397
    var scalars = String.UnicodeScalarView()

    for scalar in normalized.unicodeScalars {
        guard let regionalIndicator = UnicodeScalar(base + scalar.value) else {
            return nil
        }
        scalars.append(regionalIndicator)
    }

    return String(scalars)
}

func localizedAppLanguageNames(for codes: [String]) -> [String] {
    codes.map(localizedAppLanguageName(for:))
}

func localizedAppLanguageList(_ codes: [String]) -> String {
    let names = localizedAppLanguageNames(for: codes)
    guard let first = names.first else { return "" }
    if names.count == 1 { return first }
    if names.count == 2 {
        return "\(first)\(localizedAppOrSeparator())\(names[1])"
    }
    let allButLast = names.dropLast().joined(separator: ", ")
    return "\(allButLast),\(localizedAppText(" and ", de: " und "))\(names[names.count - 1])"
}

func localizedAppOrSeparator() -> String {
    localizedAppText(" or ", de: " oder ")
}

func featuredAppLanguageRank(for code: String) -> Int? {
    let components = NSLocale.components(fromLocaleIdentifier: code)
    let languageKey = NSLocale.Key.languageCode.rawValue
    guard let languageCode = components[languageKey]?.lowercased() else {
        return nil
    }

    let featuredLanguageOrder = [
        "de",
        "en",
        "fr",
        "es",
        "zh",
        "hi",
        "ar",
        "pt",
        "ja"
    ]

    return featuredLanguageOrder.firstIndex(of: languageCode)
}

struct InstalledApp: Identifiable, Hashable {
    let id: String // bundleIdentifier
    let name: String
    let icon: NSImage?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }
}

enum RuleEditorStep: Int, CaseIterable {
    case scope
    case behavior
    case review

    var title: String {
        switch self {
        case .scope:
            localizedAppText("Where should this rule apply?", de: "Wo gilt diese Regel?")
        case .behavior:
            localizedAppText("How should TypeWhisper respond?", de: "Wie soll TypeWhisper reagieren?")
        case .review:
            localizedAppText("Review & Advanced", de: "Review & Erweitert")
        }
    }
}

@MainActor
final class ProfilesViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: ProfilesViewModel?
    static var shared: ProfilesViewModel {
        guard let instance = _shared else {
            fatalError("ProfilesViewModel not initialized")
        }
        return instance
    }

    @Published var profiles: [Profile] = []
    @Published private(set) var focusedPromptActionId: String?

    // Editor state
    @Published var showingEditor = false
    @Published var editorStep: RuleEditorStep = .scope
    @Published var editorIsEnabled = true
    @Published var showingAdvancedSettings = false
    @Published var editingProfile: Profile?
    @Published var editorName = ""
    @Published var editorBundleIdentifiers: [String] = []
    @Published var editorUrlPatterns: [String] = []
    @Published var editorInputLanguage: String?
    @Published var editorTranslationEnabled: Bool?
    @Published var editorTranslationTargetLanguage: String?
    @Published var editorSelectedTask: String?
    @Published var editorEngineOverride: String?
    @Published var editorCloudModelOverride: String?
    @Published var editorPromptActionId: String?
    @Published var editorMemoryEnabled: Bool = false
    @Published var editorOutputFormat: String?
    @Published var editorInlineCommandsEnabled = false
    @Published var editorAutoEnterEnabled = false
    @Published var editorHotkey: UnifiedHotkey?
    @Published var editorHotkeyLabel: String = ""
    @Published var editorPriority: Int = 0

    // App picker
    @Published var showingAppPicker = false
    @Published var appSearchQuery = ""
    @Published var installedApps: [InstalledApp] = []

    // Domain autocomplete
    @Published var urlPatternInput = ""
    @Published var domainSuggestions: [String] = []
    @Published var editorDetectedAppName: String?
    @Published var editorDetectedBundleIdentifier: String?
    @Published var editorDetectedURL: String?
    @Published var editorDetectedDomain: String?
    @Published var editorDetectedIsSupportedBrowser = false
    @Published var showingWebsiteScope = false
    @Published private(set) var editorPromptActionWasPrefilled = false
    var availableDomains: [String] = []

    private let profileService: ProfileService
    private let historyService: HistoryService
    let settingsViewModel: SettingsViewModel
    private var cancellables = Set<AnyCancellable>()
    private var editorNameManuallyEdited = false

    init(profileService: ProfileService, historyService: HistoryService, settingsViewModel: SettingsViewModel) {
        self.profileService = profileService
        self.historyService = historyService
        self.settingsViewModel = settingsViewModel
        self.profiles = profileService.profiles
        setupBindings()
        scanInstalledApps()
    }

    var filteredApps: [InstalledApp] {
        guard !appSearchQuery.isEmpty else { return installedApps }
        let query = appSearchQuery.lowercased()
        return installedApps.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    var isFilteringRulesByPrompt: Bool {
        focusedPromptActionId != nil
    }

    var focusedPromptAction: PromptAction? {
        guard let focusedPromptActionId else { return nil }
        return availablePromptActions.first { $0.id.uuidString == focusedPromptActionId }
    }

    var editorPromptAction: PromptAction? {
        guard let editorPromptActionId else { return nil }
        return availablePromptActions.first { $0.id.uuidString == editorPromptActionId }
    }

    var visibleProfiles: [Profile] {
        guard let focusedPromptActionId else { return profiles }
        return profiles.filter { $0.promptActionId == focusedPromptActionId }
    }

    var suggestedRuleName: String {
        let appNames = editorBundleIdentifiers.prefix(2).map(appName(for:))
        let domains = editorUrlPatterns.prefix(2)

        switch (!appNames.isEmpty, !domains.isEmpty) {
        case (true, true):
            return "\(appNames.joined(separator: " + ")) @ \(domains.joined(separator: " + "))"
        case (true, false):
            return appNames.joined(separator: " + ")
        case (false, true):
            return domains.joined(separator: " + ")
        case (false, false):
            return localizedAppText("Default Rule", de: "Standardregel")
        }
    }

    var currentRuleName: String {
        let trimmed = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
        if editorNameManuallyEdited, !trimmed.isEmpty {
            return trimmed
        }
        return suggestedRuleName
    }

    var canAdvanceFromCurrentStep: Bool {
        switch editorStep {
        case .scope:
            return true
        case .behavior, .review:
            return true
        }
    }
    var shouldShowPrefilledPromptFallbackNotice: Bool {
        editorPromptActionWasPrefilled &&
        editorPromptActionId != nil &&
        editorBundleIdentifiers.isEmpty &&
        editorUrlPatterns.isEmpty
    }

    // MARK: - CRUD

    func addProfile() {
        profileService.addProfile(
            name: currentRuleName,
            isEnabled: editorIsEnabled,
            bundleIdentifiers: editorBundleIdentifiers,
            urlPatterns: editorUrlPatterns,
            inputLanguage: editorInputLanguage,
            translationEnabled: editorTranslationEnabled,
            translationTargetLanguage: editorTranslationTargetLanguage,
            selectedTask: editorSelectedTask,
            engineOverride: editorEngineOverride,
            cloudModelOverride: editorCloudModelOverride,
            promptActionId: editorPromptActionId,
            memoryEnabled: editorMemoryEnabled,
            outputFormat: editorOutputFormat,
            hotkeyData: editorHotkey.flatMap { try? JSONEncoder().encode($0) },
            inlineCommandsEnabled: editorInlineCommandsEnabled,
            autoEnterEnabled: editorAutoEnterEnabled,
            priority: profileService.nextPriority()
        )
    }

    func saveProfile() {
        if let profile = editingProfile {
            profile.name = currentRuleName
            profile.isEnabled = editorIsEnabled
            profile.bundleIdentifiers = editorBundleIdentifiers
            profile.urlPatterns = editorUrlPatterns
            profile.inputLanguage = editorInputLanguage
            profile.translationEnabled = editorTranslationEnabled
            profile.translationTargetLanguage = editorTranslationTargetLanguage
            profile.selectedTask = editorSelectedTask
            profile.engineOverride = editorEngineOverride
            profile.cloudModelOverride = editorCloudModelOverride
            profile.promptActionId = editorPromptActionId
            profile.memoryEnabled = editorMemoryEnabled
            profile.outputFormat = editorOutputFormat
            profile.inlineCommandsEnabled = editorInlineCommandsEnabled
            profile.autoEnterEnabled = editorAutoEnterEnabled
            profile.hotkey = editorHotkey
            profile.priority = editorPriority
            profileService.updateProfile(profile)
        } else {
            addProfile()
        }
        showingEditor = false
    }

    func deleteProfile(_ profile: Profile) {
        profileService.deleteProfile(profile)
    }

    func moveProfile(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              profiles.indices.contains(fromIndex),
              profiles.indices.contains(toIndex) else { return }

        var reorderedProfiles = profiles
        let movedProfile = reorderedProfiles.remove(at: fromIndex)
        let insertionIndex = fromIndex < toIndex ? max(toIndex - 1, 0) : toIndex
        reorderedProfiles.insert(movedProfile, at: insertionIndex)
        profileService.reorderProfiles(reorderedProfiles)
    }

    func toggleProfile(_ profile: Profile) {
        profileService.toggleProfile(profile)
    }

    func goToNextStep() {
        guard canAdvanceFromCurrentStep else { return }
        if let next = RuleEditorStep(rawValue: editorStep.rawValue + 1) {
            editorStep = next
        }
    }

    func goToPreviousStep() {
        if let previous = RuleEditorStep(rawValue: editorStep.rawValue - 1) {
            editorStep = previous
        }
    }

    func updateRuleName(_ name: String) {
        editorName = name
        editorNameManuallyEdited = true
    }

    // MARK: - Editor

    func prepareNewProfile(prefilledPromptActionId: String? = nil) {
        editingProfile = nil
        focusedPromptActionId = prefilledPromptActionId
        editorStep = .scope
        editorIsEnabled = true
        showingAdvancedSettings = false
        editorName = ""
        editorNameManuallyEdited = false
        editorBundleIdentifiers = []
        editorUrlPatterns = []
        editorInputLanguage = nil
        editorTranslationEnabled = nil
        editorTranslationTargetLanguage = nil
        editorSelectedTask = nil
        editorEngineOverride = nil
        editorCloudModelOverride = nil
        editorPromptActionId = prefilledPromptActionId
        editorMemoryEnabled = false
        editorOutputFormat = nil
        editorInlineCommandsEnabled = false
        editorAutoEnterEnabled = false
        editorHotkey = nil
        editorHotkeyLabel = ""
        editorPriority = 0
        editorPromptActionWasPrefilled = prefilledPromptActionId != nil
        urlPatternInput = ""
        domainSuggestions = []
        editorDetectedAppName = nil
        editorDetectedBundleIdentifier = nil
        editorDetectedURL = nil
        editorDetectedDomain = nil
        editorDetectedIsSupportedBrowser = false
        showingWebsiteScope = false
        loadAvailableDomains()
        refreshEditorContext()
        showingEditor = true
    }

    func prepareEditProfile(_ profile: Profile) {
        editingProfile = profile
        editorStep = .scope
        editorIsEnabled = profile.isEnabled
        showingAdvancedSettings = false
        editorName = profile.name
        editorNameManuallyEdited = true
        editorBundleIdentifiers = profile.bundleIdentifiers
        editorUrlPatterns = profile.urlPatterns
        editorInputLanguage = profile.inputLanguage
        editorTranslationEnabled = profile.translationEnabled
        editorTranslationTargetLanguage = profile.translationTargetLanguage
        editorSelectedTask = profile.selectedTask
        editorEngineOverride = profile.engineOverride
        // Validate cloudModelOverride against available plugin models
        if let modelOverride = profile.cloudModelOverride,
           let engineOverride = profile.engineOverride,
           let plugin = PluginManager.shared.transcriptionEngine(for: engineOverride) {
            let validIds = plugin.transcriptionModels.map(\.id)
            editorCloudModelOverride = validIds.contains(modelOverride) ? modelOverride : nil
        } else {
            editorCloudModelOverride = profile.cloudModelOverride
        }
        editorPromptActionId = profile.promptActionId
        editorMemoryEnabled = profile.memoryEnabled
        editorOutputFormat = profile.outputFormat
        editorInlineCommandsEnabled = profile.inlineCommandsEnabled
        editorAutoEnterEnabled = profile.autoEnterEnabled
        editorHotkey = profile.hotkey
        editorHotkeyLabel = profile.hotkey.map { HotkeyService.displayName(for: $0) } ?? ""
        editorPriority = profile.priority
        urlPatternInput = ""
        domainSuggestions = []
        editorDetectedAppName = nil
        editorDetectedBundleIdentifier = nil
        editorDetectedURL = nil
        editorDetectedDomain = nil
        editorDetectedIsSupportedBrowser = false
        showingWebsiteScope = !profile.urlPatterns.isEmpty
        editorPromptActionWasPrefilled = false
        loadAvailableDomains()
        refreshEditorContext()
        showingEditor = true
    }

    func toggleAppInEditor(_ bundleId: String) {
        if editorBundleIdentifiers.contains(bundleId) {
            editorBundleIdentifiers.removeAll { $0 == bundleId }
        } else {
            editorBundleIdentifiers.append(bundleId)
        }
    }

    func focusRules(usingPromptActionId promptActionId: String) {
        focusedPromptActionId = promptActionId
        showingEditor = false
    }

    func clearPromptRuleFocus() {
        focusedPromptActionId = nil
    }

    func promptAction(for profile: Profile) -> PromptAction? {
        guard let promptActionId = profile.promptActionId else { return nil }
        return availablePromptActions.first { $0.id.uuidString == promptActionId }
    }

    func editPrompt(for profile: Profile) {
        guard let promptAction = promptAction(for: profile) else { return }
        editPrompt(promptActionId: promptAction.id.uuidString)
    }

    func editPrompt(promptActionId: String) {
        guard let promptAction = availablePromptActions.first(where: { $0.id.uuidString == promptActionId }) else { return }
        PromptActionsViewModel.shared.startEditing(promptAction)
        SettingsNavigationCoordinator.shared.navigate(to: .prompts)
    }

    // MARK: - App Scanner

    func scanInstalledApps() {
        var apps: [String: InstalledApp] = [:]

        let directories = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]

        for dir in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleId = bundle.bundleIdentifier,
                      let name = bundle.infoDictionary?["CFBundleName"] as? String
                        ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? url.deletingPathExtension().lastPathComponent as String?
                else { continue }

                if apps[bundleId] == nil {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 24, height: 24)
                    apps[bundleId] = InstalledApp(id: bundleId, name: name, icon: icon)
                }
            }
        }

        installedApps = apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Domain Autocomplete

    func loadAvailableDomains() {
        availableDomains = historyService.uniqueDomains()
    }

    func filterDomainSuggestions() {
        let query = urlPatternInput.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            domainSuggestions = []
            return
        }
        domainSuggestions = availableDomains
            .filter { $0.lowercased().contains(query) && !editorUrlPatterns.contains($0) }
            .prefix(8)
            .map { $0 }
    }

    func addUrlPattern() {
        var input = urlPatternInput.trimmingCharacters(in: .whitespaces).lowercased()
        guard !input.isEmpty else { return }

        // Strip protocol and path
        if input.hasPrefix("https://") { input = String(input.dropFirst(8)) }
        if input.hasPrefix("http://") { input = String(input.dropFirst(7)) }
        if let slashIndex = input.firstIndex(of: "/") { input = String(input[..<slashIndex]) }
        if input.hasPrefix("www.") { input = String(input.dropFirst(4)) }

        guard !input.isEmpty, !editorUrlPatterns.contains(input) else {
            urlPatternInput = ""
            domainSuggestions = []
            return
        }

        editorUrlPatterns.append(input)
        showingWebsiteScope = true
        urlPatternInput = ""
        domainSuggestions = []
    }

    func selectDomainSuggestion(_ domain: String) {
        guard !editorUrlPatterns.contains(domain) else { return }
        editorUrlPatterns.append(domain)
        urlPatternInput = ""
        domainSuggestions = []
        showingWebsiteScope = true
    }

    func addDetectedDomainToEditor() {
        guard let domain = editorDetectedDomain, !editorUrlPatterns.contains(domain) else { return }
        editorUrlPatterns.append(domain)
        showingWebsiteScope = true
    }

    // MARK: - Helpers

    func appName(for bundleId: String) -> String {
        installedApps.first { $0.id == bundleId }?.name ?? bundleId
    }

    func ruleContextSummary(bundleIdentifiers: [String], urlPatterns: [String], hasManualOverride: Bool = false) -> String {
        let appNames = bundleIdentifiers.prefix(2).map(appName(for:))
        let domains = urlPatterns.prefix(2)
        let orSeparator = localizedAppOrSeparator()

        switch (!appNames.isEmpty, !domains.isEmpty) {
        case (true, true):
            return localizedAppText(
                "\(appNames.joined(separator: orSeparator)) is active and \(domains.joined(separator: orSeparator)) is detected",
                de: "\(appNames.joined(separator: orSeparator)) aktiv ist und \(domains.joined(separator: orSeparator)) erkannt wird"
            )
        case (true, false):
            return localizedAppText(
                "\(appNames.joined(separator: orSeparator)) is active",
                de: "\(appNames.joined(separator: orSeparator)) aktiv ist"
            )
        case (false, true):
            return localizedAppText(
                "\(domains.joined(separator: orSeparator)) is detected",
                de: "\(domains.joined(separator: orSeparator)) erkannt wird"
            )
        case (false, false):
            return hasManualOverride
                ? localizedAppText(
                    "no more specific rule matches or it is triggered manually",
                    de: "keine spezifischere Regel passt oder sie manuell ausgelöst wird"
                )
                : localizedAppText(
                    "no more specific rule matches",
                    de: "keine spezifischere Regel passt"
                )
        }
    }

    func ruleBehaviorSummary(
        inputLanguage: String?,
        translationEnabled: Bool?,
        translationTargetLanguage: String?,
        promptActionId: String?,
        engineOverride: String?,
        outputFormat: String?,
        inlineCommandsEnabled: Bool,
        autoEnterEnabled: Bool
    ) -> String {
        var parts: [String] = []

        if let promptActionId,
           let action = PromptActionsViewModel.shared.promptActions.first(where: { $0.id.uuidString == promptActionId }) {
            parts.append(localizedAppText("the prompt “\(action.name)”", de: "den Prompt „\(action.name)“"))
        }

        let languageSelection = LanguageSelection(storedValue: inputLanguage, nilBehavior: .inheritGlobal)
        switch languageSelection {
        case .inheritGlobal:
            break
        case .auto:
            parts.append(localizedAppText("with auto-detect", de: "mit automatischer Erkennung"))
        case .exact(let code):
            let languageName = localizedAppLanguageName(for: code)
            parts.append(localizedAppText("with \(languageName)", de: "mit \(languageName)"))
        case .hints(let codes):
            let languageList = localizedAppLanguageList(codes)
            parts.append(
                localizedAppText(
                    "with auto-detect between \(languageList)",
                    de: "mit automatischer Erkennung zwischen \(languageList)"
                )
            )
        }

        if translationEnabled == false {
            parts.append(localizedAppText("without translation", de: "ohne Übersetzung"))
        } else if let lang = translationTargetLanguage {
            let languageName = localizedAppLanguageName(for: lang)
            parts.append(localizedAppText("with translation to \(languageName)", de: "mit Übersetzung nach \(languageName)"))
        } else if translationEnabled == true {
            parts.append(localizedAppText("with translation", de: "mit Übersetzung"))
        }

        if let engine = engineOverride {
            let displayName = PluginManager.shared.transcriptionEngine(for: engine)?.providerDisplayName ?? engine
            parts.append(localizedAppText("via \(displayName)", de: "über \(displayName)"))
        }

        if let outputFormat {
            switch outputFormat {
            case "auto":
                parts.append(localizedAppText("with automatic formatting", de: "mit automatischem Format"))
            case "markdown":
                parts.append(localizedAppText("as Markdown", de: "als Markdown"))
            case "html":
                parts.append(localizedAppText("as HTML", de: "als HTML"))
            case "plaintext":
                parts.append(localizedAppText("as Plain Text", de: "als Plain Text"))
            case "code":
                parts.append(localizedAppText("as Code", de: "als Code"))
            default:
                parts.append(localizedAppText("with \(outputFormat)", de: "mit \(outputFormat)"))
            }
        }

        if inlineCommandsEnabled {
            parts.append(localizedAppText("with Inline Commands", de: "mit Inline Commands"))
        }

        if autoEnterEnabled {
            parts.append(localizedAppText("with Auto Enter", de: "mit Auto Enter"))
        }

        return parts.isEmpty
            ? localizedAppText("the global settings", de: "die globalen Einstellungen")
            : parts.prefix(3).joined(separator: ", ")
    }

    func ruleNarrative(for profile: Profile) -> String {
        localizedAppText(
            "When \(ruleContextSummary(bundleIdentifiers: profile.bundleIdentifiers, urlPatterns: profile.urlPatterns, hasManualOverride: profile.hotkey != nil)), TypeWhisper uses \(ruleBehaviorSummary(inputLanguage: profile.inputLanguage, translationEnabled: profile.translationEnabled, translationTargetLanguage: profile.translationTargetLanguage, promptActionId: profile.promptActionId, engineOverride: profile.engineOverride, outputFormat: profile.outputFormat, inlineCommandsEnabled: profile.inlineCommandsEnabled, autoEnterEnabled: profile.autoEnterEnabled)).",
            de: "Wenn \(ruleContextSummary(bundleIdentifiers: profile.bundleIdentifiers, urlPatterns: profile.urlPatterns, hasManualOverride: profile.hotkey != nil)), nutzt TypeWhisper \(ruleBehaviorSummary(inputLanguage: profile.inputLanguage, translationEnabled: profile.translationEnabled, translationTargetLanguage: profile.translationTargetLanguage, promptActionId: profile.promptActionId, engineOverride: profile.engineOverride, outputFormat: profile.outputFormat, inlineCommandsEnabled: profile.inlineCommandsEnabled, autoEnterEnabled: profile.autoEnterEnabled))."
        )
    }

    var editorRuleNarrative: String {
        localizedAppText(
            "When \(ruleContextSummary(bundleIdentifiers: editorBundleIdentifiers, urlPatterns: editorUrlPatterns, hasManualOverride: editorHotkey != nil)), TypeWhisper uses \(ruleBehaviorSummary(inputLanguage: editorInputLanguage, translationEnabled: editorTranslationEnabled, translationTargetLanguage: editorTranslationTargetLanguage, promptActionId: editorPromptActionId, engineOverride: editorEngineOverride, outputFormat: editorOutputFormat, inlineCommandsEnabled: editorInlineCommandsEnabled, autoEnterEnabled: editorAutoEnterEnabled)).",
            de: "Wenn \(ruleContextSummary(bundleIdentifiers: editorBundleIdentifiers, urlPatterns: editorUrlPatterns, hasManualOverride: editorHotkey != nil)), nutzt TypeWhisper \(ruleBehaviorSummary(inputLanguage: editorInputLanguage, translationEnabled: editorTranslationEnabled, translationTargetLanguage: editorTranslationTargetLanguage, promptActionId: editorPromptActionId, engineOverride: editorEngineOverride, outputFormat: editorOutputFormat, inlineCommandsEnabled: editorInlineCommandsEnabled, autoEnterEnabled: editorAutoEnterEnabled))."
        )
    }

    func matchingExplanation(bundleIdentifiers: [String], urlPatterns: [String], hasManualOverride: Bool) -> String {
        let hasApps = !bundleIdentifiers.isEmpty
        let hasDomains = !urlPatterns.isEmpty

        switch (hasApps, hasDomains) {
        case (true, true):
            var text = localizedAppText(
                "This rule is strongest when the app and website match at the same time. If multiple equally specific rules match, the higher priority wins.",
                de: "Diese Regel ist am stärksten, wenn App und Website gleichzeitig passen. Wenn mehrere gleich spezifische Regeln passen, gewinnt die höhere Priorität."
            )
            if hasManualOverride {
                text += localizedAppText(
                    " Manual override can force it at any time.",
                    de: " Mit manueller Übersteuerung kann sie jederzeit direkt erzwungen werden."
                )
            }
            return text
        case (false, true):
            var text = localizedAppText(
                "This rule applies across browsers based on the website. App + website is even more specific, and against other website rules the priority decides.",
                de: "Diese Regel greift browserübergreifend über die Website. App + Website ist noch spezifischer; gegen andere Website-Regeln entscheidet die Priorität."
            )
            if hasManualOverride {
                text += localizedAppText(
                    " Manual override can still force it at any time.",
                    de: " Mit manueller Übersteuerung kannst du sie trotzdem jederzeit direkt erzwingen."
                )
            }
            return text
        case (true, false):
            var text = localizedAppText(
                "This rule applies as soon as one of the selected apps is active. Website rules are more specific, and against other app rules the priority decides.",
                de: "Diese Regel greift, sobald eine der ausgewählten Apps aktiv ist. Website-Regeln sind spezifischer; gegen andere App-Regeln entscheidet die Priorität."
            )
            if hasManualOverride {
                text += localizedAppText(
                    " Manual override can still force it at any time.",
                    de: " Mit manueller Übersteuerung kannst du sie trotzdem jederzeit direkt erzwingen."
                )
            }
            return text
        case (false, false):
            var text = localizedAppText(
                "Without an app or website, this rule becomes the global fallback. It applies only when no more specific rule matches, and among other fallback rules the higher priority wins.",
                de: "Ohne App oder Website wird diese Regel zum globalen Fallback. Sie greift nur, wenn keine spezifischere Regel passt; unter mehreren Fallback-Regeln gewinnt die höhere Priorität."
            )
            if hasManualOverride {
                text += localizedAppText(
                    " Manual override can still force it at any time.",
                    de: " Mit manueller Übersteuerung kannst du sie trotzdem jederzeit direkt erzwingen."
                )
            }
            return text
        }
    }

    func matchingExplanation(for profile: Profile) -> String {
        matchingExplanation(
            bundleIdentifiers: profile.bundleIdentifiers,
            urlPatterns: profile.urlPatterns,
            hasManualOverride: profile.hotkey != nil
        )
    }

    var editorMatchingExplanation: String {
        matchingExplanation(
            bundleIdentifiers: editorBundleIdentifiers,
            urlPatterns: editorUrlPatterns,
            hasManualOverride: editorHotkey != nil
        )
    }

    func manualOverrideSummary(for profile: Profile) -> String {
        guard let hotkey = profile.hotkey else {
            return localizedAppText("No manual override", de: "Keine manuelle Übersteuerung")
        }
        return localizedAppText(
            "Manual override: \(HotkeyService.displayName(for: hotkey))",
            de: "Manuelle Übersteuerung: \(HotkeyService.displayName(for: hotkey))"
        )
    }

    var editorManualOverrideSummary: String {
        guard let editorHotkey else {
            return localizedAppText("No manual override", de: "Keine manuelle Übersteuerung")
        }
        return localizedAppText(
            "Manual override: \(HotkeyService.displayName(for: editorHotkey))",
            de: "Manuelle Übersteuerung: \(HotkeyService.displayName(for: editorHotkey))"
        )
    }

    var editorRelevantBrowserName: String? {
        if editorDetectedIsSupportedBrowser, let appName = editorDetectedAppName {
            return appName
        }

        guard let bundleId = firstSelectedBrowserBundleIdentifier else { return nil }
        return appName(for: bundleId)
    }

    var editorHasSelectedBrowser: Bool {
        firstSelectedBrowserBundleIdentifier != nil
    }

    private var firstSelectedBrowserBundleIdentifier: String? {
        editorBundleIdentifiers.first { bundleId in
            isSupportedBrowser(bundleIdentifier: bundleId, appName: appName(for: bundleId))
        }
    }

    private func refreshEditorContext() {
        let activeApp = ServiceContainer.shared.textInsertionService.captureActiveApp()
        editorDetectedAppName = activeApp.name
        editorDetectedBundleIdentifier = activeApp.bundleId
        editorDetectedURL = nil
        editorDetectedDomain = nil
        editorDetectedIsSupportedBrowser = isSupportedBrowser(bundleIdentifier: activeApp.bundleId, appName: activeApp.name)
        showingWebsiteScope = !editorUrlPatterns.isEmpty || editorDetectedIsSupportedBrowser || editorHasSelectedBrowser

        let bundleIdSnapshot = activeApp.bundleId

        guard let bundleId = bundleIdSnapshot else { return }

        Task { [weak self] in
            let resolvedURL = await ServiceContainer.shared.textInsertionService.resolveBrowserURL(bundleId: bundleId)

            await MainActor.run {
                guard let self else { return }
                guard self.editorDetectedBundleIdentifier == bundleIdSnapshot else { return }
                self.editorDetectedURL = resolvedURL
                self.editorDetectedDomain = self.normalizedDomain(from: resolvedURL)
            }
        }
    }

    private func normalizedDomain(from urlString: String?) -> String? {
        guard
            let urlString,
            let url = URL(string: urlString),
            let host = url.host?.lowercased()
        else {
            return nil
        }

        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }

        return host
    }

    private func isSupportedBrowser(bundleIdentifier: String?, appName: String?) -> Bool {
        let normalizedBundle = bundleIdentifier?.lowercased() ?? ""
        let normalizedName = appName?.lowercased() ?? ""

        let knownBundleFragments = [
            "com.apple.safari",
            "company.thebrowser.browser",
            "com.google.chrome",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "com.operasoftware.opera",
            "com.vivaldi.vivaldi",
            "org.chromium.chromium",
            "wavebox"
        ]

        if knownBundleFragments.contains(where: normalizedBundle.contains) {
            return true
        }

        let knownNames = [
            "safari",
            "arc",
            "chrome",
            "brave",
            "edge",
            "opera",
            "vivaldi",
            "chromium",
            "wave",
            "wavebox"
        ]

        return knownNames.contains(where: normalizedName.contains)
    }

    private func setupBindings() {
        profileService.$profiles
            .dropFirst()
            .sink { [weak self] profiles in
                DispatchQueue.main.async {
                    self?.profiles = profiles
                }
            }
            .store(in: &cancellables)

        // Reset cloud model override when engine changes
        $editorEngineOverride
            .dropFirst()
            .sink { [weak self] _ in
                self?.editorCloudModelOverride = nil
            }
            .store(in: &cancellables)

        $editorBundleIdentifiers
            .dropFirst()
            .sink { [weak self] bundleIdentifiers in
                guard let self else { return }
                let hasBrowserSelection = bundleIdentifiers.contains { bundleId in
                    self.isSupportedBrowser(bundleIdentifier: bundleId, appName: self.appName(for: bundleId))
                }
                if hasBrowserSelection {
                    self.showingWebsiteScope = true
                }
            }
            .store(in: &cancellables)
    }
}

private extension ProfilesViewModel {
    var availablePromptActions: [PromptAction] {
        PromptActionsViewModel._shared?.promptActions ?? []
    }
}
