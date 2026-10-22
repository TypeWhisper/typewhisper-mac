import SwiftUI

struct DictionaryPage: View {
    var body: some View {
        DictumPageFrame(page: .dictionary) { DictionarySettingsView() }
    }
}
