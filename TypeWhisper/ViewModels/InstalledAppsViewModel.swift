import Foundation
import AppKit

struct InstalledApp: Identifiable, Hashable, Sendable {
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
///
/// Creating it does no work, because the service container creates it at launch. The folders
/// are scanned once, off the main thread, when the Workflows settings first appear.
@MainActor
final class InstalledAppsViewModel: ObservableObject {
    @Published private(set) var installedApps: [InstalledApp] = []

    private let scan: @Sendable () -> [InstalledApp]
    private var loadTask: Task<Void, Never>?

    init(scan: @escaping @Sendable () -> [InstalledApp] = InstalledAppsViewModel.scanInstalledApps) {
        self.scan = scan
    }

    /// Starts the scan unless an earlier call did, and returns once the list is published.
    /// The scan keeps running when the caller's task is cancelled, so it runs only once.
    func loadIfNeeded() async {
        if loadTask == nil {
            let scan = scan
            loadTask = Task {
                installedApps = await Task.detached(priority: .userInitiated) { scan() }.value
            }
        }
        await loadTask?.value
    }

    nonisolated static func scanInstalledApps() -> [InstalledApp] {
        var apps: [String: InstalledApp] = [:]

        let directories = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]

        for dir in directories {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleId = bundle.bundleIdentifier,
                      let name = bundle.infoDictionary?["CFBundleName"] as? String
                        ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? url.deletingPathExtension().lastPathComponent as String?
                else { continue }

                if apps[bundleId] == nil {
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    icon.size = NSSize(width: 24, height: 24)
                    apps[bundleId] = InstalledApp(id: bundleId, name: name, icon: icon)
                }
            }
        }

        return apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
