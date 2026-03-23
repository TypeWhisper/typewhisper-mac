import SwiftUI

struct AboutSettingsView: View {
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
                    Text("Version \(version) (\(build))")
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
