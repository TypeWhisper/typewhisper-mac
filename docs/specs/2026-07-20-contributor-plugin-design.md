# Improve TypeWhisper Plugin

## Context

TypeWhisper can improve dictation cleanup models when users voluntarily contribute real
before-and-after correction pairs. An earlier development-only JSONL capture recorded accepted
candidates before a correction existed and had no user-facing review step, consent, or reward
model. That path is retired in favor of the official plugin.

The product should offer an official first-party plugin that works the same way in TypeWhisper
Production and TypeWhisper Dev. Users must not need to know which app variant captured a
correction. The host continues to isolate each app's local plugin data.

The existing `TypeWhisper/app.typewhisper.com` Cloudflare Worker is the backend. Its `APP_DB` D1
database already owns Sign in with Apple accounts, bearer sessions, devices, and cross-platform
Premium entitlements. Contributor APIs extend this service instead of introducing a second
account system or domain.

## Goals

- Capture only text that a user actually changes after TypeWhisper inserts it.
- Show the complete original and corrected text before any contribution leaves the Mac.
- Require explicit selection and a manual send action.
- Allow anonymous contributions without requiring a TypeWhisper account.
- Support optional contributor rewards without rewarding raw submission volume.
- Keep Production and Dev behavior identical while preserving separate local storage.
- Provide a corpus format suitable for cleanup-model evaluation and training.

## Non-Goals

- Capturing or uploading audio.
- Collecting unchanged or merely accepted dictations.
- Uploading target application names, bundle identifiers, URLs, selected text, or document
  contents outside the corrected pair.
- Automatically exporting contributions to Obsidian or another synced folder.
- Importing existing training captures or arbitrary correction files.
- Automatically sending data in the background.
- Publishing a contributor leaderboard in the first release.
- Running an MCP server or scheduled validation automation in the first release.
- Promising that every submitted correction will be accepted or used for training.

## Product Decisions

- The feature ships as an official TypeWhisper marketplace plugin named **Improve TypeWhisper**.
- The plugin is inactive until the user explicitly enables contribution capture.
- A contribution exists only after TypeWhisper detects a committed manual correction.
- The full original and corrected texts are shown and submitted as a pair.
- Sending remains a separate manual action after review and selection.
- Anonymous contribution is the default.
- Reward participation is optional and does not change the text payload.
- Rewards are based on accepted quality, not total submitted records.
- `app.typewhisper.com` owns contribution submission, review status, account linking, and rewards.
- The existing Apple account bearer token is never exposed directly to the plugin.
- V1 validation is an operator-triggered Codex review, not an MCP workflow.

## User Experience

### Activation

The Improve TypeWhisper plugin appears in Integrations as a first-party utility plugin. Its settings view
starts with a concise consent screen describing:

- what is captured,
- what is never captured,
- where pending corrections are stored,
- that nothing is sent automatically,
- that both complete text versions are transmitted after confirmation, and
- how accepted contributions may be used for evaluation and model training.

The user must enable **Collect corrections for review** before the plugin subscribes to correction
events. Disabling the setting stops future capture but does not silently delete pending entries.

### Review Queue

The primary plugin view is a compact review queue. It contains only actual corrections and never
shows unchanged dictations.

Each row shows:

- capture date,
- detected language,
- a short preview,
- review state, and
- a selection checkbox.

Opening an entry shows:

- **Before**: the complete text inserted by TypeWhisper,
- **After**: the complete text after the user's committed correction,
- detected language,
- transcription engine, and
- capture date.

The user can exclude an entry or delete it permanently. A sensitive-data warning may flag common
email addresses, phone numbers, access tokens, or payment-card-like values locally, but it must
not claim to detect every private value. The complete visible pair remains the source of truth for
what will be sent.

### Sending

The queue provides **Send selected corrections** as its only submission action. No entry is
selected by default. Before the network request, a confirmation dialog states the number of
selected pairs and repeats that both
complete text versions will be transmitted.

