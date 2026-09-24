import AppKit
import Combine
import Foundation

enum HistoryDateGroup: Int, CaseIterable, Identifiable {
    case today, yesterday, thisWeek, thisMonth, older

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .thisWeek: String(localized: "This Week")
        case .thisMonth: String(localized: "This Month")
        case .older: String(localized: "Older")
        }
    }
}

struct HistorySection: Identifiable {
    let group: HistoryDateGroup
    let records: [TranscriptionRecord]
    var id: Int { group.id }
}

enum HistoryTimeRange: Int, CaseIterable, Identifiable {
    case sevenDays, thirtyDays, ninetyDays, all

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .sevenDays: String(localized: "Last 7 Days")
        case .thirtyDays: String(localized: "Last 30 Days")
        case .ninetyDays: String(localized: "Last 90 Days")
        case .all: String(localized: "All Time")
        }
    }

    var cutoffDate: Date? {
        switch self {
        case .sevenDays: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .thirtyDays: Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .ninetyDays: Calendar.current.date(byAdding: .day, value: -90, to: Date())
        case .all: nil
        }
    }
}

enum HistoryCollectionScope: String, CaseIterable, Identifiable, Hashable {
    case inbox
    case all
    case withAudio
    case failed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inbox: String(localized: "Inbox")
        case .all: String(localized: "All History")
        case .withAudio: String(localized: "With Audio")
        case .failed: String(localized: "Failed")
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .all: "clock.arrow.circlepath"
        case .withAudio: "waveform"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// Compatibility filter for tests and non-sidebar callers that still use platform-wide sources.
enum HistorySourceScope: String, CaseIterable, Identifiable {
    case mac
    case mobile
    case appleWatch
    case keyboard
    case shortcut
    case importedFile
    case other

    var id: String { rawValue }

    func contains(_ source: RecordingSource) -> Bool {
        switch self {
        case .mac: source == .mac
        case .mobile: source == .iPhone || source == .iPad
        case .appleWatch: source == .appleWatch
        case .keyboard: source == .keyboard
        case .shortcut: source == .shortcut
        case .importedFile: source == .importedFile
        case .other: source == .other
        }
    }
}

enum HistorySortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case duration
    case appName

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest: String(localized: "Newest First")
        case .oldest: String(localized: "Oldest First")
        case .duration: String(localized: "Duration")
        case .appName: String(localized: "App Name")
        }
    }
}

struct AppEntry: Identifiable, Hashable {
    let bundleId: String
    let name: String
    var id: String { bundleId }
}

enum HistoryDetailViewMode: Int {
    case final
    case original
    case changes
}

enum HistoryDiffPresentation: Equatable, Sendable {
    case segments([DiffSegment])
    /// The texts are too long for a word-level comparison.
    case tooLarge
}

enum HistoryNavigationSelection: Hashable {
    case smartMailbox(HistoryCollectionScope)
    case device(String)
    case deviceSource(deviceID: String, source: RecordingSource)
}

struct HistoryDeviceSourceSection: Identifiable, Hashable {
    let source: RecordingSource
    let title: String
    let systemImage: String
    let count: Int

    var id: String { source.rawValue }
}

struct HistoryDeviceSection: Identifiable, Hashable {
    let id: String
    let title: String
    let platform: String
    let systemImage: String
    let isCurrent: Bool
    let count: Int
    let sources: [HistoryDeviceSourceSection]
}

private enum PendingHistoryTransition: Equatable {
    case recordSelection(Set<UUID>)
    case navigation(HistoryNavigationSelection)
    case appFilter(String?)
    case timeRange(HistoryTimeRange)
    case clearFilters
    case deletion(Set<UUID>)
    case closeWindow
}

@MainActor
final class HistoryViewModel: ObservableObject {
    typealias BackgroundPageLoader = @MainActor (HistoryQuery, _ offset: Int, _ limit: Int) async -> HistoryPage?
    typealias DiffPresentationLoader = @MainActor (_ rawText: String, _ finalText: String) async -> HistoryDiffPresentation?

    private static let pageSize = 100
    /// Diffs whose inputs fit in this many UTF-8 bytes are computed inline while rendering.
    static let inlineDiffInputLimit = 4_000
    /// Upper bound for the word-level LCS table, which costs one byte and one comparison per cell.
    nonisolated static let maxDiffComparisonCells = 4_000_000
    private static let diffCacheLimit = 16

    nonisolated(unsafe) static var _shared: HistoryViewModel?
    static var shared: HistoryViewModel {
        guard let instance = _shared else {
            fatalError("HistoryViewModel not initialized")
        }
        return instance
    }

    @Published var records: [TranscriptionRecord] = []
    @Published var selectedRecordIDs: Set<UUID> = [] {
        didSet {
            guard selectedRecordIDs != oldValue else { return }
            loadDraftForCurrentSelection()
        }
    }
    @Published var searchQuery = ""
    @Published var editedText = ""
    @Published var correctionSuggestions: [CorrectionSuggestion] = []
    @Published var showCorrectionBanner = false
    @Published var detailViewMode: HistoryDetailViewMode = .final
    @Published private(set) var navigationSelection: HistoryNavigationSelection = .smartMailbox(.all)
    @Published var selectedAppFilter: String?
    @Published var selectedTimeRange: HistoryTimeRange = .all
    @Published var selectedSortOrder: HistorySortOrder = .newest
    @Published var collapsedGroups: Set<HistoryDateGroup> = []
    @Published var expandedDeviceIDs: Set<String> = []
    @Published private(set) var filteredRecords: [TranscriptionRecord] = []
    @Published private(set) var groupedSections: [HistorySection] = []
    @Published private(set) var availableApps: [AppEntry] = []
    @Published private(set) var deviceSections: [HistoryDeviceSection] = []
    @Published private(set) var visibleRecordCount = 0
    @Published private(set) var visibleWordCount = 0
    @Published private(set) var totalMatchingRecordCount = 0
    @Published private(set) var hasMoreRecords = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var queryID = UUID()
    @Published private(set) var pendingDeletionIDs: Set<UUID> = []

