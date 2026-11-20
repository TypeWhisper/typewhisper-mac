import Combine
import Foundation
import os
import SwiftData
import TypeWhisperModuleKit

// The app's side of the capabilities in `ModuleHost`.

// MARK: - History

@MainActor
final class AppHistoryReading: HistoryReading {
    private let historyService: HistoryService
    private let showRecord: @MainActor (UUID, TimeInterval?) -> Void

    init(
        historyService: HistoryService,
        showRecord: @escaping @MainActor (UUID, TimeInterval?) -> Void = { id, seconds in
            HistoryViewModel.shared.requestOpenRecord(withID: id, at: seconds)
            ManagedAppWindowOpener.shared.open(id: "history")
        }
    ) {
        self.historyService = historyService
        self.showRecord = showRecord
    }

    func records(withIDs ids: Set<UUID>) async throws -> [ModuleHistoryRecord] {
        guard !ids.isEmpty else { return [] }
        let container = historyService.searchRecordReader.container
        let ids = Array(ids)
        return try await Task.detached(priority: .userInitiated) {
            try ModelContext(container)
                .fetch(FetchDescriptor<TranscriptionRecord>(predicate: #Predicate { ids.contains($0.id) }))
                .compactMap(ModuleHistoryRecord.init(record:))
        }.value
    }

    func existingRecordIDs(among ids: Set<UUID>) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let reader = historyService.searchRecordReader
        return try await Task.detached(priority: .userInitiated) { try reader.existingIDs(among: ids) }.value
    }

    func observeChanges(_ handler: @escaping @MainActor (ModuleHistoryChange) -> Void) -> AnyCancellable {
        // History sends its changes on the main actor.
        historyService.changes.sink { change in
            MainActor.assumeIsolated {
                switch change {
                case .upserted(let ids): handler(.upserted(ids))
                case .removed(let ids): handler(.removed(ids))
                case .cleared: handler(.cleared)
                }
            }
        }
    }

    func showRecord(withID id: UUID, atSeconds seconds: Double?) {
        showRecord(id, seconds)
    }
}

extension ModuleHistoryRecord {
    /// Nil while the record is transcribed and after that failed, as for the search index.
    init?(record: TranscriptionRecord) {
        guard record.processingState == .ready else { return nil }
        let bundleID = record.appBundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        let name = record.appName.flatMap { $0.isEmpty ? nil : $0 }
        let documentTitle = record.synchronizedStructuredDocument?.title.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            id: record.id,
            recordedAt: record.timestamp,
            source: record.sourceRaw,
            language: record.language,
            durationSeconds: record.durationSeconds,
            // Recordings keep their name where dictations keep the app they were made in.
            title: documentTitle ?? (bundleID == nil ? name : nil),
            appName: bundleID == nil ? nil : name,
            bundleID: bundleID,
            domain: record.appDomain,
            text: record.finalText,
            document: record.renderedDocument
        )
    }
}

@MainActor
final class AppHistorySearching: HistorySearching {
    private let index: HistorySearchIndex
    private let isEnabled: @MainActor () -> Bool
    private let prepareIndex: @MainActor () async -> Void

    /// - Parameter isEnabled: Whether the index may hold History now: the user's setting,
    ///   Premium access and the managed policy, as for the indexer. Reads find nothing otherwise.
    /// - Parameter prepareIndex: Turns the index on and waits for it to catch up with History.
    init(
        index: HistorySearchIndex,
        isEnabled: @escaping @MainActor () -> Bool,
        prepareIndex: @escaping @MainActor () async -> Void
    ) {
        self.index = index
        self.isEnabled = isEnabled
        self.prepareIndex = prepareIndex
    }

    func prepare() async {
        await prepareIndex()
    }

    func search(_ query: ModuleHistorySearchQuery) async throws -> [ModuleHistorySearchHit] {
        guard isEnabled() else { return [] }
        return try await index.search(
            words: query.words,
            names: query.names,
            in: HistorySearchScope(query.scope),
            limit: query.limit,
            includingNewest: query.includingNewest
        ).map(ModuleHistorySearchHit.init)
    }

