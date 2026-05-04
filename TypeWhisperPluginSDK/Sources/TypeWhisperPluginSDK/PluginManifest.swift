import Foundation

public enum PluginHosting: String, Codable, Sendable {
    case local
    case cloud

    public static func fallback(requiresAPIKey: Bool?) -> PluginHosting {
        requiresAPIKey == true ? .cloud : .local
    }
}

public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let minHostVersion: String?
    public let sdkCompatibilityVersion: String?
    public let minOSVersion: String?
    public let supportedArchitectures: [String]?
    public let author: String?
    public let principalClass: String
    public let requiresAPIKey: Bool?
    public let hosting: PluginHosting?
    public let iconSystemName: String?
    public let category: String?
    public let categories: [String]?

    public init(
        id: String,
        name: String,
        version: String,
        minHostVersion: String? = nil,
        sdkCompatibilityVersion: String? = nil,
        minOSVersion: String? = nil,
        supportedArchitectures: [String]? = nil,
        author: String? = nil,
        principalClass: String,
        requiresAPIKey: Bool? = nil,
        hosting: PluginHosting? = nil,
        iconSystemName: String? = nil,
        category: String? = nil,
        categories: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.minHostVersion = minHostVersion
        self.sdkCompatibilityVersion = sdkCompatibilityVersion
        self.minOSVersion = minOSVersion
        self.supportedArchitectures = supportedArchitectures
        self.author = author
        self.principalClass = principalClass
        self.requiresAPIKey = requiresAPIKey
        self.hosting = hosting
        self.iconSystemName = iconSystemName
        self.category = category
        self.categories = categories
    }
}

public extension PluginManifest {
    var resolvedHosting: PluginHosting {
        hosting ?? PluginHosting.fallback(requiresAPIKey: requiresAPIKey)
    }

    var resolvedCategoryIdentifiers: [String] {
        Self.normalizedCategoryIdentifiers(primary: category, categories: categories)
    }

    static func normalizedCategoryIdentifiers(primary: String?, categories: [String]?) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in [primary].compactMap({ $0 }) + (categories ?? []) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }

        return result
    }
}
