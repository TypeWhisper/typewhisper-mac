import Foundation
import Security

/// Provides a type-safe interface for storing, retrieving, and removing
/// generic-password items in the system Keychain.
struct KeychainService: Sendable {
    private static let servicePrefix = AppConstants.keychainServicePrefix

    /// Saves `key` as a generic-password item in the Keychain under `service`.
    ///
    /// Any pre-existing item for the same service is removed before the new
    /// value is written, ensuring the stored credential is always up-to-date.
    ///
    /// - Parameters:
    ///   - key: The secret string to persist (e.g. an API key or token).
    ///   - service: A logical service identifier appended to the shared prefix.
    /// - Throws: `KeychainError.saveFailed` if the Keychain write fails.
    static func save(key: String, service: String) throws {
        let fullService = servicePrefix + service
        guard let data = key.data(using: .utf8) else { return }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fullService,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fullService,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieves the secret string previously saved under `service`.
    ///
    /// - Parameter service: The logical service identifier used when the item
    ///   was saved.
    /// - Returns: The stored string, or `nil` if no matching item exists or the
    ///   data cannot be decoded as UTF-8.
    static func load(service: String) -> String? {
        let fullService = servicePrefix + service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fullService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// A stored secret and when it was last written.
    struct StoredItem: Equatable, Sendable {
        let value: String
        let modificationDate: Date?
    }

    /// Like ``load(service:)``, but with the modification date, and a failed read throws
    /// instead of looking like a missing item.
    ///
    /// - Returns: The item, or `nil` if none exists or its data is not UTF-8.
    /// - Throws: `KeychainError.readFailed` for any status other than success or
    ///   `errSecItemNotFound`.
    static func loadItem(service: String) throws -> StoredItem? {
        let fullService = servicePrefix + service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fullService,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.readFailed(status) }
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return StoredItem(
            value: value,
            modificationDate: attributes[kSecAttrModificationDate as String] as? Date
        )
    }

    /// Removes the Keychain item associated with `service`.
    ///
    /// - Parameter service: The logical service identifier of the item to delete.
    /// - Throws: `KeychainError.deleteFailed` if the Keychain returns an
    ///   unexpected status. A `errSecItemNotFound` result is treated as a
    ///   no-op and does **not** throw.
    static func delete(service: String) throws {
        let fullService = servicePrefix + service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fullService,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Deletes every Keychain item whose service attribute starts with
    /// `servicePrefix + prefix`.
    ///
    /// All matching items are enumerated first; deletion is then attempted for
    /// each one individually.  If any deletion fails the method continues
    /// removing remaining items and throws `KeychainError.deleteFailed` with
    /// the last failing status code once the loop completes.
    ///
    /// - Parameter prefix: The service-name prefix used to scope deletions.
    /// - Throws: `KeychainError.deleteFailed` if one or more items could not
    ///   be removed from the Keychain.
    static func deleteAll(withServicePrefix prefix: String) throws {
        let fullServicePrefix = servicePrefix + prefix

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound {
                return
            }
            throw KeychainError.deleteFailed(status)
        }

        var failedStatus: OSStatus?
        for item in items {
            if let serviceName = item[kSecAttrService as String] as? String,
               serviceName.hasPrefix(fullServicePrefix) {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName
                ]
                let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
                if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
                    failedStatus = deleteStatus
                }
            }
        }
        if let status = failedStatus {
            throw KeychainError.deleteFailed(status)
        }
    }
}

/// Errors that can be thrown by ``KeychainService`` operations.
enum KeychainError: LocalizedError {
    /// A Keychain write operation failed with the given `OSStatus` code.
    case saveFailed(OSStatus)
    /// A Keychain read operation failed with the given `OSStatus` code.
    case readFailed(OSStatus)
    /// A Keychain delete operation failed with the given `OSStatus` code.
    case deleteFailed(OSStatus)

    /// A human-readable description of the error, including the raw
    /// `OSStatus` code to aid debugging.
    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            "Failed to save to Keychain (status: \(status))"
        case .readFailed(let status):
            "Failed to read from Keychain (status: \(status))"
        case .deleteFailed(let status):
            "Failed to delete from Keychain (status: \(status))"
        }
    }
}
