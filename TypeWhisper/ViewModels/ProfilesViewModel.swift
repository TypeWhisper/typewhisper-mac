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
    @Published var editorOutputLanguage: String?
    @Published var editorSelectedTask: String?
    @Published var editorWhisperModeOverride: Bool?
    @Published var editorEngineOverride: String?
    @Published var editorPriority: Int = 0

    // App picker
    @Published var showingAppPicker = false
    @Published var appSearchQuery = ""
    @Published var installedApps: [InstalledApp] = []

    private let profileService: ProfileService
    let settingsViewModel: SettingsViewModel
    private var cancellables = Set<AnyCancellable>()

    init(profileService: ProfileService, settingsViewModel: SettingsViewModel) {
        self.profileService = profileService
        self.settingsViewModel = settingsViewModel
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
            outputLanguage: editorOutputLanguage,
            selectedTask: editorSelectedTask,
            whisperModeOverride: editorWhisperModeOverride,
            engineOverride: editorEngineOverride,
            priority: editorPriority
        )
    }

    func saveProfile() {
        if let profile = editingProfile {
            profile.name = editorName
            profile.bundleIdentifiers = editorBundleIdentifiers
            profile.urlPatterns = editorUrlPatterns
            profile.outputLanguage = editorOutputLanguage
            profile.selectedTask = editorSelectedTask
            profile.whisperModeOverride = editorWhisperModeOverride
            profile.engineOverride = editorEngineOverride
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
        editorOutputLanguage = nil
        editorSelectedTask = nil
        editorWhisperModeOverride = nil
        editorEngineOverride = nil
        editorPriority = 0
        showingEditor = true
    }

    func prepareEditProfile(_ profile: Profile) {
        editingProfile = profile
        editorName = profile.name
        editorBundleIdentifiers = profile.bundleIdentifiers
        editorUrlPatterns = profile.urlPatterns
        editorOutputLanguage = profile.outputLanguage
        editorSelectedTask = profile.selectedTask
        editorWhisperModeOverride = profile.whisperModeOverride
        editorEngineOverride = profile.engineOverride
        editorPriority = profile.priority
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
        if let lang = profile.outputLanguage {
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            parts.append(name)
        }
        if let engine = profile.engineOverride, let type = EngineType(rawValue: engine) {
            parts.append(type.displayName)
        }
        return parts.joined(separator: " · ")
    }

    private func setupBindings() {
        profileService.$profiles
            .receive(on: DispatchQueue.main)
            .assign(to: &$profiles)
    }
}
