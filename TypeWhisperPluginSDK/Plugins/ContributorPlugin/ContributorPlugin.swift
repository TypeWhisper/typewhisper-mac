import Foundation
import SwiftUI
import TypeWhisperPluginSDK

@objc(ContributorPlugin)
final class ContributorPlugin: NSObject, TypeWhisperPlugin, PluginSettingsWindowLayoutProviding,
    ObservableObject, @unchecked Sendable {
    static let pluginId = "com.typewhisper.improve"
    static let pluginName = "Improve TypeWhisper"

    static let pluginVersion = "0.1.0"
    static let consentVersion = "contribution-text-v1"
    static let defaultServiceURL = URL(string: "https://app.typewhisper.com")!
    static let contributionPolicyURL = URL(
        string: "https://www.typewhisper.com/addons/improve-typewhisper/"
    )!

    @Published private(set) var records: [ContributionRecord] = []
    @Published private(set) var activityMessage: String?
    @Published private(set) var activityIsError = false
    @Published private(set) var isWorking = false
    @Published var selectedIds: Set<UUID> = []
    @Published var selectedPreviewId: UUID?
    @Published var sendConfirmed = false

    fileprivate var host: HostServices?
    private var queueStore: ContributorQueueStore?
    private var subscriptionId: UUID?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        self.queueStore = ContributorQueueStore(rootDirectory: host.pluginDataDirectory)
        if captureEnabled {
            subscribe()
        }
        Task { @MainActor [weak self] in
            self?.reloadQueue()
        }
    }

    func deactivate() {
        unsubscribe()
        host = nil
        queueStore = nil
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(ContributorSettingsView(plugin: self))
    }

    var settingsViewManagesScrolling: Bool { true }
    var preferredSettingsWindowSize: CGSize? { CGSize(width: 860, height: 620) }
    var minimumSettingsWindowSize: CGSize? { CGSize(width: 700, height: 500) }

    var captureEnabled: Bool {
        host?.userDefault(forKey: "collectCorrections") as? Bool ?? false
    }

    @MainActor
    func updateCaptureEnabled(_ enabled: Bool) {
        host?.setUserDefault(enabled, forKey: "collectCorrections")
        if enabled {
            subscribe()
        } else {
            unsubscribe()
        }
        objectWillChange.send()
    }

    @MainActor
    func reloadQueue() {
        do {
            let loaded = try queueStore?.loadRecords() ?? []
            records = loaded
            let currentIds = Set(loaded.map(\.id))
            selectedIds.formIntersection(currentIds)
            if selectedPreviewId.flatMap({ currentIds.contains($0) }) != true {
                selectedPreviewId = loaded.first?.id
            }
            sendConfirmed = false
        } catch {
            showActivity(error.localizedDescription, isError: true)
        }
    }

    @MainActor
    func sendSelected() {
        let selected = records.filter {
            selectedIds.contains($0.id) && $0.status == .local
        }
        guard sendConfirmed, !selected.isEmpty, !isWorking else { return }
        guard let host, let queueStore else { return }
        isWorking = true
        clearActivity()

        Task { [weak self] in
            do {
                for chunk in selected.chunked(maximumCount: 50) {
                    let batchId = UUID()
                    let response = try await Self.withAuthenticatedClient(
                        host: host,
                        baseURL: self?.serviceURL
                    ) { client in
                        try await client.submit(
                            batchId: batchId,
                            records: chunk,
                            consentVersion: Self.consentVersion,
                            pluginVersion: Self.pluginVersion
                        )
                    }
                    try Self.apply(response.records, to: chunk, store: queueStore)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.isWorking = false
                    self.reloadQueue()
                    self.showActivity(contributorText(
                        "\(selected.count) changes were sent for review.",
                        de: "\(selected.count) Änderungen wurden zur Prüfung gesendet.",
                        ja: "\(selected.count)件の変更をレビュー用に送信しました。"
                    ))
                }
            } catch {
                await MainActor.run {
                    self?.isWorking = false
                    self?.showActivity(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @MainActor
    func refreshStatuses() {
        let submitted = records.filter(\.status.isRemote)
        guard !submitted.isEmpty, !isWorking, let host, let queueStore else { return }
        isWorking = true
        clearActivity()

        Task { [weak self] in
            do {
                for chunk in submitted.chunked(maximumCount: 100) {
                    let statuses = try await Self.withAuthenticatedClient(
                        host: host,
                        baseURL: self?.serviceURL
                    ) { client in
                        try await client.statuses(for: chunk.map(\.id))
                    }
                    try Self.apply(statuses, to: chunk, store: queueStore)
                }
                await MainActor.run {
                    guard let self else { return }
                    self.isWorking = false
                    self.reloadQueue()
                    self.showActivity(contributorText(
                        "Review status updated.",
                        de: "Prüfstatus aktualisiert.",
                        ja: "レビュー状況を更新しました。"
                    ))
                }
            } catch {
                await MainActor.run {
                    self?.isWorking = false
                    self?.showActivity(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @MainActor
    func delete(_ record: ContributionRecord) {
        guard !isWorking, let queueStore else { return }
        if !record.status.isRemote {
            do {
                try queueStore.remove(record.id)
                reloadQueue()
            } catch {
                showActivity(error.localizedDescription, isError: true)
            }
            return
        }
        guard let host else { return }
        isWorking = true
        clearActivity()
        Task { [weak self] in
            do {
                try await Self.withAuthenticatedClient(
                    host: host,
                    baseURL: self?.serviceURL
                ) { client in
                    try await client.delete(record.id)
                }
                try queueStore.remove(record.id)
                await MainActor.run {
                    self?.isWorking = false
                    self?.reloadQueue()
                }
            } catch {
                await MainActor.run {
                    self?.isWorking = false
                    self?.showActivity(error.localizedDescription, isError: true)
                }
            }
        }
    }

    @MainActor
    func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        selectedPreviewId = id
        sendConfirmed = false
    }

    @MainActor
    private func showActivity(_ message: String, isError: Bool = false) {
        activityMessage = message
        activityIsError = isError
    }

    @MainActor
    private func clearActivity() {
        activityMessage = nil
        activityIsError = false
    }

    private var serviceURL: URL? {
        guard let override = host?.userDefault(forKey: "serviceURL") as? String,
              let url = URL(string: override) else {
            return Self.defaultServiceURL
        }
        return url
    }

    private func subscribe() {
        guard subscriptionId == nil, let eventBus = host?.eventBus else { return }
        subscriptionId = eventBus.subscribe { [weak self] event in
            guard case .textCorrectionCommitted(let payload) = event else { return }
            await self?.capture(payload)
        }
    }

    private func unsubscribe() {
        if let subscriptionId {
            host?.eventBus.unsubscribe(id: subscriptionId)
            self.subscriptionId = nil
        }
    }

    private func capture(_ payload: TextCorrectionCommittedPayload) async {
        guard captureEnabled, let queueStore else { return }
        do {
            _ = try queueStore.insert(ContributionRecord(payload: payload))
            await MainActor.run {
                self.reloadQueue()
            }
        } catch {
            await MainActor.run {
                self.showActivity(error.localizedDescription, isError: true)
            }
        }
    }

    private static func authenticatedClient(
        host: HostServices,
        baseURL: URL?
    ) async throws -> ContributorAPIClient {
        guard let baseURL else { throw ContributorAPIError.invalidResponse }
        if let token = host.loadSecret(key: "contributor-token"), !token.isEmpty {
            return ContributorAPIClient(baseURL: baseURL, token: token)
        }
        let session = try await ContributorAPIClient(baseURL: baseURL, token: nil).createSession()
        try host.storeSecret(key: "contributor-token", value: session.token)
        return ContributorAPIClient(baseURL: baseURL, token: session.token)
    }

    private static func withAuthenticatedClient<Result: Sendable>(
        host: HostServices,
        baseURL: URL?,
        operation: @Sendable (ContributorAPIClient) async throws -> Result
    ) async throws -> Result {
        let client = try await authenticatedClient(host: host, baseURL: baseURL)
        do {
            return try await operation(client)
        } catch let error as ContributorAPIError where error.isAuthenticationFailure {
            try host.storeSecret(key: "contributor-token", value: "")
            let renewedClient = try await authenticatedClient(host: host, baseURL: baseURL)
            return try await operation(renewedClient)
        }
    }

    private static func apply(
        _ statuses: [ContributionRemoteStatus],
        to records: [ContributionRecord],
        store: ContributorQueueStore
    ) throws {
        let statusById = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
        for var record in records {
            guard let remote = statusById[record.id] else { continue }
            record.status = remote.status
            record.reasonCode = remote.reasonCode
            record.qualityCredit = remote.qualityCredit
            if record.status.isTerminal {
                try store.complete(record)
            } else {
                try store.upsert(record)
            }
        }
    }
}

extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0..<Swift.min($0 + maximumCount, count)])
        }
    }
}

func contributorText(_ english: String, de german: String, ja japanese: String) -> String {
    let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
    if language.hasPrefix("de") { return german }
    if language.hasPrefix("ja") { return japanese }
    return english
}
