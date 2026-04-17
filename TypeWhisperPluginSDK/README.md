# TypeWhisper Plugin SDK

Build plugins for [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) to add transcription engines, text-to-speech providers, LLM providers, post-processors, and custom actions.

## Quick Start

### 1. Create an Xcode Bundle Target

In your Xcode project (or the TypeWhisper project itself):

1. **File > New > Target > macOS > Bundle**
2. Set **Product Name** to your plugin name (e.g. `MyPlugin`)
3. Add the `TypeWhisperPluginSDK` package as a dependency

### 2. Add a Manifest

Create `Contents/Resources/manifest.json` in your bundle:

```json
{
  "id": "com.yourname.myplugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "minHostVersion": "1.0.0",
  "sdkCompatibilityVersion": "v1",
  "minOSVersion": "14.0",
  "author": "Your Name",
  "principalClass": "MyPlugin"
}
```

- `id` - Unique reverse-domain identifier
- `principalClass` - Must match `@objc(ClassName)` on your plugin class
- `minHostVersion` - Minimum TypeWhisper version required
- `sdkCompatibilityVersion` - Must match `PluginSDKCompatibility.currentVersion` for marketplace/external plugins
- `minOSVersion` - Minimum macOS version required (plugin is skipped on older systems)

### 3. Implement the Plugin

```swift
import Foundation
import SwiftUI
import TypeWhisperPluginSDK

@objc(MyPlugin)
final class MyPlugin: NSObject, PostProcessorPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.myplugin"
    static let pluginName = "My Plugin"

    private var host: HostServices?

    required override init() { super.init() }

    func activate(host: HostServices) {
        self.host = host
    }

    func deactivate() {
        host = nil
    }

    // PostProcessorPlugin
    var processorName: String { "My Processor" }
    var priority: Int { 500 }

    @MainActor
    func process(text: String, context: PostProcessingContext) async throws -> String {
        // Transform text here
        return text.uppercased()
    }
}
```

### 4. Install and Test

Build your plugin, then install it using one of:

- **Install from File**: Settings > Integrations > Install from File... (select the `.bundle`)
- **Manual**: Copy the `.bundle` to `~/Library/Application Support/TypeWhisper/Plugins/`
- **Symlink** (development): `ln -s /path/to/DerivedData/.../MyPlugin.bundle ~/Library/Application\ Support/TypeWhisper/Plugins/`

Enable your plugin in Settings > Integrations.

---

## Plugin Types

### TranscriptionEnginePlugin

Add a speech-to-text engine. Receives raw audio, returns text.

```swift
@objc(MyTranscriptionEngine)
final class MyTranscriptionEngine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.mytranscription"
    static let pluginName = "My Transcription"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var providerId: String { "my-engine" }
    var providerDisplayName: String { "My Engine" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] {
        [PluginModelInfo(id: "default", displayName: "Default Model")]
    }
    var selectedModelId: String? { "default" }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        // audio.samples  - [Float] 16kHz mono PCM
        // audio.wavData   - Pre-encoded WAV Data
        // audio.duration  - TimeInterval
        let text = "transcribed text"
        return PluginTranscriptionResult(text: text)
    }
}
```

If your engine exposes a wider selectable catalog than its currently loaded
`transcriptionModels`, add the optional `TranscriptionModelCatalogProviding`
conformance:

```swift
extension MyTranscriptionEngine: TranscriptionModelCatalogProviding {
    var availableModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "small", displayName: "Small"),
            PluginModelInfo(id: "large", displayName: "Large")
        ]
    }
}
```

### LLMProviderPlugin

Add an LLM for prompt processing (text transformation, summarization, etc.).

```swift
@objc(MyLLMProvider)
final class MyLLMProvider: NSObject, LLMProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.myllm"
    static let pluginName = "My LLM"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var providerName: String { "My LLM" }
    var isAvailable: Bool { host?.loadSecret(key: "apiKey") != nil }
    var supportedModels: [PluginModelInfo] {
        [PluginModelInfo(id: "my-model", displayName: "My Model")]
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        let apiKey = host?.loadSecret(key: "apiKey") ?? ""
        // Call your LLM API here
        return "processed result"
    }
}
```

For OpenAI-compatible APIs, use the built-in helper:

```swift
let helper = PluginOpenAIChatHelper(baseURL: "https://api.example.com")
let result = try await helper.process(
    apiKey: apiKey, model: "my-model",
    systemPrompt: systemPrompt, userText: userText
)
```