    func newestRecords(in scope: ModuleHistorySearchScope, limit: Int) async throws -> ModuleHistoryNewestRecords {
        guard isEnabled() else { return ModuleHistoryNewestRecords(hits: [], total: 0) }
        let (hits, total) = try await index.newestRecords(in: HistorySearchScope(scope), limit: limit)
        return ModuleHistoryNewestRecords(hits: hits.map(ModuleHistorySearchHit.init), total: total)
    }

    func transcript(ofRecord id: UUID) async throws -> ModuleHistoryTranscript? {
        guard isEnabled(), let transcript = try await index.transcript(ofRecord: id) else { return nil }
        return ModuleHistoryTranscript(
            passages: transcript.passages.map(ModuleHistoryPassage.init),
            contentHash: transcript.contentHash
        )
    }

    func summary(ofRecord id: UUID, language: String) async throws -> ModuleHistorySummary? {
        guard isEnabled() else { return nil }
        return try await index.summary(ofRecord: id, language: language).map {
            ModuleHistorySummary(text: $0.text, providerId: $0.providerId)
        }
    }

    func setSummary(
        _ summary: String, providerId: String, ofRecord id: UUID, contentHash: String, language: String
    ) async throws {
        guard isEnabled() else { return }
        try await index.setSummary(summary, providerId: providerId, ofRecord: id, contentHash: contentHash, language: language)
    }

    func vocabulary() async throws -> ModuleHistoryVocabulary {
        guard isEnabled() else { return ModuleHistoryVocabulary() }
        let vocabulary = try await index.vocabulary()
        return ModuleHistoryVocabulary(
            speakers: vocabulary.speakers,
            apps: vocabulary.apps.map { ModuleHistoryVocabulary.App(name: $0.name, bundleID: $0.bundleID) },
            domains: vocabulary.domains
        )
    }
}

extension HistorySearchScope {
    init(_ scope: ModuleHistorySearchScope) {
        self.init(
            period: scope.period,
            sources: scope.sources,
            bundleIDs: scope.bundleIDs,
            domains: scope.domains,
            recordIDs: scope.recordIDs
        )
    }
}

extension ModuleHistoryPassage {
    init(_ passage: HistoryPassage) {
        self.init(
            kind: passage.kind == .transcript ? .transcript : .result,
            text: passage.text,
            speakers: passage.speakers,
            startSeconds: passage.startSeconds,
            endSeconds: passage.endSeconds,
            utf16Range: passage.utf16Range
        )
    }
}

extension ModuleHistorySearchHit {
    init(_ hit: HistorySearchHit) {
        self.init(
            recordID: hit.recordID,
            recordedAt: hit.recordedAt,
            source: hit.source,
            title: hit.title,
            appName: hit.appName,
            domain: hit.domain,
            ordinals: hit.ordinals,
            passage: ModuleHistoryPassage(hit.passage),
            score: hit.score
        )
    }
}

// MARK: - Language models

@MainActor
final class AppLanguageModelAnswering: LanguageModelAnswering {
    private let service: PromptProcessingService
    private let openSettings: @MainActor () -> Void

    init(
        service: PromptProcessingService,
        openSettings: @escaping @MainActor () -> Void = {
            SettingsNavigationCoordinator.shared.navigate(to: .workflows)
            ManagedAppWindowOpener.shared.open(id: "settings")
        }
    ) {
        self.service = service
        self.openSettings = openSettings
    }

    func providers() throws -> [ModuleLanguageModelProvider] {
        do {
            return try service.languageModelAttempts().map { attempt in
                ModuleLanguageModelProvider(
                    id: attempt.providerId,
                    name: attempt.name,
                    kind: attempt.isLocal ? .local : .cloud,
                    pluginId: attempt.pluginId,
                    modelId: attempt.modelId,
                    effortId: attempt.effortId
                )
            }
        } catch {
            throw Self.moduleError(for: error)
        }
    }

    func answer(instructions: String, prompt: String, using provider: ModuleLanguageModelProvider) async throws -> String {
        let reply: String
        do {
            reply = try await service.answerModuleRequest(
                instructions: instructions, prompt: prompt, with: Self.attempt(for: provider)
            )
        } catch {
            throw Self.moduleError(for: error)
        }
        guard !reply.isEmpty else { throw ModuleLanguageModelError.emptyReply }
        return reply
    }

