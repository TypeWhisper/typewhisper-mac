import SwiftUI

/// The "Detect Speakers" switch of the Recorder and file transcription.
/// Without Premium it stays visible, is off, and leads to the Premium page.
struct SpeakerDetectionToggle: View {
    @Binding var isOn: Bool
    var isDisabled = false
    /// What turning the switch on does, where it is not the History record.
    var descriptionKey: String.LocalizationValue = "speakers.toggle.description"

    @ObservedObject private var license = ServiceContainer.shared.licenseService
    @ObservedObject private var premiumAccount = ServiceContainer.shared.premiumAccountService

    private var hasAccess: Bool {
        SpeakerWorkspacePremiumAccess.isGranted(
            hasCommercialLicense: license.hasCommercialLicense,
            hasPremiumEntitlement: premiumAccount.hasPremiumEntitlement
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(
                    String(localized: "speakers.toggle.title"),
                    isOn: hasAccess ? $isOn : .constant(false)
                )
                .disabled(isDisabled || !hasAccess)

                if !hasAccess {
                    Button(String(localized: "Premium")) {
                        SettingsNavigationCoordinator.shared.navigate(to: .premium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(String(localized: "speakers.premium.required"))
                }
            }

            Text(String(localized: hasAccess ? descriptionKey : "speakers.premium.required"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
