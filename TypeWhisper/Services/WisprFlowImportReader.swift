import CryptoKit
import Foundation
import SQLite3

/// Never opens SQLite in the source directory. Main and WAL are copied and hash-verified first.
enum WisprFlowImportReader {
    private static let maximumBytes = 2 * 1024 * 1024 * 1024
    private static let suffixes = ["", "-wal", "-shm", "-journal"]

    private struct Part: Equatable {
        let size: Int
        let modified: Date
        let inode: UInt64
        let digest: Data
    }

    static func read(
        url: URL,
        destination: AppVocabularyImport.Destination,
        scratchParent: URL = FileManager.default.temporaryDirectory,
        afterCopy: (() throws -> Void)? = nil
    ) throws -> AppVocabularyImport.Batch {
        let fm = FileManager.default
        let scratch = scratchParent.appendingPathComponent("typewhisper-import-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }

        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let before = try parts(url)
                let directory = scratch.appendingPathComponent(String(attempt))
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
                let copy = directory.appendingPathComponent("flow.sqlite")
                for suffix in ["", "-wal"] where before[suffix] != nil {
                    try copyFile(from: URL(fileURLWithPath: url.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
                }
                try afterCopy?()
                let after = try parts(url)
                guard before == after else { continue }
                for suffix in ["", "-wal"] where before[suffix] != nil {
                    guard try digest(URL(fileURLWithPath: copy.path + suffix)) == before[suffix]?.digest else {
                        throw AppVocabularyImportError.unstableSource
                    }
                }
                return try query(copy, destination: destination)
            } catch AppVocabularyImportError.tooLarge {
                throw AppVocabularyImportError.tooLarge
            } catch AppVocabularyImportError.invalidFormat {
                throw AppVocabularyImportError.invalidFormat
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Retry torn snapshots, unreadable files and invalid database generations.
            }
        }
        throw AppVocabularyImportError.unstableSource
    }

    private static func parts(_ url: URL) throws -> [String: Part] {
        var result: [String: Part] = [:]
        var total = 0
        for suffix in suffixes {
            let path = url.path + suffix
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError && !suffix.isEmpty {
                continue
            }
            guard suffix != "-journal", attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw AppVocabularyImportError.unstableSource
            }
            total += size.intValue
            guard total <= maximumBytes else { throw AppVocabularyImportError.tooLarge }
            result[suffix] = Part(size: size.intValue, modified: modified, inode: inode.uint64Value,
                                  digest: try digest(URL(fileURLWithPath: path)))
        }
        guard result[""] != nil else { throw AppVocabularyImportError.unstableSource }
        return result
    }

    private static func digest(_ url: URL) throws -> Data {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256(), total = 0
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            total += block.count
            guard total <= maximumBytes else { throw AppVocabularyImportError.tooLarge }
            hash.update(data: block)
        }
        return Data(hash.finalize())
    }

    private static func copyFile(from source: URL, to target: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppVocabularyImportError.unstableSource
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var total = 0
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            total += block.count
            guard total <= maximumBytes else { throw AppVocabularyImportError.tooLarge }
            try output.write(contentsOf: block)
        }
    }

    private static func query(_ url: URL, destination: AppVocabularyImport.Destination) throws -> AppVocabularyImport.Batch {
        var database: OpaquePointer?
        // A cleanly closed WAL database may have neither sidecar. SQLite must be able
        // to recreate them inside the private copy; READONLY fails with SQLITE_CANTOPEN.
        // No CREATE flag: a missing copied database is an error. Queries remain read-only.
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK, let database else { throw sqliteFailure(opened) }
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_000_000)
        let configured = sqlite3_exec(database, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;", nil, nil, nil)
        guard configured == SQLITE_OK else { throw sqliteFailure(configured) }
        var statement: OpaquePointer?
        let sql = "SELECT phrase, replacement, isDeleted, isSnippet FROM Dictionary ORDER BY id COLLATE BINARY ASC LIMIT \(AppVocabularyImport.maximumRows + 1)"
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw sqliteFailure(prepared) }
        defer { sqlite3_finalize(statement) }
        var batch = AppVocabularyImport.Batch(), count = 0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            count += 1
            guard count <= AppVocabularyImport.maximumRows else { throw AppVocabularyImportError.tooLarge }
            let original = try text(statement, column: 0, optional: false)!
            let replacement = try text(statement, column: 1, optional: true)
            let deleted = try boolean(statement, column: 2)
            let snippet = try boolean(statement, column: 3)
            if deleted || snippet != (destination == .snippets) {
                batch.excluded += 1
            } else if destination == .dictionary {
                AppVocabularyImport.appendWisprWord(original: original, replacement: replacement, to: &batch)
            } else {
                AppVocabularyImport.append(original: original, replacement: replacement, destination: destination, to: &batch)
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw sqliteFailure(status) }
        return batch
    }

    private static func sqliteFailure(_ status: Int32) -> AppVocabularyImportError {
        switch status & 0xFF {
        case SQLITE_TOOBIG:
            return .tooLarge
        case SQLITE_BUSY, SQLITE_LOCKED, SQLITE_IOERR, SQLITE_CANTOPEN,
             SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_PROTOCOL, SQLITE_SCHEMA:
            // A fresh snapshot can recover from a transient database generation or I/O failure.
            return .unstableSource
        default:
            // Missing tables/columns and unsupported SQL values are format errors.
            return .invalidFormat
        }
    }

    private static func text(_ statement: OpaquePointer?, column: Int32, optional: Bool) throws -> String? {
        if optional, sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column) else { throw AppVocabularyImportError.invalidFormat }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw AppVocabularyImportError.invalidFormat }
        return value
    }

    private static func boolean(_ statement: OpaquePointer?, column: Int32) throws -> Bool {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw AppVocabularyImportError.invalidFormat }
        let value = sqlite3_column_int64(statement, column)
        guard value == 0 || value == 1 else { throw AppVocabularyImportError.invalidFormat }
        return value == 1
    }
}
