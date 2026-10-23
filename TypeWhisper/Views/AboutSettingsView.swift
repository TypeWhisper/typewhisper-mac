import SwiftUI

struct AboutSettingsView: View {
    @State private var isLogoHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "About"))
            Divider()
            Form {
                Section {
                    VStack(spacing: 12) {
                        WaveformLogoView(isActive: isLogoHovering && !reduceMotion)
                            .frame(width: 96, height: 96)
                            .scaleEffect(isLogoHovering && !reduceMotion ? 1.05 : 1)
                            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isLogoHovering)
                            .onHover { isLogoHovering = $0 }
                            .accessibilityHidden(true)
                        Text("dictum")
                            .font(.title)
                            .fontWeight(.semibold)
                            .accessibilityAddTraits(.isHeader)
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
                Section {
                    HStack {
                        Spacer()
                        Button {
                            UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
                            NotificationCenter.default.post(name: .resetSetupWizardWindow, object: nil)
                            ManagedAppWindowOpener.shared.open(id: "setup")
                        } label: {
                            Label(
                                localizedAppText("Open Setup Wizard", de: "Einrichtungsassistent öffnen"),
                                systemImage: "sparkles"
                            )
                        }
                        Spacer()
                    }
                    Text(localizedAppText(
                        "Run the first-time setup flow again without changing your saved settings.",
                        de: "Starte den Einrichtungsassistenten erneut, ohne deine gespeicherten Einstellungen zu ändern."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section {
                    VStack(spacing: 4) {
                        Text(verbatim: "\u{00A9} 2024-2026 TypeWhisper Contributors")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link("based on TypeWhisper", destination: URL(string: "https://github.com/TypeWhisper/typewhisper-mac")!)
                            .font(.caption)
                        Text(String(localized: "Licensed under the GNU General Public License v3.0"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}

struct WaveformLogoView: View {
    var isActive: Bool

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .scaleEffect(isActive ? 1.02 : 1)
    }
}
