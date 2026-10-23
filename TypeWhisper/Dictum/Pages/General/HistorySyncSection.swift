import SwiftUI

struct HistorySyncSection: View {
    var body: some View {
        GroupedFormSection(title: "History & Sync") {
            CloudFolderSyncSettingsView(controller: ServiceContainer.shared.cloudFolderSyncController)
        }
    }
}
