# AssemblyAI Static Model Catalog

## Context

AssemblyAI does not expose a documented model-discovery endpoint comparable to OpenAI's dynamic writing-model catalog. Its transcription models also differ in more than their display names: REST and streaming identifiers, language handling, streaming query parameters, dictionary-term budgets, and dictionary payload fields are model-specific.

The Universal-3.5 Pro fix for issue #1042 currently centralizes model identifiers through helper constants, but the remaining model metadata and branching still live in `AssemblyAIPlugin.swift`. Adding future AssemblyAI models that way would require coordinated edits across the picker, request construction, streaming behavior, and language support.

## Goals

- Keep the AssemblyAI model list static and independent of network discovery.
- Make each supported model's identifiers and capabilities available from one internal definition.
- Derive model selection, migration, UI metadata, REST behavior, streaming behavior, language support, and dictionary behavior from the same catalog.
- Preserve the behavior already implemented and locally validated for issue #1042.
- Keep legacy and unknown model selections compatible without exposing obsolete identifiers in the picker or outbound requests.

## Non-Goals

- Adding a remote AssemblyAI model-discovery request.
- Adding or removing supported models.
- Changing the public TypeWhisper Plugin SDK.
- Changing Universal-3.5 Pro or Universal-2 request behavior established by issue #1042.
- Bumping the AssemblyAIPlugin manifest version from `1.0.14`.
- Committing, pushing, or opening a pull request before the revised local build is tested and explicitly approved by Marco.

## Architecture

Add `TypeWhisperPluginSDK/Plugins/AssemblyAIPlugin/AssemblyAIModelCatalog.swift` to both the Swift Package target and the AssemblyAIPlugin Xcode target.

The file defines internal, `Sendable` model metadata:

```swift
struct AssemblyAIModelDefinition: Sendable {
    let id: String
    let displayName: String
    let legacyIds: Set<String>
    let restModelId: String
    let supportedLanguages: [String]
    let dictionaryTermsBudget: DictionaryTermsBudget
    let dictionaryPayload: AssemblyAIDictionaryPayload
    let streamingConfiguration: AssemblyAIStreamingModelConfiguration
}
```

`AssemblyAIDictionaryPayload` distinguishes the two supported outbound formats:

- `keytermsPrompt` for Universal-3.5 Pro.
- `wordBoost(boostParam: "high")` for Universal-2.

`AssemblyAIStreamingModelConfiguration` represents the model-specific streaming behavior without constructing URLs itself:

- Universal-3.5 Pro uses `speech_model=universal-3-5-pro`, omits `format_turns`, and may add a single supported normalized language through `language_codes`.
- Universal-2 chooses `universal-streaming-english` for English or no explicit language, otherwise `universal-streaming-multilingual`, and sets `format_turns=true`.

The catalog exposes:

- `universal35Pro`
- `universal2`
- `all`, ordered for picker presentation
- `defaultModel`, equal to Universal-3.5 Pro
- `resolve(_:)`, returning Universal-2 for its canonical ID and Universal-3.5 Pro for its canonical ID, `universal-3-pro`, unknown IDs, empty IDs, or `nil`

Within the AssemblyAI plugin implementation, canonical and legacy identifier literals must occur only in the catalog. Catalog-focused migration tests reference those definitions instead of repeating string literals, and other plugin callers compare resolved definitions or their canonical IDs. Host-level fixtures may continue to use canonical public model IDs without exposing the catalog outside the plugin target.

## Plugin Integration

`AssemblyAIPlugin.swift` remains responsible for host lifecycle, HTTP and WebSocket transport, request assembly, response parsing, settings UI, and persistence.

It consumes the catalog as follows:

