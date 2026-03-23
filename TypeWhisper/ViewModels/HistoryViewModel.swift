import Foundation
import Combine
import AppKit

// MARK: - Supporting Types

enum HistoryDateGroup: Int, CaseIterable, Identifiable {
    case today, yesterday, thisWeek, lastMonth, older

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .today: String(localized: "Today")
        case .yesterday: String(localized: "Yesterday")
        case .thisWeek: String(localized: "This Week")
        case .lastMonth: String(localized: "Last Month")
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

struct AppEntry: Identifiable, Hashable {
    let bundleId: String
    let name: String
    var id: String { bundleId }
}

// MARK: - ViewModel

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
    @Published var selectedRecordIDs: Set<UUID> = []
    @Published var searchQuery: String = ""
    @Published var isEditing: Bool = false
    @Published var editedText: String = ""
    @Published var correctionSuggestions: [CorrectionSuggestion] = []
    @Published var showCorrectionBanner: Bool = false

    let audioPlaybackService = AudioPlaybackService()

    // Filter state
    @Published var selectedAppFilter: String? = nil
    @Published var selectedTimeRange: HistoryTimeRange = .all
    @Published var collapsedGroups: Set<HistoryDateGroup> = []
    @Published var showDeleteAllVisibleConfirmation: Bool = false

    private let historyService: HistoryService
    private let textDiffService: TextDiffService
    private let dictionaryService: DictionaryService
    private var cancellables = Set<AnyCancellable>()

    init(historyService: HistoryService, textDiffService: TextDiffService, dictionaryService: DictionaryService) {
        self.historyService = historyService
        self.textDiffService = textDiffService
        self.dictionaryService = dictionaryService
        self.records = historyService.records
        // Compute initial values before Combine pipeline kicks in
        self.filteredRecords = historyService.records
        self.groupedSections = Self.computeSections(historyService.records)
        self.availableApps = Self.computeAvailableApps(historyService.records)
        self.visibleRecordCount = historyService.records.count
        self.visibleWordCount = historyService.records.reduce(0) { $0 + $1.wordsCount }
        setupBindings()
    }

    var hasVisibleSelection: Bool {
        !visibleSelectedRecordIDs.isEmpty
    }

    var selectedRecord: TranscriptionRecord? {
        guard visibleSelectedRecordIDs.count == 1, let firstID = visibleSelectedRecordIDs.first else {
            return nil
        }
        return records.first { $0.id == firstID }
    }

    var selectedRecords: [TranscriptionRecord] {
        let ids = visibleSelectedRecordIDs
        return records.filter { ids.contains($0.id) }
    }

    @Published private(set) var filteredRecords: [TranscriptionRecord] = []
    @Published private(set) var groupedSections: [HistorySection] = []
    @Published private(set) var availableApps: [AppEntry] = []

    var hasActiveFilters: Bool {
        selectedAppFilter != nil || selectedTimeRange != .all
    }

    var totalRecords: Int { historyService.totalRecords }
    var totalWords: Int { historyService.totalWords }
    var totalDuration: Double { historyService.totalDuration }

    @Published private(set) var visibleRecordCount: Int = 0
    @Published private(set) var visibleWordCount: Int = 0

