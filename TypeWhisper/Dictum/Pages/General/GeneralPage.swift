import SwiftUI

struct GeneralPage: View {
    var body: some View {
        DictumPageFrame(page: .general) {
            ScrollView {
                VStack(spacing: 22) {
                    ShortcutsSection()
                    PolishStrengthSection()
                    TranslationLanguagesSection()
                    SoundSection()
                    HistorySyncSection()
                    AppSection()
                }
                .frame(maxWidth: 600)
                .padding(.top, 4).padding(.horizontal, 28).padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
    }
}
