import Foundation

enum PortDiscovery {
    static let defaultPort: UInt16 = 8978

    static func discoverPort(dev: Bool = false, applicationSupportDirectory: URL? = nil) -> UInt16 {
        let dirName = dev ? "TypeWhisper-Dev" : "TypeWhisper"
        let baseDirectory = applicationSupportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let portFileURL = baseDirectory
            .appendingPathComponent(dirName)
            .appendingPathComponent("api-port")

        guard let content = try? String(contentsOf: portFileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let port = UInt16(content) else {
            return defaultPort
        }
        return port
    }
}
