# Workflows Redesign

## Summary

TypeWhisper replaces the current user-facing `Prompts` + `Rules` model with a single new primary object: `Workflow`.

A workflow always has:
- exactly one template
- exactly one trigger
- behavior details based on the selected template
- optional fine-tuning
- an output configuration

`Legacy` data remains visible and importable, but is no longer executable.

## Why This Change

The current model forces users to split one intention into two objects:
- create a prompt
- assign that prompt to a rule

That produces avoidable navigation hops, unclear ownership, and frequent misuse of fallback rules for manual actions.

The redesign aligns the product with the user’s actual mental model:
- “I want meeting notes”
- “triggered by this hotkey”
- “with this output style”

## Goals

- Make `Workflow` the only active automation concept in the product.
- Remove `Prompt` and `Rule` as user-facing concepts.
- Make manual actions first-class via `Hotkey` workflows.
- Keep creation and editing in one consistent builder experience.
- Preserve old user data safely without auto-migrating it.
- Allow per-entry import from legacy data into the new model.

## Non-Goals

- No automatic migration of old prompts/rules into workflows in v1.
- No free-form canvas or node-based editor.
- No multi-trigger workflows.
- No multi-app or mixed app+website workflows.
- No global fallback workflow in v1.
- No prompt palette in v1.

## Information Architecture

### Navigation

The `Rules` area is renamed to `Workflows`.

Primary navigation inside the area:
- `Meine Workflows`
- `Legacy`

Primary action in `Meine Workflows`:
- `Neuer Workflow`

`Neuer Workflow` is a button, not a permanent navigation destination.

### Page Model

`Meine Workflows`
- list of active new workflows
- search, ordering, enable/disable
- primary button `Neuer Workflow`

`Neuer Workflow`
- dedicated page
- opened via push-style navigation with a back button
- starts with workflow creation builder

`Workflow bearbeiten`
- dedicated page
- uses the same builder shell as creation
- opens directly into the existing workflow state

`Legacy`
- dedicated page
- shows old prompts/rules in read-only form
- every entry can be imported into a new workflow

## User-Facing Naming

New primary term:
- `Workflow`

New labels:
- `Meine Workflows`
- `Neuer Workflow`
- `Workflow bearbeiten`
- `Legacy`

Terms removed from the UI:
- `Prompt`
- `Rule`

This rename also applies internally. New domain objects, stores, view models, and screens should use `Workflow` naming instead of `Rule` or `Prompt`.

## Workflow Model

### Core Model

A workflow has:
- `id`
- `name`
- `isEnabled`
- `template`
- `trigger`
- `behavior`
- `output`
- `sortOrder`
- timestamps / metadata as needed

### Template

Each workflow has exactly one template.

Initial template set:
- `Bereinigter Text`
- `Übersetzung`
- `E-Mail-Antwort`
- `Meeting Notes`
- `Checkliste`
- `JSON`
- `Zusammenfassung`
- `Eigener Workflow`

Template selection is immutable after creation.

If a user wants a different template later, they create a new workflow or duplicate an existing one as a new workflow.

### Trigger

Each workflow has exactly one trigger.

Allowed trigger types in v1:
- `App`
- `Website`
- `Hotkey`

Not supported in v1:
- global workflows
- mixed triggers
- app + website combinations
- multiple apps

### Behavior

`Behavior` contains:
- template-specific fields
- optional `Feinabstimmung`
- advanced output configuration

`Feinabstimmung` is the replacement for free-form prompt-level customization.

It is explicitly secondary to the structured template fields.

### Output

Output remains available for every workflow, but lives inside an `Erweitert` section of the behavior step rather than as a top-level primary choice.

## Builder

### Shared Builder Shell

Creation and editing use the same builder shell and visual language.

Creation flow:
1. `Vorlage`
2. `Verhalten`
3. `Trigger`
4. `Review`

Edit flow:
- same builder shell
- no template selection step
- template shown as fixed header information

### Step 1: Vorlage

This step is a large gallery of concrete outcomes, not abstract prompt types.

Each card should describe the end result clearly.

`Eigener Workflow` is the last card and enters the same builder, not a separate prompt editor.

### Step 2: Verhalten

This step includes:
- template-specific details
- optional `Feinabstimmung`
- `Erweitert` section with output controls

This is the main behavior-first step and should carry most of the workflow’s configuration weight.

### Step 3: Trigger

User chooses exactly one trigger:
- `App`
- `Website`
- `Hotkey`

Each trigger type gets a focused configuration UI for a single target only.

### Step 4: Review

This step presents a readable summary of the workflow before saving.

The review should read like a concise sentence or short paragraph, for example:
- “Wenn Hotkey X gedrückt wird, erzeugt TypeWhisper Meeting Notes.”
- “Wenn Website Y aktiv ist, übersetzt TypeWhisper den Text nach Englisch.”

