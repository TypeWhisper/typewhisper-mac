import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "HistoryService")

@MainActor
final class HistoryService: ObservableObject {
    @Published var records: [TranscriptionRecord] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    private(set) var totalRecords: Int = 0
    private(set) var totalWords: Int = 0
    private(set) var totalDuration: Double = 0

    private let audioDirectory: URL

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        let schema = Schema([TranscriptionRecord.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let audioDir = storeDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        self.audioDirectory = audioDir

        let storeURL = storeDir.appendingPathComponent("history.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Incompatible schema — delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("history.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                fatalError("Failed to create history ModelContainer after reset: \(error)")
            }
        }
        modelContext = ModelContext(modelContainer)
        modelContext.autosaveEnabled = true

        fetchRecords()
    }

    func addRecord(
        rawText: String,
        finalText: String,
        appName: String?,
        appBundleIdentifier: String?,
        appURL: String? = nil,
        durationSeconds: Double,
        language: String?,
        engineUsed: String,
        modelUsed: String? = nil,
        audioSamples: [Float]? = nil
    ) {
        let sanitizedRaw = Self.sanitize(rawText)
        let sanitizedFinal = Self.sanitize(finalText)
        guard !sanitizedRaw.isEmpty, !sanitizedFinal.isEmpty else {
            logger.warning("Skipping history record: empty text after sanitization")
            return
        }
        guard durationSeconds.isFinite, durationSeconds >= 0 else {
            logger.warning("Skipping history record: invalid duration \(durationSeconds)")
            return
        }
        let recordId = UUID()
        var audioFileName: String?

        if let samples = audioSamples, !samples.isEmpty {
            let fileName = "\(recordId.uuidString).wav"
            let fileURL = audioDirectory.appendingPathComponent(fileName)
            let wavData = WavEncoder.encode(samples)
            do {
                try wavData.write(to: fileURL, options: .atomic)
                audioFileName = fileName
                logger.info("Saved audio file: \(fileName)")
            } catch {
                logger.error("Failed to save audio file: \(error.localizedDescription)")
            }
        }

        let record = TranscriptionRecord(
            id: recordId,
            rawText: sanitizedRaw,
            finalText: sanitizedFinal,
            appName: appName.flatMap { Self.sanitize($0).isEmpty ? nil : Self.sanitize($0) },
            appBundleIdentifier: appBundleIdentifier,
            appURL: appURL,
            durationSeconds: durationSeconds,
            language: language,
            engineUsed: engineUsed.isEmpty ? "unknown" : engineUsed,
            modelUsed: modelUsed,
            audioFileName: audioFileName
        )
        modelContext.insert(record)
        save()
        fetchRecords()
    }