    let audioPlaybackService = AudioPlaybackService()

    private let historyService: HistoryService
    private let textDiffService: TextDiffService
    private let dictionaryService: DictionaryService
    private let syncController: CloudFolderSyncController?
    private let currentDeviceID: String?
    private var devices: [CloudFolderSyncDeviceRecord] = []
    private var draftRecordID: UUID?
    private var originalDraftText = ""
    private var pendingTransition: PendingHistoryTransition?
    private var didInitializeDeviceExpansion = false
    private var closeWindowHandler: (() -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var isActive = false
    private var facetDevices: [HistoryDeviceFacet] = []
    private let backgroundPageLoader: BackgroundPageLoader
    private let diffPresentationLoader: DiffPresentationLoader
    private let historyRefreshDelay: Duration
    private var queryGeneration = 0
    /// A reload that was skipped or dropped while the draft had unsaved changes.
    private var deferredReload: (preservingLoadedRecords: Bool, resetListIdentity: Bool)?
    private var queryTask: Task<Void, Never>?
    private var loadMoreAfterQuery = false
    private var facetsGeneration = 0
    private var facetsTask: Task<Void, Never>?
    private var pendingHistoryRefresh: Task<Void, Never>?
    private var pendingWork: [UUID: Task<Void, Never>] = [:]
    private var diffCache: [UUID: CachedDiff] = [:]
    private var diffCacheOrder: [UUID] = []

    private struct CachedDiff {
        let rawText: String
        let finalText: String
        let presentation: HistoryDiffPresentation
    }
    @Published private(set) var inboxCount = 0
    @Published private(set) var audioCount = 0
    @Published private(set) var failedCount = 0

    init(
        historyService: HistoryService,
        textDiffService: TextDiffService,
        dictionaryService: DictionaryService,
        syncController: CloudFolderSyncController? = nil,
        historyRefreshDelay: Duration = .milliseconds(150),
        backgroundPageLoader: BackgroundPageLoader? = nil,
        diffPresentationLoader: DiffPresentationLoader? = nil
    ) {
        self.historyService = historyService
        self.textDiffService = textDiffService
        self.dictionaryService = dictionaryService
        self.syncController = syncController
        self.historyRefreshDelay = historyRefreshDelay
        self.backgroundPageLoader = backgroundPageLoader ?? { [historyService] query, offset, limit in
            await historyService.fetchPageInBackground(query: query, offset: offset, limit: limit)
        }
        self.diffPresentationLoader = diffPresentationLoader ?? { rawText, finalText in
            await HistoryViewModel.computeDiffPresentationInBackground(rawText: rawText, finalText: finalText)
        }
        currentDeviceID = syncController?.historySyncPreferences?.deviceID
        records = historyService.recentRecords
        totalMatchingRecordCount = historyService.totalRecords
        hasMoreRecords = records.count < totalMatchingRecordCount
        inboxCount = records.count(where: \.isOpenInInbox)
        audioCount = records.count(where: Self.hasAudio)
        failedCount = records.count { $0.processingState == .failed }
        devices = syncController?.devices ?? []
        availableApps = Self.computeAvailableApps(records)
        deviceSections = Self.computeDeviceSections(
            records: records,
            devices: devices,
            currentDeviceID: currentDeviceID
        )
        initializeDeviceExpansionIfNeeded()
        recomputeVisibleRecords()
        setupBindings()
    }

    var hasVisibleSelection: Bool { !visibleSelectedRecordIDs.isEmpty }

    var selectedRecord: TranscriptionRecord? {
        guard selectedRecordIDs.count == 1,
              let id = selectedRecordIDs.first else { return nil }
        return records.first { $0.id == id }
    }

    var selectedRecords: [TranscriptionRecord] {
        records.filter { selectedRecordIDs.contains($0.id) }
    }

    var hasActiveFilters: Bool {
        selectedAppFilter != nil || selectedTimeRange != .all
    }

    var isDirty: Bool {
        guard draftRecordID == selectedRecord?.id else { return false }
        return editedText != originalDraftText
    }

    var canSaveDraft: Bool {
        isDirty && !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsUnsavedChangesPrompt: Bool { pendingTransition != nil }

    var navigationTitle: String {
        switch navigationSelection {
        case .smartMailbox(let scope): scope.displayName
        case .device(let id): deviceSections.first { $0.id == id }?.title ?? String(localized: "Device")
        case .deviceSource(let id, let source):
            deviceSections.first { $0.id == id }?.sources.first { $0.source == source }?.title
                ?? source.displayName
        }
    }

    var navigationSummary: String {
        String.localizedStringWithFormat(
            String(localized: "%lld entries"),
            Int64(totalMatchingRecordCount)
        )
    }

    var selectedSmartMailbox: HistoryCollectionScope? {
        guard case .smartMailbox(let scope) = navigationSelection else { return nil }
        return scope
    }

    var canEditSelectedRecord: Bool {
        guard let record = selectedRecord else { return false }
        return record.processingState == .ready && !record.displayText.isEmpty
    }

    func count(for scope: HistoryCollectionScope) -> Int {
        switch scope {
        case .inbox: inboxCount
        case .all: historyService.totalRecords
        case .withAudio: audioCount
        case .failed: failedCount
        }
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        reloadCurrentQuery(resetListIdentity: false)
        refreshFacets()
    }

    func deactivate() {
        isActive = false
        cancelPendingQueryWork()
        records = historyService.recentRecords
        totalMatchingRecordCount = historyService.totalRecords
        hasMoreRecords = records.count < totalMatchingRecordCount
        recomputeVisibleRecords()
    }

    func loadMoreRecords() {
        guard isActive, hasMoreRecords, !isLoadingMore else { return }
        // Until a reload deferred by the unsaved draft runs, the records belong to an older
        // query, so their count is no valid offset into the current one.
        guard deferredReload == nil else { return }
        guard queryTask == nil else {
            // A reload is still searching; continue paging once its first page is shown.
            loadMoreAfterQuery = true
            return
        }
        let query = currentQuery
        let offset = records.count
        isLoadingMore = true

        guard query.requiresPostFiltering else {
            defer { isLoadingMore = false }
            appendPage(historyService.fetchPage(query: query, offset: offset, limit: Self.pageSize))
            return
        }

        let generation = queryGeneration
        let loader = backgroundPageLoader
        queryTask = startTrackedTask { [weak self] in
            let page = await loader(query, offset, Self.pageSize)
            // A newer reload or deactivation resets the paging state itself.
            guard let self, generation == self.queryGeneration else { return }
            self.queryTask = nil
            self.isLoadingMore = false
            if let page { self.appendPage(page) }
        }
    }

    /// Waits until coalesced refreshes, background searches, and facet scans started so far,
    /// including the work they start themselves, have finished.
    func waitForPendingWork() async {
        while let task = pendingWork.values.first {
            await task.value
        }
    }

    func toggleDeviceExpansion(_ id: String) {
        if expandedDeviceIDs.contains(id) {
            expandedDeviceIDs.remove(id)
        } else {
            expandedDeviceIDs.insert(id)
        }
    }

    func toggleSection(_ group: HistoryDateGroup) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            if let section = groupedSections.first(where: { $0.group == group }) {
                syncSelection(withVisibleRecordIDs: visibleRecordIDs.subtracting(section.records.map(\.id)))
            }
            collapsedGroups.insert(group)
        }
    }