    func inputTokens(
        instructions: String, prompt: String, using provider: ModuleLanguageModelProvider
    ) async -> ModuleTokenCount? {
        await service.moduleRequestInputTokens(
            instructions: instructions, prompt: prompt, with: Self.attempt(for: provider)
        ).map { ModuleTokenCount(count: $0.count, contextSize: $0.contextSize) }
    }

    func prewarm() {
        service.prewarmWorkflowLLMProvider(providerOverride: nil)
    }

    func showSettings() {
        openSettings()
    }

    private static func attempt(for provider: ModuleLanguageModelProvider) -> PromptProcessingService.LanguageModelAttempt {
        PromptProcessingService.LanguageModelAttempt(
            providerId: provider.id,
            modelId: provider.modelId,
            effortId: provider.effortId,
            name: provider.name,
            isLocal: provider.kind == .local,
            pluginId: provider.pluginId
        )
    }

    /// The error a module sees: cancellation stays cancellation, the rest becomes `ModuleLanguageModelError`.
    static func moduleError(for error: any Error) -> any Error {
        if PromptProcessingService.isCancellation(error) { return CancellationError() }
        if let error = error as? ModuleLanguageModelError { return error }
        if let refusal = error as? ManagedPolicyRefusal { return ModuleLanguageModelError.refused(refusal.reason) }
        if LLMContextLimit.isReported(by: error) { return ModuleLanguageModelError.contextExceeded }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if PromptProcessingService.isNotSetUp(error) { return ModuleLanguageModelError.notSetUp(message) }
        return ModuleLanguageModelError.failed(message.isEmpty ? "Unknown provider failure." : message)
    }
}

// MARK: - Managed settings

@MainActor
final class AppModuleManagedPolicyReading: TypeWhisperModuleKit.ManagedPolicyReading {
    private let service: ManagedPolicyService

    init(service: ManagedPolicyService) {
        self.service = service
    }

    func state(ofKey name: String) -> ModuleManagedPolicyState {
        guard ManagedPolicyKeys.isDeclaredByModule(name) else {
            return ModuleManagedPolicyState()
        }
        let snapshot = service.current
        return ModuleManagedPolicyState(
            enforced: snapshot.enforced(name).map(ModuleManagedPolicyValue.init),
            recommended: snapshot.recommended(name).map(ModuleManagedPolicyValue.init),
            isBlocked: snapshot.isBlocked(name)
        )
    }

    func refresh() {
        service.refresh()
    }

    func observeChanges(_ handler: @escaping @MainActor () -> Void) -> AnyCancellable {
        // `current` publishes before it changes; the handler reads the new snapshot.
        service.$current
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { handler() } }
    }
}

extension ModuleManagedPolicyValue {
    init(_ value: ManagedPolicyValue) {
        switch value {
        case .boolean(let flag): self = .boolean(flag)
        case .enumeration(let number): self = .enumeration(number)
        case .text(let text): self = .text(text)
        case .list(let items): self = .list(items)
        }
    }
}

extension ManagedPolicyDefinition {
    init(_ key: ModuleManagedPolicyKey) {
        let kind: ManagedPolicyValueKind = switch key.kind {
        case .boolean: .boolean
        case .enumeration: .enumeration
        case .text: .text
        case .list: .list
        }
        self.init(
            name: key.name,
            kind: kind,
            allowsRecommendation: key.allowsRecommendation,
            enumerationMaximum: key.enumerationMaximum,
            sensitive: key.sensitive
        )
    }
}

// MARK: - Premium access

@MainActor
final class AppPremiumAccessReading: PremiumAccessReading {
    /// What a module can read about the access. A change of any part is reported.
    struct State: Equatable {
        var hasCommercialLicense = false
        var hasPremiumAccount = false
        var signedAccountEntitlement: String?

        var hasPremiumAccess: Bool { hasCommercialLicense || hasPremiumAccount }
    }

    private let state: @MainActor () -> State
    private let accessChanges: AnyPublisher<Void, Never>
    private let showAccess: @MainActor () -> Void

    /// - Parameter accessChanges: Publishes before the access may change, like `objectWillChange`.
    init(
        state: @escaping @MainActor () -> State,
        accessChanges: AnyPublisher<Void, Never>,
        showAccess: @escaping @MainActor () -> Void = { PremiumSettingsWindowManager.shared.present(.access) }
    ) {
        self.state = state
        self.accessChanges = accessChanges
        self.showAccess = showAccess
    }

