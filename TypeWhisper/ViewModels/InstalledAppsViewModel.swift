import Foundation
import AppKit

struct InstalledApp: Identifiable, Hashable {
    let id: String // bundleIdentifier
    let name: String
    let icon: NSImage?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// The apps in the Applications folders, for the workflow editor's app picker.
@MainActor
final class InstalledAppsViewModel: ObservableObject {
    @Published private(set) var installedApps: [InstalledApp] = []

    init(directories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/System/Applications"),
    ]) {
        scanInstalledApps(in: directories)
    }

    private func scanInstalledApps(in directories: [URL]) {
        var apps: [String: InstalledApp] = [:]

        for dir in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                // 创建 Bundle 会将外部应用注册到 MLX 也会遍历的全局资源列表。
                guard let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any],
                      let bundleId = info["CFBundleIdentifier"] as? String
                else { continue }
                let name = info["CFBundleName"] as? String
                    ?? info["CFBundleDisplayName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent

                if apps[bundleId] == nil {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 24, height: 24)
                    apps[bundleId] = InstalledApp(id: bundleId, name: name, icon: icon)
                }
            }
        }

        installedApps = apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