    func toggleSection(_ group: HistoryDateGroup) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
            if let section = groupedSections.first(where: { $0.group == group }) {
                syncSelection(
                    withVisibleRecordIDs: visibleRecordIDs.subtracting(section.records.map(\.id))
                )
            }
            collapsedGroups.insert(group)
        }
    }

    func clearAllFilters() {
        selectedAppFilter = nil
        selectedTimeRange = .all
        searchQuery = ""
    }

    func selectRecord(_ record: TranscriptionRecord?) {
        cancelEditing()
        audioPlaybackService.stop()
        if let record {
            selectedRecordIDs = [record.id]
        } else {
            selectedRecordIDs = []
        }
    }

    func startEditing() {
        guard let record = selectedRecord else { return }
        editedText = record.finalText
        isEditing = true
        showCorrectionBanner = false
        correctionSuggestions = []
    }

    func saveEditing() {
        guard let record = selectedRecord, isEditing else { return }
        let originalText = record.finalText
        let newText = editedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newText.isEmpty, newText != originalText else {
            cancelEditing()
            return
        }

        historyService.updateRecord(record, finalText: newText)
        isEditing = false

        let suggestions = textDiffService.extractCorrections(original: originalText, edited: newText)
        if !suggestions.isEmpty {
            for suggestion in suggestions {
                dictionaryService.learnCorrection(original: suggestion.original, replacement: suggestion.replacement)
            }
            correctionSuggestions = suggestions
            showCorrectionBanner = true

            // Store corrections as memories
            ServiceContainer.shared.memoryService.storeCorrections(
                suggestions.map { (original: $0.original, replacement: $0.replacement) },
                appName: record.appName,
                bundleIdentifier: record.appBundleIdentifier
            )
        }
    }

    func cancelEditing() {
        isEditing = false
        editedText = ""
        showCorrectionBanner = false
        correctionSuggestions = []
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        selectedRecordIDs.remove(record.id)
        if selectedRecordIDs.isEmpty {
            cancelEditing()
        }
        historyService.deleteRecord(record)
    }

    func deleteSelectedRecords() {
        let toDelete = selectedRecords
        selectedRecordIDs = []
        cancelEditing()
        historyService.deleteRecords(toDelete)
    }

    func deleteAllVisible() {
        let toDelete = filteredRecords
        selectedRecordIDs = []
        cancelEditing()
        historyService.deleteRecords(toDelete)
    }

    func clearAll() {
        selectedRecordIDs = []
        cancelEditing()
        historyService.clearAll()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func exportRecord(_ record: TranscriptionRecord, format: HistoryExportFormat) {
        HistoryExporter.saveToFile(record, format: format)
    }

    func exportSelectedRecords(format: HistoryExportFormat) {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        if records.count == 1, let single = records.first {
            HistoryExporter.saveToFile(single, format: format)
        } else {
            HistoryExporter.saveMultipleToFile(records, format: format)
        }
    }

    func audioFileURL(for record: TranscriptionRecord) -> URL? {
        historyService.audioFileURL(for: record)
    }

    func dismissCorrectionBanner() {
        showCorrectionBanner = false
        correctionSuggestions = []
    }

    private func setupBindings() {
        historyService.$records
            .dropFirst()
            .sink { [weak self] records in
                DispatchQueue.main.async {
                    self?.records = records
                }
            }
            .store(in: &cancellables)

        // Cached filter pipeline - single computation per change
        Publishers.CombineLatest4($records, $searchQuery, $selectedAppFilter, $selectedTimeRange)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] records, query, appFilter, timeRange in
                guard let self else { return }
                let filtered = Self.applyFilters(records: records, query: query, appFilter: appFilter, timeRange: timeRange)
                let sections = Self.computeSections(filtered)
                let visibleRecordIDs = Self.visibleRecordIDs(sections: sections, collapsedGroups: self.collapsedGroups)
                self.syncSelection(withVisibleRecordIDs: visibleRecordIDs)
                self.filteredRecords = filtered
                self.groupedSections = sections
                self.visibleRecordCount = filtered.count
                self.visibleWordCount = filtered.reduce(0) { $0 + $1.wordsCount }
            }
            .store(in: &cancellables)

        $collapsedGroups
            .dropFirst()
            .sink { [weak self] collapsedGroups in
                guard let self else { return }
                let visibleRecordIDs = Self.visibleRecordIDs(sections: self.groupedSections, collapsedGroups: collapsedGroups)
                self.syncSelection(withVisibleRecordIDs: visibleRecordIDs)
            }
            .store(in: &cancellables)

        // availableApps only recomputed when records change
        $records
            .map { Self.computeAvailableApps($0) }
            .assign(to: &$availableApps)
    }

    // MARK: - Static Helpers

    private static func applyFilters(
        records: [TranscriptionRecord],
        query: String,
        appFilter: String?,
        timeRange: HistoryTimeRange
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
                $0.finalText.lowercased().contains(lowered)
                || ($0.appName?.lowercased().contains(lowered) ?? false)
                || ($0.appDomain?.lowercased().contains(lowered) ?? false)
            }
        }

        return result
    }

    private static func computeSections(_ records: [TranscriptionRecord]) -> [HistorySection] {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? todayStart

        var buckets: [HistoryDateGroup: [TranscriptionRecord]] = [:]
        for record in records {
            let group: HistoryDateGroup
            if record.timestamp >= todayStart { group = .today }
            else if record.timestamp >= yesterdayStart { group = .yesterday }
            else if record.timestamp >= weekStart { group = .thisWeek }
            else if record.timestamp >= monthStart { group = .lastMonth }
            else { group = .older }
            buckets[group, default: []].append(record)
        }
        return HistoryDateGroup.allCases.compactMap { group in
            guard let records = buckets[group], !records.isEmpty else { return nil }
            return HistorySection(group: group, records: records)
        }
    }

    private static func visibleRecordIDs(
        sections: [HistorySection],
        collapsedGroups: Set<HistoryDateGroup>
    ) -> Set<UUID> {
        Set(
            sections
                .filter { !collapsedGroups.contains($0.group) }
                .flatMap(\.records)
                .map(\.id)
        )
    }

    private static func computeAvailableApps(_ records: [TranscriptionRecord]) -> [AppEntry] {
        var counts: [String: (name: String, count: Int)] = [:]
        for record in records {
            guard let bundleId = record.appBundleIdentifier,
                  let name = record.appName else { continue }
            counts[bundleId, default: (name: name, count: 0)].count += 1
        }
        return counts.sorted { $0.value.count > $1.value.count }
            .map { AppEntry(bundleId: $0.key, name: $0.value.name) }
    }

    private var visibleSelectedRecordIDs: Set<UUID> {
        selectedRecordIDs.intersection(visibleRecordIDs)
    }

    private var visibleRecordIDs: Set<UUID> {
        Self.visibleRecordIDs(sections: groupedSections, collapsedGroups: collapsedGroups)
    }

    private func syncSelection<S: Sequence>(withVisibleRecordIDs visibleRecordIDs: S) where S.Element == UUID {
        let visibleIDSet = Set(visibleRecordIDs)
        let previousSelectedRecordID = selectedRecordIDs.count == 1 ? selectedRecordIDs.first : nil
        let normalizedSelection = selectedRecordIDs.intersection(visibleIDSet)
        let normalizedSelectedRecordID = normalizedSelection.count == 1 ? normalizedSelection.first : nil

        guard normalizedSelection != selectedRecordIDs else {
            return
        }

        selectedRecordIDs = normalizedSelection

        if isEditing && normalizedSelectedRecordID != previousSelectedRecordID {
            cancelEditing()
        }
    }
}
