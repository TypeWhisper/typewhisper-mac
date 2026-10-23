import Foundation

enum HistorySyncPresentation {
    static var missingFolder: String {
        String(localized: "Can't sync: iCloud Drive folder not found", table: "DictumHistory")
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
