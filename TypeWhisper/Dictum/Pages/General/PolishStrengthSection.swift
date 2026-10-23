import SwiftUI

struct PolishStrengthSection: View {
    @ObservedObject private var store = StyleStore.shared
    var body: some View {
        GroupedFormSection(title: "Polish strength", tableName: "DictumStyle") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(horizontalSpacing: 8) {
                    GridRow {
                        ForEach(PolishLevel.allCases, id: \.self) { level in
                            OptionCard(title: LocalizedStringKey(level.rawValue), detail: LocalizedStringKey("polish." + level.rawValue),
                                       isSelected: store.level == level, tableName: "DictumStyle") { store.level = level }
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("polish.sample", tableName: "DictumStyle").foregroundStyle(.secondary)
                    Text(LocalizedStringKey("polish.sample." + store.level.rawValue), tableName: "DictumStyle")
                }.font(.system(size: 12)).lineSpacing(4).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DictumTheme.inset, in: RoundedRectangle(cornerRadius: 8))
            }.padding(12)
        }
    }
}
