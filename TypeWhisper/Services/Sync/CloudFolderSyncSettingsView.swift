import AppKit
import Foundation
import SwiftUI

@MainActor
final class CloudFolderSyncController: ObservableObject {
    private enum Keys {
        static let folderBookmark = "cloudFolderSync.folderBookmark"
        static let syncState = "cloudFolderSync.syncState"
        static let legacyFolderBookmark = "plugin.com.typewhisper.cloud-folder-sync.folderBookmark"
        static let legacySyncState = "plugin.com.typewhisper.cloud-folder-sync.syncState"
    }

    private let licenseService: LicenseService
    private let syncStore: TypeWhisperUserDataSyncStore
    private let defaults: UserDefaults
    private var state: CloudFolderSyncState
    private var localChangeObserverId: UUID?
    private var scheduledSyncTask: Task<Void, Never>?

    @Published private(set) var selectedFolderURL: URL?
    @Published private(set) var provider: CloudFolderSyncProvider = .custom
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var pendingChanges = 0
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    var canUseSync: Bool {
        licenseService.hasCommercialLicense
    }

    var selectedFolderDisplayName: String {
        selectedFolderURL?.path(percentEncoded: false) ?? String(localized: "No folder selected")
    }

    init(
        licenseService: LicenseService,
        syncStore: TypeWhisperUserDataSyncStore,
        defaults: UserDefaults = .standard
    ) {
        self.licenseService = licenseService
        self.syncStore = syncStore
        self.defaults = defaults
        self.state = Self.loadState(from: defaults)
        self.lastSyncDate = state.lastSyncAt

        restoreSelectedFolder()
        installLocalChangeObserver()
    }

    deinit {
        scheduledSyncTask?.cancel()
    }

    func deactivate() {
        scheduledSyncTask?.cancel()
        if let localChangeObserverId {
            syncStore.removeLocalChangeObserver(localChangeObserverId)
            self.localChangeObserverId = nil
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a cloud-synced folder for TypeWhisper.")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
        Task { await syncNow() }
    }

    func clearFolder() {
        selectedFolderURL = nil
        provider = .custom
        removeDefault(forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
        pendingChanges = 0
        statusMessage = nil
        errorMessage = nil
    }

    func syncNow() async {
        guard let selectedFolderURL else {
            errorMessage = String(localized: "Choose a sync folder first.")
            return
        }
        guard canUseSync else {
            errorMessage = CloudFolderSyncError.notEntitled.localizedDescription
            return
        }
        guard !isSyncing else { return }

        errorMessage = nil
        isSyncing = true
        let accessed = selectedFolderURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                selectedFolderURL.stopAccessingSecurityScopedResource()
            }
            isSyncing = false
        }

        do {
            var syncState = state
            let result = try await CloudFolderSyncEngine.sync(
                folderURL: selectedFolderURL,
                store: syncStore,
                state: &syncState,
                entitlements: PaidEntitlements(canUseCloudFolderSync: canUseSync)
            )
            state = syncState
            saveState()
            lastSyncDate = result.syncedAt
            pendingChanges = 0
            statusMessage = String(localized: "Synced \(result.operationsRead) changes.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setFolder(_ url: URL) {
        selectedFolderURL = url
        provider = CloudFolderSyncProvider.detect(folderURL: url)
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            saveDefault(bookmark, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreSelectedFolder() {
        guard let data = migratedData(forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark) else { return }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            selectedFolderURL = url
            provider = CloudFolderSyncProvider.detect(folderURL: url)
            if isStale {
                setFolder(url)
            } else if defaults.object(forKey: Keys.folderBookmark) == nil {
                saveDefault(data, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installLocalChangeObserver() {
        localChangeObserverId = syncStore.observeLocalChanges { [weak self] in
            self?.scheduleSyncAfterLocalChange()
        }
    }

    private func scheduleSyncAfterLocalChange() {
        guard selectedFolderURL != nil, canUseSync else { return }
        pendingChanges += 1
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.syncNow()
        }
    }

    private func saveState() {
        guard let data = try? Self.encoder.encode(state) else { return }
        saveDefault(data, forKey: Keys.syncState, legacyKey: Keys.legacySyncState)
    }

    private func migratedData(forKey key: String, legacyKey: String) -> Data? {
        if let data = defaults.data(forKey: key) {
            return data
        }
        return defaults.data(forKey: legacyKey)
    }

    private func saveDefault(_ value: Any, forKey key: String, legacyKey: String) {
        defaults.set(value, forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private func removeDefault(forKey key: String, legacyKey: String) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    private static func loadState(from defaults: UserDefaults) -> CloudFolderSyncState {
        let data = defaults.data(forKey: Keys.syncState) ?? defaults.data(forKey: Keys.legacySyncState)
        guard let data,
              let state = try? decoder.decode(CloudFolderSyncState.self, from: data) else {
            return CloudFolderSyncState()
        }
        return state
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct CloudFolderSyncSettingsView: View {
    @ObservedObject var controller: CloudFolderSyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !controller.canUseSync {
                lockedPanel
            }

            VStack(alignment: .leading, spacing: 10) {
                statusRow(title: String(localized: "Provider"), value: controller.provider.displayName, systemImage: "cloud")
                statusRow(title: String(localized: "Folder"), value: controller.selectedFolderDisplayName, systemImage: "folder")
                statusRow(title: String(localized: "Last Sync"), value: lastSyncText, systemImage: "clock")
                statusRow(title: String(localized: "Pending"), value: "\(controller.pendingChanges)", systemImage: "arrow.triangle.2.circlepath")
            }

            HStack(spacing: 8) {
                Button {
                    controller.chooseFolder()
                } label: {
                    Label(String(localized: "Choose Folder"), systemImage: "folder.badge.plus")
                }

                Button {
                    Task { await controller.syncNow() }
                } label: {
                    if controller.isSyncing {
                        Label(String(localized: "Syncing"), systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label(String(localized: "Sync Now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(!controller.canUseSync || controller.selectedFolderURL == nil || controller.isSyncing)

                Button {
                    controller.clearFolder()
                } label: {
                    Label(String(localized: "Clear"), systemImage: "xmark.circle")
                }
                .disabled(controller.selectedFolderURL == nil)
            }

            if let status = controller.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.07)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Cloud Folder Sync"))
                    .font(.headline)
                Text(String(localized: "Dictionary and snippets"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lockedPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.yellow)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Commercial license required"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "Activate or buy a license to start writing sync files."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                SettingsNavigationCoordinator.shared.navigateToLicense(target: .activationKey)
            } label: {
                Label(String(localized: "Open License"), systemImage: "key")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.yellow.opacity(0.08)))
    }

    private func statusRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private var lastSyncText: String {
        guard let date = controller.lastSyncDate else {
            return String(localized: "Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
