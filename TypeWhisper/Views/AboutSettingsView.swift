import SwiftUI

struct AboutSettingsView: View {
    #if !APPSTORE
    @AppStorage(UserDefaultsKeys.updateChannel) private var selectedUpdateChannelRawValue = AppConstants.defaultReleaseChannel.rawValue
    #endif

    #if !APPSTORE
    private var selectedUpdateChannel: AppConstants.ReleaseChannel {
        AppConstants.ReleaseChannel(rawValue: selectedUpdateChannelRawValue) ?? AppConstants.defaultReleaseChannel
    }

    private var updateChannelBinding: Binding<AppConstants.ReleaseChannel> {
        Binding(
            get: { selectedUpdateChannel },
            set: { newChannel in
                guard selectedUpdateChannel != newChannel else { return }
                selectedUpdateChannelRawValue = newChannel.rawValue
                UpdateChecker.shared?.resetUpdateCycleAfterSettingsChange()
            }
        )
    }
    #endif

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)

                    Text("TypeWhisper")
                        .font(.title)
                        .fontWeight(.semibold)

                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    let channelSuffix = AppConstants.releaseChannel.versionDisplayName.map { " - \($0)" } ?? ""
                    Text("Version \(version) (\(build))\(channelSuffix)")
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Fast, private speech-to-text for your Mac. Transcribe with local or cloud engines, process text with AI prompts, and insert directly into any app."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            #if !APPSTORE
            Section {
                Picker(String(localized: "Update Channel"), selection: updateChannelBinding) {
                    ForEach(AppConstants.ReleaseChannel.allCases, id: \.self) { channel in
                        Text(channel.selectionDisplayName)
                            .tag(channel)
                    }
                }
                .pickerStyle(.menu)

                Text(selectedUpdateChannel.updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button(String(localized: "Check for Updates...")) {
                        UpdateChecker.shared?.checkForUpdates()
                    }
                    .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
                    Spacer()
                }
            }
            #endif

            Section {
                VStack(spacing: 4) {
                    Text(String(localized: "\u{00A9} 2024-2026 TypeWhisper Contributors"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Licensed under the GNU General Public License v3.0"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
    }
}