    func requestNavigationSelection(_ selection: HistoryNavigationSelection) {
        guard selection != navigationSelection else { return }
        prepare(.navigation(selection))
    }

    func requestRecordSelection(_ selection: Set<UUID>) {
        guard selection != selectedRecordIDs else { return }
        prepare(.recordSelection(selection))
    }

    func requestAppFilter(_ bundleID: String?) {
        guard bundleID != selectedAppFilter else { return }
        prepare(.appFilter(bundleID))
    }

    func requestTimeRange(_ range: HistoryTimeRange) {
        guard range != selectedTimeRange else { return }
        prepare(.timeRange(range))
    }

    func requestSortOrder(_ order: HistorySortOrder) {
        guard order != selectedSortOrder else { return }
        selectedSortOrder = order
        reloadCurrentQuery()
    }

    func requestClearAllFilters() {
        guard hasActiveFilters || !searchQuery.isEmpty else { return }
        prepare(.clearFilters)
    }

    func requestDeletion(of ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        prepare(.deletion(ids))
    }

    func consumePendingDeletion() {
        pendingDeletionIDs = []
    }

    func requestWindowClose() {
        prepare(.closeWindow)
    }

    func installCloseWindowHandler(_ handler: @escaping () -> Void) {
        closeWindowHandler = handler
    }

    func saveAndContinue() {
        guard canSaveDraft, saveEditing() else { return }
        continuePendingTransition()
    }

    func discardAndContinue() {
        discardEditing()
        continuePendingTransition()
    }

    func cancelPendingTransition() {
        pendingTransition = nil
        objectWillChange.send()
    }

    func clearAllFilters() {
        selectedAppFilter = nil
        selectedTimeRange = .all
        searchQuery = ""
        reloadCurrentQuery()
    }

    func selectRecord(_ record: TranscriptionRecord?) {
        requestRecordSelection(record.map { [$0.id] } ?? [])
    }

    func startEditing() {
        loadDraftForCurrentSelection(force: true)
    }

    @discardableResult
    func saveEditing() -> Bool {
        guard let record = selectedRecord, canSaveDraft else { return false }
        let originalText = originalDraftText
        let newText = editedText.trimmingCharacters(in: .whitespacesAndNewlines)

        historyService.updateRecord(record, finalText: newText)
        editedText = newText
        originalDraftText = newText
        detailViewMode = .final
        reloadDeferredQueryIfNeeded()

        let suggestions = textDiffService.extractCorrections(original: originalText, edited: newText)
        guard !suggestions.isEmpty else {
            showCorrectionBanner = false
            correctionSuggestions = []
            return true
        }
        dictionaryService.learnCorrections(suggestions)
        correctionSuggestions = suggestions
        showCorrectionBanner = true
        ServiceContainer.shared.memoryService.storeCorrections(
            suggestions.map { (original: $0.original, replacement: $0.replacement) },
            appName: record.appName,
            bundleIdentifier: record.appBundleIdentifier
        )
        return true
    }

