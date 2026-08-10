# MCP Client Action Add-on

## Context

GitHub issue [#1085](https://github.com/TypeWhisper/typewhisper-mac/issues/1085)
requests a low-friction path from a completed meeting transcription to action items in a to-do
application. The issue author clarified that TypeWhisper itself should act as the MCP client:
TypeWhisper should connect to a configured to-do application's MCP server and invoke its tools as
part of a TypeWhisper workflow.

This is the opposite direction from the existing
[`@typewhisper/mcp`](https://github.com/TypeWhisper/typewhisper-mcp) package, which exposes
TypeWhisper as an MCP server to external hosts. The existing package remains independent and does
not become part of this add-on.

TypeWhisper already supports action add-ons through `ActionPlugin`. Workflows persist an action
target ID, transform the transcript through their normal processing pipeline, and pass the final
text to the selected action. Linear and Obsidian are current first-party examples. A generic MCP
client belongs in this action stage, but one plugin bundle must be able to expose multiple named
actions backed by different server and tool configurations.

## Goals

- Ship a first-party marketplace add-on named **MCP Client** at version `0.1.0`.
- Let TypeWhisper connect to local MCP servers over the standard stdio transport.
- Let one plugin bundle expose multiple independently selectable workflow actions.
- Keep server connections reusable across multiple configured actions.
- Discover tools from the running MCP server and bind workflow data to a selected tool's input
  schema.
- Support one tool call per workflow and sequential calls for a JSON array of action items.
- Execute configured actions without a confirmation prompt on every workflow run.
- Store secret environment values in the host-provided Keychain storage.
- Avoid automatic retries that could duplicate externally visible writes.
- Preserve existing Linear, Obsidian, and other single-action add-ons unchanged.

## Non-Goals

- Streamable HTTP, legacy HTTP+SSE, or any other remote transport.
- OAuth, bearer-token handling, or browser-based authentication.
- Turning TypeWhisper itself into an MCP server; that remains the responsibility of
  `@typewhisper/mcp`.
- Letting an LLM autonomously choose among arbitrary MCP tools at runtime.
- MCP resources, prompts, sampling, elicitation, roots, or server-initiated application UI.
- Chaining multiple MCP tools or servers within one configured action.
- Supporting TypeWhisper hosts older than `1.6.0`.
- Importing MCP configuration files from Codex, Claude Desktop, or other hosts in version `0.1.0`.
- Automatically retrying failed or indeterminate write operations.
- Publishing the add-on or changing a public registry without separate release authorization.

## Product Decisions

- The plugin name is **MCP Client**.
- The plugin identifier is `com.typewhisper.mcp-client`.
- The Swift package target and principal class are `MCPClientPlugin`.
- The initial plugin version is `0.1.0`.
- The manifest uses `minHostVersion: "1.6.0"` and `sdkCompatibilityVersion: "v1"`.
- The add-on supports stdio only.
- Users configure reusable servers separately from workflow actions.
- Every action profile binds to exactly one server and one discovered tool.
- Every action profile appears as a separate entry in the existing **Action Target** picker.
- Tool choice and argument mapping are deterministic after setup.
- Single and batch invocation modes are selectable per action profile.
- Saving and selecting an action profile is the user's authorization for automatic execution.
- A destructive tool requires an additional one-time acknowledgement during action setup.
- Tool calls are never automatically replayed after an indeterminate transport failure.

## Host SDK Extension

The plugin SDK adds an optional multi-action provider beside the existing single-action protocol:

```swift
public protocol AdditionalActionPluginsProviding: TypeWhisperPlugin {
    var additionalActionPlugins: [any ActionPlugin] { get }
}
```

`PluginManager.actionPlugins` changes from a `compactMap` of top-level plugin instances to a
`flatMap` that collects:

1. the top-level instance when it conforms to `ActionPlugin`, and
2. every action returned by `AdditionalActionPluginsProviding`.

`PluginManager.actionPlugin(for:)` continues resolving by `actionId`, so workflow persistence and
the rest of the action execution pipeline do not need a new storage field. Existing single-action
plugins do not adopt the new provider and retain their current behavior.

The MCP Client plugin adopts `AdditionalActionPluginsProviding` and does not need to be a
top-level `ActionPlugin`. It returns one lightweight `MCPConfiguredAction` object for every saved
action profile. Creating, deleting, renaming, or reconfiguring an action calls
`HostServices.notifyCapabilitiesChanged()` so pickers refresh immediately.

The extension is additive within SDK compatibility line `v1`. The MCP Client plugin itself has no
fallback for older hosts; its `minHostVersion` enforces the `1.6.0` boundary before loading.

## Dependency and Packaging

`TypeWhisperPluginSDK/Package.swift` adds the official
[`modelcontextprotocol/swift-sdk`](https://github.com/modelcontextprotocol/swift-sdk) dependency at
exact version `0.12.1`. Only `MCPClientPlugin` and its tests depend on the `MCP` product.

The package adds:

- an `MCPClientPlugin` target,
- an `MCPClientPluginTests` test target,
- localized settings resources,
- `manifest.json`, and
- the release-workflow target mapping needed to build a future MCP Client plugin artifact.

The implementation must remain compatible with the repository's Swift 6 language mode and macOS
14 deployment target. Adding the target and release mapping prepares the artifact but does not
publish it.

## Data Model

### Server Configuration

`MCPServerConfiguration` is a `Codable`, `Sendable`, and `Identifiable` value with:

- stable UUID,
- display name,
- command as entered by the user,
- ordered argument array,
- non-secret environment values,
- the names of secret environment values,
- created and updated timestamps, and
- a revision used to invalidate an existing session after changes.

Secret values are stored separately through `HostServices.storeSecret`, keyed by server UUID and
environment-variable name. They never appear in the encoded server configuration.

The command is not a shell command line. If it is absolute, the plugin validates that the file is
executable. If it is a bare executable name such as `npx`, the plugin resolves it without invoking
a shell by searching, in order:

1. the server's configured `PATH`,
2. the host process `PATH`, and
3. `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and `/bin`.

The resolved executable is shown in the settings UI before the server can be saved as ready. Users
with version-manager-specific paths can supply an explicit `PATH` environment value.

### Action Configuration

`MCPActionConfiguration` is a `Codable`, `Sendable`, and `Identifiable` value with:

- stable UUID,
- stable action ID derived from that UUID,
- display name,
- SF Symbol name,
- referenced server UUID,
- selected MCP tool name,
- canonical tool input schema snapshot,
- SHA-256 schema fingerprint,
- ordered argument bindings,
- invocation mode (`single` or `batch`),
- destructive-tool acknowledgement state,
- created and updated timestamps.

The action ID uses the form `mcp-client-action-<uuid>`. Renaming or editing an action does not
change its ID. Deleting and recreating an action produces a new ID. Workflows that reference a
deleted action use TypeWhisper's existing unavailable-action-target behavior.

### Argument Binding

Each `MCPArgumentBinding` targets a property in the selected tool's input schema and obtains its
value from one of these sources:

- processed workflow text,
- original transcript,
- current batch item,
- a property path within parsed workflow JSON or the current batch item,
- active application name,
- active application bundle identifier,
- active application URL,
- detected language,
- a typed literal, or
- literal JSON.

Bindings preserve the schema property's expected type. Required properties must have a valid
binding before an action can be saved. Optional properties may be omitted when their source value
is absent.

Version `0.1.0` renders ordinary top-level JSON Schema properties directly. String, number,
integer, boolean, array, and object values are supported. Schemas that use constructs the form
cannot faithfully represent, including nested alternatives, may use **Raw JSON Arguments**. Raw
mode still validates the resulting value as an object and against the tool schema before any call.

When a tool exposes exactly one required string property, the settings UI automatically maps it
to processed workflow text in single mode and the current batch item in batch mode. The user may
replace the automatic binding.

## Settings Experience

The plugin settings view owns its scrolling and contains two primary sections: **Servers** and
**Actions**. A small activity section shows bounded connection and invocation results without
storing transcript contents or full argument payloads.

### Adding a Server

The server editor contains:

- name,
- command,
- one argument per row,
- one environment variable per row,
- a **Secret** toggle for each environment value,
- resolved executable path,
- connection status, and
- **Connect & Load Tools**.

The first save displays a warning that TypeWhisper will launch the configured executable with the
current user's permissions. The warning names the resolved executable and must be acknowledged.

**Connect & Load Tools** launches the process, connects an MCP client, performs the MCP lifecycle,
and calls `tools/list`. The UI shows tool names, descriptions, and relevant annotations. Connection
errors include a bounded, secret-redacted excerpt from standard error.

### Adding an Action

The action editor proceeds in this order:

1. choose a configured server,
2. connect or use its live tool catalog,
3. choose exactly one tool,
4. provide an action name and symbol,
5. select single or batch mode,
6. configure schema-derived argument bindings,
7. review the generated argument preview using synthetic placeholder data, and
8. save the action.

If the tool advertises `destructiveHint: true`, saving requires a separate acknowledgement that
the action will run automatically whenever a matching TypeWhisper workflow completes. MCP
annotations are advisory; the general automatic-execution notice is always visible even when a
server does not mark a write tool as destructive.

Saving the action makes it immediately available in the existing workflow and prompt-action
target pickers.

## Tool Discovery and Schema Stability

A connected session owns the live tool catalog for its server. The catalog is loaded when the
session connects and refreshed when the server advertises that the tool list changed. Reconnecting
always reloads the catalog.

Input schemas are canonicalized before hashing so object-key order does not create false changes.
At execution time the selected tool must exist in the live catalog and its schema fingerprint must
match the saved action configuration. If the tool was removed or its schema changed, the plugin
does not guess, drop fields, or invoke it with stale arguments. It returns an error stating that
the action configuration needs to be refreshed.

Refreshing an action loads the new schema, retains bindings whose target paths and expected types
remain compatible, and requires the user to resolve every new or incompatible required property
before saving.

## Execution Flow

When a TypeWhisper workflow finishes processing text:

1. the host resolves its action target ID to an `MCPConfiguredAction`,
2. the action snapshots its immutable server and action configurations,
3. the plugin obtains the serialized session for the referenced server,
4. the session ensures the stdio process and MCP client are connected,
5. the action resolves the selected tool against the live catalog and checks the schema
   fingerprint,
6. the complete input is parsed and all invocations are validated before the first tool call,
7. the action invokes the selected tool once or once per batch item, and
8. the action returns one aggregate `ActionResult` to the existing host pipeline.

The session is isolated in a Swift actor. Calls to one server are serialized so concurrent
workflows cannot interleave messages on the same stdio stream. Different configured servers may
execute concurrently.

### Single Mode

Single mode produces one argument object and sends exactly one `tools/call` request. Mapping or
schema validation failure occurs before the request.

### Batch Mode

Batch mode requires the processed workflow result to be a JSON array. Each element may be a scalar
or an object and becomes the current batch item for mapping. The complete array is parsed and every
item is mapped and validated before the first call, preventing predictable mapping failures from
creating a partial batch.

Version `0.1.0` accepts at most 100 batch elements. Valid elements are invoked sequentially in
array order. A tool-level failure for one item is recorded and execution continues with the next
item. The plugin never automatically retries a failed item.

If every item succeeds, the action succeeds with a summary such as `5 actions completed`. If some
items fail, the aggregate action fails with a summary such as
`4 of 5 actions completed; failed items: 3.` The activity view records failed indices and sanitized
error summaries so the user can identify partial completion without storing the submitted text.

## Process and Session Lifecycle

Each configured server has at most one lazy `MCPServerSession`. A session owns:

- the resolved executable and environment snapshot,
- the child `Process`,
- standard-input, standard-output, and standard-error pipes,
- the MCP SDK client and stdio transport,
- the live tool catalog, and
- a bounded standard-error buffer.

The session remains alive between actions to avoid repeatedly paying command startup and MCP
initialization latency. It closes when:

- the plugin is deactivated,
- the server is disabled or deleted,
- command, arguments, or environment change,
- the server revision changes, or
- the child process exits.

Connection and initialization have a 20-second timeout. Each tool call has a 60-second timeout.
Cancellation uses the MCP SDK cancellation path when the request is active. Graceful shutdown is
attempted for two seconds before terminating a child process that does not exit.

If the process is known to have exited before a request is sent, the session may start a new
process and issue the request once. If the transport fails during or after request transmission,
the outcome may be externally visible but unknown to TypeWhisper. The plugin reports the
indeterminate failure and never replays that request automatically.

## Result Handling

An MCP tool result with `isError: true` is a failed invocation. Successful text content may provide
a short transient feedback message, capped at 200 characters, but is not written to persistent
logs. A returned MCP resource link may populate `ActionResult.url`; the plugin does not infer URLs
from arbitrary text or structured content.

Single-mode failures return the sanitized server error. Batch mode returns only the aggregate
summary through `ActionResult` and keeps per-item sanitized details in the bounded activity view.
Secret values are redacted from every surfaced error.

## Security and Privacy

- The plugin never evaluates the command through a shell.
- Executable, arguments, and environment are passed as separate process fields.
- Secret environment values use host Keychain storage and are absent from `UserDefaults`, exported
  settings, diagnostics, and logs.
- Tool arguments, processed workflow text, original transcripts, and full tool results are not
  persistently logged.
- Standard error is capped at 64 KiB per server session and redacted against every configured
  secret before display.
- The server setup warning explains that a local MCP command runs with the user's permissions and
  may access data outside TypeWhisper.
- Tool selection is fixed during setup; untrusted transcript content cannot select another tool or
  change the executable.
- Required schema validation occurs locally before invoking a tool.
- There is no automatic write retry.
- Deleting a server removes its Keychain secrets and invalidates dependent actions.

## Error Handling

The settings and runtime UI distinguish:

- executable not found or not executable,
- process launch failure,
- MCP initialization failure,
- tool discovery failure,
- missing configured tool,
- changed tool schema,
- invalid mapping,
- invalid single or batch input,
- batch-size violation,
- MCP tool error,
- timeout or cancellation,
- definite process exit before transmission, and
- indeterminate transport loss after possible transmission.

Errors identify the configured server, action, and tool but do not include transcript contents,
full arguments, or secrets. The existing TypeWhisper action feedback path remains the user-facing
runtime surface.

## Localization and Accessibility

All user-facing strings live in the plugin's string catalog with English, German, and Japanese
localizations, matching the existing first-party action add-ons. Dynamic status text uses
localized formats rather than string concatenation where pluralization matters.

Server and action editors provide accessibility labels for add, remove, reorder, secret, connect,
refresh, and mapping controls. Secret values use secure fields. Error and connection state are
available as text and do not rely on color alone.

## Testing Strategy

### Host SDK Tests

- A plugin exposing only `AdditionalActionPluginsProviding` contributes every child action.
- A plugin conforming to both `ActionPlugin` and the multi-action provider contributes both its
  primary and additional actions exactly once.
- Disabled plugins contribute no actions.
- `actionPlugin(for:)` resolves stable child action IDs.
- Existing Linear and Obsidian action IDs continue to resolve unchanged.
- Capability-change notifications refresh action-target consumers.

### Plugin Unit Tests

- Server and action configurations encode and decode without secret values.
- Secret environment values use UUID-scoped host secret keys and are removed with the server.
- Bare and absolute executable resolution is deterministic and never invokes a shell.
- Tool schemas canonicalize to stable fingerprints.
- Compatible schema refresh retains valid bindings; incompatible required fields block saving.
- Every binding source resolves with the correct JSON type.
- The one-required-string-field automatic mapping behaves correctly in single and batch modes.
- Raw JSON arguments reject non-object and schema-invalid values.
- Batch input rejects non-arrays, invalid elements, and arrays larger than 100 before any call.
- Partial batch failures continue in order and produce the documented aggregate result.
- Definite pre-send process failure may reconnect once.
- Indeterminate post-send failure is never replayed.
- Activity and error text redact configured secrets and exclude transcripts and full arguments.

### Stdio Contract Tests

A test-only local MCP server fixture exercises:

- process launch,
- MCP connection lifecycle,
- `tools/list`,
- `tools/call`,
- tool-list change notification,
- cancellation,
- standard-error capture,
- clean shutdown,
- child-process crash before a request, and
- connection loss after receiving a write request.

The fixture records request counts and IDs so tests can prove that write requests are not replayed.

### Integration Validation

Focused package validation uses:

```bash
swift build --package-path TypeWhisperPluginSDK --target MCPClientPlugin
swift test --package-path TypeWhisperPluginSDK --filter MCPClientPluginTests
swift test --package-path TypeWhisperPluginSDK --filter TypeWhisperPluginSDKTests
```

Host integration validation runs the focused `PluginManagerAdditionalActionTests` through the
TypeWhisper Xcode test target. A development plugin build is then installed with the private
TypeWhisper development-plugin workflow and exercised against the local fixture server.

The manual acceptance flow creates one single action and one batch action, selects each in a real
TypeWhisper workflow, and verifies that the fixture receives exactly one request per intended
item. Installation and automated proof remain distinct from publication; version `0.1.0` is not
released without separate authorization.

## Acceptance Criteria

- TypeWhisper 1.6.0 discovers all configured MCP child actions in existing action-target pickers.
- Hosts older than 1.6.0 reject the MCP Client plugin before activation.
- A user can configure an stdio server, discover tools, select one tool, and save a named action.
- A single action maps processed workflow text and context into one schema-valid MCP call.
- A batch action maps a JSON array into ordered, separately validated tool calls.
- A partial batch failure reports completed and failed item counts without retrying writes.
- Renaming or editing an action does not break workflows that reference its stable ID.
- Tool removal or schema change blocks execution until the action is refreshed.
- Existing Linear and Obsidian action add-ons behave unchanged.
- Secret environment values never appear in encoded configuration, logs, or exported diagnostics.
- Process crashes and indeterminate transport failures do not create automatic duplicate calls.
- The focused package, host, and local-fixture validation passes before the plugin is considered
  implementation-complete.
