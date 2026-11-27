import Foundation
import Security

/// The shared, versioned format of API keys in iCloud Keychain. TypeWhisper for iOS writes and
/// reads exactly the same items, so neither app may change a name or attribute on its own.
///
/// Compiled into the app, the iCloud bridge XPC service and the App Store edition.
enum SharedAPIKeyItemFormat {
    /// A new incompatible format gets a new service name, so readers never see items they do not
    /// understand.
    static let service = "com.typewhisper.api-keys.v1"
    /// Shared with TypeWhisper for iOS and its keyboard. Only a bundle with a provisioning profile
    /// may use it: the bridge in the direct download, the app itself in the App Store edition.
    static let accessGroup = "2D8ALY3LCL.com.typewhisper.writing-services"
    /// `kSecAttrGeneric`: `{"format":1}`. Readers ignore unknown fields.
    static let versionMarker = Data(#"{"format":1}"#.utf8)
    /// Not localized: devices in different languages share the item.
    static let itemDescription = "TypeWhisper API key"

    /// Only first-party plugins sync, under the account `<name>` of `com.typewhisper.<name>`.
    static let pluginIdPrefix = "com.typewhisper."
    /// The one plugin secret that syncs. OAuth tokens and other secrets stay on this Mac.
    static let pluginSecretKey = "api-key"
    /// Keys that belong to an address the user enters (a server, an Azure resource, a Cloudflare
    /// endpoint). The address is not in the Keychain, so a synced key would reach another Mac
    /// without it, or replace the key that belongs to that Mac's own address.
    static let neverSyncedAccounts: Set<String> = ["openai-compatible", "microsoft-ai", "cloudflare-asr"]
    static let maximumAccountLength = 64
    static let maximumDisplayNameLength = 64

    /// The names TypeWhisper for iOS uses in its labels, so both apps write the same label.
    private static let knownDisplayNames: [String: String] = [
        "groq": "Groq",
        "soniox": "Soniox",
        "reson8": "Reson8",
        "elevenlabs": "ElevenLabs",
        "openai": "OpenAI",
        "meta": "Meta",
        "gemini": "Gemini",
        "assemblyai": "AssemblyAI",
        "openrouter": "OpenRouter",
        "deepgram": "Deepgram",
    ]

    /// The shared account for a plugin, or nil for plugins of other publishers and keys that
    /// never sync.
    static func account(forPluginId pluginId: String) -> String? {
        guard pluginId.hasPrefix(pluginIdPrefix) else { return nil }
        let name = String(pluginId.dropFirst(pluginIdPrefix.count))
        return isValidAccount(name) ? name : nil
    }

    static func pluginId(forAccount account: String) -> String {
        pluginIdPrefix + account
    }

    /// Lowercase ASCII letters and digits, separated by single dots or hyphens.
    static func isValidAccount(_ account: String) -> Bool {
        guard !account.isEmpty,
              account.utf8.count <= maximumAccountLength,
              !neverSyncedAccounts.contains(account) else {
            return false
        }
        var previousWasSeparator = true
        for byte in account.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                previousWasSeparator = false
            case UInt8(ascii: "-"), UInt8(ascii: "."):
                guard !previousWasSeparator else { return false }
                previousWasSeparator = true
            default:
                return false
            }
        }
        return !previousWasSeparator
    }

    /// The provider name in the item label: the name iOS uses, otherwise the plugin's name.
    static func displayName(forAccount account: String, pluginName: String?) -> String {
        if let known = knownDisplayNames[account] { return known }
        if let pluginName = sanitizedDisplayName(pluginName) { return pluginName }
        return account
    }

    /// A single-line name of reasonable length, or nil.
    static func sanitizedDisplayName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= maximumDisplayNameLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    static func label(displayName: String) -> String {
        "TypeWhisper \(displayName) API Key"
    }

    /// The stored value is the trimmed key as UTF-8, nothing else.
    static func encode(_ key: String) -> Data? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    static func decode(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The value of a shared item and when any device last changed it.
struct SharedAPIKeyStoredItem: Codable, Equatable, Sendable {
    var value: Data
    var modificationDate: Date?
}

/// A failed Keychain or bridge call. Carries a status code, never a key.
enum SharedAPIKeyStoreError: LocalizedError, Codable, Equatable, Sendable {
    /// This build cannot reach the shared access group: no bridge, or no entitlement.
    case unavailable
    case invalidAccount
    case emptyValue
    case keychain(Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "This build of TypeWhisper can't reach iCloud Keychain.")
        case .invalidAccount, .emptyValue:
            String(localized: "TypeWhisper couldn't save the API key in iCloud Keychain.")
        case let .keychain(status):
            String(localized: "iCloud Keychain refused the change (error \(Int(status))).")
        case .timedOut:
            String(localized: "iCloud Keychain didn't answer in time. Try again in a moment.")
        }
    }

    /// For logs: a status code or the case name, never a key.
    var technicalSummary: String {
        switch self {
        case .unavailable: "unavailable"
        case .invalidAccount: "invalid account"
        case .emptyValue: "empty value"
        case let .keychain(status): "OSStatus \(status)"
        case .timedOut: "timed out"
        }
    }
}

