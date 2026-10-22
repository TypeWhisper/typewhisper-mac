import SwiftUI

struct DictumHistoryPage: View {
    var body: some View {
        DictumPageFrame(page: .history) {
            HistorySettingsView()
        }
    }
}
