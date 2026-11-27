import SwiftUI

/// The API key sync switch under Settings → General, as on iOS.
struct APIKeySyncSettingsSection: View {
    @ObservedObject private var sync: APIKeySyncService

    init(sync: APIKeySyncService = ServiceContainer.shared.apiKeySyncService) {
        self.sync = sync
    }

    private var restriction: APIKeySyncService.Restriction? { sync.restriction }

    var body: some View {
        Section(String(localized: "API Keys")) {
            Toggle(String(localized: "Sync with iCloud Keychain"), isOn: Binding(
                get: { sync.isEnabled && restriction == nil },
                set: { sync.setEnabled($0) }
            ))
            .disabled(restriction != nil || sync.isUpdating)
            .managedLockAccessibilityHint(isLocked: restriction == .managedConfiguration, reason: nil)
            .accessibilityIdentifier("settings.apiKeySync")

            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.apiKeySync.footer")

            if restriction == .managedConfiguration {
                ManagedByOrganizationLabel()
            }
        }
        .alert(
            String(localized: "Couldn't Change API Key Sync"),
            isPresented: Binding(
                get: { sync.errorMessage != nil },
                set: { if !$0 { sync.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(sync.errorMessage ?? "")
        }
    }

    private var footer: String {
        switch restriction {
        case .storefront:
            String(localized: "API key sync isn't available in your region.")
        case .managedConfiguration:
            String(localized: "Your organization keeps API keys on this Mac.")
        case .unavailable:
            String(localized: "This build of TypeWhisper can't reach iCloud Keychain, so API keys stay on this Mac.")
        case nil:
            if sync.isEnabled {
                String(localized: "API keys of TypeWhisper plugins sync through iCloud Keychain, which is end-to-end encrypted. Other devices receive them only while iCloud Keychain is on. If it's off on this Mac, the keys stay here and keep working. Deleting a key here also deletes it on your devices that sync API keys. Turning this off keeps the keys on this Mac and on your other devices.")
            } else {
                String(localized: "Syncs the API keys of TypeWhisper plugins, such as OpenAI and Groq, with your iPhone, iPad and other Macs through iCloud Keychain. iCloud Keychain is end-to-end encrypted, so only your devices signed in to your Apple Account can read the keys. Keys for custom servers and plugins from other developers stay on this Mac.")
            }
        }
    }
}