### TTSProviderPlugin

Add a text-to-speech provider for spoken feedback and manual readback.

```swift
@objc(MyTTSProvider)
final class MyTTSProvider: NSObject, TTSProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.mytts"
    static let pluginName = "My TTS"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var providerId: String { "my-tts" }
    var providerDisplayName: String { "My TTS" }
    var isConfigured: Bool { true }
    var availableVoices: [PluginVoiceInfo] {
        [PluginVoiceInfo(id: "default", displayName: "Default Voice")]
    }
    var selectedVoiceId: String? { nil }
    func selectVoice(_ voiceId: String?) {}

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        // request.text     - text to speak
        // request.language - optional language hint
        // request.purpose  - .status, .transcription, or .manualReadback
        MyPlaybackSession()
    }
}
```

`TTSPlaybackSession` must keep track of active playback so TypeWhisper can stop or replace it:

```swift
final class MyPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    var isActive: Bool = true
    var onFinish: (@Sendable () -> Void)?

    func stop() {
        isActive = false
        onFinish?()
    }
}
```

### PostProcessorPlugin

Transform text after transcription. Runs in priority order (lower = earlier).

```swift
var processorName: String { "My Processor" }
var priority: Int { 500 }  // Built-in: LLM=300, Snippets=500, Dictionary=600

@MainActor
func process(text: String, context: PostProcessingContext) async throws -> String {
    // context.appName           - Active app name
    // context.bundleIdentifier  - Active app bundle ID
    // context.url               - Browser URL (if available)
    // context.language          - Detected language
    return text
}
```

### ActionPlugin

Perform custom actions on text (e.g. create issues, send to APIs).

```swift
@objc(MyAction)
final class MyAction: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = "com.yourname.myaction"
    static let pluginName = "My Action"

    private var host: HostServices?

    required override init() { super.init() }
    func activate(host: HostServices) { self.host = host }
    func deactivate() { host = nil }

    var actionName: String { "Do Something" }
    var actionId: String { "my-action" }
    var actionIcon: String { "star.fill" }  // SF Symbol name

    func execute(input: String, context: ActionContext) async throws -> ActionResult {
        // context.originalText - text before LLM processing
        // input                - text after LLM processing
        return ActionResult(
            success: true,
            message: "Done!",
            url: "https://example.com",       // optional, makes result clickable
            icon: "checkmark.circle.fill",     // optional SF Symbol
            displayDuration: 3.0              // optional, seconds to show feedback
        )
    }
}
```

### Multi-Purpose Plugins

A single plugin class can conform to multiple protocols:

```swift
@objc(MyCloudPlugin)
final class MyCloudPlugin: NSObject, TranscriptionEnginePlugin, LLMProviderPlugin, @unchecked Sendable {
    // Implement both protocols in one plugin
}
```

---

## Host Services

Plugins receive a `HostServices` instance on activation:

```swift
func activate(host: HostServices) {
    self.host = host

    // Secure storage (plugin-scoped keychain)
    try host.storeSecret(key: "apiKey", value: "sk-...")
    let key = host.loadSecret(key: "apiKey")

    // Preferences (plugin-scoped UserDefaults)
    host.setUserDefault("value", forKey: "myPref")
    let pref = host.userDefault(forKey: "myPref")

    // File storage (~/Library/Application Support/TypeWhisper/PluginData/<pluginId>/)
    let dataDir = host.pluginDataDirectory

    // App context
    let appName = host.activeAppName
    let bundleId = host.activeAppBundleId

    // Rule names
    let rules = host.availableRuleNames

    // Host UI coordination
    host.notifyCapabilitiesChanged()
    host.setStreamingDisplayActive(true)
}
```

---

## Event Bus

Subscribe to app events:

```swift
func activate(host: HostServices) {
    host.eventBus.subscribe { event in
        switch event {
        case .transcriptionCompleted(let payload):
            print("Transcribed: \(payload.finalText)")
            print("Engine: \(payload.engineUsed)")
            print("App: \(payload.appName ?? "unknown")")
        case .recordingStarted(let payload):
            print("Recording started at \(payload.timestamp)")
        case .recordingStopped(let payload):
            print("Duration: \(payload.durationSeconds)s")
        case .textInserted(let payload):
            print("Inserted: \(payload.text)")
        case .actionCompleted(let payload):
            print("Action \(payload.actionId): \(payload.message)")
        case .transcriptionFailed(let payload):
            print("Error: \(payload.error)")
        }
    }
}
```

