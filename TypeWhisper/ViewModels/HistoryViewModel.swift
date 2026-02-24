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

    static func group(for date: Date) -> HistoryDateGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let weekInterval = cal.dateInterval(of: .weekOfYear, for: Date()),
           date >= weekInterval.start { return .thisWeek }
        if let monthInterval = cal.dateInterval(of: .month, for: Date()),
           date >= monthInterval.start { return .lastMonth }
        return .older
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
        setupBindings()
    }

    var selectedRecord: TranscriptionRecord? {
        guard selectedRecordIDs.count == 1, let firstID = selectedRecordIDs.first else {
            return nil
        }
        return records.first { $0.id == firstID }
    }

    var selectedRecords: [TranscriptionRecord] {
        let ids = selectedRecordIDs
        return records.filter { ids.contains($0.id) }
    }

    var filteredRecords: [TranscriptionRecord] {
        var result = records

        // Time range filter
        if let cutoff = selectedTimeRange.cutoffDate {
            result = result.filter { $0.timestamp >= cutoff }
        }

        // App filter
        if let appFilter = selectedAppFilter {
            result = result.filter { $0.appBundleIdentifier == appFilter }
        }

        // Search query
        if !searchQuery.isEmpty {
            let lowered = searchQuery.lowercased()
            result = result.filter {
                $0.finalText.lowercased().contains(lowered)
                || ($0.appName?.lowercased().contains(lowered) ?? false)
                || ($0.appDomain?.lowercased().contains(lowered) ?? false)
            }
        }

        return result
    }

    var groupedSections: [HistorySection] {
        let filtered = filteredRecords
        var buckets: [HistoryDateGroup: [TranscriptionRecord]] = [:]
        for record in filtered {
            let group = HistoryDateGroup.group(for: record.timestamp)
            buckets[group, default: []].append(record)
        }
        return HistoryDateGroup.allCases.compactMap { group in
            guard let records = buckets[group], !records.isEmpty else { return nil }
            return HistorySection(group: group, records: records)
        }
    }

    var availableApps: [AppEntry] {
        var counts: [String: (name: String, count: Int)] = [:]
        for record in records {
            guard let bundleId = record.appBundleIdentifier,
                  let name = record.appName else { continue }
            counts[bundleId, default: (name: name, count: 0)].count += 1
        }
        return counts.sorted { $0.value.count > $1.value.count }
            .map { AppEntry(bundleId: $0.key, name: $0.value.name) }
    }

    var hasActiveFilters: Bool {
        selectedAppFilter != nil || selectedTimeRange != .all
    }

    var totalRecords: Int { historyService.totalRecords }
    var totalWords: Int { historyService.totalWords }
    var totalDuration: Double { historyService.totalDuration }

    var visibleRecordCount: Int { filteredRecords.count }
    var visibleWordCount: Int { filteredRecords.reduce(0) { $0 + $1.wordsCount } }

    func toggleSection(_ group: HistoryDateGroup) {
        if collapsedGroups.contains(group) {
            collapsedGroups.remove(group)
        } else {
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
    }
}
