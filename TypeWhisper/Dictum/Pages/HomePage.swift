import SwiftUI

struct HomePage: View {
    var body: some View {
        DictumPageFrame(page: .home) { HomeSettingsView() }
    }
}
