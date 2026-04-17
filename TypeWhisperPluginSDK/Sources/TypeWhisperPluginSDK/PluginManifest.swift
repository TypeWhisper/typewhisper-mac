import Foundation

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
    public let iconSystemName: String?
    public let category: String?

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
        iconSystemName: String? = nil,
        category: String? = nil
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
        self.iconSystemName = iconSystemName
        self.category = category
    }
}
