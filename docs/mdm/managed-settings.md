# Managed settings on macOS

Administrators configure TypeWhisper through configuration profiles with a custom
settings payload (`com.apple.ManagedClient.preferences`), the mechanism Iru, Jamf
and other MDMs use for app preferences. The key names, values and precedence match
the [registry policies of TypeWhisper for Windows](https://github.com/TypeWhisper/typewhisper-win/blob/main/docs/enterprise/windows-managed-settings.md),
so one set of decisions applies to both platforms. The contract and the remaining
work are tracked in [#1313](https://github.com/TypeWhisper/typewhisper-mac/issues/1313).

## Preference domains

| Edition | Domain |
| --- | --- |
| TypeWhisper (direct download) | `com.typewhisper.mac` |
| TypeWhisper from the Mac App Store | `com.typewhisper.typewhisper-app` |
| Development builds | the same domains with a `.dev` suffix |

## Profile layout

Only values the profile forces count. Keys at the top level of the payload are
enforced: users cannot change them. Keys inside a `Recommended` dictionary are
administrator defaults: they apply until the user makes an explicit choice and stay
editable. Precedence is enforced value, then the user's explicit choice, then the
recommendation, then the application default. TypeWhisper never writes these values
and never stores the effective result over a user's own setting, so removing a value
brings the user's setting back.

```xml
<key>PayloadContent</key>
<dict>
    <key>com.typewhisper.mac</key>
    <dict>
        <key>Forced</key>
        <array>
            <dict>
                <key>mcx_preference_settings</key>
                <dict>
                    <key>UpdateMode</key>
                    <integer>1</integer>
                    <key>AllowedUpdateChannels</key>
                    <array>
                        <string>stable</string>
                    </array>
                    <key>SuppressOptionalPrompts</key>
                    <true/>
                    <key>Recommended</key>
                    <dict>
                        <key>LaunchAtLogin</key>
                        <true/>
                    </dict>
                </dict>
            </dict>
        </array>
    </dict>
</dict>
```

The surrounding profile is the same as in the
[license example](TypeWhisper-License.mobileconfig). Device and user scope both
work.

- Booleans are `<true/>` or `<false/>`; `<integer>1</integer>` is not a Boolean.
- Enumerations are integers.
- Text is a string, trimmed, at most 1024 characters, without control characters.
- Lists are arrays of strings, at most 256. An empty array, or the single entry
  `none`, denies everything.
- Key names are case-sensitive. A key that differs only in letter case is reported
  with the intended name and ignored.

A value of the wrong type is invalid. An invalid enforced value blocks its setting
until it is corrected; it never relaxes anything. An invalid recommendation is
reported and ignored. Restrictions placed in `Recommended` are reported and ignored.
Values written with `defaults write` are user-writable and therefore ignored and
reported; `ManagedLicenseKey` is the one exception, see
[managed license activation](README.md).

TypeWhisper reads the profile at launch, before any other setting is used, and again
when the app becomes active, after wake, after switching back to the user session
and every 30 seconds. macOS has no change notification for profiles, so a new,
replaced or removed profile takes effect within about 30 seconds without a restart.

Settings > Advanced > Managed Settings lists the managed values, invalid keys and
policy problems, with the time of the last check and a Refresh button. The support
diagnostics contain the same information; the license key appears only as `[set]`.

## Supported keys

| Key | Type | Scope | Behavior |
| --- | --- | --- | --- |
| `ManagedLicenseKey` | String | enforced | Activates a commercial license for the signed-in user. See [managed license activation](README.md). A changed key is applied without restarting. Not available in the App Store edition. |
| `UpdateMode` | Integer 0–2 | enforced | 0 = External: no update checks, downloads or installations; Settings states that the organization manages updates. 1 = CheckOnly: TypeWhisper checks at launch, when the policy changes and on Sparkle's schedule, and shows a newer version in Settings > About without installing it. 2 = UserInitiated: updates install only when the user chooses Check for Updates; automatic background downloads are refused. Unset keeps the normal update behavior. In every mode the app does not ask whether to check automatically. |
| `UpdateChannel` | Integer 0–2 | enforced or recommended | 0 = Stable, 1 = Daily, 2 = Release Candidate. Enforced locks the channel picker; recommended is the channel of a user who never chose one. |
| `AllowedUpdateChannels` | Array | enforced | Entries `stable`, `daily`, `release-candidate`. The picker offers only these channels, and checks on any other channel are refused. An empty array, or `none`, turns app updates off. An enforced `UpdateChannel` outside the list is a policy problem that turns updates off; TypeWhisper never switches channels on its own. |
| `LaunchAtLogin` | Boolean | enforced or recommended | Enforced registers or removes TypeWhisper's login item and locks the setting. The state before enforcement is restored once the value is removed. Recommended applies once, to a user who has not completed setup and has not chosen. See [login items](#login-items). |
| `SkipOnboardingWhenReady` | Boolean | enforced | `true` keeps the setup wizard closed when a transcription engine is ready, the microphone and (outside the App Store edition) Accessibility are granted, and a dictation shortcut exists. Otherwise setup opens at the first missing step instead of the welcome page. Nothing is marked as completed, so setup returns if a prerequisite goes missing or the value is removed. |
| `AllowCloudTranscription` | Boolean | enforced | `false` keeps audio on the Mac: only plugins whose locality is `local` transcribe. Dictation, file transcription, the Recorder, watch folders, recovery, history re-transcription and the HTTP API refuse a refused engine with the reason (the API answers 403) instead of sending audio. |
| `AllowCloudTextProcessing` | Boolean | enforced | `false` keeps transcripts, prompts, dictionary terms and context on the Mac: language models, post-processors, actions, speech output, memory plugins and event subscribers that are not local receive nothing. Dictionary terms are not sent as prompt text to a transcription engine that is not local. |
| `AllowedTranscriptionProviders` | Array | enforced | Provider IDs that may receive audio (see [provider IDs](#provider-ids)). Applies to every entry point, including workflow and API overrides. |
| `AllowedLlmProviders` | Array | enforced | Provider IDs that may receive text, including workflows, prompts, translation by language model and memory extraction. Apple Intelligence is `com.typewhisper.apple-intelligence`. |
| `AllowedPlugins` | Array | enforced | Plugin IDs that may be installed, loaded and enabled. A plugin outside the list never loads; one that is running when the list changes stops and loads again once the list allows it. |
| `AllowPluginDownloads` | Boolean | enforced | `false` refuses installing and updating plugins from the Marketplace, from settings backups, from setup and from files. Installed plugins keep running. |
| `AllowModelDownloads` | Boolean | enforced | `false` refuses model downloads: models a plugin downloads from its settings, while loading or when restoring, Hugging Face imports, and the speaker detection models. Installed models keep working. Requires plugin versions built for TypeWhisper 1.8. |
| `SuppressOptionalPrompts` | Boolean | enforced or recommended | `true` hides the automatic What's New window, the iPhone app promotion, the work-use license card on the dashboard and the Unlock button on the Premium page. License, setup, permission, policy and error messages stay visible; What's New and access management remain available from Settings. |

The App Store edition is updated by the App Store and has its plugins built in:
`UpdateMode`, `UpdateChannel`, `AllowedUpdateChannels`, `AllowPluginDownloads` and
`ManagedLicenseKey` do not apply there and are listed as policy problems.

The provider and model pair keys (`TranscriptionProviderId`, `TranscriptionModelId`,
`LlmProviderId`, `LlmModelId`) are validated and listed but have no effect yet.

## Provider IDs

Policies name providers by plugin ID, the `id` of the plugin's manifest, for example
`com.typewhisper.parakeet`, `com.typewhisper.whisperkit` or `com.typewhisper.groq`.
A plugin ID covers every provider the plugin offers. To allow a single provider of a
plugin with several, such as one endpoint profile of OpenAI Compatible, use
`<plugin ID>:<provider ID>`. Apple Intelligence, which is built into the app, is
`com.typewhisper.apple-intelligence`. Matching ignores letter case. Plugin IDs differ
from TypeWhisper for Windows for some plugins; Parakeet is `com.typewhisper.parakeet`
on macOS and `com.typewhisper.sherpa-onnx` on Windows.

## Plugin locality

Every plugin manifest declares where it processes content in its `locality` field,
and the plugin catalog publishes it: `local` (nothing leaves the Mac), `cloud` (the
vendor's fixed service) or `configurable` (an endpoint, script or command the user
configures, which TypeWhisper cannot classify). Under `AllowCloudTranscription` or
`AllowCloudTextProcessing` only `local` plugins keep receiving that content; `cloud`,
`configurable` and plugins without a known value are refused. Plugin versions released
before TypeWhisper 1.8 have no `locality` and are refused under these keys, so update
plugins before applying them.

A plugin that is not local and whose every capability (its manifest categories) is
refused is refused as a whole: it is neither installed, loaded nor enabled, and the
Marketplace and its plugin page show the reason. A plugin with an allowed capability
keeps running, and its refused capability is refused where it is used; refused
engines and language models disappear from the pickers.

When the selected engine is refused, TypeWhisper falls back to an allowed engine for
the moment, as it does for any unavailable engine, and keeps the user's choice for
when it is allowed again. When no allowed engine is ready, dictation reports the
reason.

Known limits:

- Code of a plugin that was running when it became refused stays loaded until
  TypeWhisper quits; the plugin receives no further calls.
- Configuration actions in a plugin's settings, such as validating an API key, still
  run; they carry credentials, not transcripts.
- Audio a streaming engine received before a stricter policy arrived cannot be
  recalled; the policy applies again at the next request.
- A plugin refused as a whole never runs, so TypeWhisper learns its engine IDs only
  from an earlier launch of TypeWhisper 1.8 or later. If the selected engine belongs
  to such a plugin, dictation can report that no engine is selected instead of the
  reason when no allowed engine is ready.
- These keys govern TypeWhisper's behavior. They are not a network firewall: use
  your MDM's network controls for stronger guarantees.

## Updates

TypeWhisper updates itself with Sparkle from
`https://typewhisper.github.io/typewhisper-mac/appcast.xml`. An update that Sparkle
downloaded for automatic installation before a restrictive `UpdateMode` arrived can
still install when TypeWhisper quits; Sparkle offers no way to cancel it. Deploy the
policy together with the app to avoid that window.

## Login items

macOS lists TypeWhisper in System Settings > General > Login Items & Extensions,
where users can turn it off even while `LaunchAtLogin` is enforced; Settings >
General in TypeWhisper then shows that the item needs approval. To approve and lock
the item, add a Service Management payload
(`com.apple.servicemanagement`, macOS 13 or later, delivered by MDM) with a rule for
TypeWhisper's team identifier `2D8ALY3LCL` or bundle identifier. An app that is never
started cannot register its login item, so launch it once after installation.