The plugin never schedules background submission. A retry after a network error requires no new
consent for the unchanged selected batch, but it remains a user-visible action and uses idempotent
record identifiers.

After a successful server response:

- rejected entries remain local with a short reason and can be deleted,
- pending-review entries retain their local text until the server reaches a terminal decision,
- accepted entries delete their local text and retain only a receipt, timestamp, status, and
  quality-credit summary.

## Host and Plugin Architecture

### New Correction Event

The plugin SDK adds an event for a committed manual correction. The host emits it only when the
inserted text and committed text differ.

The payload contains:

- stable correction UUID,
- correction timestamp,
- original inserted text,
- corrected committed text,
- detected language,
- transcription engine identifier,
- model identifier when available,
- TypeWhisper version and build,
- platform version,
- commit signal, and
- source channel (`production` or `development`).

The payload deliberately excludes active application identity, bundle identifier, URL, selected
text, and audio references.

The event is additive to the existing event bus. The SDK compatibility and minimum host version
must be updated if the public enum change requires a compatibility boundary. Existing plugins
must continue to handle unknown events through a default switch branch.

### Detection Lifetime

The host keeps only the transient state required to associate inserted text with a subsequent
committed edit. If no correction is detected, no contribution record is created. The host does
not record accepted candidates in any build.

The host remains responsible for correction detection because a plugin cannot reliably observe
the target application's edited text by itself. The plugin is responsible for consent, local
queue storage, preview, submission, and receipts.

### Local Storage

The plugin stores pending records below `HostServices.pluginDataDirectory`. The host already
provides distinct plugin data directories for Production and Dev, so both apps can run at the
same time without writing to a shared file.

Pending corrections use one atomic JSON file per UUID. This permits a single entry to be deleted
without leaving its text in an append-only log. Submission receipts are stored separately and do
not retain original or corrected text after terminal acceptance.

The legacy development capture JSONL file is no longer written. Improve TypeWhisper exposes no
import command; its review queue contains only corrections captured by the enabled plugin after
installation.

## Contribution Schema

Each submitted correction contains:

- `schemaVersion`
- `id`
- `capturedAt`
- `originalText`
- `correctedText`
- `language`
- `engineId`
- `modelId`
- `appVersion`
- `appBuild`
- `platformVersion`
- `commitSignal`
- `sourceChannel`

Each batch additionally contains:

- consent-text version,
- plugin version,
- an anonymous contributor identifier or optional reward identity assertion, and
- batch UUID for idempotency.

The API rejects records where the two text fields are equal, required fields are absent, the
schema is unsupported, or the same UUID was already processed. Server-side quality checks may
reject obvious placeholders, unrelated replacements, duplicates, and abuse, but unusual grammar
or genuine ASR mistakes are not rejected merely for looking imperfect.

## Backend Flow

The Contributor API is added to the existing Cloudflare Worker in
`TypeWhisper/app.typewhisper.com`. It uses the existing `APP_DB` D1 binding for the initial beta
and adds migrations for:

- anonymous contributor identities and hashed contributor tokens,
- optional links from a contributor identity to an existing Apple account,
- encrypted contribution payloads and non-content indexing metadata,
- per-record review decisions and quality credit,
- idempotent batch receipts, and
- reward grants.

Account, contributor, contribution, and reward data remain in separate tables. Contribution rows
reference the opaque contributor UUID, not an Apple subject, email address, license key, or account
session token.

The first backend routes provide:

- authenticated transport for an anonymous contributor token,
- idempotent batch submission,
- per-record validation results,
- status polling for pending review,
- receipt retrieval, and
- deletion of contributions that have not yet been incorporated into a training dataset.

Anonymous bootstrap and submission use a dedicated contributor token. Linking rewards requires
an existing `account_sessions` bearer session and mints a short-lived, contributor-scoped
assertion. The TypeWhisper host obtains that assertion through `PremiumAccountService`; the plugin
receives only the scoped assertion.

