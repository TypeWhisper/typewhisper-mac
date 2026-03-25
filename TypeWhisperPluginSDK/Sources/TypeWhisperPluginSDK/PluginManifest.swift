import Foundation

public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let minHostVersion: String?
    public let minOSVersion: String?
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
        minOSVersion: String? = nil,
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
        self.minOSVersion = minOSVersion
        self.author = author
        self.principalClass = principalClass
        self.requiresAPIKey = requiresAPIKey
        self.iconSystemName = iconSystemName
        self.category = category
    }
}
