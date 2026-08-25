# TypeWhisper Plugins

TypeWhisper supports external plugins as macOS `.bundle` files. Place compiled bundles in:

```
~/Library/Application Support/TypeWhisper/Plugins/
```

The first-party plugin sources that ship with this repository now live under
`TypeWhisperPluginSDK/Plugins/`.

## Plugin Types

| Protocol | Purpose | Returns value? |
|---|---|---|
| `TypeWhisperPlugin` | Base protocol, event observation | No |
| `PostProcessorPlugin` | Transform text in the pipeline | Yes (processed text) |
| `LLMProviderPlugin` | Add custom LLM providers | Yes (LLM response) |
| `TTSProviderPlugin` | Add text-to-speech providers for spoken feedback and readback | Yes (playback session) |
| `TranscriptionEnginePlugin` | Custom transcription engines | Yes (transcription result) |
| `ActionPlugin` | Route LLM output to custom actions (e.g. create Linear issues) | Yes (action result) |
| `MediaImportPlugin` | Resolve a remote media link into a temporary local file | Yes (imported media) |
| `PluginUserInterfaceProviding` | Add host-rendered menu commands and plugin-owned settings-sidebar pages | No |

For transcription plugins, dictionary-term support remains optional. Engines that
have documented input limits can additionally conform to `DictionaryTermsBudgetProviding`
and return a `DictionaryTermsBudget` so the host clips the global dictionary before
request assembly. Legacy `v1` plugins that do not implement the budget protocol keep
working unchanged and automatically fall back to the host's default 600-character
dictionary prompt budget.

## Event Bus

Plugins can subscribe to events without modifying the transcription pipeline:

- `recordingStarted` - recording began
- `recordingStopped` - recording ended (with duration)
- `transcriptionCompleted` - transcription finished (with full payload)
- `transcriptionFailed` - transcription error
- `textInserted` - text was inserted into the target app
- `actionCompleted` - an action plugin finished executing (with result payload)

## Creating a Plugin

1. Create a new **macOS Bundle** target in Xcode
2. Add `TypeWhisperPluginSDK` as a package dependency
3. Implement `TypeWhisperPlugin` (or a subprotocol)
4. Add `manifest.json` to `Contents/Resources/`
5. Build and copy the `.bundle` to the Plugins directory

### manifest.json

```json
{
    "id": "com.yourname.plugin-id",
    "name": "My Plugin",
    "version": "1.0.0",
    "minHostVersion": "1.0.0",
    "sdkCompatibilityVersion": "v1",
    "minOSVersion": "14.0",
    "supportedArchitectures": ["arm64"],
    "author": "Your Name",
    "principalClass": "MyPluginClassName"
}
```

`category` may be one of `transcription`, `tts`, `llm`, `post-processor`, `action`, `memory`, or `utility`.

### Host Services

Each plugin receives a `HostServices` object providing:

- **Keychain**: `storeSecret(key:value:)`, `loadSecret(key:)`
- **UserDefaults** (plugin-scoped): `userDefault(forKey:)`, `setUserDefault(_:forKey:)`
- **Data directory**: `pluginDataDirectory` - persistent storage at `~/Library/Application Support/TypeWhisper/PluginData/<pluginId>/`
- **App context**: `activeAppBundleId`, `activeAppName`
- **Rules**: `availableRuleNames` - list of user-defined rule names
- **Event Bus**: `eventBus` for subscribing to events
- **Capabilities**: `notifyCapabilitiesChanged()` - notify the host when plugin state changes (e.g. model loaded/unloaded)
- **Settings**: `openPluginSettings()` - ask TypeWhisper to open this plugin's host-managed settings window
- **Settings sidebar**: `openSettingsSidebarItem(_:)` - open a sidebar page contributed by this plugin
- **Imported media**: `enqueueImportedMediaForTranscription(_:)` - hand downloaded media to TypeWhisper's transcription queue
- **Streaming display hint**: `setStreamingDisplayActive(_:)` - tell TypeWhisper that your plugin renders its own streaming UI

### Menu and menu-bar contributions (TypeWhisper 1.7+)

Plugins can optionally conform to `PluginUserInterfaceProviding` and return
localized `PluginCommandDescriptor` values in one or more placements:

- `appMenuCommands` appear in TypeWhisper's **Integrations** application menu,
  grouped in a submenu named after the plugin.
- `primaryMenuBarCommands` appear in the existing TypeWhisper menu-bar menu.
- `settingsSidebarItems` appear in the **Integrations** group of TypeWhisper's
  settings sidebar. The host requests their SwiftUI content through
  `settingsSidebarView(for:)`.

TypeWhisper owns the native menu objects, removes commands when the plugin is
disabled, and routes declared command identifiers back through
`performPluginCommand(_:)`. If a plugin changes its descriptors at runtime, it
must call `HostServices.notifyCapabilitiesChanged()`. Plugins using this API
should declare `"minHostVersion": "1.7.0"` in their manifest.

Media-import plugins download or otherwise resolve a URL into a local media
file. They can hand that file to the host with
`enqueueImportedMediaForTranscription(_:)`, while the host retains
responsibility for audio loading, transcription-engine selection, progress,
subtitles, and batch processing. The host returns temporary imports to the
plugin for cleanup when a queue item is removed.

Bundled MLX plugins such as Qwen3, Granite, and Voxtral store their optional HuggingFace token via the same plugin-scoped keychain helpers.

Bundled experimental local TTS plugins such as Supertonic store optional HuggingFace tokens the same way, but model weights are not bundled in the plugin ZIP. Supertonic downloads `Supertone/supertonic-3` assets only after the user accepts the OpenRAIL-M model license in plugin settings. That model-license confirmation is scoped to the model download and does not change TypeWhisper app licensing.

Bundled cloud plugins include Groq, OpenAI, OpenAI Compatible, and xAI/Grok. The xAI/Grok bundle is a combined `LLMProviderPlugin`, `TranscriptionEnginePlugin`, `LiveTranscriptionCapablePlugin`, and `TTSProviderPlugin` implementation for Grok text generation, STT, and TTS.

## Example

See `WebhookPlugin/` in `TypeWhisperPluginSDK/Plugins/` for a complete example that sends HTTP webhooks on each transcription.