All transport uses TLS. Original and corrected text are encrypted at the application layer before
being stored in D1, using a dedicated Worker secret with explicit key-version metadata. Access is
restricted to the model-evaluation and corpus-maintenance workflow. D1 remains the operational
source for the beta. Versioned accepted-corpus snapshots may later be exported to a private R2
bucket without changing client APIs.

The current portal documentation states that the service does not store transcripts. That
statement and the public privacy material must be updated before Improve TypeWhisper reaches external
users. The release is blocked until the contribution consent, retention policy, deletion
behavior, and post-training withdrawal limitations have received privacy and legal review and are
presented accurately in the plugin.

The backend stores contribution identity separately from text content. Account linking updates
reward ownership but does not add account details to an existing correction payload.

## V1 Codex Validation Gate

V1 assumes a small contribution volume. Validation runs on demand, approximately weekly when new
pending records exist, and does not require an MCP server or scheduled automation.

The operator workflow is:

1. Run deterministic server checks for schema validity, equal texts, empty fields, duplicate UUIDs,
   known placeholders, and exact corpus duplicates.
2. Export the remaining pending records through an operator-only review command.
3. Ask Codex to evaluate each pair against a versioned review rubric.
4. Apply high-confidence accept decisions and route every ambiguous, sensitive, or low-confidence
   pair to a short manual queue.
5. Review a small random sample of Codex-accepted pairs.
6. Create an immutable validated dataset snapshot only after the manual queue and sample are
   complete.

The operator command uses narrowly scoped review credentials and creates only a temporary local
review artifact. It must not expose account, Apple, license, reward, target-app, or session data.
Temporary plaintext review files are removed after decisions are recorded.

Codex receives each original and corrected text as untrusted data, never as instructions. The
review prompt and tool wrapper must prevent text inside a contribution from changing the rubric,
requesting additional data, or triggering commands.

Each recorded decision contains:

- contribution UUID,
- `accepted`, `rejected`, or `quarantined`,
- concise reason code,
- confidence class,
- validator name and model,
- rubric version,
- validation timestamp, and
- `automatic` or `human` decision source.

Codex may automatically accept only pairs that satisfy every rubric criterion unambiguously with
high confidence. All other pairs require manual review. If a run contains more than 100 pending
records, produces an unusual rejection rate, or fails the random sample, snapshot creation stops
and reports the anomaly instead of increasing automatic throughput.

Use of Codex as a validation processor must be disclosed in the contribution consent and privacy
material before external users participate. No submitted pair may enter a training corpus without
a terminal validation decision.

An MCP review server and scheduled weekly automation are deferred until actual volume shows that
the manual operator workflow is insufficient.

## Identity and Rewards

### Anonymous Default

On activation, the plugin creates a random contributor identifier and secret in plugin-scoped
Keychain storage. Anonymous contributors can submit and receive local acceptance receipts without
an account.

### Optional Reward Link

Users may voluntarily link the contributor identity to their TypeWhisper account for rewards.
The link reuses the existing Sign in with Apple account and `PremiumAccountService`. A new
host-service method exchanges the account bearer token for a short-lived scoped assertion rather
than exposing the bearer token to the plugin or adding identity fields to each text record.

Anonymous contribution remains available when the user does not link an account. Unlinking an
account stops future reward attribution but is separate from contribution deletion.

### Quality Credit

Credit is awarded only for accepted, non-duplicate corrections. The scoring service may consider:

- whether the correction is a real edit,
- whether the pair is structurally usable,
- whether it adds language or error-pattern diversity,
- whether it duplicates existing corpus material, and
- whether the contributor shows repeated low-quality or abusive behavior.

The client displays accepted contribution counts and broad progress levels. Exact scoring weights
remain server-controlled to reduce gaming. Initial rewards may include a Contributor badge,
Premium time, and opt-in public recognition. Thresholds are configured only after the beta
provides enough quality and cost data; they are not hard-coded into the plugin.

