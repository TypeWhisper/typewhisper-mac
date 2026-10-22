import AppKit
import Combine
import Foundation
import SwiftUI

enum PremiumSyncMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case automaticICloud
    case cloudFolder

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: String(localized: "premium.window.sync.mode.off")
        case .automaticICloud: String(localized: "premium.window.sync.mode.automaticICloud")
        case .cloudFolder: String(localized: "premium.window.sync.mode.cloudFolder")
        }
    }
}

private enum TypeWhisperBuildCapabilities {
    static var iCloudSyncEnabled: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "TypeWhisperICloudEnabled") as? String else {
            return true
        }
        return !["no", "false", "0"].contains(value.lowercased())
    }
}

@MainActor
final class CloudFolderSyncController: ObservableObject {
    private enum Keys {
        static let mode = "premiumSync.mode"
        static let automaticSyncState = "premiumSync.iCloudState"
        static let folderBookmark = "cloudFolderSync.folderBookmark"
        static let syncState = "cloudFolderSync.syncState"
        static let legacyFolderBookmark = "plugin.com.typewhisper.cloud-folder-sync.folderBookmark"
        static let legacySyncState = "plugin.com.typewhisper.cloud-folder-sync.syncState"
    }

    private let syncStore: any UserDataSyncStore
    private let defaults: UserDefaults
    private let automaticICloudBridge: any PremiumICloudBridging
    private let automaticICloudAvailableOverride: Bool?
    private var automaticICloudAvailable: Bool {
        automaticICloudAvailableOverride
            ?? (TypeWhisperBuildCapabilities.iCloudSyncEnabled && automaticICloudBridge.isAvailable)
    }
    #if APPSTORE
    private var ubiquityIdentityObserver: NSObjectProtocol?
    #endif
    private let historyService: HistoryService?
    let historySyncPreferences: HistorySyncPreferences?
    private var customState: CloudFolderSyncState
    private var automaticState: CloudFolderSyncState
    private var localChangeObserverId: UUID?
    private var scheduledSyncTask: Task<Void, Never>?
    private var automaticPollTask: Task<Void, Never>?
    private var needsResync = false
    private var needsChangeCheck = false
    private var isCheckingForChanges = false
    private var isInstallingSynchronizedAudio = false
    private var hasPendingLocalChanges = false
    private var synchronizedPackage: (
        mode: PremiumSyncMode,
        folderURL: URL,
        fingerprint: CloudFolderSyncPackageFingerprint?
    )?
    private let syncCache = CloudFolderSyncCache()
    private(set) var initialSyncTask: Task<Void, Never>?

    private static let automaticPollInterval: Duration = .seconds(30)

    @Published private(set) var mode: PremiumSyncMode
    @Published private(set) var selectedFolderURL: URL?
    @Published private(set) var provider: CloudFolderSyncProvider = .custom
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var pendingChanges = 0
    @Published private(set) var deviceCount = 0
    @Published private(set) var devices: [CloudFolderSyncDeviceRecord] = []
    @Published private(set) var isSyncing = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    var availableModes: [PremiumSyncMode] {
        #if APPSTORE
        // Keep a chosen automatic iCloud sync selectable while iCloud is signed out.
        automaticICloudAvailable || mode == .automaticICloud
            ? PremiumSyncMode.allCases : [.off, .cloudFolder]
        #else
        automaticICloudAvailable ? PremiumSyncMode.allCases : [.off, .cloudFolder]
        #endif
    }

    var selectedFolderDisplayName: String {
        switch mode {
        case .automaticICloud: String(localized: "premium.window.sync.privateICloudContainer")
        case .cloudFolder: selectedFolderURL?.path(percentEncoded: false)
            ?? String(localized: "premium.window.sync.noFolderSelected")
        case .off: String(localized: "premium.window.sync.syncOff")
        }
    }

    var isConfigured: Bool { mode == .automaticICloud || (mode == .cloudFolder && selectedFolderURL != nil) }

