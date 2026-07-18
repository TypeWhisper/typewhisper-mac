# Settings Visual Language

## Context

TypeWhisper's settings destinations currently use several unrelated presentation styles:
native grouped forms, custom lists and toolbars, data dashboards, and branded card layouts.
The settings sidebar already provides a stable macOS navigation shell, so this work focuses on
making the destination views feel like one product without replacing their specialized behavior.

## Direction

Use a native macOS hybrid visual language:

- Keep native `Form`, `List`, picker, toolbar, and split-view behavior where it fits the task.
- Give every destination the same fixed page-header rhythm.
- Reuse semantic system surfaces, spacing, corner radii, borders, and empty-state presentation.
- Preserve specialized layouts for workflows, history, integrations, premium, and licensing.
- Keep the existing macOS 15+ `NSSplitViewController` shell and macOS 14 sidebar fallback.

## Shared Components

The shared vocabulary is deliberately small:

- `SettingsPageHeader` presents a title, an optional existing summary, and optional trailing actions.
- `SettingsCard` provides the standard semantic card surface and optional selected-state accent.
- `SettingsEmptyState` provides a consistent symbol, title, message, and optional action.
- `SettingsLayoutMetrics` defines the common 20-point page edge, 16-point section/card spacing,
  16-point card inset, 12-point card radius, and 8-point compact-control radius.

These components are internal to the app. They do not change the plugin SDK, persistence,
view-model interfaces, or user data.

## Page Families

### Form pages

General, Dictation, Hotkeys, Recovery, Advanced, and About keep grouped native forms. Their page
header sits above the form, separated by a divider, and their content uses the shared page edge.

### Dashboard and collection pages

Home, Statistics, Dictionary, and Snippets keep their existing dashboards, filters, editing flows,
and list structures. They adopt the shared page header, cards, empty states, and layout metrics.

### Tool and workspace pages

History, File Transcription, and Recorder keep their specialized split, progress, and tool layouts.
Only their top-level chrome and general surfaces are standardized.

### Complex and commercial pages

Workflows, Integrations, Premium, and License keep their builder, marketplace, entitlement, pricing,
and purchasing hierarchy. General page chrome and base card surfaces use the shared vocabulary,
while meaningful product/status tints remain local.

## Color and Accessibility

- Use semantic macOS colors for general surfaces and text.
- Use accent or status colors only where they communicate selection, state, or product meaning.
- Avoid white-opacity fills as general-purpose backgrounds because they do not adapt reliably
  between light, dark, and increased-contrast appearances.
- Keep keyboard behavior, accessibility labels, and VoiceOver grouping intact.
- New user-facing strings must include English, German, and Japanese localizations.

## Rollout

Deliver the migration in five sequential pull requests:

1. Shared foundation and form pages.
2. Dashboard and collection pages.
3. Tool and workspace pages.
4. Complex and commercial pages.
5. Full visual, localization, resize, and accessibility audit.

No phase may intentionally change navigation, persisted state, view-model behavior, or plugin APIs.

## Verification

Each phase runs whitespace checks, repository preflight, and the complete `TypeWhisper` test scheme.
The final audit uses the signed TypeWhisper-Dev app and covers all destinations at minimum, ideal,
and wide window sizes in light and dark appearance, with English, German, and Japanese content.
