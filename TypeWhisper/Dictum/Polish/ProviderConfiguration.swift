import Foundation
import TypeWhisperPluginSDK

@MainActor
enum ProviderConfiguration {
    struct Choice: Identifiable {
        let id: String
        let name: String
        var preset: Bool = false
    }
    static var compatiblePlugin: NSObject? {
        PluginManager.shared?.loadedPlugins.first { $0.id == "com.typewhisper.openai-compatible" }?.instance as? NSObject
    }
    static var choices: [Choice] {
        let native = PluginManager.shared.loadedPlugins.compactMap { loaded -> Choice? in
            guard loaded.id != "com.typewhisper.openai-compatible",
                  let provider = loaded.instance as? any LLMProviderPlugin else { return nil }
            return Choice(id: provider.llmProviderId, name: displayName(provider))
        }
        let selector = NSSelectorFromString("dictumPresets")
        let presets = compatiblePlugin?.responds(to: selector) == true
            ? compatiblePlugin?.perform(selector)?.takeUnretainedValue() as? [[String: String]] ?? [] : []
        return native + presets.compactMap { value in
            guard let id = value["id"], let name = value["name"] else { return nil }
            return Choice(id: id, name: localizedName(name), preset: true)
        } + [Choice(id: "custom", name: String(localized: "OpenAI Compatible", table: "DictumStyle"), preset: true)]
    }
    static func displayName(_ provider: any LLMProviderPlugin) -> String {
        switch type(of: provider).pluginId {
        case "com.typewhisper.openai": return "OpenAI"
        case "com.typewhisper.claude": return "Anthropic"
        default: return localizedName(provider.llmProviderDisplayName)
        }
    }
    private static func localizedName(_ name: String) -> String {
        switch name {
        case "通义千问", "智谱", "硅基流动":
            return String(localized: String.LocalizationValue(name), table: "DictumStyle")
        default: return name
        }
    }
    static func configure(_ values: [String: Any]) throws -> [String: Any] {
        let selector = NSSelectorFromString("dictumConfigure:")
        guard let plugin = compatiblePlugin, plugin.responds(to: selector),
              let result = plugin.perform(selector, with: values as NSDictionary)?.takeUnretainedValue() as? [String: Any],
              result["error"] == nil else { throw ConfigurationError.unavailable }
        return result
    }
    static func saveKey(_ key: String, providerID: String) throws {
        if providerID.hasPrefix("openai-compatible") {
            _ = try configure(["id": providerID, "key": key])
            refreshModels(providerID)
        } else {
            guard let provider = PluginManager.shared.llmProvider(for: providerID) else { throw ConfigurationError.unavailable }
            let pluginID = type(of: provider).pluginId
            try KeychainService.save(key: key, service: pluginID + ".api-key")
            PluginManager.shared.setPluginEnabled(pluginID, enabled: true)
        }
    }
    static func removeProfile(_ providerID: String) {
        let selector = NSSelectorFromString("dictumRemoveProfile:")
        if providerID.hasPrefix("openai-compatible:"), compatiblePlugin?.responds(to: selector) == true {
            compatiblePlugin?.perform(selector, with: providerID)
        }
    }
    static func refreshModels(_ providerID: String) {
        let selector = NSSelectorFromString("dictumRefreshModels:")
        if compatiblePlugin?.responds(to: selector) == true {
            compatiblePlugin?.perform(selector, with: providerID)
        }
    }
    static func connectionErrorKey(_ error: Error) -> String {
        if let error = error as? PluginChatError {
            switch error {
            case .invalidApiKey: return "provider.error.401"
            case .rateLimited: return "provider.error.429"
            default: break
            }
        }
        return ["401", "402", "429"].first { error.localizedDescription.contains($0) }
            .map { "provider.error." + $0 } ?? "provider.error.network"
    }
    enum ConfigurationError: Error { case unavailable }
}