- `transcriptionModels` maps `AssemblyAIModelCatalog.all` to `PluginModelInfo`.
- Activation resolves the persisted selection and writes back the canonical ID when the stored value is missing, legacy, empty, or unknown.
- `selectModel(_:)` resolves every direct, workflow, profile, or API override before storing it.
- `supportedLanguages` and `dictionaryTermsBudget` come from the resolved selected definition.
- REST request construction uses `restModelId` and the model's dictionary payload definition.
- Realtime URL construction uses the model's streaming configuration while retaining URL construction in the plugin helper.
- Unsupported Universal-3.5 Pro language codes remain omitted from `language_codes`.
- Realtime response handling remains unchanged and continues to use `end_of_turn` as the final-turn signal.

No transport code, secrets, host service references, mutable state, or UI state belongs in the catalog.

## Compatibility and Failure Behavior

- `universal-3-pro` resolves to Universal-3.5 Pro and is immediately persisted as `universal-3-5-pro`.
- Unknown, empty, or missing IDs resolve to Universal-3.5 Pro.
- The picker exposes only Universal-3.5 Pro and Universal-2.
- Outbound REST and streaming requests never contain a legacy or unknown model ID.
- Catalog entries must have unique canonical IDs and must not share legacy IDs.
- If another model is added later, it must supply all required metadata at compile time; there is no partially configured fallback entry.

## Project Integration

Swift Package Manager automatically compiles the new Swift source because the AssemblyAIPlugin target includes the plugin directory and excludes only `Tests`.

The checked-in `TypeWhisper.xcodeproj/project.pbxproj` must explicitly add `AssemblyAIModelCatalog.swift` to the AssemblyAIPlugin group and its Sources build phase. No project regeneration or unrelated project-file rewrite is required.

## Tests

Extend `AssemblyAIPluginTests.swift` with catalog-focused coverage:

1. `all` contains exactly Universal-3.5 Pro followed by Universal-2.
2. Canonical IDs are unique and legacy IDs do not collide.
3. `defaultModel` is Universal-3.5 Pro.
4. Canonical, legacy, unknown, empty, and missing selections resolve as specified.
5. Each definition exposes the expected display name, language list, REST ID, streaming configuration, dictionary budget, and dictionary payload.
6. Existing activation and `selectModel(_:)` migration tests still prove canonical persistence.
7. Existing REST tests still prove canonical `speech_models`, `keyterms_prompt`, and `word_boost` behavior.
8. Existing realtime URL tests still prove Universal-3.5 Pro language bias, omitted `format_turns`, Universal-2 English/multilingual routing, and legacy normalization.
9. The existing ModelManager normalized-override regression remains unchanged and passing.

After implementation, run:

```bash
swift test --package-path TypeWhisperPluginSDK --filter AssemblyAIPluginTests

xcodebuild test \
  -project TypeWhisper.xcodeproj \
  -scheme TypeWhisper \
  -destination 'platform=macOS' \
  -only-testing:TypeWhisperTests/AudioRecorderViewModelTests \
  -only-testing:TypeWhisperTests/ModelManagerLiveSessionModelOverrideTests \
  CODE_SIGNING_ALLOWED=NO

rg -n '"universal-3-pro"' \
  TypeWhisper \
  TypeWhisperTests \
  TypeWhisperPluginSDK/Plugins/AssemblyAIPlugin

./scripts/pr-preflight.sh origin/main
```

The `rg` result must contain exactly the catalog's legacy constant; migration tests reference that constant symbolically.

## Local Acceptance Gate

Because this refactor changes the already installed fix, it starts a new local approval round:

1. Keep all product and project-file changes uncommitted.
2. Run the complete verification commands above.
3. Rebuild the stable TypeWhisper-Dev app.
4. Rebuild and install AssemblyAIPlugin from the same uncommitted worktree.
5. Verify valid Apple Development signatures, the expected App Group, installed plugin version `1.0.14`, and a running Dev app using the installed bundle.
6. Report automated evidence and any missing real-provider evidence.
7. Stop for Marco's personal test and explicit approval before any commit, push, branch rename, or pull request.