    func cancelEditing() {
        discardEditing()
    }

    func discardEditing() {
        editedText = originalDraftText
        showCorrectionBanner = false
        correctionSuggestions = []
        reloadDeferredQueryIfNeeded()
    }

    func markComplete(_ records: [TranscriptionRecord]) {
        historyService.completeInbox(records)
    }

    func reopen(_ records: [TranscriptionRecord]) {
        historyService.reopenInbox(records)
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        deleteRecords([record])
    }

    func deleteRecords(_ records: [TranscriptionRecord]) {
        selectedRecordIDs.subtract(records.map(\.id))
        historyService.deleteRecords(records)
    }

    func deleteSelectedRecords() {
        let selected = selectedRecords
        selectedRecordIDs = []
        historyService.deleteRecords(selected)
    }

    func clearAll() {
        selectedRecordIDs = []
        historyService.clearAll()
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copySelectedRecords() {
        copyToClipboard(selectedRecords.map(\.displayText).joined(separator: "\n\n"))
    }

    func exportRecord(_ record: TranscriptionRecord, format: HistoryExportFormat) {
        exportRecords([record], format: format)
    }

    func exportRecords(_ records: [TranscriptionRecord], format: HistoryExportFormat) {
        guard !records.isEmpty else { return }
        if records.count == 1, let record = records.first {
            HistoryExporter.saveToFile(record, format: format)
        } else {
            HistoryExporter.saveMultipleToFile(records, format: format)
        }
    }

    func exportSelectedRecords(format: HistoryExportFormat) {
        let selected = selectedRecords
        guard !selected.isEmpty else { return }
        if selected.count == 1, let record = selected.first {
            HistoryExporter.saveToFile(record, format: format)
        } else {
            HistoryExporter.saveMultipleToFile(selected, format: format)
        }
    }

    func audioFileURL(for record: TranscriptionRecord) -> URL? {
        historyService.audioFileURL(for: record)
    }

    /// Returns the diff for the record's current texts from the cache. Small inputs are
    /// computed on demand; larger ones return `nil` until `loadDiffPresentation(for:)` finishes.
    func diffPresentation(for record: TranscriptionRecord) -> HistoryDiffPresentation? {
        let rawText = record.rawText
        let finalText = record.finalText
        if let cached = diffCache[record.id],
           cached.rawText == rawText,
           cached.finalText == finalText {
            return cached.presentation
        }
        guard rawText.utf8.count + finalText.utf8.count <= Self.inlineDiffInputLimit else { return nil }
        let presentation = Self.makeDiffPresentation(rawText: rawText, finalText: finalText, checkCancellation: {})
        cacheDiff(presentation, for: record.id, rawText: rawText, finalText: finalText)
        return presentation
    }

    /// Computes a missing diff off the main actor and publishes it once it is cached. The result
    /// is discarded when the caller was cancelled or the record's text changed in the meantime,
    /// so a superseded comparison cannot replace the diff of the current text.
    func loadDiffPresentation(for record: TranscriptionRecord) async {
        guard diffPresentation(for: record) == nil else { return }
        let recordID = record.id
        let rawText = record.rawText
        let finalText = record.finalText
        guard let presentation = await diffPresentationLoader(rawText, finalText),
              !Task.isCancelled,
              !record.isDeleted, record.modelContext != nil,
              record.rawText == rawText, record.finalText == finalText
        else { return }
        cacheDiff(presentation, for: recordID, rawText: rawText, finalText: finalText)
        objectWillChange.send()
    }

    /// Compares the texts on a detached task and forwards the caller's cancellation to it, so an
    /// obsolete comparison stops early instead of finishing the LCS table. Returns `nil` when the
    /// comparison was cancelled.
    static func computeDiffPresentationInBackground(
        rawText: String,
        finalText: String
    ) async -> HistoryDiffPresentation? {
        let comparison = Task.detached(priority: .userInitiated) {
            try HistoryViewModel.makeDiffPresentation(rawText: rawText, finalText: finalText) {
                try Task.checkCancellation()
            }
        }
        return await withTaskCancellationHandler {
            try? await comparison.value
        } onCancel: {
            comparison.cancel()
        }
    }

    func dismissCorrectionBanner() {
        showCorrectionBanner = false
        correctionSuggestions = []
    }

    static func applyFilters(
        records: [TranscriptionRecord],
        query: String,
        appFilter: String?,
        timeRange: HistoryTimeRange,
        collectionScope: HistoryCollectionScope,
        sourceScope: HistorySourceScope?,
        sortOrder: HistorySortOrder
    ) -> [TranscriptionRecord] {
        var result = applyCollectionScope(collectionScope, to: records)
        if let sourceScope {
            result = result.filter { sourceScope.contains($0.source) }
        }
        return applyCommonFilters(
            to: result,
            query: query,
            appFilter: appFilter,
            timeRange: timeRange,
            sortOrder: sortOrder
        )
    }

    static func computeSections(_ records: [TranscriptionRecord]) -> [HistorySection] {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
        var buckets: [HistoryDateGroup: [TranscriptionRecord]] = [:]

        for record in records {
            let group: HistoryDateGroup
            if record.timestamp >= todayStart { group = .today }
            else if record.timestamp >= yesterdayStart { group = .yesterday }
            else if record.timestamp >= weekStart { group = .thisWeek }
            else if record.timestamp >= monthStart { group = .thisMonth }
            else { group = .older }
            buckets[group, default: []].append(record)
        }
        return HistoryDateGroup.allCases.compactMap { group in
            guard let records = buckets[group], !records.isEmpty else { return nil }
            return HistorySection(group: group, records: records)
        }
    }

    static func computeDeviceSections(
        records: [TranscriptionRecord],
        devices: [CloudFolderSyncDeviceRecord],
        currentDeviceID: String?
    ) -> [HistoryDeviceSection] {
        struct Key: Hashable {
            let deviceID: String
            let platform: String
            let source: RecordingSource
        }
        var counts: [Key: Int] = [:]
        for record in records {
            let key = Key(
                deviceID: deviceIdentity(for: record, currentDeviceID: currentDeviceID),
                platform: record.originPlatformRaw,
                source: record.source
            )
            counts[key, default: 0] += 1
        }
        return computeDeviceSections(
            facets: counts.map {
                HistoryDeviceFacet(
                    deviceID: $0.key.deviceID,
                    platform: $0.key.platform,
                    source: $0.key.source,
                    count: $0.value
                )
            },
            devices: devices,
            currentDeviceID: currentDeviceID
        )
    }

    static func computeDeviceSections(
        facets: [HistoryDeviceFacet],
        devices: [CloudFolderSyncDeviceRecord],
        currentDeviceID: String?
    ) -> [HistoryDeviceSection] {
        struct Accumulator {
            var metadata: CloudFolderSyncDeviceRecord?
            var platform: String
            var sourceCounts: [RecordingSource: Int]
        }

        var grouped: [String: Accumulator] = [:]
        for device in devices {
            let id = deviceIdentity(
                historyOriginDeviceID: device.historyOriginDeviceID,
                platform: device.platform,
                currentDeviceID: currentDeviceID
            )
            let previous = grouped[id]
            if let existing = previous?.metadata, existing.updatedAt >= device.updatedAt {
                continue
            }
            grouped[id] = Accumulator(
                metadata: device,
                platform: device.platform,
                sourceCounts: previous?.sourceCounts ?? [:]
            )
        }

        for facet in facets {
            var accumulator = grouped[facet.deviceID] ?? Accumulator(
                metadata: nil,
                platform: facet.platform,
                sourceCounts: [:]
            )
            accumulator.sourceCounts[facet.source, default: 0] += facet.count
            if accumulator.platform.isEmpty {
                accumulator.platform = facet.platform
            }
            grouped[facet.deviceID] = accumulator
        }

        if let currentDeviceID, grouped[currentDeviceID] == nil {
            grouped[currentDeviceID] = Accumulator(
                metadata: nil,
                platform: "macOS",
                sourceCounts: [:]
            )
        }

        let sourceOrder: [RecordingSource] = [
            .mac, .iPhone, .iPad, .appleWatch, .keyboard, .shortcut, .importedFile, .other,
        ]
        return grouped.map { id, accumulator in
            let isCurrent = id == currentDeviceID
            let sources = sourceOrder.compactMap { source -> HistoryDeviceSourceSection? in
                guard let count = accumulator.sourceCounts[source], count > 0 else { return nil }
                return HistoryDeviceSourceSection(
                    source: source,
                    title: sourceTitle(source),
                    systemImage: sourceSystemImage(source),
                    count: count
                )
            }
            let title = accumulator.metadata?.name.flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? fallbackDeviceTitle(platform: accumulator.platform, isCurrent: isCurrent)
            return HistoryDeviceSection(
                id: id,
                title: title,
                platform: accumulator.platform,
                systemImage: deviceSystemImage(platform: accumulator.platform),
                isCurrent: isCurrent,
                count: accumulator.sourceCounts.values.reduce(0, +),
                sources: sources
            )
        }
        .sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var currentQuery: HistoryQuery {
        let sortOrder: HistoryQuery.SortOrder = switch selectedSortOrder {
        case .newest: .newest
        case .oldest: .oldest
        case .duration: .duration
        case .appName: .appName
        }
        var query = HistoryQuery(
            searchText: searchQuery,
            appBundleIdentifier: selectedAppFilter,
            cutoffDate: selectedTimeRange.cutoffDate,
            collection: .all,
            sortOrder: sortOrder
        )

        switch navigationSelection {
        case .smartMailbox(let scope):
            query.collection = switch scope {
            case .inbox: .inbox
            case .all: .all
            case .withAudio: .withAudio
            case .failed: .failed
            }
        case .device(let deviceID):
            query.originDeviceID = deviceID
            query.includeLegacyCurrentMacRecords = deviceID == currentDeviceID
        case .deviceSource(let deviceID, let source):
            query.originDeviceID = deviceID
            query.includeLegacyCurrentMacRecords = deviceID == currentDeviceID
            query.source = source
        }
        return query
    }

    private func reloadCurrentQuery(
        preservingLoadedRecords: Bool = false,
        resetListIdentity: Bool = true
    ) {
        guard !isDirty else {
            deferReload(preservingLoadedRecords: preservingLoadedRecords, resetListIdentity: resetListIdentity)
            return
        }
        deferredReload = nil
        queryGeneration &+= 1
        queryTask?.cancel()
        queryTask = nil
        loadMoreAfterQuery = false
        if isLoadingMore { isLoadingMore = false }

        let limit: Int
        if isActive {
            limit = preservingLoadedRecords ? max(records.count, Self.pageSize) : Self.pageSize
        } else {
            limit = HistoryService.recentRecordsLimit
        }
        let query = currentQuery
        guard query.requiresPostFiltering else {
            applyReloadedPage(
                historyService.fetchPage(query: query, offset: 0, limit: limit),
                resetListIdentity: resetListIdentity
            )
            return
        }

        // Free-text search and device, app, time, or source filters scan the complete history,
        // so they run off the main actor. The result is dropped when a newer query or
        // deactivation supersedes it, and deferred while the draft has unsaved changes.
        let generation = queryGeneration
        let loader = backgroundPageLoader
        queryTask = startTrackedTask { [weak self] in
            let page = await loader(query, 0, limit)
            guard let self, generation == self.queryGeneration else { return }
            self.queryTask = nil
            guard let page, !self.isDirty else {
                self.loadMoreAfterQuery = false
                if page != nil {
                    self.deferReload(
                        preservingLoadedRecords: preservingLoadedRecords,
                        resetListIdentity: resetListIdentity
                    )
                }
                return
            }
            self.applyReloadedPage(page, resetListIdentity: resetListIdentity)
            if self.loadMoreAfterQuery {
                self.loadMoreAfterQuery = false
                self.loadMoreRecords()
            }
        }
    }

    private func deferReload(preservingLoadedRecords: Bool, resetListIdentity: Bool) {
        let pending = deferredReload
        deferredReload = (
            preservingLoadedRecords: (pending?.preservingLoadedRecords ?? true) && preservingLoadedRecords,
            resetListIdentity: (pending?.resetListIdentity ?? false) || resetListIdentity
        )
    }

    /// Runs the reload that the unsaved draft held back, now that the draft is clean again.
    private func reloadDeferredQueryIfNeeded() {
        guard let pending = deferredReload, !isDirty else { return }
        reloadCurrentQuery(
            preservingLoadedRecords: pending.preservingLoadedRecords,
            resetListIdentity: pending.resetListIdentity
        )
    }

    private func applyReloadedPage(_ page: HistoryPage, resetListIdentity: Bool) {
        records = page.records
        totalMatchingRecordCount = page.totalCount
        hasMoreRecords = page.hasMore
        if resetListIdentity {
            queryID = UUID()
        }
        recomputeVisibleRecords()
    }

    private func appendPage(_ page: HistoryPage) {
        let existingIDs = Set(records.map(\.id))
        records.append(contentsOf: page.records.filter { !existingIDs.contains($0.id) })
        totalMatchingRecordCount = page.totalCount
        hasMoreRecords = page.hasMore
        recomputeVisibleRecords()
    }

    private func refreshFacets() {
        guard isActive else { return }
        facetsGeneration &+= 1
        let generation = facetsGeneration
        facetsTask?.cancel()
        let historyService = historyService
        let currentDeviceID = currentDeviceID
        facetsTask = startTrackedTask { [weak self] in
            let facets = await historyService.facetsInBackground(currentDeviceID: currentDeviceID)
            guard let self, generation == self.facetsGeneration else { return }
            self.facetsTask = nil
            guard let facets, self.isActive else { return }
            self.applyFacets(facets)
        }
    }

    private func applyFacets(_ facets: HistoryFacets) {
        inboxCount = facets.inboxCount
        audioCount = facets.audioCount
        failedCount = facets.failedCount
        availableApps = facets.apps
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map { AppEntry(bundleId: $0.bundleID, name: $0.name) }
        facetDevices = facets.devices
        recomputeDeviceSections(facets: facetDevices, devices: devices)
    }

    private func setupBindings() {
        historyService.$recentRecords
            .dropFirst()
            .sink { [weak self] recentRecords in
                guard let self else { return }
                if self.isActive {
                    self.removeDetachedRecords()
                    self.scheduleHistoryRefresh()
                } else {
                    self.records = recentRecords
                    self.totalMatchingRecordCount = self.historyService.totalRecords
                    self.hasMoreRecords = recentRecords.count < self.totalMatchingRecordCount
                    self.recomputeVisibleRecords()
                }
            }
            .store(in: &cancellables)

        $searchQuery
            .dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadCurrentQuery() }
            .store(in: &cancellables)

        $collapsedGroups
            .dropFirst()
            .sink { [weak self] groups in
                guard let self else { return }
                self.syncSelection(withVisibleRecordIDs: Self.visibleRecordIDs(
                    sections: self.groupedSections,
                    collapsedGroups: groups
                ))
            }
            .store(in: &cancellables)

        syncController?.$devices
            .sink { [weak self] devices in
                guard let self else { return }
                self.devices = devices
                self.recomputeDeviceSections(facets: self.facetDevices, devices: devices)
            }
            .store(in: &cancellables)
    }

    /// Dictation, inbox changes, and sync can publish in quick succession. Coalesce them into
    /// one query reload and one facet scan instead of full-history scans for every publish.
    private func scheduleHistoryRefresh() {
        guard pendingHistoryRefresh == nil else { return }
        let delay = historyRefreshDelay
        pendingHistoryRefresh = startTrackedTask { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.pendingHistoryRefresh = nil
            guard self.isActive else { return }
            self.reloadCurrentQuery(preservingLoadedRecords: true, resetListIdentity: false)
            self.refreshFacets()
        }
    }

    /// Deleted records must leave the list immediately rather than after the coalesced reload,
    /// because rendering a deleted model can fault on data that no longer exists.
    private func removeDetachedRecords() {
        let attached = records.filter { !$0.isDeleted && $0.modelContext != nil }
        guard attached.count != records.count else { return }
        totalMatchingRecordCount = max(0, totalMatchingRecordCount - (records.count - attached.count))
        records = attached
        recomputeVisibleRecords()
    }

    private func cancelPendingQueryWork() {
        deferredReload = nil
        queryGeneration &+= 1
        queryTask?.cancel()
        queryTask = nil
        loadMoreAfterQuery = false
        if isLoadingMore { isLoadingMore = false }
        facetsGeneration &+= 1
        facetsTask?.cancel()
        facetsTask = nil
        pendingHistoryRefresh?.cancel()
        pendingHistoryRefresh = nil
    }

    @discardableResult
    private func startTrackedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            self?.pendingWork[id] = nil
        }
        pendingWork[id] = task
        return task
    }

    nonisolated private static func makeDiffPresentation(
        rawText: String,
        finalText: String,
        checkCancellation: () throws -> Void
    ) rethrows -> HistoryDiffPresentation {
        guard let segments = try TextDiffService.wordDiff(
            original: rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            processed: finalText,
            maxComparisonCells: maxDiffComparisonCells,
            checkCancellation: checkCancellation
        ) else {
            return .tooLarge
        }
        return .segments(segments)
    }

    private func cacheDiff(
        _ presentation: HistoryDiffPresentation,
        for recordID: UUID,
        rawText: String,
        finalText: String
    ) {
        let entry = CachedDiff(rawText: rawText, finalText: finalText, presentation: presentation)
        guard diffCache.updateValue(entry, forKey: recordID) == nil else { return }
        diffCacheOrder.append(recordID)
        if diffCacheOrder.count > Self.diffCacheLimit {
            diffCache.removeValue(forKey: diffCacheOrder.removeFirst())
        }
    }

    private func recomputeDeviceSections(
        facets: [HistoryDeviceFacet],
        devices: [CloudFolderSyncDeviceRecord]
    ) {
        deviceSections = Self.computeDeviceSections(
            facets: facets,
            devices: devices,
            currentDeviceID: currentDeviceID
        )
        initializeDeviceExpansionIfNeeded()
    }

    private func initializeDeviceExpansionIfNeeded() {
        guard !didInitializeDeviceExpansion else { return }
        if let current = deviceSections.first(where: \.isCurrent) {
            expandedDeviceIDs.insert(current.id)
            didInitializeDeviceExpansion = true
        } else if !deviceSections.isEmpty {
            didInitializeDeviceExpansion = true
        }
    }

    private func recomputeVisibleRecords() {
        let sections = Self.computeSections(records)
        if !isDirty {
            syncSelection(withVisibleRecordIDs: Self.visibleRecordIDs(
                sections: sections,
                collapsedGroups: collapsedGroups
            ))
        }
        filteredRecords = records
        groupedSections = sections
        visibleRecordCount = records.count
        visibleWordCount = records.reduce(0) { $0 + $1.wordsCount }
    }

    private func prepare(_ transition: PendingHistoryTransition) {
        if isDirty {
            pendingTransition = transition
            objectWillChange.send()
        } else {
            execute(transition)
        }
    }

    private func continuePendingTransition() {
        guard let transition = pendingTransition else { return }
        pendingTransition = nil
        execute(transition)
    }

    private func execute(_ transition: PendingHistoryTransition) {
        switch transition {
        case .recordSelection(let selection):
            detailViewMode = .final
            audioPlaybackService.stop()
            selectedRecordIDs = selection
        case .navigation(let selection):
            navigationSelection = selection
            reloadCurrentQuery()
        case .appFilter(let bundleID):
            selectedAppFilter = bundleID
            reloadCurrentQuery()
        case .timeRange(let range):
            selectedTimeRange = range
            reloadCurrentQuery()
        case .clearFilters:
            clearAllFilters()
        case .deletion(let ids):
            pendingDeletionIDs = ids
        case .closeWindow:
            closeWindowHandler?()
        }
    }

    private func loadDraftForCurrentSelection(force: Bool = false) {
        let record = selectedRecord
        guard force || record?.id != draftRecordID else { return }
        draftRecordID = record?.id
        originalDraftText = record?.finalText ?? ""
        editedText = originalDraftText
        detailViewMode = .final
        showCorrectionBanner = false
        correctionSuggestions = []
    }

    private static func applyCollectionScope(
        _ scope: HistoryCollectionScope,
        to records: [TranscriptionRecord]
    ) -> [TranscriptionRecord] {
        switch scope {
        case .inbox: records.filter(\.isOpenInInbox)
        case .all: records
        case .withAudio: records.filter(Self.hasAudio)
        case .failed: records.filter { $0.processingState == .failed }
        }
    }

    private static func applyCommonFilters(
        to records: [TranscriptionRecord],
        query: String,
        appFilter: String?,
        timeRange: HistoryTimeRange,
        sortOrder: HistorySortOrder
    ) -> [TranscriptionRecord] {
        var result = records
        if let cutoff = timeRange.cutoffDate {
            result = result.filter { $0.timestamp >= cutoff }
        }
        if let appFilter {
            result = result.filter { $0.appBundleIdentifier == appFilter }
        }
        if !query.isEmpty {
            let lowered = query.lowercased()
            result = result.filter {
                $0.rawText.lowercased().contains(lowered)
                    || $0.finalText.lowercased().contains(lowered)
                    || ($0.renderedDocument?.lowercased().contains(lowered) ?? false)
                    || ($0.appName?.lowercased().contains(lowered) ?? false)
                    || ($0.appDomain?.lowercased().contains(lowered) ?? false)
                    || $0.source.displayName.lowercased().contains(lowered)
            }
        }

        switch sortOrder {
        case .newest: result.sort { $0.timestamp > $1.timestamp }
        case .oldest: result.sort { $0.timestamp < $1.timestamp }
        case .duration: result.sort { $0.durationSeconds > $1.durationSeconds }
        case .appName:
            result.sort {
                ($0.appName ?? "").localizedCaseInsensitiveCompare($1.appName ?? "") == .orderedAscending
            }
        }
        return result
    }

    private static func hasAudio(_ record: TranscriptionRecord) -> Bool {
        record.audioFileName != nil || record.hasRemoteAudio
    }

    private static func visibleRecordIDs(
        sections: [HistorySection],
        collapsedGroups: Set<HistoryDateGroup>
    ) -> Set<UUID> {
        Set(sections
            .filter { !collapsedGroups.contains($0.group) }
            .flatMap(\.records)
            .map(\.id))
    }

    private static func computeAvailableApps(_ records: [TranscriptionRecord]) -> [AppEntry] {
        var counts: [String: (name: String, count: Int)] = [:]
        for record in records {
            guard let bundleID = record.appBundleIdentifier,
                  let name = record.appName else { continue }
            counts[bundleID, default: (name: name, count: 0)].count += 1
        }
        return counts.sorted { $0.value.count > $1.value.count }
            .map { AppEntry(bundleId: $0.key, name: $0.value.name) }
    }

    private static func deviceIdentity(
        for record: TranscriptionRecord,
        currentDeviceID: String?
    ) -> String {
        deviceIdentity(
            historyOriginDeviceID: record.originDeviceID,
            platform: record.originPlatformRaw,
            currentDeviceID: currentDeviceID
        )
    }

    private static func deviceIdentity(
        historyOriginDeviceID: String?,
        platform: String,
        currentDeviceID: String?
    ) -> String {
        if let historyOriginDeviceID {
            let trimmed = historyOriginDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let normalized = platform.lowercased()
        if normalized.contains("mac"), let currentDeviceID {
            return currentDeviceID
        }
        return "platform:\(normalized.isEmpty ? "unknown" : normalized)"
    }

    private static func fallbackDeviceTitle(platform: String, isCurrent: Bool) -> String {
        if isCurrent { return String(localized: "This Mac") }
        let normalized = platform.lowercased()
        if normalized.contains("ipad") { return String(localized: "iPad") }
        if normalized.contains("ios") || normalized.contains("iphone") || normalized.contains("watch") {
            return String(localized: "iPhone")
        }
        if normalized.contains("mac") { return String(localized: "Mac") }
        return String(localized: "Device")
    }

    private static func deviceSystemImage(platform: String) -> String {
        let normalized = platform.lowercased()
        if normalized.contains("ipad") { return "ipad" }
        if normalized.contains("ios") || normalized.contains("iphone") || normalized.contains("watch") {
            return "iphone"
        }
        if normalized.contains("mac") { return "macbook"
        }
        return "desktopcomputer"
    }

    private static func sourceTitle(_ source: RecordingSource) -> String {
        switch source {
        case .mac: String(localized: "Mac Dictation")
        case .iPhone: String(localized: "iPhone App")
        case .iPad: String(localized: "iPad App")
        case .appleWatch: String(localized: "Apple Watch")
        case .keyboard: String(localized: "iOS Keyboard")
        case .shortcut: String(localized: "Shortcuts")
        case .importedFile: String(localized: "Imported Files")
        case .other: String(localized: "Other")
        }
    }

    private static func sourceSystemImage(_ source: RecordingSource) -> String {
        switch source {
        case .mac: "waveform"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleWatch: "applewatch"
        case .keyboard: "keyboard"
        case .shortcut: "square.stack.3d.up"
        case .importedFile: "doc"
        case .other: "ellipsis.circle"
        }
    }

    private var visibleSelectedRecordIDs: Set<UUID> {
        selectedRecordIDs.intersection(visibleRecordIDs)
    }

    private var visibleRecordIDs: Set<UUID> {
        Self.visibleRecordIDs(sections: groupedSections, collapsedGroups: collapsedGroups)
    }

    private func syncSelection<S: Sequence>(withVisibleRecordIDs visibleRecordIDs: S) where S.Element == UUID {
        let visible = Set(visibleRecordIDs)
        let normalized = selectedRecordIDs.intersection(visible)
        guard normalized != selectedRecordIDs else { return }
        selectedRecordIDs = normalized
    }
}
