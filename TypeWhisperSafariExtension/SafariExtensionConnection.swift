import Foundation

/// The API port and token that TypeWhisper hands to its Safari web extension, so nobody has to
/// paste the token. The app writes them to the App Group container while its API server runs,
/// and the extension's native handler reads them.
///
/// The development and release builds share the App Group, so each app writes its own file,
/// named after its bundle identifier. Otherwise the extension of one build would read the
/// port and token of the other.
struct SafariExtensionConnection: Codable, Equatable, Sendable {
    let port: Int
    let token: String

    /// The suffix of the extension's bundle identifier after the app's.
    static let extensionBundleIdentifierSuffix = ".safari-extension"

    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
            ?? "2D8ALY3LCL.com.typewhisper.mac"
    }

    /// The app that contains the extension with this bundle identifier.
    static func hostBundleIdentifier(ofExtension extensionBundleIdentifier: String) -> String? {
        guard extensionBundleIdentifier.hasSuffix(extensionBundleIdentifierSuffix) else { return nil }
        let host = String(extensionBundleIdentifier.dropLast(extensionBundleIdentifierSuffix.count))
        return host.isEmpty ? nil : host
    }

    static func fileURL(hostBundleIdentifier: String, in container: URL) -> URL {
        container.appendingPathComponent("safari-extension-connection-\(hostBundleIdentifier).json")
    }

    static func containerURL(groupIdentifier: String = groupIdentifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    static func load(from url: URL) -> SafariExtensionConnection? {
        guard let data = try? Data(contentsOf: url),
              let connection = try? JSONDecoder().decode(SafariExtensionConnection.self, from: data),
              (1...65535).contains(connection.port),
              !connection.token.isEmpty else {
            return nil
        }
        return connection
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(self).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
