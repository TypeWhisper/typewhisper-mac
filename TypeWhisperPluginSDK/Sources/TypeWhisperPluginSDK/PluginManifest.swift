import Foundation

public enum PluginHosting: String, Codable, Sendable {
    case local
    case cloud

    public static func fallback(requiresAPIKey: Bool?) -> PluginHosting {
        requiresAPIKey == true ? .cloud : .local
    }
}

public enum PluginCapability: String, Codable, Sendable, CaseIterable {
    case sourceFootageProgress = "source-footage-progress"
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
    public let iconResourceName: String?
    public let category: String?
    public let categories: [String]?
    public let capabilities: [String]?
    public let detailsURL: String?
    public let homepageURL: String?
    public let iconURL: String?
    public let iconDarkURL: String?

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
        iconResourceName: String? = nil,
        category: String? = nil,
        categories: [String]? = nil,
        capabilities: [String]? = nil,
        detailsURL: String? = nil,
        homepageURL: String? = nil,
        iconURL: String? = nil,
        iconDarkURL: String? = nil
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
        self.iconResourceName = iconResourceName
        self.category = category
        self.categories = categories
        self.capabilities = capabilities
        self.detailsURL = detailsURL
        self.homepageURL = homepageURL
        self.iconURL = iconURL
        self.iconDarkURL = iconDarkURL
    }
}

public extension PluginManifest {
    var resolvedHosting: PluginHosting {
        hosting ?? PluginHosting.fallback(requiresAPIKey: requiresAPIKey)
    }

    var resolvedCategoryIdentifiers: [String] {
        Self.normalizedCategoryIdentifiers(primary: category, categories: categories)
    }

    var resolvedCapabilityIdentifiers: [String] {
        Self.normalizedCapabilityIdentifiers(capabilities)
    }

    func supportsCapability(_ capability: PluginCapability) -> Bool {
        resolvedCapabilityIdentifiers.contains(capability.rawValue)
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

    static func normalizedCapabilityIdentifiers(_ capabilities: [String]?) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in capabilities ?? [] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }

        return result
    }
}
