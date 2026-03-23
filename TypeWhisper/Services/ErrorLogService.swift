import Foundation
import os.log

private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "ErrorLogService")

@MainActor
final class ErrorLogService: ObservableObject {
    @Published private(set) var entries: [ErrorLogEntry] = []

    private static let maxEntries = 200
    private let fileURL: URL

    init() {
        let dir = AppConstants.appSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("error-log.json")
        loadEntries()
    }

    func addEntry(message: String, category: String = "general") {
        let entry = ErrorLogEntry(message: message, category: category)
        entries.insert(entry, at: 0)

        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        saveEntries()
        logger.info("Error logged: [\(category)] \(message)")
    }

    func clearAll() {
        entries.removeAll()
        saveEntries()
    }

    private func loadEntries() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ErrorLogEntry].self, from: data) else { return }
        entries = decoded
    }

    private func saveEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
