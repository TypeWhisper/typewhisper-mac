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

    init(
        historyService: HistoryService,
        textDiffService: TextDiffService,
        dictionaryService: DictionaryService,
        syncController: CloudFolderSyncController? = nil
    ) {
        self.historyService = historyService
        self.textDiffService = textDiffService
        self.dictionaryService = dictionaryService
        self.syncController = syncController
        currentDeviceID = syncController?.historySyncPreferences?.deviceID
        records = historyService.records
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

    var totalRecords: Int { historyService.totalRecords }
    var totalWords: Int { historyService.totalWords }
    var totalDuration: Double { historyService.totalDuration }
    var inboxCount: Int { records.count(where: \.isOpenInInbox) }
    var audioCount: Int { records.count(where: Self.hasAudio) }
    var failedCount: Int { records.count { $0.processingState == .failed } }

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
        let entries = String.localizedStringWithFormat(
            String(localized: "%lld entries"),
            Int64(visibleRecordCount)
        )
        let words = String.localizedStringWithFormat(
            String(localized: "%lld words"),
            Int64(visibleWordCount)
        )
        return String.localizedStringWithFormat(
            String(localized: "%@, %@"),
            entries,
            words
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
        case .all: records.count
        case .withAudio: audioCount
        case .failed: failedCount
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
        recomputeVisibleRecords()
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
        recomputeVisibleRecords()
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
    }

    func markComplete(_ records: [TranscriptionRecord]) {
        for record in records where record.isOpenInInbox {
            historyService.completeInbox(record)
        }
    }

    func reopen(_ records: [TranscriptionRecord]) {
        for record in records where record.inboxState == .completed {
            historyService.reopenInbox(record)
        }
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

    func diffSegments(for record: TranscriptionRecord) -> [DiffSegment] {
        textDiffService.computeWordDiff(
            original: record.rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            processed: record.finalText
        )
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
        struct Accumulator {
            var metadata: CloudFolderSyncDeviceRecord?
            var platform: String
            var records: [TranscriptionRecord]
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
                records: previous?.records ?? []
            )
        }

        for record in records {
            let id = deviceIdentity(for: record, currentDeviceID: currentDeviceID)
            var accumulator = grouped[id] ?? Accumulator(
                metadata: nil,
                platform: record.originPlatformRaw,
                records: []
            )
            accumulator.records.append(record)
            if accumulator.platform.isEmpty {
                accumulator.platform = record.originPlatformRaw
            }
            grouped[id] = accumulator
        }

        if let currentDeviceID, grouped[currentDeviceID] == nil {
            grouped[currentDeviceID] = Accumulator(
                metadata: nil,
                platform: "macOS",
                records: []
            )
        }

        let sourceOrder: [RecordingSource] = [
            .mac, .iPhone, .iPad, .appleWatch, .keyboard, .shortcut, .importedFile, .other,
        ]
        return grouped.map { id, accumulator in
            let isCurrent = id == currentDeviceID
            let counts = Dictionary(grouping: accumulator.records, by: \.source).mapValues(\.count)
            let sources = sourceOrder.compactMap { source -> HistoryDeviceSourceSection? in
                guard let count = counts[source], count > 0 else { return nil }
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
                count: accumulator.records.count,
                sources: sources
            )
        }
        .sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func setupBindings() {
        historyService.$records
            .dropFirst()
            .sink { [weak self] records in self?.records = records }
            .store(in: &cancellables)

        let deferredTriggers: [AnyPublisher<Void, Never>] = [
            $searchQuery.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            $records.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(deferredTriggers)
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeVisibleRecords() }
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

        $records
            .map(Self.computeAvailableApps)
            .assign(to: &$availableApps)

        $records
            .sink { [weak self] records in
                guard let self else { return }
                self.recomputeDeviceSections(records: records, devices: self.devices)
            }
            .store(in: &cancellables)

        syncController?.$devices
            .sink { [weak self] devices in
                guard let self else { return }
                self.devices = devices
                self.recomputeDeviceSections(records: self.records, devices: devices)
            }
            .store(in: &cancellables)
    }

    private func recomputeDeviceSections(
        records: [TranscriptionRecord],
        devices: [CloudFolderSyncDeviceRecord]
    ) {
        deviceSections = Self.computeDeviceSections(
            records: records,
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
        var scoped = records
        switch navigationSelection {
        case .smartMailbox(let scope):
            scoped = Self.applyCollectionScope(scope, to: scoped)
        case .device(let id):
            scoped = scoped.filter {
                Self.deviceIdentity(for: $0, currentDeviceID: currentDeviceID) == id
            }
        case .deviceSource(let id, let source):
            scoped = scoped.filter {
                Self.deviceIdentity(for: $0, currentDeviceID: currentDeviceID) == id
                    && $0.source == source
            }
        }
        let filtered = Self.applyCommonFilters(
            to: scoped,
            query: searchQuery,
            appFilter: selectedAppFilter,
            timeRange: selectedTimeRange,
            sortOrder: selectedSortOrder
        )
        let sections = Self.computeSections(filtered)
        if !isDirty {
            syncSelection(withVisibleRecordIDs: Self.visibleRecordIDs(
                sections: sections,
                collapsedGroups: collapsedGroups
            ))
        }
        filteredRecords = filtered
        groupedSections = sections
        visibleRecordCount = filtered.count
        visibleWordCount = filtered.reduce(0) { $0 + $1.wordsCount }
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
            recomputeVisibleRecords()
        case .appFilter(let bundleID):
            selectedAppFilter = bundleID
            recomputeVisibleRecords()
        case .timeRange(let range):
            selectedTimeRange = range
            recomputeVisibleRecords()
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