    func audioFileURL(for record: TranscriptionRecord) -> URL? {
        guard let fileName = record.audioFileName else { return nil }
        let url = audioDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func updateRecord(_ record: TranscriptionRecord, finalText: String) {
        record.finalText = finalText
        record.wordsCount = finalText.split(separator: " ").count
        save()
        fetchRecords()
    }

    func deleteRecord(_ record: TranscriptionRecord) {
        deleteAudioFile(for: record)
        modelContext.delete(record)
        save()
        fetchRecords()
    }

    func deleteRecords(_ records: [TranscriptionRecord]) {
        for record in records {
            deleteAudioFile(for: record)
            modelContext.delete(record)
        }
        save()
        fetchRecords()
    }

    func clearAll() {
        for record in records {
            deleteAudioFile(for: record)
            modelContext.delete(record)
        }
        save()
        fetchRecords()
    }

    func searchRecords(query: String) -> [TranscriptionRecord] {
        guard !query.isEmpty else { return records }
        let lowered = query.lowercased()
        return records.filter {
            $0.finalText.lowercased().contains(lowered) ||
            ($0.appName?.lowercased().contains(lowered) ?? false)
        }
    }

    func uniqueDomains(limit: Int = 50) -> [String] {
        var counts: [String: Int] = [:]
        for record in records {
            guard let domain = record.appDomain else { continue }
            let cleaned = domain.hasPrefix("www.") ? String(domain.dropFirst(4)) : domain
            guard !cleaned.isEmpty else { continue }
            counts[cleaned, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    func purgeOldRecords(retentionDays: Int = 90) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let old = records.filter { $0.timestamp < cutoff }
        guard !old.isEmpty else { return }
        for record in old {
            deleteAudioFile(for: record)
            modelContext.delete(record)
        }
        save()
        fetchRecords()
    }

    private func fetchRecords() {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        do {
            records = try modelContext.fetch(descriptor)
        } catch {
            records = []
        }
        migrateWordsCountIfNeeded()
        updateAggregates()
    }

    private func migrateWordsCountIfNeeded() {
        var needsSave = false
        for record in records where record.wordsCount == 0 && !record.finalText.isEmpty {
            record.wordsCount = record.finalText.split(separator: " ").count
            needsSave = true
        }
        if needsSave {
            save()
        }
    }

    private func updateAggregates() {
        totalRecords = records.count
        totalWords = records.reduce(0) { $0 + $1.wordsCount }
        totalDuration = records.reduce(0) { $0 + $1.durationSeconds }
    }

    private func deleteAudioFile(for record: TranscriptionRecord) {
        guard let fileName = record.audioFileName else { return }
        let fileURL = audioDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Remove null bytes and other control characters that can crash CoreData/SQLite.
    private static func sanitize(_ string: String) -> String {
        string.unicodeScalars.filter { $0 != "\0" }.map(String.init).joined()
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Demo Data (DEBUG only)

    #if DEBUG
    func seedDemoData() {
        // Clear existing data first
        clearAll()

        let calendar = Calendar.current
        let now = Date()

        struct DemoEntry {
            let dayOffset: Int     // days ago
            let hourOffset: Int    // hour of day
            let rawText: String
            let finalText: String
            let appName: String
            let bundleId: String
            let appURL: String?
            let duration: Double
            let language: String
            let engine: String
        }

        let entries: [DemoEntry] = [
            // Today
            DemoEntry(dayOffset: 0, hourOffset: 10, rawText: "Quick note about the meeting tomorrow. Need to prepare slides for the product review.", finalText: "Quick note about the meeting tomorrow. Need to prepare slides for the product review.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 6.2, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 0, hourOffset: 11, rawText: "Fix the authentication bug in the login controller. The session token expires too early and users get logged out.", finalText: "Fix the authentication bug in the login controller. The session token expires too early and users get logged out.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 8.5, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 0, hourOffset: 14, rawText: "Hey team the new release is ready for testing. Please check the staging environment and report any issues.", finalText: "Hey team, the new release is ready for testing. Please check the staging environment and report any issues.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.8, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 0, hourOffset: 15, rawText: "The API response time improved from 250 milliseconds to 80 milliseconds after adding the Redis cache layer.", finalText: "The API response time improved from 250 milliseconds to 80 milliseconds after adding the Redis cache layer.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 8.1, language: "en", engine: "whisper"),

            // Yesterday
            DemoEntry(dayOffset: 1, hourOffset: 9, rawText: "Dear Sarah thanks for the feedback on the proposal. I've updated the budget section as discussed.", finalText: "Dear Sarah, thanks for the feedback on the proposal. I've updated the budget section as discussed.", appName: "Mail", bundleId: "com.apple.mail", appURL: nil, duration: 7.4, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 1, hourOffset: 10, rawText: "Add error handling for the API timeout scenario. Retry up to three times with exponential backoff.", finalText: "Add error handling for the API timeout scenario. Retry up to three times with exponential backoff.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 7.9, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 1, hourOffset: 13, rawText: "Heute Nachmittag Termin mit dem Kunden. Bitte Präsentation vorbereiten und die aktuellen Zahlen einbauen.", finalText: "Heute Nachmittag Termin mit dem Kunden. Bitte Präsentation vorbereiten und die aktuellen Zahlen einbauen.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 7.2, language: "de", engine: "whisper"),
            DemoEntry(dayOffset: 1, hourOffset: 15, rawText: "Review the pull request from Alex. Focus on the database migration and the new API endpoints.", finalText: "Review the pull request from Alex. Focus on the database migration and the new API endpoints.", appName: "Safari", bundleId: "com.apple.Safari", appURL: "https://github.com/pulls", duration: 7.0, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 1, hourOffset: 16, rawText: "Schedule the deployment for Friday at six PM. Make sure all tests pass before merging to main.", finalText: "Schedule the deployment for Friday at 6 PM. Make sure all tests pass before merging to main.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.5, language: "en", engine: "whisper"),

            // 2 days ago
            DemoEntry(dayOffset: 2, hourOffset: 9, rawText: "The quarterly report shows a fifteen percent increase in user engagement. Mobile sessions are up by twenty percent.", finalText: "The quarterly report shows a 15% increase in user engagement. Mobile sessions are up by 20%.", appName: "Pages", bundleId: "com.apple.iWork.Pages", appURL: nil, duration: 9.2, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 2, hourOffset: 11, rawText: "Update the README with the new installation instructions and system requirements for Apple Silicon.", finalText: "Update the README with the new installation instructions and system requirements for Apple Silicon.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 7.6, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 2, hourOffset: 14, rawText: "Implement the dark mode toggle. Use the system preference as default and allow manual override in settings.", finalText: "Implement the dark mode toggle. Use the system preference as default and allow manual override in settings.", appName: "Xcode", bundleId: "com.apple.dt.Xcode", appURL: nil, duration: 8.3, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 2, hourOffset: 16, rawText: "Hey everyone standup notes. Backend team completed the migration. Frontend is working on the redesign.", finalText: "Hey everyone, standup notes. Backend team completed the migration. Frontend is working on the redesign.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 8.0, language: "en", engine: "whisper"),

            // 3 days ago
            DemoEntry(dayOffset: 3, hourOffset: 10, rawText: "The performance tests show a thirty percent improvement after switching to the new caching strategy.", finalText: "The performance tests show a 30% improvement after switching to the new caching strategy.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 7.1, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 3, hourOffset: 11, rawText: "Write unit tests for the payment processing module. Cover edge cases like currency conversion and rounding.", finalText: "Write unit tests for the payment processing module. Cover edge cases like currency conversion and rounding.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 8.4, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 3, hourOffset: 14, rawText: "Lieber Herr Müller anbei finden Sie die aktualisierten Vertragsbedingungen. Bitte prüfen Sie die Änderungen.", finalText: "Lieber Herr Müller, anbei finden Sie die aktualisierten Vertragsbedingungen. Bitte prüfen Sie die Änderungen.", appName: "Mail", bundleId: "com.apple.mail", appURL: nil, duration: 8.8, language: "de", engine: "whisper"),
            DemoEntry(dayOffset: 3, hourOffset: 15, rawText: "Check the latest design mockups on Figma. The new dashboard layout needs feedback by end of day.", finalText: "Check the latest design mockups on Figma. The new dashboard layout needs feedback by end of day.", appName: "Arc", bundleId: "company.thebrowser.Browser", appURL: "https://figma.com/design", duration: 7.3, language: "en", engine: "parakeet"),

            // 4 days ago
            DemoEntry(dayOffset: 4, hourOffset: 9, rawText: "Meeting notes. Decided to postpone the launch by one week. Need more QA time for the payment flow.", finalText: "Meeting notes. Decided to postpone the launch by one week. Need more QA time for the payment flow.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 7.8, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 4, hourOffset: 11, rawText: "Refactor the networking layer to use async await instead of completion handlers. Start with the user service.", finalText: "Refactor the networking layer to use async/await instead of completion handlers. Start with the user service.", appName: "Xcode", bundleId: "com.apple.dt.Xcode", appURL: nil, duration: 8.6, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 4, hourOffset: 13, rawText: "The new onboarding flow increased conversion by eight percent compared to the previous version.", finalText: "The new onboarding flow increased conversion by 8% compared to the previous version.", appName: "Safari", bundleId: "com.apple.Safari", appURL: "https://analytics.google.com", duration: 6.9, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 4, hourOffset: 16, rawText: "Bitte den Entwurf für das Logo bis morgen fertigstellen. Die Farben sollten zum Branding passen.", finalText: "Bitte den Entwurf für das Logo bis morgen fertigstellen. Die Farben sollten zum Branding passen.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.1, language: "de", engine: "whisper"),

            // 5 days ago
            DemoEntry(dayOffset: 5, hourOffset: 9, rawText: "Good morning team. Today's priorities are bug fixes for the release candidate and documentation updates.", finalText: "Good morning team. Today's priorities are bug fixes for the release candidate and documentation updates.", appName: "Slack", bundleId: "com.tinyspeck.slackmacgap", appURL: nil, duration: 7.5, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 5, hourOffset: 11, rawText: "Add input validation for the registration form. Email format phone number and password strength.", finalText: "Add input validation for the registration form. Email format, phone number, and password strength.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 7.2, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 5, hourOffset: 14, rawText: "The user research report is ready. Key finding most users prefer keyboard shortcuts over menu navigation.", finalText: "The user research report is ready. Key finding: most users prefer keyboard shortcuts over menu navigation.", appName: "Notes", bundleId: "com.apple.Notes", appURL: nil, duration: 8.0, language: "en", engine: "whisper"),

            // 6 days ago
            DemoEntry(dayOffset: 6, hourOffset: 10, rawText: "Initialize the project with Swift Package Manager. Add dependencies for networking and JSON parsing.", finalText: "Initialize the project with Swift Package Manager. Add dependencies for networking and JSON parsing.", appName: "Terminal", bundleId: "com.apple.Terminal", appURL: nil, duration: 7.0, language: "en", engine: "parakeet"),
            DemoEntry(dayOffset: 6, hourOffset: 13, rawText: "Create the database schema for the user profiles. Include fields for name email preferences and avatar.", finalText: "Create the database schema for the user profiles. Include fields for name, email, preferences, and avatar.", appName: "Visual Studio Code", bundleId: "com.microsoft.VSCode", appURL: nil, duration: 8.2, language: "en", engine: "whisper"),
            DemoEntry(dayOffset: 6, hourOffset: 15, rawText: "Check the server logs for the memory leak. It seems to happen after about two hours of continuous use.", finalText: "Check the server logs for the memory leak. It seems to happen after about two hours of continuous use.", appName: "Terminal", bundleId: "com.apple.Terminal", appURL: nil, duration: 7.8, language: "en", engine: "parakeet"),
        ]

        for entry in entries {
            let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -entry.dayOffset, to: now)!)
            let timestamp = calendar.date(byAdding: .hour, value: entry.hourOffset, to: dayStart)!

            let record = TranscriptionRecord(
                timestamp: timestamp,
                rawText: entry.rawText,
                finalText: entry.finalText,
                appName: entry.appName,
                appBundleIdentifier: entry.bundleId,
                appURL: entry.appURL,
                durationSeconds: entry.duration,
                language: entry.language,
                engineUsed: entry.engine
            )
            modelContext.insert(record)
        }

        save()
        fetchRecords()
    }
    #endif
}
