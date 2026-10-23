import Foundation

/// Saves, loads and removes API keys and tokens in the private
/// ``SecretFileStore`` file of the current Application Support folder.
/// The type keeps its original name so existing callers stay unchanged.
struct KeychainService: Sendable {
    private static let servicePrefix = AppConstants.secretKeyPrefix

    private static var store: SecretFileStore {
        SecretFileStore(directory: AppConstants.appSupportDirectory)
    }

    /// Saves `key` under `servicePrefix + service`, replacing any earlier value.
    static func save(key: String, service: String) throws {
        try store.save(key, name: servicePrefix + service)
    }

    /// Returns the secret saved under `service`, or `nil` if there is none.
    static func load(service: String) -> String? {
        store.load(name: servicePrefix + service)
    }

    /// Removes the secret saved under `service`. A missing entry is not an error.
    static func delete(service: String) throws {
        try store.delete(name: servicePrefix + service)
    }

    /// Removes every secret whose service name starts with `prefix`.
    static func deleteAll(withServicePrefix prefix: String) throws {
        try store.deleteAll(withNamePrefix: servicePrefix + prefix)
    }
}