Premium-time rewards are issued through the existing signed entitlement response. The backend
records a unique contributor reward grant and exposes it to the entitlement resolver alongside
Polar and StoreKit entitlements. Reward grants must be idempotent and must never shorten or
replace a stronger paid entitlement.

There is no public leaderboard in the first release.

## Failure Handling

- Network failure leaves selected entries pending locally and reports no successful send.
- A partial batch response updates each record independently.
- Duplicate submissions return the existing receipt and do not grant credit twice.
- Corrupt local records are quarantined and shown as a local problem; they are never uploaded.
- Unsupported schema versions remain local until the plugin can migrate them.
- Disabling or uninstalling the plugin never causes a final background upload.
- Deleting a pending entry removes its content from plugin storage.

## Verification

### Host Tests

1. No event is emitted for unchanged text.
2. A committed edit emits exactly one correction event.
3. The event preserves the complete before-and-after texts.
4. The event excludes target app, URL, selected text, and audio metadata.
5. Production and Dev resolve different plugin data directories.
6. Correction capture remains inactive when the plugin setting is disabled.

### Plugin Tests

1. Enabling capture persists explicit consent state.
2. A correction event creates one atomic pending record.
3. The review view renders the complete pair.
4. Selection and deletion operate per entry.
5. No submission occurs without the manual send action.
6. The serialized payload matches the visible pair and excludes forbidden context.
7. Retries are idempotent.
8. Partial success updates only the corresponding records.
9. Accepted content is removed locally while its receipt remains.
10. Account linking changes reward attribution without changing correction payloads.
11. Newly loaded queue entries are not selected automatically.

### Backend Tests

1. Anonymous contributor tokens are stored only as hashes.
2. Batch UUIDs and correction UUIDs are idempotent.
3. Stored text fields contain versioned ciphertext rather than plaintext.
4. Contribution responses never expose account, Apple, license, or session identifiers.
5. Account linking requires a valid existing account session and produces only a scoped assertion.
6. Deleting an unincorporated contribution removes its encrypted payload.
7. Quality credit is granted only once for an accepted correction.
8. Contributor Premium rewards do not override a stronger Polar or StoreKit entitlement.
9. Account deletion unlinks reward attribution without silently changing contribution consent.
10. Only terminally accepted records can enter a dataset snapshot.
11. Review exports exclude all account, reward, target-app, and session data.
12. Duplicate validation decisions do not grant quality credit twice.

### Validation Tests

1. Deterministic invalid records never reach Codex review.
2. Contribution text is treated as untrusted data and cannot alter the review rubric.
3. High-confidence valid pairs can be accepted automatically.
4. Ambiguous, sensitive, and low-confidence pairs are quarantined for manual review.
5. A failed random sample blocks snapshot creation.
6. A run above the V1 volume threshold blocks snapshot creation and reports the anomaly.
7. Temporary plaintext review artifacts are removed after decisions are recorded.

### End-to-End Smoke

Run the signed TypeWhisper-Dev app with the development plugin build and verify:

1. A normal unchanged dictation creates no review item.
2. Editing an inserted dictation and committing the change creates one review item.
3. The full pair and highlighted diff match the target application.
4. The outbound request is absent until manual confirmation.
5. A successful test-server response updates the queue and removes accepted local text.
6. Production and Dev can run at the same time without sharing pending queues.

## Rollout

1. Add and test the correction event in the host and SDK.
2. Build the local Improve TypeWhisper plugin queue and preview without any upload endpoint.
3. Add the Contributor D1 migration and development-only routes to `app.typewhisper.com`.
4. Exercise consent, encryption, retries, deletion, and receipts against the test API.
5. Add the operator-only Codex review export, decision import, and snapshot commands.
6. Invite a small contributor beta with rewards disabled but acceptance counts visible.
7. Complete privacy and legal review and publish the contribution policy.
8. Enable optional Apple-account reward linking and manually configured Premium rewards.
9. Publish the signed plugin through the official marketplace feed.

The plugin remains opt-in at every rollout stage. No separate development capture runs alongside
it.
