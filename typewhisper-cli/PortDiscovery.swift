import Foundation

struct APIDiscovery: Equatable {
    let port: UInt16
    let token: String?
}

enum PortDiscovery {
    static let defaultPort: UInt16 = 8978

    static func discover(dev: Bool = false, applicationSupportDirectory: URL? = nil) -> APIDiscovery {
        let appDirectory = apiDirectory(dev: dev, applicationSupportDirectory: applicationSupportDirectory)

        if let discovery = readDiscoveryFile(at: appDirectory.appendingPathComponent("api-discovery.json")) {
            return discovery
        }

        return APIDiscovery(
            port: readPortFile(at: appDirectory.appendingPathComponent("api-port")) ?? defaultPort,
            token: nil
        )
    }

    static func discoverPort(dev: Bool = false, applicationSupportDirectory: URL? = nil) -> UInt16 {
        discover(dev: dev, applicationSupportDirectory: applicationSupportDirectory).port
    }

    private static func apiDirectory(dev: Bool, applicationSupportDirectory: URL?) -> URL {
        let dirName = dev ? "TypeWhisper-Dev" : "TypeWhisper"
        let baseDirectory = applicationSupportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseDirectory
            .appendingPathComponent(dirName)
    }

    private static func readDiscoveryFile(at url: URL) -> APIDiscovery? {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(APIDiscoveryDocument.self, from: data),
              document.port > 0 else {
            return nil
        }

        let token = document.token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return APIDiscovery(port: document.port, token: token?.isEmpty == false ? token : nil)
    }

    private static func readPortFile(at url: URL) -> UInt16? {
        guard let content = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return UInt16(content)
    }
}

private struct APIDiscoveryDocument: Decodable {
    let port: UInt16
    let token: String?
}

struct CLITranscribeLanguageOptions: Equatable {
    var language: String?
    var languageHints: [String] = []

    func validationError() -> String? {
        if language != nil, !languageHints.isEmpty {
            return "Error: --language and --language-hint cannot be used together."
        }
        return nil
    }
}
