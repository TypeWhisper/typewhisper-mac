# TypeWhisper 1.6.0 RC1 Release Design

## Summary

TypeWhisper `1.6.0-rc1` freezes the `1.6` feature set at commit `7e30e7cc967bd355b60c8c64221312d671e6c464`, plus the release preparation changes described here. The candidate is a public GitHub prerelease on the Sparkle `release-candidate` channel. It does not update Homebrew or stable website messaging.

The candidate uses the proven no-iCloud Developer ID distribution path. Automatic private iCloud sync is disabled, while user-selected Cloud Folder Sync remains available. Marco owns a three-day post-publication soak, and Discord is the only active tester-outreach channel.

## Scope

The release includes the complete `main` history through the frozen commit, curated release notes, the no-iCloud tag policy, the release checklist, signed and notarized artifacts, public appcast publication, artifact verification, and a Discord tester call.

The Simplified Chinese localization in PR #1041, the automatic iCloud work in draft PR #1014, unrelated new features, a GitHub Discussion, Homebrew, stable website messaging, and the final `v1.6.0` release are out of scope.

If `main` advances before the preparation branch is created, each additional commit must be reviewed explicitly against this scope. No unrelated commit may be included implicitly.

## Release Preparation

The preparation branch is `seofood/release-1.6.0-rc1`. Its pull request contains this design, the curated `1.6.0-rc1` notes, the release-readiness policy, and the workflow change. The pull request does not auto-close the release checklist issue.

Local validation is:

```bash
actionlint -shellcheck= .github/workflows/release.yml
./scripts/pr-preflight.sh origin/main
```

The exact pull-request head must also pass the release build, app tests, Plugin SDK tests, first-party warning check, CodeQL, PR Guard, and review-thread gates before an exact-head squash merge.

## No-iCloud Tag Policy

All app tag pushes matched by `v*` set `WITHOUT_ICLOUD=true`. Scheduled builds continue to use `MACOS_SCHEDULED_WITHOUT_ICLOUD`. Manual workflow dispatches continue to use the explicit `without_icloud` input. Plugin tags do not match the app release workflow.

This policy remains in force until the production iCloud container and Developer ID provisioning profile are approved. A future activation requires a deliberate workflow change, an embedded profile, matching signed entitlements, Sparkle upgrade proof, and real two-Mac synchronization validation.

## Candidate and Publication

After the preparation pull request is merged, create an English release-checklist issue titled `[Release] TypeWhisper 1.6.0 RC1` with the `area: build & release` label. Record the exact merged `main` commit, `v1.5.1` as the previous stable release, and Marco as test owner.

Create the lightweight tag `v1.6.0-rc1` at that exact commit and push only that tag. The workflow must report `without_icloud=true` before proceeding. It must pass release-tool self-tests, app and Plugin SDK tests, first-party warning checks, an unsigned release build, CLI instrumentation validation, Developer ID and no-iCloud signing checks, app and DMG notarization, stapling, signed app launch, Sparkle signing, GitHub prerelease creation, and canonical appcast publication. Website and Homebrew jobs must be skipped.

## Publication Verification

Publication is complete only when all three evidence layers agree:

1. The GitHub tag targets the approved commit, the release is a published prerelease, and both DMG and ZIP assets exist with the curated notes.
2. The canonical appcast advertises `1.6.0-rc1` on `release-candidate`, requires macOS 14.0, and contains the exact ZIP URL, signature, and length.
3. The downloaded ZIP contains a signed and notarized app with `CFBundleShortVersionString=1.6.0`, `TypeWhisperReleaseTag=v1.6.0-rc1`, `TypeWhisperReleaseChannel=release-candidate`, `TypeWhisperICloudEnabled=NO`, the expected numeric build, no iCloud or ubiquity entitlements, and the production App Group.

The Discord announcement is published only after all three layers pass.

## Discord Outreach

The English Discord post identifies RC1 as a public test build rather than a stable release. It links the GitHub release, explains how to select `Settings > About > Update Channel > Release Candidate`, summarizes the productivity and reliability highlights, calls out the disabled automatic iCloud mode, and asks testers to report the exact version, macOS version, hardware, reproduction steps, and diagnostics through the GitHub bug template.

No GitHub Discussion or broader social announcement is created.

## Soak and Failure Policy

Marco validates the published binary through an upgrade from `v1.5.1`, a clean installation, recording and insertion, audio routes, Recorder, file transcription, workflows, History, API and CLI, integrations, Dictionary, models, plugins, indicators, localization, and the update channel.

Data loss, security or signing failures, reproducible crashes, and unusable core paths without an acceptable workaround are P0/P1 failures. They receive the `release-blocker` label and block stable. Any product-code change after RC1 requires at least `v1.6.0-rc2`. P2/P3 issues block only after an explicit severity escalation.

The RC1 tag and announced artifacts are immutable. An infrastructure-only failure may be rerun at the same unchanged tag before publication is complete. If remediation changes tagged workflow or product code, the next candidate is RC2 rather than a moved RC1 tag.

The earliest stable decision is after 72 complete hours without an open P0/P1 blocker and with the core smoke tests complete. Publishing stable `v1.6.0` is outside this design.

## Compatibility

RC1 introduces no new product API, CLI, or Plugin SDK compatibility change. The operational change is limited to the app release workflow: tag pushes matching `v*` use the no-iCloud path. Sparkle remains on the existing release-candidate channel, and `v1.5.1`, Homebrew, and stable website distribution remain unchanged.
