import Foundation

enum MemPalaceDeployment: String, Codable, CaseIterable, Identifiable {
    case cloud
    case selfHosted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloud: return "MemPalace Cloud"
        case .selfHosted: return "Self-Hosted"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .cloud: return "https://api.mempalace.cloud"
        case .selfHosted: return ""
        }
    }
}

struct MemPalaceConfig: Codable, Equatable {
    var deployment: MemPalaceDeployment
    var baseURL: String
    var wing: String
    var room: String

    static let `default` = MemPalaceConfig(
        deployment: .cloud,
        baseURL: MemPalaceDeployment.cloud.defaultBaseURL,
        wing: "wing_typewhisper",
        room: "captures"
    )

    var resolvedBaseURL: URL? {
        let trimmed = baseURL
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              url.host != nil
        else { return nil }
        // Cloud must be https. Self-hosted accepts http for LAN/dev.
        switch deployment {
        case .cloud:
            guard scheme == "https" else { return nil }
        case .selfHosted:
            guard scheme == "https" || scheme == "http" else { return nil }
        }
        return url
    }

    var isValid: Bool {
        guard resolvedBaseURL != nil else { return false }
        let trimmedWing = wing.trimmingCharacters(in: .whitespaces)
        let trimmedRoom = room.trimmingCharacters(in: .whitespaces)
        return !trimmedWing.isEmpty && !trimmedRoom.isEmpty
    }
}

enum MemPalaceUserDefaultsKey {
    static let config = "mempalace.config"
    static let secretAPIKey = "api-key"
}

enum MemPalaceSourceFile {
    static let prefix = "tw_"

    static func encode(_ uuid: UUID) -> String {
        prefix + uuid.uuidString
    }

    static func decode(_ source: String?) -> UUID? {
        guard let source, source.hasPrefix(prefix) else { return nil }
        let raw = String(source.dropFirst(prefix.count))
        return UUID(uuidString: raw)
    }
}