    convenience init(licenseService: LicenseService, premiumAccountService: PremiumAccountService) {
        self.init(
            state: { [licenseService, premiumAccountService] in
                State(
                    hasCommercialLicense: licenseService.hasCommercialLicense,
                    hasPremiumAccount: premiumAccountService.hasPremiumEntitlement,
                    signedAccountEntitlement: premiumAccountService.signedEntitlement
                )
            },
            accessChanges: Publishers.Merge(
                licenseService.objectWillChange.map { _ in () },
                premiumAccountService.objectWillChange.map { _ in () }
            )
            .eraseToAnyPublisher()
        )
    }

    var hasPremiumAccess: Bool { state().hasPremiumAccess }

    func meets(_ requirement: ModulePremiumRequirement) -> Bool {
        let current = state()
        return switch requirement {
        case .commercialOrPremium: current.hasPremiumAccess
        case .commercial: current.hasCommercialLicense
        case .premiumAccount: current.hasPremiumAccount
        }
    }

    var signedAccountEntitlement: String? { state().signedAccountEntitlement }

    func observeChanges(_ handler: @escaping @MainActor (Bool) -> Void) -> AnyCancellable {
        var last = state()
        // The services publish before they change, so read the state after the change.
        return accessChanges
            .receive(on: DispatchQueue.main)
            .sink { [state] _ in
                MainActor.assumeIsolated {
                    let current = state()
                    guard current != last else { return }
                    last = current
                    handler(current.hasPremiumAccess)
                }
            }
    }

    func showPremiumAccess() {
        showAccess()
    }
}

// MARK: - User data

@MainActor
final class AppModuleUserDataLifecycle: UserDataLifecycle {
    /// The folder of a data export that holds the modules' files.
    static let exportFolderName = "Modules"
    /// The folder in Application Support that holds the modules' data folders.
    /// Erasing all data deletes it and the export copies it, like the rest of
    /// Application Support.
    static let dataFolderName = "Modules"

    enum DataFolderError: Error, Equatable {
        case invalidIdentifier(String)
    }

    private(set) var registrations: [ModuleUserData] = []
    private let appSupportDirectory: () -> URL
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Modules")

    init(appSupportDirectory: @escaping () -> URL = { AppConstants.appSupportDirectory }) {
        self.appSupportDirectory = appSupportDirectory
    }

    func dataFolder(forModuleID id: String) throws -> URL {
        guard ModuleIdentifier.isValid(id) else { throw DataFolderError.invalidIdentifier(id) }
        let folder = appSupportDirectory()
            .appendingPathComponent(Self.dataFolderName, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func register(_ userData: ModuleUserData) {
        guard ModuleIdentifier.isValid(userData.id) else {
            logger.error("Module data not registered: invalid identifier")
            return
        }
        registrations.removeAll { $0.id == userData.id }
        registrations.append(userData)
    }

    /// Erases every module's data. A failure does not stop the others.
    func eraseAll() async -> [UserDataEraser.Failure] {
        var failures: [UserDataEraser.Failure] = []
        for userData in registrations {
            do {
                try await userData.erase()
            } catch {
                failures.append(UserDataEraser.Failure(item: userData.id, message: error.localizedDescription))
            }
        }
        return failures
    }

    /// The modules' files for a data export, by their path in the archive.
    /// Names that are no file name, such as a path, are left out.
    /// - Throws: `UserDataExportService.ExportError.duplicateModuleFile` for two
    ///   paths that differ only in case, which would share one file.
    func exportFiles() async throws -> [String: Data] {
        var files: [String: Data] = [:]
        // Whole paths, because two modules' identifiers can differ only in case too.
        var paths = Set<String>()
        for userData in registrations {
            for (name, data) in try await userData.export().sorted(by: { $0.key < $1.key }) {
                guard Self.isFileName(name) else {
                    logger.error("Module file left out of the export: invalid name")
                    continue
                }
                let path = "\(Self.exportFolderName)/\(userData.id)/\(name)"
                guard paths.insert(path.lowercased()).inserted else {
                    throw UserDataExportService.ExportError.duplicateModuleFile(name)
                }
                files[path] = data
            }
        }
        return files
    }

    /// A single file name: no path separator, not `.` or `..`, at most 255 bytes.
    static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains(":") && !name.unicodeScalars.contains { $0.value == 0 }
    }
}
