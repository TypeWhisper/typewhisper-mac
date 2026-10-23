import Foundation
import Security

/// 把 API 密钥和令牌保存在当前应用支持文件夹的私有文件
/// ``SecretFileStore`` 中。类型名保持不变，已有调用方无需修改。
struct KeychainService: Sendable {
    private static let servicePrefix = AppConstants.secretKeyPrefix

    private static var store: SecretFileStore {
        SecretFileStore(directory: AppConstants.appSupportDirectory)
    }

    /// 以 `servicePrefix + service` 为名保存 `key`，覆盖之前的值。
    static func save(key: String, service: String) throws {
        try store.save(key, name: servicePrefix + service)
    }

    /// 返回保存在 `service` 下的密钥，没有则返回 `nil`。
    static func load(service: String) -> String? {
        store.load(name: servicePrefix + service)
    }

    /// 删除保存在 `service` 下的密钥，条目不存在不算错误。
    static func delete(service: String) throws {
        try store.delete(name: servicePrefix + service)
    }

    /// 删除服务名以 `prefix` 开头的所有密钥。
    static func deleteAll(withServicePrefix prefix: String) throws {
        try store.deleteAll(withNamePrefix: servicePrefix + prefix)
    }

    /// 删除旧版本留在钥匙串里、服务名以 `fullServicePrefix` 开头的条目。
    /// 逐个删除，单个失败不影响其余条目，最后抛出最后一个失败状态。
    static func deleteLegacyKeychainItems(withFullServicePrefix fullServicePrefix: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound { return }
            throw KeychainError.deleteFailed(status)
        }

        var failedStatus: OSStatus?
        for item in items {
            guard let serviceName = item[kSecAttrService as String] as? String,
                  serviceName.hasPrefix(fullServicePrefix) else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                failedStatus = deleteStatus
            }
        }
        if let failedStatus {
            throw KeychainError.deleteFailed(failedStatus)
        }
    }
}

/// 清除旧钥匙串条目时的错误。
enum KeychainError: LocalizedError {
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let status):
            "Failed to delete from Keychain (status: \(status))"
        }
    }
}
