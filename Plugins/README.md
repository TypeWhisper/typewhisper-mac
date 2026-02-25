# TypeWhisper Plugins

TypeWhisper supports external plugins as macOS `.bundle` files. Place compiled bundles in:

```
~/Library/Application Support/TypeWhisper/Plugins/
```

## Plugin Types

| Protocol | Purpose | Returns value? |
|---|---|---|
| `TypeWhisperPlugin` | Base protocol, event observation | No |
| `PostProcessorPlugin` | Transform text in the pipeline | Yes (processed text) |
| `LLMProviderPlugin` | Add custom LLM providers | Yes (LLM response) |
| `TranscriptionEnginePlugin` | Custom transcription engines | Yes (transcription result) |
| `ActionPlugin` | Route LLM output to custom actions (e.g. create Linear issues) | Yes (action result) |

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
    "minHostVersion": "0.9.0",
    "author": "Your Name",
    "principalClass": "MyPluginClassName"
}
```

### Host Services

Each plugin receives a `HostServices` object providing:

- **Keychain**: `storeSecret(key:value:)`, `loadSecret(key:)`
- **UserDefaults** (plugin-scoped): `userDefault(forKey:)`, `setUserDefault(_:forKey:)`
- **Data directory**: `pluginDataDirectory` - persistent storage at `~/Library/Application Support/TypeWhisper/PluginData/<pluginId>/`
- **App context**: `activeAppBundleId`, `activeAppName`
- **Event Bus**: `eventBus` for subscribing to events

## Example

See `WebhookPlugin/` for a complete example that sends HTTP webhooks on each transcription.
