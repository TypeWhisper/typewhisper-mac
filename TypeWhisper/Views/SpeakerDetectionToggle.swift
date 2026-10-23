import SwiftUI

struct SpeakerDetectionToggle: View {
    @Binding var isOn: Bool
    var isDisabled = false
    var descriptionKey: String.LocalizationValue = "speakers.toggle.description"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(String(localized: "speakers.toggle.title"), isOn: $isOn)
                .disabled(isDisabled)
            Text(String(localized: descriptionKey))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
