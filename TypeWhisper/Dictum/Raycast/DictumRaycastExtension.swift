import Foundation

/// dictum 的 Raycast 扩展从 GitHub 仓库安装为本机扩展，不在 Raycast 商店。
enum DictumRaycastExtension {
    static let author = "schneider_vaughn"
    static let name = "dictum"
    // 本机扩展没有商店页面，只写作者和名称的链接会打开空白页，所以打开一个没有副作用的命令。
    static let openURL = URL(string: "raycast://extensions/\(author)/\(name)/search-history")!
    static let repositoryURL = URL(string: "https://github.com/schneidervvv/dictum-raycast")!

    static var defaultExtensionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/raycast/extensions", isDirectory: true)
    }

    static var infoText: String {
        String(
            localized: "Start dictation, search history, manage the dictionary and dictate with a workflow directly from Raycast. Requires the API server to be running.",
            table: "DictumRaycast"
        )
    }

    static func isInstalled(extensionsDirectory: URL = defaultExtensionsDirectory) -> Bool {
        let manifestURL = extensionsDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return false }
        return manifest.name == name && manifest.author == author
    }

    private struct Manifest: Decodable {
        let name: String
        let author: String
    }
}
