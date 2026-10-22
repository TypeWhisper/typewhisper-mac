import SwiftUI
import TypeWhisperPluginSDK

struct AIModelsPage: View {
    @ObservedObject private var plugins = PluginManager.shared
    @State private var selection = ""

    private var availablePlugins: [LoadedPlugin] {
        plugins.loadedPlugins.filter { $0.instance is any LLMProviderPlugin }
            .sorted { $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending }
    }

    private var selectedPlugin: LoadedPlugin? {
        availablePlugins.first { $0.id == selection } ?? availablePlugins.first
    }

    var body: some View {
        DictumPageFrame(page: .aiModels, actions: {
            Picker(selection: Binding(
                get: { selectedPlugin?.id ?? "" },
                set: { selection = $0 }
            )) {
                ForEach(availablePlugins, id: \.id) { plugin in
                    Text(verbatim: plugin.manifest.name).tag(plugin.id)
                }
            } label: {
                Text("AI Models", tableName: "DictumShell")
            }
            .labelsHidden().fixedSize().tint(.primary)
        }) {
            if let plugin = selectedPlugin {
                PluginSettingsView(focusedPluginId: plugin.id)
            }
        }
    }
}
