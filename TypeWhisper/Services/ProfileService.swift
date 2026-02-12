import Foundation
import SwiftData
import Combine

@MainActor
final class ProfileService: ObservableObject {
    @Published var profiles: [Profile] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init() {
        let schema = Schema([Profile.self])
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent("TypeWhisper", isDirectory: true)
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
        bundleIdentifiers: [String] = [],
        urlPatterns: [String] = [],
        outputLanguage: String? = nil,
        selectedTask: String? = nil,
        whisperModeOverride: Bool? = nil,
        engineOverride: String? = nil,
        priority: Int = 0
    ) {
        let profile = Profile(
            name: name,
            priority: priority,
            bundleIdentifiers: bundleIdentifiers,
            urlPatterns: urlPatterns,
            outputLanguage: outputLanguage,
            selectedTask: selectedTask,
            whisperModeOverride: whisperModeOverride,
            engineOverride: engineOverride
        )
        modelContext.insert(profile)
        save()
        fetchProfiles()
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

    func matchProfile(bundleIdentifier: String?) -> Profile? {
        guard let bundleId = bundleIdentifier, !bundleId.isEmpty else { return nil }
        return profiles
            .filter { $0.isEnabled && $0.bundleIdentifiers.contains(bundleId) }
            .sorted { $0.priority > $1.priority }
            .first
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
            print("ProfileService save error: \(error)")
        }
    }
}