/// The answer of the bridge to every API key request, encoded as JSON.
struct SharedAPIKeyBridgeReply: Codable, Equatable, Sendable {
    var items: [String: SharedAPIKeyStoredItem] = [:]
    var failure: SharedAPIKeyStoreError?

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decoded(from data: Data) -> SharedAPIKeyBridgeReply {
        (try? JSONDecoder().decode(SharedAPIKeyBridgeReply.self, from: data))
            ?? SharedAPIKeyBridgeReply(failure: .unavailable)
    }
}

/// The shared items in the data protection keychain. Runs in a process that holds the
/// `keychain-access-groups` entitlement for `SharedAPIKeyItemFormat.accessGroup`.
/// Never logs values.
struct SystemSharedAPIKeyKeychain: Sendable {
    let accessGroup: String

    init(accessGroup: String = SharedAPIKeyItemFormat.accessGroup) {
        self.accessGroup = accessGroup
    }

    /// Every present item with a valid account. Items of unknown accounts stay untouched.
    func readAll() throws -> [String: SharedAPIKeyStoredItem] {
        var search = baseQuery()
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw SharedAPIKeyStoreError.keychain(status) }
        guard let attributeList = result as? [[String: Any]] else { return [:] }

        var items: [String: SharedAPIKeyStoredItem] = [:]
        for attributes in attributeList {
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  SharedAPIKeyItemFormat.isValidAccount(account),
                  let item = try read(account: account) else {
                continue
            }
            items[account] = item
        }
        return items
    }

    /// Replaces the value of an existing item or adds a new one.
    func write(_ value: Data, account: String, displayName: String) throws {
        guard SharedAPIKeyItemFormat.isValidAccount(account) else {
            throw SharedAPIKeyStoreError.invalidAccount
        }
        guard let decoded = SharedAPIKeyItemFormat.decode(value),
              let data = SharedAPIKeyItemFormat.encode(decoded) else {
            throw SharedAPIKeyStoreError.emptyValue
        }
        let name = SharedAPIKeyItemFormat.sanitizedDisplayName(displayName) ?? account
        var changes: [String: Any] = [kSecValueData as String: data]
        addDescriptiveAttributes(displayName: name, to: &changes)
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            changes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SharedAPIKeyStoreError.keychain(updateStatus)
        }

        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addDescriptiveAttributes(displayName: name, to: &item)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SharedAPIKeyStoreError.keychain(addStatus)
        }
    }

    /// Deletes the item on every device that syncs it. A missing item is not an error.
    func delete(account: String) throws {
        guard SharedAPIKeyItemFormat.isValidAccount(account) else {
            throw SharedAPIKeyStoreError.invalidAccount
        }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedAPIKeyStoreError.keychain(status)
        }
    }

    /// Value and modification date from one lookup, so both describe the same version of an item
    /// that another device may change at any moment.
    private func read(account: String) throws -> SharedAPIKeyStoredItem? {
        var search = baseQuery(account: account)
        search[kSecReturnData as String] = true
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SharedAPIKeyStoreError.keychain(status) }
        guard let attributes = result as? [String: Any],
              let value = attributes[kSecValueData as String] as? Data else {
            return nil
        }
        return SharedAPIKeyStoredItem(
            value: value,
            modificationDate: attributes[kSecAttrModificationDate as String] as? Date
        )
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: SharedAPIKeyItemFormat.service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    private func addDescriptiveAttributes(displayName: String, to attributes: inout [String: Any]) {
        attributes[kSecAttrLabel as String] = SharedAPIKeyItemFormat.label(displayName: displayName)
        attributes[kSecAttrDescription as String] = SharedAPIKeyItemFormat.itemDescription
        attributes[kSecAttrGeneric as String] = SharedAPIKeyItemFormat.versionMarker
    }
}