    init(
        syncStore: any UserDataSyncStore,
        historyService: HistoryService? = nil,
        historySyncPreferences: HistorySyncPreferences? = nil,
        defaults: UserDefaults = .standard,
        automaticICloudBridge: any PremiumICloudBridging = PremiumICloudBridgeFactory.makeDefault(),
        automaticICloudAvailable: Bool? = nil
    ) {
        self.syncStore = syncStore
        self.historyService = historyService
        self.historySyncPreferences = historySyncPreferences
        self.defaults = defaults
        self.automaticICloudBridge = automaticICloudBridge
        self.automaticICloudAvailableOverride = automaticICloudAvailable
        #if !APPSTORE
        let isAutomaticICloudAvailable = automaticICloudAvailable
            ?? (TypeWhisperBuildCapabilities.iCloudSyncEnabled && automaticICloudBridge.isAvailable)
        #endif
        self.customState = Self.loadState(from: defaults, key: Keys.syncState, legacyKey: Keys.legacySyncState)
        self.automaticState = Self.loadState(from: defaults, key: Keys.automaticSyncState)
        let storedMode = defaults.string(forKey: Keys.mode).flatMap(PremiumSyncMode.init(rawValue:))
        let requestedMode = AppConstants.isPremiumSyncSmokeTest
            ? PremiumSyncMode.automaticICloud
            : storedMode ?? (defaults.data(forKey: Keys.folderBookmark) != nil ? .cloudFolder : .off)
        #if APPSTORE
        // iCloud can be signed out only temporarily; syncs report it until it returns.
        self.mode = requestedMode
        #else
        self.mode = requestedMode == .automaticICloud && !isAutomaticICloudAvailable ? .off : requestedMode
        #endif
        self.lastSyncDate = mode == .automaticICloud ? automaticState.lastSyncAt : customState.lastSyncAt

        restoreSelectedFolder()
        if mode == .automaticICloud { provider = .iCloudDrive }
        installLocalChangeObserver()
        updateICloudObservation()
        #if APPSTORE
        // Offer automatic iCloud once the user signs in to iCloud while TypeWhisper runs,
        // and resume a chosen automatic iCloud sync.
        ubiquityIdentityObserver = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUbiquityIdentityChange() }
        }
        #endif
        if isConfigured {
            initialSyncTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.isConfigured else { return }
                await self.syncIfNeeded()
            }
        }
    }

    deinit {
        scheduledSyncTask?.cancel()
        automaticPollTask?.cancel()
    }

    func deactivate() {
        scheduledSyncTask?.cancel()
        if let localChangeObserverId {
            syncStore.removeLocalChangeObserver(localChangeObserverId)
            self.localChangeObserverId = nil
        }
        stopICloudObservation()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose a cloud-synced folder for dictum.")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await selectCustomFolder(url) }
    }

    func setMode(_ newMode: PremiumSyncMode) async {
        guard automaticICloudAvailable || newMode != .automaticICloud else { return }
        guard newMode != mode, !isSyncing else { return }
        if isConfigured { await syncNow() }
        guard !isSyncing else { return }
        mode = newMode
        if newMode == .automaticICloud { provider = .iCloudDrive }
        if newMode == .cloudFolder, let selectedFolderURL {
            provider = CloudFolderSyncProvider.detect(folderURL: selectedFolderURL)
        }
        defaults.set(newMode.rawValue, forKey: Keys.mode)
        pendingChanges = 0
        statusMessage = nil
        errorMessage = nil
        updateICloudObservation()
        lastSyncDate = state(for: newMode)?.lastSyncAt
        if isConfigured { await syncNow() }
    }

    func setHistorySyncEnabled(_ enabled: Bool) async {
        guard let historySyncPreferences,
              historySyncPreferences.isEnabled != enabled else { return }
        historySyncPreferences.isEnabled = enabled
        objectWillChange.send()
        if enabled, isConfigured {
            await syncNow()
        }
    }

    func setHistoryAudioSyncEnabled(_ enabled: Bool) {
        historySyncPreferences?.isAudioEnabled = enabled
        // The next automatic check installs audio that is now allowed to arrive.
        if enabled { hasPendingLocalChanges = true }
        objectWillChange.send()
    }

    func clearFolder() {
        guard !isSyncing else { return }
        scheduledSyncTask?.cancel()
        selectedFolderURL = nil
        provider = .custom
        resetCustomSyncState()
        removeDefault(forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
        pendingChanges = 0
        devices = []
        deviceCount = 0
        statusMessage = nil
        errorMessage = nil
        if mode == .cloudFolder {
            mode = .off
            defaults.set(mode.rawValue, forKey: Keys.mode)
        }
    }

    /// True for this Mac's record, including an older record of the same
    /// installation that still carries its history origin.
    func isCurrentDevice(_ device: CloudFolderSyncDeviceRecord) -> Bool {
        let state = mode == .automaticICloud ? automaticState : customState
        if device.deviceId == state.deviceId { return true }
        guard let origin = device.historyOriginDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !origin.isEmpty else {
            return false
        }
        return origin == historySyncPreferences?.deviceID
    }

    /// Removes another device from the sync list. Its synced entries stay, and
    /// it appears again when it syncs.
    func removeDevice(_ device: CloudFolderSyncDeviceRecord) async {
        guard mode != .off, !isSyncing, !isCurrentDevice(device),
              let folderURL = activeFolderURL() else {
            return
        }
        let removalMode = mode
        isSyncing = true
        errorMessage = nil
        defer { finishSyncWork() }
        do {
            if removalMode == .automaticICloud {
                try await automaticICloudBridge.removeDevice(device.deviceId)
            } else {
                let accessed = folderURL.startAccessingSecurityScopedResource()
                defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
                let deviceID = device.deviceId
                try await Task.detached(priority: .utility) {
                    try PremiumSyncDeviceRemoval.removeRecords(
                        of: deviceID,
                        inPackages: [CloudFolderSyncEngine.packageURL(for: folderURL)]
                    )
                }.value
            }
            let remaining = await Task.detached(priority: .utility) {
                CloudFolderSyncEngine.devices(folderURL: folderURL)
            }.value
            guard mode == removalMode else { return }
            devices = remaining ?? devices.filter { $0.deviceId != device.deviceId }
            deviceCount = devices.count
            statusMessage = String(localized: "Device removed from the sync list. Synced data was kept.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ends a sync or a device removal and runs what was requested meanwhile:
    /// local edits and folder changes only set a flag while one is running.
    private func finishSyncWork() {
        isSyncing = false
        if needsResync {
            needsResync = false
            needsChangeCheck = false
            Task { @MainActor [weak self] in
                await self?.syncNow()
            }
        } else if needsChangeCheck {
            needsChangeCheck = false
            Task { @MainActor [weak self] in
                await self?.syncIfNeeded()
            }
        }
    }

    func syncNow() async {
        if AppConstants.isScreenshotAutomation {
            isSyncing = false
            return
        }

        let syncMode = mode
        guard syncMode != .off else { return }
        guard let folderURL = activeFolderURL(for: syncMode) else { return }
        guard !isSyncing else {
            needsResync = true
            return
        }

        errorMessage = nil
        isSyncing = true
        hasPendingLocalChanges = false
        synchronizedPackage = nil
        let accessed = syncMode == .cloudFolder && folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                folderURL.stopAccessingSecurityScopedResource()
            }
            finishSyncWork()
        }

        do {
            if syncMode == .automaticICloud {
                try await automaticICloudBridge.synchronize()
            }
            var syncState = state(for: syncMode) ?? CloudFolderSyncState()
            let result = try await CloudFolderSyncEngine.sync(
                folderURL: folderURL,
                store: syncStore,
                state: &syncState,
                historyOriginDeviceID: historySyncPreferences?.deviceID,
                cache: syncCache
            )
            setState(syncState, for: syncMode)
            if syncMode == .automaticICloud {
                try await automaticICloudBridge.synchronize()
            }
            let audioDiagnostics = await installPendingSynchronizedAudio(in: folderURL)
            guard mode == syncMode else { return }
            let diagnostics = result.diagnostics + audioDiagnostics
            // Later checks only skip an unchanged package when nothing is left to retry. Files
            // that become readable or finish downloading often keep their size and date, and a
            // requested republish does not change the package either.
            if !result.requiresFollowUpSync, !diagnostics.contains(where: \.isTransient) {
                synchronizedPackage = (syncMode, folderURL, result.packageFingerprint)
            }
            lastSyncDate = result.syncedAt
            pendingChanges = 0
            devices = result.devices
            deviceCount = devices.count
            let synchronizedChanges = result.operationsWritten + result.mutationsApplied
            if diagnostics.isEmpty {
                statusMessage = String.localizedStringWithFormat(
                    String(localized: "Synced %lld changes."), Int64(synchronizedChanges)
                )
            } else {
                statusMessage = String.localizedStringWithFormat(
                    String(localized: "Synced %lld changes; skipped %lld invalid files."),
                    Int64(synchronizedChanges), Int64(diagnostics.count)
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectCustomFolder(_ url: URL) async {
        guard !isSyncing else { return }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if isConfigured { await syncNow() }
        guard !isSyncing else { return }
        if selectedFolderURL != url {
            scheduledSyncTask?.cancel()
            resetCustomSyncState()
            pendingChanges = 0
            statusMessage = nil
            errorMessage = nil
        }
        selectedFolderURL = url
        mode = .cloudFolder
        defaults.set(mode.rawValue, forKey: Keys.mode)
        provider = CloudFolderSyncProvider.detect(folderURL: url)
        saveDefault(bookmark, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
        await syncNow()
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
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                saveDefault(bookmark, forKey: Keys.folderBookmark, legacyKey: Keys.legacyFolderBookmark)
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
        // Installing received audio only records the local file name, which is not synced.
        guard !isInstallingSynchronizedAudio else { return }
        hasPendingLocalChanges = true
        guard isConfigured else { return }
        pendingChanges += 1
        if isSyncing {
            needsResync = true
            return
        }
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
                try Task.checkCancellation()
                await self?.syncNow()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    #if APPSTORE
    private func handleUbiquityIdentityChange() {
        objectWillChange.send()
        updateICloudObservation()
        guard mode == .automaticICloud, automaticICloudAvailable else { return }
        errorMessage = nil
        Task { await syncNow() }
    }
    #endif

    private func updateICloudObservation() {
        stopICloudObservation()
        guard mode == .automaticICloud, automaticICloudBridge.isAvailable else { return }
        automaticPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.automaticPollInterval)
                    try Task.checkCancellation()
                    guard let self else { return }
                    await self.automaticPollTick()
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
            }
        }
    }

    /// Checks for remote changes; a full sync only runs when the package or local data changed.
    func automaticPollTick() async {
        guard mode == .automaticICloud, !isSyncing else { return }
        await syncIfNeeded()
    }

    func handleApplicationDidBecomeActive() async {
        await syncIfNeeded()
    }

    /// Runs a full sync only when local edits are pending or the sync package changed since
    /// the last completed sync; otherwise only mirrors iCloud and lists the package.
    /// Returns false when the check found nothing to synchronize.
    @discardableResult
    func syncIfNeeded() async -> Bool {
        let syncMode = mode
        guard syncMode != .off else { return false }
        guard !isSyncing else {
            needsChangeCheck = true
            return true
        }
        guard !isCheckingForChanges else { return true }
        guard !hasPendingLocalChanges,
              let synchronizedPackage,
              synchronizedPackage.mode == syncMode,
              let folderURL = activeFolderURL(for: syncMode),
              synchronizedPackage.folderURL == folderURL else {
            await syncNow()
            return true
        }

        isCheckingForChanges = true
        defer { isCheckingForChanges = false }
        if syncMode == .automaticICloud {
            do {
                try await automaticICloudBridge.synchronize()
            } catch {
                // Let a full sync report the bridge failure, as the unconditional poll did.
                await syncNow()
                return true
            }
        }
        let accessed = syncMode == .cloudFolder && folderURL.startAccessingSecurityScopedResource()
        // Device files are rewritten in place by every sync of their device, so they are read
        // directly instead of being part of the fingerprint.
        let (fingerprint, packageDevices) = await Task.detached(priority: .utility) {
            (
                CloudFolderSyncEngine.packageFingerprint(folderURL: folderURL),
                CloudFolderSyncEngine.devices(folderURL: folderURL)
            )
        }.value
        if accessed {
            folderURL.stopAccessingSecurityScopedResource()
        }
        guard mode == syncMode else { return true }
        guard !isSyncing else {
            // A sync started meanwhile; compare again once it has recorded its package state.
            needsChangeCheck = true
            return true
        }
        guard !hasPendingLocalChanges,
              fingerprint != nil,
              fingerprint == self.synchronizedPackage?.fingerprint else {
            await syncNow()
            return true
        }
        // Speaker components held back at the last sync are released once every
        // recent device reads them: after an update, or when an old device has
        // not synced for long enough.
        let state = syncMode == .automaticICloud ? automaticState : customState
        let now = Date()
        let releasesSpeakerComponents = !CloudFolderSyncEngine.speakerComponentsCanBeWritten(
            devices: devices, ownDeviceId: state.deviceId, now: lastSyncDate ?? now
        ) && CloudFolderSyncEngine.speakerComponentsCanBeWritten(
            devices: packageDevices ?? devices, ownDeviceId: state.deviceId, now: now
        )
        if let packageDevices, packageDevices != devices {
            devices = packageDevices
            deviceCount = packageDevices.count
        }
        if releasesSpeakerComponents {
            await syncNow()
            return true
        }
        return false
    }

    private func stopICloudObservation() {
        automaticPollTask?.cancel()
        automaticPollTask = nil
    }

    private func resetCustomSyncState() {
        synchronizedPackage = nil
        customState = CloudFolderSyncState()
        lastSyncDate = nil
        removeDefault(forKey: Keys.syncState, legacyKey: Keys.legacySyncState)
    }

    private func saveState(_ state: CloudFolderSyncState, key: String, legacyKey: String? = nil) {
        guard let data = try? Self.encoder.encode(state) else { return }
        defaults.set(data, forKey: key)
        if let legacyKey { defaults.removeObject(forKey: legacyKey) }
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

    private static func loadState(from defaults: UserDefaults, key: String, legacyKey: String? = nil) -> CloudFolderSyncState {
        let data = defaults.data(forKey: key) ?? legacyKey.flatMap(defaults.data(forKey:))
        guard let data,
              let state = try? decoder.decode(CloudFolderSyncState.self, from: data) else {
            return CloudFolderSyncState()
        }
        return state
    }

    private func state(for mode: PremiumSyncMode) -> CloudFolderSyncState? {
        switch mode {
        case .off: nil
        case .automaticICloud: automaticState
        case .cloudFolder: customState
        }
    }

    private func setState(_ state: CloudFolderSyncState, for mode: PremiumSyncMode) {
        switch mode {
        case .off: return
        case .automaticICloud:
            automaticState = state
            saveState(state, key: Keys.automaticSyncState)
        case .cloudFolder:
            customState = state
            saveState(state, key: Keys.syncState, legacyKey: Keys.legacySyncState)
        }
    }

    private func activeFolderURL(for mode: PremiumSyncMode? = nil) -> URL? {
        switch mode ?? self.mode {
        case .off: return nil
        case .cloudFolder:
            guard let selectedFolderURL else {
                errorMessage = String(localized: "Choose a sync folder first.")
                return nil
            }
            return selectedFolderURL
        case .automaticICloud:
            guard let folderURL = automaticICloudBridge.localFolderURL else {
                errorMessage = PremiumICloudBridgeError.appGroupUnavailable.localizedDescription
                return nil
            }
            return folderURL
        }
    }

    func canRetrieveHistoryAudio(_ record: TranscriptionRecord) -> Bool {
        guard mode != .off,
              historySyncPreferences?.isEnabled == true,
              historySyncPreferences?.isAudioEnabled == true,
              let descriptor = historyService?.synchronizedAudioDescriptor(for: record),
              historySyncPreferences?.shouldReceiveSynchronizedAudio(createdAt: descriptor.createdAt) == true else {
            return false
        }
        return descriptor.isValid
    }

    /// Called only after explicit download consent. Uses the verified sync asset directly,
    /// so cancellation or a provider error does not install audio or modify the record.
    func retrieveHistoryAudio(_ record: TranscriptionRecord) async throws -> URL {
        guard canRetrieveHistoryAudio(record), let folder = activeFolderURL(),
              let descriptor = historyService?.synchronizedAudioDescriptor(for: record) else {
            throw HistoryRetranscriptionError.audioMissing
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let package = CloudFolderSyncEngine.packageURL(for: folder)
        let source = try await HistorySyncAssetStore.verifiedAssetURL(packageURL: package, descriptor: descriptor)
        try Task.checkCancellation()
        guard canRetrieveHistoryAudio(record) else { throw HistoryRetranscriptionError.audioMissing }
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-comparison-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    func installPendingSynchronizedAudio(
        in folderURL: URL
    ) async -> [CloudFolderSyncDiagnostic] {
        guard let historySyncPreferences,
              historySyncPreferences.isEnabled,
              historySyncPreferences.isAudioEnabled,
              let historyService else {
            return []
        }
        let records: [TranscriptionRecord]
        do {
            records = try historyService.recordsWithSynchronizedAudio()
        } catch {
            // Reported as a transient failure so the package is not recorded as synchronized
            // while received audio may still be waiting to be installed.
            return [.init(kind: .audioTransferFailed, fileName: "history")]
        }
        let pending = records.compactMap { record -> (UUID, UserDataSyncHistoryAudioV1)? in
            guard historyService.audioFileURL(for: record) == nil,
                  let descriptor = historyService.synchronizedAudioDescriptor(for: record),
                  historySyncPreferences.shouldReceiveSynchronizedAudio(
                      createdAt: descriptor.createdAt
                  ) else {
                return nil
            }
            return (record.id, descriptor)
        }
        guard !pending.isEmpty else { return [] }

        let packageURL = CloudFolderSyncEngine.packageURL(for: folderURL)
        var diagnostics: [CloudFolderSyncDiagnostic] = []
        for (recordID, descriptor) in pending {
            do {
                let sourceURL = try await Task.detached(priority: .utility) {
                    try await HistorySyncAssetStore.verifiedAssetURL(
                        packageURL: packageURL,
                        descriptor: descriptor
                    )
                }.value
                // The install runs synchronously on the main actor, so only its own history
                // refresh is ignored by the local change observer.
                isInstallingSynchronizedAudio = true
                defer { isInstallingSynchronizedAudio = false }
                try historyService.installSynchronizedAudio(
                    recordID: recordID,
                    sourceURL: sourceURL
                )
            } catch {
                diagnostics.append(.init(
                    kind: .audioTransferFailed,
                    fileName: descriptor.relativeAssetPath
                ))
            }
        }
        return diagnostics
    }

    #if DEBUG
    func prepareScreenshotFixture(hasPremiumAccess: Bool) {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        stopICloudObservation()
        selectedFolderURL = nil
        mode = hasPremiumAccess ? .automaticICloud : .off
        provider = hasPremiumAccess ? .iCloudDrive : .custom
        lastSyncDate = hasPremiumAccess ? AppConstants.screenshotFixtureReferenceDate : nil
        pendingChanges = 0
        if AppConstants.screenshotState == "history" {
            deviceCount = 2
            devices = [
                CloudFolderSyncDeviceRecord(
                    deviceId: "screenshot-mac",
                    historyOriginDeviceID: historySyncPreferences?.deviceID
                        ?? "screenshot-mac-history",
                    platform: "macOS",
                    appVersion: "1.7.0",
                    updatedAt: AppConstants.screenshotFixtureReferenceDate,
                    name: "MacBook Pro"
                ),
                CloudFolderSyncDeviceRecord(
                    deviceId: "screenshot-iphone",
                    historyOriginDeviceID: "screenshot-iphone-history",
                    platform: "iOS",
                    appVersion: "1.1.0",
                    updatedAt: AppConstants.screenshotFixtureReferenceDate,
                    name: "iPhone 16 Pro"
                ),
            ]
        } else {
            deviceCount = hasPremiumAccess ? 2 : 0
            devices = []
        }
        isSyncing = false
        errorMessage = nil
        statusMessage = nil
    }
    #endif

    func deletePrivateSyncFolder() async {
        guard !isSyncing else { return }
        let deletedMode = mode
        guard let folderURL = activeFolderURL(for: deletedMode) else { return }
        // An error of an earlier sync no longer applies once the folder is deleted;
        // a deletion error below replaces it.
        errorMessage = nil
        scheduledSyncTask?.cancel()
        scheduledSyncTask = nil
        stopICloudObservation()
        synchronizedPackage = nil
        mode = .off
        defaults.set(mode.rawValue, forKey: Keys.mode)
        pendingChanges = 0

        let accessed = deletedMode == .cloudFolder && folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        do {
            if deletedMode == .automaticICloud {
                try await automaticICloudBridge.deleteRemotePackage()
            }
            let packageURL = CloudFolderSyncEngine.packageURL(for: folderURL)
            if FileManager.default.fileExists(atPath: packageURL.path) { try FileManager.default.removeItem(at: packageURL) }
            setState(CloudFolderSyncState(), for: deletedMode)
            lastSyncDate = nil
            deviceCount = 0
            devices = []
            statusMessage = String(localized: "The private sync folder was deleted. Local data was kept.")
        } catch {
            errorMessage = error.localizedDescription
        }
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

/// Announces a background sync error once instead of on every failed retry, and
/// again when it comes back after a sync has succeeded or the user started one.
struct SyncErrorAnnouncementFilter {
    private var lastAnnounced: String?

    mutating func shouldAnnounce(_ message: String?) -> Bool {
        guard let message, message != lastAnnounced else { return false }
        lastAnnounced = message
        return true
    }

    mutating func reset() {
        lastAnnounced = nil
    }
}

struct CloudFolderSyncSettingsView: View {
    @ObservedObject var controller: CloudFolderSyncController
    @State private var confirmingSyncFolderDeletion = false
    @State private var showingSyncDevices = false
    @State private var confirmingHistorySync = false
    @State private var errorAnnouncementFilter = SyncErrorAnnouncementFilter()

    private var modePicker: some View {
        Picker(String(localized: "premium.window.sync.modePicker"), selection: Binding(
            get: { controller.mode },
            set: { mode in Task { await controller.setMode(mode) } }
        )) {
            ForEach(controller.availableModes) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "cloud",
                accent: .cyan,
                title: String(localized: "premium.hub.sync.title"),
                description: String(localized: "premium.window.sync.description"),
                status: statusText,
                statusColor: statusColor
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.sync.modeTitle"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    // Long mode names do not fit side by side in a narrow window.
                    ViewThatFits(in: .horizontal) {
                        modePicker.pickerStyle(.segmented)
                        modePicker.pickerStyle(.menu).fixedSize()
                    }
                    .labelsHidden()
                    .disabled(controller.isSyncing)
                    .accessibilityIdentifier("premium.sync.mode")

                    Toggle(
                        String(localized: "Sync History & Inbox"),
                        isOn: Binding(
                            get: { controller.historySyncPreferences?.isEnabled == true },
                            set: { enabled in
                                if enabled {
                                    confirmingHistorySync = true
                                } else {
                                    Task { await controller.setHistorySyncEnabled(false) }
                                }
                            }
                        )
                    )
                    .disabled(controller.mode == .off || controller.isSyncing)
                    .accessibilityIdentifier("premium.sync.history")

                    if controller.historySyncPreferences?.isEnabled == true {
                        Toggle(
                            String(localized: "Sync Audio for New Entries"),
                            isOn: Binding(
                                get: { controller.historySyncPreferences?.isAudioEnabled == true },
                                set: { controller.setHistoryAudioSyncEnabled($0) }
                            )
                        )
                        .disabled(controller.mode == .off || controller.isSyncing)
                        .accessibilityIdentifier("premium.sync.historyAudio")
                    }

                    Text(String(localized: "premium.window.sync.modeHelp"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.sync.statusTitle"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    statusRow(title: String(localized: "premium.window.sync.provider"), value: controller.provider.displayName, systemImage: "cloud")
                    statusRow(title: String(localized: "premium.window.sync.folder"), value: controller.selectedFolderDisplayName, systemImage: "folder")
                    statusRow(title: String(localized: "premium.window.sync.lastSync"), value: lastSyncText, systemImage: "clock")
                    statusRow(title: String(localized: "premium.window.sync.pending"), value: "\(controller.pendingChanges)", systemImage: "arrow.triangle.2.circlepath")
                    Button {
                        showingSyncDevices = true
                    } label: {
                        HStack(spacing: 0) {
                            statusRow(title: String(localized: "premium.window.sync.devices"), value: "\(controller.deviceCount)", systemImage: "laptopcomputer.and.iphone")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 6)
                                .accessibilityHidden(true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "premium.window.sync.devices"))
                    .accessibilityValue(controller.deviceCount.formatted())
                    .accessibilityIdentifier("premium.sync.devices")
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.sync.actionsTitle"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)

                    HStack(spacing: 8) {
                        // Choosing a folder switches to Cloud Folder; in the other modes the
                        // folder actions would change the mode behind the user's back.
                        if controller.mode == .cloudFolder {
                            Button {
                                controller.chooseFolder()
                            } label: {
                                Label(String(localized: "premium.window.sync.chooseFolder"), systemImage: "folder.badge.plus")
                            }
                            .disabled(controller.isSyncing)
                            .accessibilityIdentifier("premium.sync.chooseFolder")
                        }

                        Button {
                            errorAnnouncementFilter.reset()
                            Task {
                                await controller.syncNow()
                                announceStatus()
                            }
                        } label: {
                            if controller.isSyncing {
                                Label(String(localized: "premium.window.sync.syncing"), systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label(String(localized: "premium.window.sync.syncNow"), systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(!controller.isConfigured || controller.isSyncing)
                        .accessibilityIdentifier("premium.sync.syncNow")

                        if controller.mode == .cloudFolder {
                            Button {
                                controller.clearFolder()
                            } label: {
                                Label(String(localized: "premium.window.sync.clear"), systemImage: "xmark.circle")
                            }
                            .disabled(controller.selectedFolderURL == nil || controller.isSyncing)
                            .accessibilityIdentifier("premium.sync.clearFolder")
                        }
                    }
                }
            }

            SettingsCard(accent: .red) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "premium.window.sync.deleteTitle"))
                            .font(.callout.weight(.semibold))
                        Text(String(localized: "premium.window.sync.deleteHelp"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button(role: .destructive) {
                        confirmingSyncFolderDeletion = true
                    } label: {
                        Label(String(localized: "premium.window.sync.deleteData"), systemImage: "trash")
                    }
                    .disabled(!controller.isConfigured || controller.isSyncing)
                    .accessibilityIdentifier("premium.sync.deleteData")
                }
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Results and errors only appear in the labels above, so VoiceOver
        // users hear them. A repeated background error is announced once,
        // until a sync succeeds again.
        .onChange(of: controller.errorMessage) { _, message in
            guard errorAnnouncementFilter.shouldAnnounce(message), let message else { return }
            ServiceContainer.shared.accessibilityAnnouncementService.announceError(message)
        }
        .onChange(of: controller.lastSyncDate) { _, date in
            if date != nil { errorAnnouncementFilter.reset() }
        }
        .sheet(isPresented: $showingSyncDevices) {
            PremiumSyncDevicesView(controller: controller)
        }
        .confirmationDialog(
            String(localized: "premium.window.sync.deleteConfirmationTitle"),
            isPresented: $confirmingSyncFolderDeletion
        ) {
            Button(String(localized: "premium.window.sync.deleteConfirmationAction"), role: .destructive) {
                errorAnnouncementFilter.reset()
                Task {
                    await controller.deletePrivateSyncFolder()
                    announceStatus()
                }
            }
            Button(String(localized: "premium.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "premium.window.sync.deleteConfirmationMessage"))
        }
        .confirmationDialog(
            String(localized: "Sync History & Inbox?"),
            isPresented: $confirmingHistorySync
        ) {
            Button(String(localized: "Enable History Sync")) {
                Task { await controller.setHistorySyncEnabled(true) }
            }
            Button(String(localized: "premium.common.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Existing transcription text and metadata will be added to your private sync folder. Audio is synchronized only for new entries created after you enable this feature."))
        }
    }

    private func statusRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        // "Last Sync, Oct 20, 2026" as one element.
        .accessibilityElement(children: .combine)
    }

    /// Announces the result of an action the user started; errors are
    /// announced when they appear.
    private func announceStatus() {
        guard controller.errorMessage == nil, let status = controller.statusMessage else { return }
        ServiceContainer.shared.accessibilityAnnouncementService.announce(status)
    }

    private var lastSyncText: String {
        guard let date = controller.lastSyncDate else {
            return String(localized: "premium.window.sync.never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusText: String {
        if controller.isSyncing {
            return String(localized: "premium.window.sync.syncing")
        }
        return controller.mode.displayName
    }

    private var statusColor: Color {
        if controller.isSyncing {
            return .blue
        }
        return controller.mode == .off ? .secondary : .green
    }
}

/// The devices that sync through the private folder, as on iOS: a list, and
/// for each device its details and a way to remove it from the list.
private struct PremiumSyncDevicesView: View {
    @ObservedObject var controller: CloudFolderSyncController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.devices.isEmpty {
                    ContentUnavailableView(
                        String(localized: "No Synced Devices"),
                        systemImage: "laptopcomputer.and.iphone",
                        description: Text(String(localized: "Devices appear here after their first successful sync."))
                    )
                } else {
                    Section {
                        ForEach(controller.devices, id: \.deviceId) { device in
                            NavigationLink {
                                PremiumSyncDeviceDetailView(controller: controller, device: device)
                            } label: {
                                PremiumSyncDeviceRow(device: device, isCurrent: controller.isCurrentDevice(device))
                            }
                        }
                    } footer: {
                        Text(String(localized: "Removing a device only removes it from this list. Synced entries stay available, and the device appears again if it syncs later."))
                    }
                }
            }
            .navigationTitle(String(localized: "premium.window.sync.devices"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .accessibilityIdentifier("premium.sync.devices.sheet")
    }
}

private struct PremiumSyncDeviceRow: View {
    let device: CloudFolderSyncDeviceRecord
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.platformSymbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityLabel(device.platformDisplayName)
                .accessibilityHidden(device.displayName == device.platformDisplayName)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                    if isCurrent {
                        Text(String(localized: "This Device"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(device.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PremiumSyncDeviceDetailView: View {
    @ObservedObject var controller: CloudFolderSyncController
    let device: CloudFolderSyncDeviceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Platform"), value: device.platformDisplayName)
                LabeledContent(String(localized: "App Version"), value: device.appVersion)
                LabeledContent(
                    String(localized: "premium.window.sync.lastSync"),
                    value: device.updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
                LabeledContent(String(localized: "Device ID"), value: device.shortIdentifier)
            }

            if controller.isCurrentDevice(device) {
                Section {
                    Label(String(localized: "This is the current device."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button(String(localized: "Remove Device"), role: .destructive) {
                        confirmingRemoval = true
                    }
                    // With sync off the list still shows the last known devices, but
                    // there is no folder to remove them from.
                    .disabled(controller.isSyncing || controller.mode == .off)
                } footer: {
                    Text(String(localized: "This keeps all synchronized entries. If the device syncs again, it will reappear in the list."))
                }
            }

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.displayName)
        .confirmationDialog(
            String(localized: "Remove this device from the sync list?"),
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Remove Device"), role: .destructive) {
                Task {
                    await controller.removeDevice(device)
                    if controller.errorMessage == nil {
                        dismiss()
                    }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Synchronized entries remain in your private sync folder. The device will reappear if it syncs again."))
        }
        .accessibilityIdentifier("premium.sync.device.detail")
    }
}

private extension CloudFolderSyncDeviceRecord {
    var displayName: String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return platformDisplayName
    }

    var platformDisplayName: String {
        switch platform.lowercased() {
        case "ios", "ipados": String(localized: "iPhone or iPad")
        case "macos": "Mac"
        default: platform
        }
    }

    var platformSymbol: String {
        switch platform.lowercased() {
        case "ios", "ipados": "iphone"
        case "macos": "macbook"
        default: "laptopcomputer.and.iphone"
        }
    }

    var shortIdentifier: String {
        String(deviceId.prefix(8)).uppercased()
    }
}