---

## Settings UI

Provide a SwiftUI view for plugin configuration:

```swift
var settingsView: AnyView? {
    AnyView(MySettingsView(plugin: self))
}
```

The view appears as a sheet when the user clicks the gear icon in Settings > Integrations.

---

## Built-in Helpers

### PluginOpenAITranscriptionHelper

For OpenAI-compatible Whisper APIs. Clips shorter than one second are padded automatically before upload so providers do not reject them as too short:

```swift
let helper = PluginOpenAITranscriptionHelper(baseURL: "https://api.groq.com/openai")
let result = try await helper.transcribe(
    audio: audio, apiKey: apiKey, modelName: "whisper-large-v3",
    language: "en", translate: false, prompt: nil
)
```

### PluginAudioUtils

Helpers for short-clip handling:

```swift
let padded = PluginAudioUtils.paddedSamples(samples, minimumDuration: 1.0)
let shouldKeep = PluginAudioUtils.shouldAcceptShortClipTranscription(
    audioDuration: audio.duration,
    confidence: confidence
)
```

### PluginOpenAIChatHelper

For OpenAI-compatible chat APIs:

```swift
let helper = PluginOpenAIChatHelper(baseURL: "https://api.openai.com")
let result = try await helper.process(
    apiKey: apiKey, model: "gpt-4o",
    systemPrompt: "Fix grammar", userText: inputText
)
```

You can override or omit the output-token parameter for providers that do not use the
default `max_tokens` field, and optionally control whether `temperature` is sent:

```swift
let result = try await helper.process(
    apiKey: apiKey,
    model: "gpt-5.4",
    systemPrompt: "Fix grammar",
    userText: inputText,
    maxOutputTokens: 4096,
    maxOutputTokenParameter: "max_completion_tokens"
)
```

For GPT-5 chat-completions requests with reasoning enabled, omit `temperature` entirely:

```swift
let result = try await helper.process(
    apiKey: apiKey,
    model: "gpt-5.4",
    systemPrompt: "Fix grammar",
    userText: inputText,
    maxOutputTokens: 4096,
    maxOutputTokenParameter: "max_completion_tokens",
    reasoningEffort: "medium",
    temperature: nil
)
```

This helper stays provider-agnostic. OpenAI-compatible servers may expect different
token-limit parameter names, so plugin authors should set the appropriate field for
their provider when needed.

### PluginWavEncoder

Encode audio samples to WAV:

```swift
let wavData = PluginWavEncoder.encode(samples, sampleRate: 16000)
```

---

## Manifest Reference

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Unique reverse-domain ID (e.g. `com.yourname.myplugin`) |
| `name` | Yes | Display name |
| `version` | Yes | Semver string (e.g. `1.0.0`) |
| `minHostVersion` | No | Minimum TypeWhisper version (e.g. `1.0.0`) |
| `sdkCompatibilityVersion` | No | Exact plugin SDK compatibility line. Marketplace/external plugins must match `PluginSDKCompatibility.currentVersion`. |
| `minOSVersion` | No | Minimum macOS version (e.g. `14.0`, `26.0`). Plugin is skipped on older systems. |
| `author` | No | Author name |
| `principalClass` | Yes | Objective-C class name, must match `@objc(Name)` |

---

## Publishing

To distribute via the TypeWhisper plugin marketplace:

1. Build your plugin in Release configuration
2. ZIP the `.bundle`: `ditto -ck --sequesterRsrc MyPlugin.bundle MyPlugin.zip`
3. Host the ZIP (GitHub Releases, your own server, etc.)
4. Submit a PR to add your plugin to the [plugin registry](https://github.com/TypeWhisper/typewhisper-mac/blob/gh-pages/plugins.json)

Registry entry format:

```json
{
  "id": "com.yourname.myplugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "minHostVersion": "1.0.0",
  "sdkCompatibilityVersion": "v1",
  "minOSVersion": "14.0",
  "author": "Your Name",
  "description": "What your plugin does.",
  "category": "transcription|tts|llm|post-processor|action|memory|utility",
  "size": 12345678,
  "downloadURL": "https://example.com/MyPlugin.zip",
  "iconSystemName": "star.fill"
}
```

---

## Requirements

- macOS 14.0+
- Swift 6.0
- TypeWhisper 1.0+
