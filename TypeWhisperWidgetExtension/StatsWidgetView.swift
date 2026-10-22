import SwiftUI
import WidgetKit

struct StatsWidgetView: View {
    let data: WidgetStatsData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("dictum", systemImage: "mic.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text("\(data.wordsToday)")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .foregroundStyle(.primary)
                Text("words today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(data.timeSavedToday)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
