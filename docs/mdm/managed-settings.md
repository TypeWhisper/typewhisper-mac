# Managed settings on macOS (TypeWhisper 1.8 and later)

Administrators configure TypeWhisper through configuration profiles that set
managed preferences for its preference domain, the mechanism Iru, Jamf and other
MDMs use for app preferences. The key names, values and precedence match
the [registry policies of TypeWhisper for Windows](https://github.com/TypeWhisper/typewhisper-win/blob/main/docs/enterprise/windows-managed-settings.md),
so one set of decisions applies to both platforms. Example profiles, a profile
generator and schemas for Jamf Pro and profile editors are in
[`deployment/macos`](../../deployment/macos); see [deployment files](#deployment-files).

## Preference domains

| Edition | Domain |
| --- | --- |
| TypeWhisper (direct download) | `com.typewhisper.mac` |
| TypeWhisper from the Mac App Store | `com.typewhisper.typewhisper-app` |
| Development builds | the same domains with a `.dev` suffix |
| Screenshot runs (`--store-screenshots`, Debug builds) | `com.typewhisper.mac.screenshots` |

## Profile layout

Only values the profile forces count. Keys at the top level of the payload are
enforced: users cannot change them. Keys inside a `Recommended` dictionary are
administrator defaults: they apply until the user makes an explicit choice and stay
editable. Precedence is enforced value, then the user's explicit choice, then the
recommendation, then the application default. TypeWhisper never writes these values
and never stores the effective result over a user's own setting, so removing a value
brings the user's setting back.

Each payload names the domain as its `PayloadType` and holds the settings next to
its own `Payload` keys. System Settings then lists every setting with its value when
the profile is installed:

```xml
<dict>
    <key>PayloadType</key>
    <string>com.typewhisper.mac</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>PayloadIdentifier</key>
    <string>com.example.typewhisper.com.typewhisper.mac</string>
    <key>PayloadUUID</key>
    <string>0D5A3A6E-9C1B-4F3A-8E2D-6B7C1F0A2E41</string>
    <key>PayloadDisplayName</key>
    <string>TypeWhisper managed settings</string>
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
```

The surrounding profile is the same as in the
[examples](../../deployment/macos/examples). The custom settings payload
(`com.apple.ManagedClient.preferences`) with the values under `Forced` >
`mcx_preference_settings`, as in the [license example](TypeWhisper-License.mobileconfig),
works the same way. Device and user scope both work. macOS copies some keys of the
profile itself into the domain, such as `PayloadUUID` and `_manualProfile`;
TypeWhisper ignores keys that start with `Payload` or `_`.

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
reported.

TypeWhisper reads the profile at launch, before any other setting is used, and again
when the app becomes active, after wake, after switching back to the user session
and every 30 seconds. macOS has no change notification for profiles, so a new,
replaced or removed profile takes effect within about 30 seconds without a restart.

Settings > Advanced > Managed Settings lists the managed values, invalid keys and
policy problems, with the time of the last check and a Refresh button. The support
diagnostics contain the same information.

## Supported keys

| Key | Type | Scope | Behavior |
| --- | --- | --- | --- |
| `UpdateMode` | Integer 0–2 | enforced | 0 = External: no update checks, downloads or installations; Settings states that the organization manages updates. 1 = CheckOnly: TypeWhisper checks at launch, when the policy changes and on Sparkle's schedule, and shows a newer version in Settings > About without installing it. 2 = UserInitiated: updates install only when the user chooses Check for Updates; automatic background downloads are refused. Unset keeps the normal update behavior. In every mode the app does not ask whether to check automatically. |
| `UpdateChannel` | Integer 0–2 | enforced or recommended | 0 = Stable, 1 = Daily, 2 = Release Candidate. Enforced locks the channel picker; recommended is the channel of a user who never chose one. |
| `AllowedUpdateChannels` | Array | enforced | Entries `stable`, `daily`, `release-candidate`. The picker offers only these channels, and checks on any other channel are refused. An empty array, or `none` as the only entry, turns app updates off; next to a channel, `none` is ignored. An enforced `UpdateChannel` outside the list is a policy problem that turns updates off; TypeWhisper never switches channels on its own. |
| `LaunchAtLogin` | Boolean | enforced or recommended | Enforced registers or removes TypeWhisper's login item and locks the setting. The state before enforcement is restored once the value is removed. Recommended applies once, to a user who has not completed setup and has not chosen. See [login items](#login-items). |
| `SkipOnboardingWhenReady` | Boolean | enforced | `true` keeps the setup wizard closed when a transcription engine is ready, the microphone and (outside the App Store edition) Accessibility are granted, and a dictation shortcut exists. Otherwise setup opens at the first missing step instead of the welcome page. Nothing is marked as completed, so setup returns if a prerequisite goes missing or the value is removed. |
| `TranscriptionProviderId`, `TranscriptionModelId` | String pair | enforced or recommended | Enforced fixes the transcription engine and model for every entry point; see [provider and model pairs](#provider-and-model-pairs). Recommended is the initial selection of a user who never chose an engine. Both values must be set at the same scope. |
| `LlmProviderId`, `LlmModelId` | String pair | enforced or recommended | Enforced replaces the provider and model of every language model call: workflows, prompts, the fallback list, translation by language model and the text processing API. Recommended replaces the built-in default language model of a user who never changed it. Both values must be set at the same scope. |
| `AllowCloudTranscription` | Boolean | enforced | `false` keeps audio on the Mac: only plugins whose locality is `local` transcribe. Dictation, file transcription, the Recorder, watch folders, recovery, history re-transcription and the HTTP API refuse a refused engine with the reason (the API answers 403) instead of sending audio. |
| `AllowCloudTextProcessing` | Boolean | enforced | `false` keeps transcripts, prompts, dictionary terms and context on the Mac: language models, post-processors, actions, speech output, memory plugins and event subscribers that are not local receive nothing. Dictionary terms are not sent as prompt text to a transcription engine that is not local. |
| `AllowedTranscriptionProviders` | Array | enforced | Provider IDs that may receive audio (see [provider IDs](#provider-ids)). Applies to every entry point, including workflow and API overrides. |
| `AllowedLlmProviders` | Array | enforced | Provider IDs that may receive text, including workflows, prompts, translation by language model and memory extraction. Apple Intelligence is `com.typewhisper.apple-intelligence`. |
| `AllowedPlugins` | Array | enforced | Plugin IDs that may be installed, loaded and enabled. A plugin outside the list never loads; one that is running when the list changes stops and loads again once the list allows it. |
| `AllowPluginDownloads` | Boolean | enforced | `false` refuses installing and updating plugins from the Marketplace, from settings backups, from setup and from files. Installed plugins keep running. |
| `AllowModelDownloads` | Boolean | enforced | `false` refuses model downloads: models a plugin downloads from its settings, while loading or when restoring, Hugging Face imports, and the speaker detection models. Installed models keep working. Requires plugin versions built for TypeWhisper 1.8. |
| `SuppressOptionalPrompts` | Boolean | enforced or recommended | `true` hides the automatic What's New window, the iPhone app promotion, the work-use license card on the dashboard and the Unlock button on the Premium page. License, setup, permission, policy and error messages stay visible; What's New and access management remain available from Settings. |

The App Store edition is updated by the App Store and has its plugins built in:
`UpdateMode`, `UpdateChannel`, `AllowedUpdateChannels` and `AllowPluginDownloads`
do not apply there and are listed as policy problems.

## Provider and model pairs

A pair names a provider by its [provider ID](#provider-ids) and a model by the ID the
provider lists, for example `com.typewhisper.parakeet` with
`parakeet-tdt-0.6b-v3`, or `com.typewhisper.groq` with `whisper-large-v3`.
Apple Intelligence has a single model and accepts any model ID, for example
`default`. Providers that list no models accept the ID as written.

An **enforced transcription pair** is used by dictation, its live preview, file
transcription, the Recorder, watch folders, recovery, history re-transcription and
the HTTP API, regardless of the selected engine, workflow overrides or per-feature
engines. An API request that asks for another engine or model, or to load another
model, gets 403. The engine and model pickers are locked. The user's own engine
selection is kept and applies again once the pair is removed.

Parakeet 1.5.0 and WhisperKit 1.3.0 or later use the enforced model without saving it.
Once the pair is removed, they return to the model the user had selected, or to no
model, also when the profile was removed while TypeWhisper was not running. A model the
user picks on the engine's settings page meanwhile is saved and used after the pair is
removed. Other engines save the enforced model as their selection: TypeWhisper selects
the user's model again once the pair is removed, but if the engine had no model
selected, the enforced model stays selected.

An **enforced LLM pair** replaces the provider and model of every language model call.
The workflow editor and the fallback list keep their saved selections but are locked.

A pair that cannot be used never falls back to another provider: a provider that is not
installed, turned off, refused by another key, or a model it does not offer, blocks
the affected feature with the reason, and Settings > Advanced > Managed Settings lists
the problem. With `AllowModelDownloads` set to `false`, deploy the model files with the
app. An incomplete pair (one of the two keys) is invalid and blocks the feature until
it is complete.

A **recommended pair** is applied once, when the user has not chosen an engine (or has
kept the built-in default language model) and the provider and model are ready.

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
TypeWhisper's team identifier `2D8ALY3LCL` or bundle identifier; the
[login item example](../../deployment/macos/examples/TypeWhisper-LoginItem.mobileconfig)
covers both editions. An app that is never started cannot register its login item,
so launch it once after installation.

## Deployment files

[`deployment/macos`](../../deployment/macos) contains:

| File | Purpose |
| --- | --- |
| `make-typewhisper-profile.py` | Builds a configuration profile from `KEY=VALUE` pairs and checks every value against the keys above, the counterpart to `Set-TypeWhisperPolicy.ps1` on Windows. Python 3.9 or later, no packages. |
| `examples/TypeWhisper-LocalOnly.mobileconfig` | Audio and text stay on the Mac; Parakeet v3 is enforced for transcription. |
| `examples/TypeWhisper-ApprovedCloud.mobileconfig` | Only Parakeet and OpenAI may transcribe, only OpenAI and Apple Intelligence may process text, no plugin downloads; OpenAI is recommended for transcription. |
| `examples/TypeWhisper-DeploymentUpdates.mobileconfig` | The deployment updates the app, TypeWhisper starts at login, setup stays closed when ready and optional prompts are hidden. |
| `examples/TypeWhisper-RecommendedDefaults.mobileconfig` | Editable defaults for both editions. |
| `examples/TypeWhisper-LoginItem.mobileconfig` | Approves the login item (Service Management payload). |
| `examples/TypeWhisper-Privacy.mobileconfig` | Privacy preferences (PPPC), see [permissions](#permissions). |
| `examples/TypeWhisper-AppSettings-Privacy.json` | Declarative app settings for macOS 27 and later that propose Accessibility and the microphone, see [permissions](#permissions). |
| `jamf/<domain>.json` | Jamf Pro custom schemas, one per edition. The App Store schema leaves out the keys that edition ignores. |
| `ProfileManifests/<domain>.plist` | The same settings in the [ProfileManifests](https://github.com/ProfileManifests/ProfileManifests) format of profile editors such as iMazing Profile Editor. |

The examples use the direct-download domain unless their name says otherwise; build
your own with the generator rather than editing them, so the values are checked:

```sh
deployment/macos/make-typewhisper-profile.py \
    --set AllowCloudTranscription=false --set AllowCloudTextProcessing=false \
    --set TranscriptionProviderId=com.typewhisper.parakeet \
    --set TranscriptionModelId=parakeet-tdt-0.6b-v3 \
    --set SuppressOptionalPrompts=true \
    --recommend LaunchAtLogin=true \
    --domain com.typewhisper.mac --domain com.typewhisper.typewhisper-app \
    --organization "Example Corp" --output TypeWhisper.mobileconfig
```

Lists are comma-separated, and an empty value (`--set AllowedPlugins=`) denies
everything. `UpdateMode` accepts `external`, `check-only` or `user-initiated`,
`UpdateChannel` `stable`, `daily` or `release-candidate`. The generator refuses
unknown keys (with the intended spelling for a key in the wrong case), restrictions
passed to `--recommend` and incomplete pairs. Keep `--identifier`, a reverse-DNS
style name such as `com.example.typewhisper`, stable to replace a deployed profile
instead of adding a second one. The profile's UUIDs derive from
the identifier, so regenerating it with new values keeps them.

Restrictive keys apply only to the domains you include. To manage both editions,
include both domains (or deploy one profile per domain): the App Store edition reads
only `com.typewhisper.typewhisper-app`. The App Store edition ignores `UpdateMode`,
`UpdateChannel`, `AllowedUpdateChannels` and `AllowPluginDownloads`
and lists them as policy problems; the generator leaves them out
of its payload and says so.

### Iru

Add the generated profile to the Library as a custom profile and assign it to the
Blueprints of the intended Macs. The login item and privacy examples are custom
profiles as well. When the profile is removed from a Mac, TypeWhisper returns to
the users' own settings within about 30 seconds.

### Jamf Pro

Jamf Pro can configure the settings through a form generated from a schema:

1. Computers > Configuration Profiles > New, then Application & Custom Settings >
   External Applications > Add > Custom Schema.
2. Enter the preference domain, `com.typewhisper.mac` or
   `com.typewhisper.typewhisper-app`, and paste the content of the matching
   `jamf/<domain>.json`.
3. Configure the properties you manage and leave the others at "Not Configured",
   which writes nothing. Recommended settings are under "Recommended settings (users
   can change)".
4. Scope the profile and save. Add a second payload for the other edition if needed.

Jamf Pro delivers the configured top-level values as managed preferences, which
TypeWhisper treats as enforced; values under "Recommended settings (users can change)"
are defaults users can change. Uploading a profile built with the generator
(Configuration Profiles > Upload) works as well and is the way to deploy the login
item and privacy examples.

### Other MDMs

Any MDM that installs custom configuration profiles works: upload the generated
`.mobileconfig`. For a profile editor, import the matching `ProfileManifests` file,
or write the payload by hand following [profile layout](#profile-layout). Sign the
profile if your MDM expects signed uploads.

To test a profile without MDM, open it in Finder and install it in System Settings >
General > Device Management. The managed preferences then apply as in a managed
fleet; the Service Management and privacy payloads take effect only when an MDM
delivers them.

## Permissions

TypeWhisper asks for these permissions when a feature first needs them. A privacy
preferences profile (PPPC, `com.apple.TCC.configuration-profile-policy`) delivered by
MDM can pre-approve some of them. The
[privacy example](../../deployment/macos/examples/TypeWhisper-Privacy.mobileconfig)
contains entries for Accessibility, PostEvent, Input Monitoring and Screen Recording.
Each belongs to the features in the table below; pre-approve only the entries your
features and edition need. Calendars and Automation are optional; add their entries
yourself if the organization wants them pre-approved.

From macOS 27, Accessibility in a PPPC profile is deprecated: macOS notifies the user
and lets them turn it off in System Settings. Apple's replacement is the `Privacy` key
of the declarative app settings configuration (`com.apple.configuration.app.settings`)
for supervised Macs with macOS 27 or later. It sets permission defaults per app,
matched by bundle identifier and code requirement, which the user confirms in one
prompt when the app launches, together with your organization's justification. It can
propose Accessibility, the microphone and local network access but never grants them
silently. The
[app settings example](../../deployment/macos/examples/TypeWhisper-AppSettings-Privacy.json)
proposes Accessibility and the microphone for both editions; adapt its
`OrganizationJustification`. The prompt lists only permissions the user has not been
asked for yet and does not appear once they have seen all of them, so deploy the
declaration before users first launch TypeWhisper. Deliver it with an MDM that supports
declarative device management on the user channel, because macOS applies the
`Privacy` key only to users, and give it a new `ServerToken` whenever you change it,
or the Mac keeps the previous version; most MDMs set the token themselves. Keep the
privacy profile for earlier macOS versions and for PostEvent, Input Monitoring and
Screen Recording.

| Permission | Used for | PPPC |
| --- | --- | --- |
| Microphone | Dictation and recording | Cannot be pre-approved; users approve the prompt. From macOS 27, the app settings configuration can propose it (`Microphone`: Allow). |
| Accessibility | Direct download: dictation shortcuts, inserting text and reading the active app's context. | `Accessibility`: Allow; deprecated from macOS 27, where the app settings configuration proposes it instead. |
| Accessibility (post events) | Pasting the transcript; in the App Store edition, the Accessibility entry in System Settings. | `PostEvent`: Allow. |
| Input Monitoring | App Store edition: dictation shortcuts. Direct download: shortcuts the system cannot register and Esc in other apps. | `ListenEvent`: only "Allow Standard User To Set System Service", which lets users without administrator rights approve it. |
| Screen & System Audio Recording | System audio in the Recorder. | `ScreenCapture`: only "Allow Standard User To Set System Service". |
| Automation (Apple Events) | Reading the current browser URL for profiles. | `AppleEvents`: Allow, with one entry per browser as receiver. |
| Calendars | Meeting reminders and starting recordings. | `Calendar`: Allow, if the organization wants it. |
| Local Network | Paired iPhones and iPads that use the Mac for transcription. | Not configurable; users approve the prompt. From macOS 27, the app settings configuration can propose it (`LocalNetwork`: Allow). |

The code requirements in the example are TypeWhisper's designated requirements. To
check them against an installed app, run `codesign -dr - /Applications/TypeWhisper.app`.
macOS applies privacy preferences only when an MDM with user-approved or automated
device enrollment delivers them.

## Installing the app

| Edition | Source | Updates |
| --- | --- | --- |
| Direct download | `TypeWhisper-v<version>.dmg` or `.zip` from the [GitHub releases](https://github.com/TypeWhisper/typewhisper-mac/releases), signed with Developer ID and notarized. Most MDMs install the DMG or a package built from it; place `TypeWhisper.app` in `/Applications`. The Homebrew cask is `typewhisper/tap/typewhisper`. | Sparkle, governed by `UpdateMode`, `UpdateChannel` and `AllowedUpdateChannels`. Under `UpdateMode` 0, deploy new versions with your MDM. |
| Mac App Store | Apple Business Manager > Apps and Books, assigned through your MDM. | The App Store. |

TypeWhisper needs macOS 14 or later. It needs no administrator rights to run and
stores settings, models and plugins in the user's account. The direct download and
the App Store edition are separate apps with separate settings, so usually only one
of them is installed.

## Network hosts

The app itself contacts these hosts over HTTPS, using the system proxy settings.

| Host | Used for |
| --- | --- |
| `app.typewhisper.com` | Premium account sign-in and status, and the Improve TypeWhisper plugin. |
| `typewhisper.github.io` | App updates (`/typewhisper-mac/appcast.xml`, unless `UpdateMode` is 0), the plugin catalog and term packs. |
| `github.com` and `release-assets.githubusercontent.com` | App update and plugin downloads. |
| `huggingface.co` and the `*.hf.co` content hosts it redirects to (the wildcard must cover several subdomain levels) | Model downloads of the local plugins: Parakeet, WhisperKit, Qwen3, Canary, Granite, Voxtral, Cohere Transcribe, Local LLM, Supertonic, Speaker Detection and Hugging Face imports. |
| `www.typewhisper.com` | Documentation opened in the browser. |

The Remote Link for paired iPhones and iPads listens on the local network when a user
turns it on; the HTTP API listens on the loopback interface only.

Cloud plugins contact their vendor; the table lists the hosts of the plugins in the
catalog at the time of writing. `configurable` plugins contact whatever endpoint,
command or service the user configures.

| Plugin | Hosts |
| --- | --- |
| AssemblyAI | `api.assemblyai.com`, `streaming.assemblyai.com` |
| Cartesia | `api.cartesia.ai` |
| Cerebras | `api.cerebras.ai` |
| Claude | `api.anthropic.com` |
| Cohere | `api.cohere.com` |
| Deepgram | `api.deepgram.com` |
| ElevenLabs | `api.elevenlabs.io` |
| Fireworks AI | `api.fireworks.ai`, `audio-prod.api.fireworks.ai`, `audio-turbo.api.fireworks.ai` |
| Gemini | `generativelanguage.googleapis.com` |
| Gladia | `api.gladia.io` |
| Google Cloud Speech-to-Text | `speech.googleapis.com`, `oauth2.googleapis.com` |
| Groq | `api.groq.com` |
| Linear | `api.linear.app` |
| Meta | `api.meta.ai` |
| Microsoft AI | the configured Azure resource, `*.cognitiveservices.azure.com` or `<region>.api.cognitive.microsoft.com` |
| Mistral AI | `api.mistral.ai` |
| OpenAI / ChatGPT, OpenAI Vector Memory | `api.openai.com`; `auth.openai.com` and `chatgpt.com` for ChatGPT sign-in |
| OpenRouter | `openrouter.ai` |
| Sber SaluteSpeech | `smartspeech.sber.ru`, `ngw.devices.sberbank.ru` |
| Smallest Pulse | `api.smallest.ai` |
| Soniox | `api.soniox.com` and its `eu`/`jp` regions, `stt-rt.*` and `tts-rt.*` |
| Speechmatics | the regional `*.speechmatics.com` hosts |
| Vercel AI Gateway | `ai-gateway.vercel.sh` |
| xAI / Grok | `api.x.ai` |
| Reson8 | `api.reson8.dev` or the configured endpoint |
| MemPalace | `api.mempalace.cloud` or the configured server |
| OpenAI Compatible, Cloudflare ASR, MCP Client, Obsidian, Webhook, Script Runner, File Job Script, Authenticated Provider CLIs, R2T2 | the endpoint, command or vault the user configures |
| Web Link Transcription | the sites of the links users transcribe, through yt-dlp |

## Deployment notes

- TypeWhisper reads the profile before anything else at launch, so a profile present
  at the first launch applies immediately. Deploy restrictive profiles before or
  together with the app.
- With `AllowModelDownloads` or `AllowPluginDownloads` turned off, users cannot fetch
  models or plugins themselves. Models and plugins live in each user's
  `~/Library/Application Support`; stage them before the restriction applies or
  allow downloads for the first setup. Never copy another user's settings or Keychain
  items.
- Several users on one Mac each have their own settings, models and plugins. A
  device profile applies to all of them, a user profile only to that user.
- The keys govern TypeWhisper's behavior, not the network. Combine them with your
  MDM's network controls where you need stronger guarantees.

## Pilot checklist

Before a fleet rollout, test the release on one managed Mac:

1. Deploy the profile and launch TypeWhisper as a standard user. Settings > Advanced >
   Managed Settings lists the values and no invalid keys or policy problems.
2. Confirm that locked settings show "Managed by your organization." and that refused
   providers and plugins show the reason.
3. Dictate once with the intended engine and, if used, a language model workflow.
4. Change a value in the MDM and confirm the app applies it within about 30 seconds
   without a restart; remove the profile and confirm the user's own settings return.
5. Restart the Mac and confirm the login item and permissions behave as intended.
6. Repeat with the App Store edition if you deploy it.

Automated tests cover the policy reader, the precedence rules and every key with
simulated profiles. They do not prove delivery through your MDM.
