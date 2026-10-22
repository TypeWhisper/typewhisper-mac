import SwiftUI
import TypeWhisperPluginSDK

struct SpeechPage: View {
    var body: some View {
        DictumPageFrame(page: .speech) {
            DictumSpeechSettings()
        }
    }
}

private struct DictumSpeechSettings: View {
    @ObservedObject private var plugins = PluginManager.shared
    @State private var selection = ""

    private var availablePlugins: [LoadedPlugin] {
        plugins.loadedPlugins.filter {
            $0.instance is any TranscriptionEnginePlugin
        }.sorted { $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(DictumPage.speech.title, selection: Binding(
                get: { availablePlugins.contains(where: { $0.id == selection }) ? selection : (availablePlugins.first?.id ?? "") },
                set: { selection = $0 }
            )) {
                ForEach(availablePlugins, id: \.id) { plugin in
                    Text(plugin.manifest.name).tag(plugin.id)
                }
            }.padding(.horizontal, 28).padding(.bottom, 12)
            if let plugin = availablePlugins.first(where: { $0.id == selection }) ?? availablePlugins.first {
                PluginSettingsView(focusedPluginId: plugin.id)
            }
        }
        .onAppear {
            if let providerId = ServiceContainer.shared.modelManagerService.selectedProviderId,
               let selected = plugins.loadedTranscriptionPlugin(for: providerId) {
                selection = selected.id
            }
        }
    }
}
