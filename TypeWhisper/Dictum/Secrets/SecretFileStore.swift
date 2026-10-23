import Darwin
import Foundation
import os

/// 密钥保存失败。附带的底层错误只描述文件操作，不含密钥内容。
enum SecretStoreError: LocalizedError {
    case writeFailed(underlying: Error)
    case readFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let underlying):
            "Failed to write the secrets file: \(underlying.localizedDescription)"
        case .readFailed(let underlying):
            "Failed to read the secrets file: \(underlying.localizedDescription)"
        }
    }
}

/// 把 API 密钥保存在应用支持文件夹里的 `secrets.json`：文件夹权限 0700，文件权限 0600，
/// 只有当前用户账号能读取，内容没有加密。
///
/// 自签名构建每次重新构建后钥匙串都会要求输入登录密码，所以不用钥匙串。
struct SecretFileStore: Sendable {
    static let fileName = "secrets.json"

    private static let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "SecretFileStore")

    // 同一进程内所有实例共用一把锁，读改写不会交错。
    private static let lock = NSLock()

    /// 密钥文件、被移到一边的损坏文件和写入中的临时文件。
    static func isSecretFileName(_ name: String) -> Bool {
        name.hasPrefix(fileName) || name.hasPrefix(".\(fileName)")
    }

    let directory: URL

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load(name: String) -> String? {
        Self.lock.withLock {
            do {
                return try readAll()[name]
            } catch {
                Self.logger.error("Could not read the secrets file: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    func save(_ value: String, name: String) throws {
        try Self.lock.withLock {
            var secrets = try readAll()
            secrets[name] = value
            try writeAll(secrets)
        }
    }

    func delete(name: String) throws {
        try Self.lock.withLock {
            var secrets = try readAll()
            guard secrets.removeValue(forKey: name) != nil else { return }
            try writeAll(secrets)
        }
    }

    func deleteAll(withNamePrefix prefix: String) throws {
        try Self.lock.withLock {
            let secrets = try readAll()
            let remaining = secrets.filter { !$0.key.hasPrefix(prefix) }
            guard remaining.count != secrets.count else { return }
            try writeAll(remaining)
        }
    }

    // MARK: - File access (call with the lock held)

    private func readAll() throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return [:]
        } catch {
            throw SecretStoreError.readFailed(underlying: error)
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            try setCorruptFileAside()
            return [:]
        }
    }

    // 移不开时抛出读取错误，保存操作因此不会覆盖损坏的文件。
    private func setCorruptFileAside() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let suffix = UUID().uuidString.prefix(8)
        let asideURL = directory.appendingPathComponent("\(Self.fileName).corrupt-\(stamp)-\(suffix)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: asideURL)
            Self.logger.error("The secrets file could not be parsed and was moved to \(asideURL.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("The secrets file could not be parsed and could not be moved aside: \(error.localizedDescription, privacy: .public)")
            throw SecretStoreError.readFailed(underlying: error)
        }
    }

    private func writeAll(_ secrets: [String: String]) throws {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(secrets)

            // 临时文件创建时就是 0600，密钥内容不会以更宽的权限出现在磁盘上。
            let temporaryURL = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
            let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                // 改名会把这个标记带到最终文件上，密钥文件不进入时间机器备份。
                var excludedFromBackup = URLResourceValues()
                excludedFromBackup.isExcludedFromBackup = true
                var mutableTemporaryURL = temporaryURL
                try mutableTemporaryURL.setResourceValues(excludedFromBackup)
                guard rename(temporaryURL.path, fileURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw error
            }
        } catch {
            throw SecretStoreError.writeFailed(underlying: error)
        }
    }
}
