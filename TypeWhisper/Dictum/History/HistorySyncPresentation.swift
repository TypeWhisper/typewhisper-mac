import Foundation

enum HistorySyncPresentation {
    static var missingFolder: String {
        String(localized: "Can't sync: iCloud Drive folder not found", table: "DictumHistory")
    }

    /// iCloud Drive 里的文件夹显示为 `iCloud Drive › dictum`，其他文件夹显示以 ~ 开头的路径。
    static func folderDisplay(_ folder: URL?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let iCloudName = String(localized: "iCloud Drive", table: "DictumHistory")
        guard let folder else { return "\(iCloudName) › dictum" }
        let iCloudRoot = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true).standardizedFileURL.pathComponents
        let components = folder.standardizedFileURL.pathComponents
        if components.count > iCloudRoot.count, Array(components.prefix(iCloudRoot.count)) == iCloudRoot {
            return ([iCloudName] + components.dropFirst(iCloudRoot.count)).joined(separator: " › ")
        }
        let homePath = home.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    @MainActor
    static func status(_ controller: CloudFolderSyncController) -> String {
        syncedLine(controller) { String(format: String(localized: "Synced to iCloud Drive · %@", table: "DictumHistory"), $0) }
    }

    @MainActor
    static func settingsStatus(_ controller: CloudFolderSyncController) -> String {
        syncedLine(controller) {
            String(format: String(localized: "Synced %@ · %lld records", table: "DictumHistory"), $0, Int64(controller.synchronizedRecordCount))
        }
    }

    @MainActor
    private static func syncedLine(_ controller: CloudFolderSyncController, synced: (String) -> String) -> String {
        if let error = controller.errorMessage { return error }
        if controller.mode == .off { return String(localized: "Off", table: "DictumHistory") }
        guard let date = controller.lastSyncDate else { return String(localized: "Syncing…", table: "DictumHistory") }
        return synced(date.formatted(.relative(presentation: .named)))
    }
}
