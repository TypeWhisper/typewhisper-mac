import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "ProfileService")

enum RuleMatchKind: String, Sendable {
    case appAndWebsite
    case websiteOnly
    case appOnly
    case globalFallback
    case manualOverride

    var label: String {
        switch self {
        case .appAndWebsite:
            "App + Website"
        case .websiteOnly:
            "Nur Website"
        case .appOnly:
            "Nur App"
        case .globalFallback:
            "Globaler Fallback"
        case .manualOverride:
            "Manuell erzwungen"
        }
    }
}

struct RuleMatchResult {
    let profile: Profile
    let kind: RuleMatchKind
    let matchedDomain: String?
    let competingProfileCount: Int
    let wonByPriority: Bool
}

@MainActor
final class ProfileService: ObservableObject {
    @Published var profiles: [Profile] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        let schema = Schema([Profile.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("profiles.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Incompatible schema — delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("profiles.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create profiles ModelContainer after reset: \(error)")
            }
        }
        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = true

        fetchProfiles()
    }

    func addProfile(
        name: String,
        isEnabled: Bool = true,
        bundleIdentifiers: [String] = [],
        urlPatterns: [String] = [],
        inputLanguage: String? = nil,
        translationEnabled: Bool? = nil,
        translationTargetLanguage: String? = nil,
        selectedTask: String? = nil,
        engineOverride: String? = nil,
        cloudModelOverride: String? = nil,
        promptActionId: String? = nil,
        memoryEnabled: Bool = false,
        outputFormat: String? = nil,
        hotkeyData: Data? = nil,
        inlineCommandsEnabled: Bool = false,
        autoEnterEnabled: Bool = false,
        priority: Int = 0
    ) {
        let profile = Profile(
            name: name,
            isEnabled: isEnabled,
            priority: priority,
            bundleIdentifiers: bundleIdentifiers,
            urlPatterns: urlPatterns,
            inputLanguage: inputLanguage,
            translationEnabled: translationEnabled,
            translationTargetLanguage: translationTargetLanguage,
            selectedTask: selectedTask,
            engineOverride: engineOverride,
            cloudModelOverride: cloudModelOverride,
            promptActionId: promptActionId,
            memoryEnabled: memoryEnabled,
            outputFormat: outputFormat,
            hotkeyData: hotkeyData,
            inlineCommandsEnabled: inlineCommandsEnabled,
            autoEnterEnabled: autoEnterEnabled
        )
        modelContext.insert(profile)
        save()
        fetchProfiles()
    }

    func nextPriority() -> Int {
        (profiles.map(\.priority).max() ?? -1) + 1
    }

    func updateProfile(_ profile: Profile) {
        profile.updatedAt = Date()
        save()
        fetchProfiles()
    }

    func deleteProfile(_ profile: Profile) {
        modelContext.delete(profile)
        save()
        fetchProfiles()
    }

    func toggleProfile(_ profile: Profile) {
        profile.isEnabled.toggle()
        profile.updatedAt = Date()
        save()
        fetchProfiles()
    }

    func reorderProfiles(_ orderedProfiles: [Profile]) {
        let highestPriority = max(orderedProfiles.count - 1, 0)

        for (index, profile) in orderedProfiles.enumerated() {
            profile.priority = highestPriority - index
            profile.updatedAt = Date()
        }

        save()
        fetchProfiles()
    }

    func forcedRuleMatch(for profile: Profile) -> RuleMatchResult {
        RuleMatchResult(
            profile: profile,
            kind: .manualOverride,
            matchedDomain: nil,
            competingProfileCount: 0,
            wonByPriority: false
        )
    }

    func matchRule(bundleIdentifier: String?, url: String? = nil) -> RuleMatchResult? {
        let bundleId = bundleIdentifier ?? ""
        let domain = extractDomain(from: url)
        let enabled = profiles.filter { $0.isEnabled }

        if !bundleId.isEmpty, let domain {
            let matches = enabled.filter { profile in
                profile.bundleIdentifiers.contains(bundleId) &&
                profile.urlPatterns.contains { domainMatches(domain, pattern: $0) }
            }
            if let result = bestMatch(from: matches, kind: .appAndWebsite, matchedDomain: domain) {
                return result
            }
        }

        if let domain {
            let matches = enabled.filter { profile in
                !profile.urlPatterns.isEmpty &&
                profile.urlPatterns.contains { domainMatches(domain, pattern: $0) }
            }
            if let result = bestMatch(from: matches, kind: .websiteOnly, matchedDomain: domain) {
                return result
            }
        }

        if !bundleId.isEmpty {
            let matches = enabled.filter { $0.bundleIdentifiers.contains(bundleId) }
            if let result = bestMatch(from: matches, kind: .appOnly, matchedDomain: nil) {
                return result
            }
        }

        let fallbackMatches = enabled.filter {
            $0.bundleIdentifiers.isEmpty && $0.urlPatterns.isEmpty
        }
        if let result = bestMatch(from: fallbackMatches, kind: .globalFallback, matchedDomain: nil) {
            return result
        }

        return nil
    }

    func matchProfile(bundleIdentifier: String?, url: String? = nil) -> Profile? {
        matchRule(bundleIdentifier: bundleIdentifier, url: url)?.profile
    }

    /// Extracts a clean domain from a URL string, stripping "www." prefix.
    private func extractDomain(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Checks if a domain matches a pattern. Supports exact match and subdomain match.
    /// e.g. pattern "google.com" matches "google.com" and "docs.google.com"
    private func domainMatches(_ domain: String, pattern: String) -> Bool {
        let d = domain.lowercased()
        let p = pattern.lowercased()
        return d == p || d.hasSuffix("." + p)
    }

    private func bestMatch(from matches: [Profile], kind: RuleMatchKind, matchedDomain: String?) -> RuleMatchResult? {
        let sorted = matches.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        guard let best = sorted.first else { return nil }
        let secondPriority = sorted.dropFirst().first?.priority

        return RuleMatchResult(
            profile: best,
            kind: kind,
            matchedDomain: matchedDomain,
            competingProfileCount: max(sorted.count - 1, 0),
            wonByPriority: secondPriority.map { best.priority > $0 } ?? false
        )
    }

    private func fetchProfiles() {
        let descriptor = FetchDescriptor<Profile>(
            sortBy: [SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.name)]
        )
        do {
            profiles = try modelContext.fetch(descriptor)
        } catch {
            profiles = []
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }
}
