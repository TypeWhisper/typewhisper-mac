import Foundation

enum HistorySyncPresentation {
    static var missingFolder: String {
        String(localized: "Can't sync: iCloud Drive folder not found", table: "DictumHistory")
    }

    @MainActor
    static func status(_ controller: CloudFolderSyncController) -> String {
        if let error = controller.errorMessage { return error }
        if controller.mode == .off { return String(localized: "Off", table: "DictumHistory") }
        guard let date = controller.lastSyncDate else { return String(localized: "Syncing…", table: "DictumHistory") }
        return String(format: String(localized: "Synced %@ · %lld records", table: "DictumHistory"),
                      date.formatted(.relative(presentation: .named)), Int64(controller.synchronizedRecordCount))
    }
}
