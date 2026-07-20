import Foundation
import TypeWhisperPluginSDK

final class ContributorQueueStore: @unchecked Sendable {
    private static let privateDirectoryPermissions = 0o700
    private static let privateFilePermissions = 0o600

    private let rootDirectory: URL
    private let pendingDirectory: URL
    private let receiptsDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.pendingDirectory = rootDirectory.appendingPathComponent("pending", isDirectory: true)
        self.receiptsDirectory = rootDirectory.appendingPathComponent("receipts", isDirectory: true)
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadRecords() throws -> [ContributionRecord] {
        try lock.withLock {
            try ensureDirectories()
            let urls = try fileManager.contentsOfDirectory(
                at: pendingDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return try urls
                .filter { $0.pathExtension == "json" }
                .map { try decoder.decode(ContributionRecord.self, from: Data(contentsOf: $0)) }
                .sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    @discardableResult
    func insert(_ record: ContributionRecord) throws -> Bool {
        guard record.isValidCorrection else {
            throw ContributorQueueError.invalidCorrection
        }
        return try lock.withLock {
            try ensureDirectories()
            let destination = recordURL(record.id)
            guard !fileManager.fileExists(atPath: destination.path) else { return false }
            try writeSecurely(encoder.encode(record), to: destination)
            return true
        }
    }

    func upsert(_ record: ContributionRecord) throws {
        guard record.isValidCorrection else {
            throw ContributorQueueError.invalidCorrection
        }
        try lock.withLock {
            try ensureDirectories()
            try writeSecurely(encoder.encode(record), to: recordURL(record.id))
        }
    }

    func remove(_ id: UUID) throws {
        try lock.withLock {
            let url = recordURL(id)
            guard fileManager.fileExists(atPath: url.path) else { return }
            try fileManager.removeItem(at: url)
        }
    }

    func complete(_ record: ContributionRecord) throws {
        guard record.status.isTerminal else { return }
        try lock.withLock {
            try ensureDirectories()
            let receipt = ContributionReceipt(
                id: record.id,
                status: record.status,
                reasonCode: record.reasonCode,
                qualityCredit: record.qualityCredit,
                completedAt: Date()
            )
            try writeSecurely(
                encoder.encode(receipt),
                to: receiptsDirectory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")
            )
            let pendingURL = recordURL(record.id)
            if fileManager.fileExists(atPath: pendingURL.path) {
                try fileManager.removeItem(at: pendingURL)
            }
        }
    }

    private func ensureDirectories() throws {
        try secureDirectory(rootDirectory)
        try secureDirectory(pendingDirectory)
        try secureDirectory(receiptsDirectory)
        try secureExistingFiles(in: pendingDirectory)
        try secureExistingFiles(in: receiptsDirectory)
    }

    private func secureDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: Self.privateDirectoryPermissions],
            ofItemAtPath: directory.path
        )
    }

    private func writeSecurely(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: .atomic)
        try secureFile(destination)
    }

    private func secureExistingFiles(in directory: URL) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in urls where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            try secureFile(url)
        }
    }

    private func secureFile(_ file: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: Self.privateFilePermissions],
            ofItemAtPath: file.path
        )
    }

    private func recordURL(_ id: UUID) -> URL {
        pendingDirectory.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }
}

enum ContributorQueueError: LocalizedError {
    case invalidCorrection

    var errorDescription: String? {
        switch self {
        case .invalidCorrection:
            "The correction is incomplete or unchanged."
        }
    }
}