## Workflow List

`Meine Workflows` should be optimized for quick scanning and management.

Recommended row style:
- short readable sentence
- plus a few compact badges for template, trigger, and status

This keeps the list human-readable without becoming too verbose.

## Legacy Strategy

### Legacy Principles

Legacy data remains:
- visible
- read-only
- importable

Legacy data does not remain:
- executable
- editable

There is no mixed runtime between new workflows and legacy items in v1.

### Legacy Storage

Legacy data lives in a completely separate model and store from the new workflow system.

This separation is required to keep the new domain model clean and prevent compatibility logic from polluting the workflow core.

Suggested internal split:
- `Workflow` store
- `LegacyWorkflow` store or equivalent legacy archive store

### Legacy Presentation

`Legacy` is a separate page in navigation.

Each legacy entry:
- is readable
- is clearly marked as deprecated / legacy
- can be imported
- may show an `Importiert` status after successful import

Imported status does not need to link to the new workflow.

Legacy entries remain visible after import.

## Import Flow

### Import Principles

Import is:
- per entry
- explicit
- user-confirmed
- copy-based, not move-based

Import is not:
- automatic
- bulk-based
- silent

### Import UX

Per legacy entry action:
- `Als Workflow importieren`

Import result:
- opens the new workflow builder as a prefilled draft
- user reviews and saves it explicitly

After save:
- no deactivation prompt is needed
- legacy entry remains visible in `Legacy`
- legacy entry may be marked as `Importiert`

### Import Mapping

Import behavior depends on source quality:

Legacy rule with clear trigger and clear behavior:
- import into matching workflow template and trigger when possible

Legacy prompt without a clear trigger:
- import as a prefilled `Eigener Workflow`
- require the user to choose a trigger before save

If a legacy item cannot be mapped cleanly:
- preserve as much behavior text as possible
- fall back to `Eigener Workflow`
- show a short warning/explanation inside the draft

## Internal Architecture

### New Domain

New internal domain should use workflow terminology consistently:
- `Workflow`
- `WorkflowTemplate`
- `WorkflowTrigger`
- `WorkflowBehavior`
- `WorkflowOutput`
- `WorkflowStore`
- `WorkflowListViewModel`
- `WorkflowBuilderViewModel`

### Legacy Domain

Legacy should be modeled separately:
- `LegacyWorkflow`
- `LegacyStore`
- `LegacyImportMapper`

No shared write path between workflow and legacy stores.

### Runtime

Only the new workflow system participates in runtime matching and execution.

Legacy is an archive/import surface only.

This removes:
- old-vs-new precedence rules
- duplicate execution risk
- hidden compatibility behavior

## Rollout Plan

### Phase 1

- Introduce new workflow domain model and store
- Build new `Meine Workflows` list
- Build new workflow builder
- Rename user-facing language from rules/prompts to workflows
- Add `Legacy` page
- make legacy entries read-only and non-executable
- add per-entry import

### Phase 2

- polish template gallery and builder copy
- improve import fidelity
- add duplication / cloning for workflows if useful

### Phase 3

- evaluate whether legacy can eventually be hidden further or removed

## Testing

### Model Tests

- workflow persistence roundtrip
- template immutability after creation
- single-trigger validation
- no-global-trigger validation
- import mapping from legacy rule to workflow
- import mapping from legacy prompt to `Eigener Workflow`

### View Model Tests

- create flow starts in template gallery
- edit flow skips template selection
- behavior step exposes `Feinabstimmung`
- output is only shown under `Erweitert`
- import creates prefilled workflow draft
- legacy items are marked read-only
- legacy items are never returned by runtime matching

### UI / Navigation Tests

- `Meine Workflows` is default landing page
- `Neuer Workflow` opens dedicated page with back navigation
- saving returns correctly to workflow list
- `Legacy` is reachable via navigation
- imported legacy entry can display `Importiert`

### Manual QA

- create one workflow per trigger type
- edit a workflow without changing template
- verify hotkey-only workflow replaces prompt-palette style manual usage
- verify legacy entries remain visible but do not execute
- import a legacy entry and confirm the new workflow executes

## Risks

- The rename is broad and touches both UI and internal model names.
- Import quality may vary across legacy data shapes.
- Users familiar with the old split model may need clear onboarding copy.
- Removing legacy execution in v1 is a hard behavioral break and must be communicated clearly.

## Success Criteria

- New users can create an automation without learning prompt-to-rule assignment.
- Manual actions are configured through hotkey workflows, not fallback tricks.
- The builder feels like one coherent flow.
- Legacy items are preserved safely without blocking the new architecture.
- The codebase reflects the new workflow model cleanly rather than carrying prompt/rule duality forward.
