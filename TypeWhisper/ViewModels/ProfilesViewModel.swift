import Foundation
import Combine
import AppKit

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

    // Editor state
    @Published var showingEditor = false
    @Published var editingProfile: Profile?
    @Published var editorName = ""
    @Published var editorBundleIdentifiers: [String] = []
    @Published var editorUrlPatterns: [String] = []
    @Published var editorInputLanguage: String?
    @Published var editorTranslationTargetLanguage: String?
    @Published var editorSelectedTask: String?
    @Published var editorWhisperModeOverride: Bool?
    @Published var editorEngineOverride: String?
    @Published var editorCloudModelOverride: String?
    @Published var editorPromptActionId: String?
    @Published var editorAutoSubmitEnabled: Bool?
    @Published var editorPriority: Int = 0

    // App picker
    @Published var showingAppPicker = false
    @Published var appSearchQuery = ""
    @Published var installedApps: [InstalledApp] = []

    // Domain autocomplete
    @Published var urlPatternInput = ""
    @Published var domainSuggestions: [String] = []
    var availableDomains: [String] = []

    private let profileService: ProfileService
    private let historyService: HistoryService
    let settingsViewModel: SettingsViewModel
    private var cancellables = Set<AnyCancellable>()

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

    // MARK: - CRUD

    func addProfile() {
        profileService.addProfile(
            name: editorName,
            bundleIdentifiers: editorBundleIdentifiers,
            urlPatterns: editorUrlPatterns,
            inputLanguage: editorInputLanguage,
            translationTargetLanguage: editorTranslationTargetLanguage,
            selectedTask: editorSelectedTask,
            whisperModeOverride: editorWhisperModeOverride,
            engineOverride: editorEngineOverride,
            cloudModelOverride: editorCloudModelOverride,
            promptActionId: editorPromptActionId,
            autoSubmitEnabled: editorAutoSubmitEnabled,
            priority: editorPriority
        )
    }

    func saveProfile() {
        if let profile = editingProfile {
            profile.name = editorName
            profile.bundleIdentifiers = editorBundleIdentifiers
            profile.urlPatterns = editorUrlPatterns
            profile.inputLanguage = editorInputLanguage
            profile.translationTargetLanguage = editorTranslationTargetLanguage
            profile.selectedTask = editorSelectedTask
            profile.whisperModeOverride = editorWhisperModeOverride
            profile.engineOverride = editorEngineOverride
            profile.cloudModelOverride = editorCloudModelOverride
            profile.promptActionId = editorPromptActionId
            profile.autoSubmitEnabled = editorAutoSubmitEnabled
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

    func toggleProfile(_ profile: Profile) {
        profileService.toggleProfile(profile)
    }

    // MARK: - Editor

    func prepareNewProfile() {
        editingProfile = nil
        editorName = ""
        editorBundleIdentifiers = []
        editorUrlPatterns = []
        editorInputLanguage = nil
        editorTranslationTargetLanguage = nil
        editorSelectedTask = nil
        editorWhisperModeOverride = nil
        editorEngineOverride = nil
        editorCloudModelOverride = nil
        editorPromptActionId = nil
        editorAutoSubmitEnabled = nil
        editorPriority = 0
        urlPatternInput = ""
        domainSuggestions = []
        loadAvailableDomains()
        showingEditor = true
    }

    func prepareEditProfile(_ profile: Profile) {
        editingProfile = profile
        editorName = profile.name
        editorBundleIdentifiers = profile.bundleIdentifiers
        editorUrlPatterns = profile.urlPatterns
        editorInputLanguage = profile.inputLanguage
        editorTranslationTargetLanguage = profile.translationTargetLanguage
        editorSelectedTask = profile.selectedTask
        editorWhisperModeOverride = profile.whisperModeOverride
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
        editorAutoSubmitEnabled = profile.autoSubmitEnabled
        editorPriority = profile.priority
        urlPatternInput = ""
        domainSuggestions = []
        loadAvailableDomains()
        showingEditor = true
    }

    func toggleAppInEditor(_ bundleId: String) {
        if editorBundleIdentifiers.contains(bundleId) {
            editorBundleIdentifiers.removeAll { $0 == bundleId }
        } else {
            editorBundleIdentifiers.append(bundleId)
        }
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
        urlPatternInput = ""
        domainSuggestions = []
    }

    func selectDomainSuggestion(_ domain: String) {
        guard !editorUrlPatterns.contains(domain) else { return }
        editorUrlPatterns.append(domain)
        urlPatternInput = ""
        domainSuggestions = []
    }

    // MARK: - Helpers

    func appName(for bundleId: String) -> String {
        installedApps.first { $0.id == bundleId }?.name ?? bundleId
    }

    func profileSubtitle(_ profile: Profile) -> String {
        var parts: [String] = []
        let appNames = profile.bundleIdentifiers.prefix(3).map { appName(for: $0) }
        if !appNames.isEmpty {
            parts.append(appNames.joined(separator: ", "))
            if profile.bundleIdentifiers.count > 3 {
                parts[parts.count - 1] += " +\(profile.bundleIdentifiers.count - 3)"
            }
        }
        if !profile.urlPatterns.isEmpty {
            let domains = profile.urlPatterns.prefix(2).joined(separator: ", ")
            let suffix = profile.urlPatterns.count > 2 ? " +\(profile.urlPatterns.count - 2)" : ""
            parts.append(domains + suffix)
        }
        if let lang = profile.inputLanguage {
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            parts.append(name)
        }
        if let lang = profile.translationTargetLanguage {
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            parts.append("→ " + name)
        }
        if let engine = profile.engineOverride, let type = EngineType(rawValue: engine) {
            parts.append(type.displayName)
        }
        return parts.joined(separator: " · ")
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
    }
}
