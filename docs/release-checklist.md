# Release Validation Process

Release scope, compatibility contracts, channels, and automated ship gates are
defined in the [release readiness guide](release-readiness.md).

Automated build, test, signing, packaging, and appcast checks belong in
[`release.yml`](../.github/workflows/release.yml) and
[`scripts/pr-preflight.sh`](../scripts/pr-preflight.sh), not in a manual
checklist.

For every release candidate or stable release:

1. Create a GitHub issue from the
   [release checklist template](../.github/ISSUE_TEMPLATE/release-checklist.md).
2. Record the candidate tag or commit and link the relevant workflow runs.
3. Complete the manual smoke checks on representative real hardware.
4. Link the completed issue from the release notes or release discussion.

The issue is the evidence for a specific release. This document only defines
the process so the checklist does not accumulate stale, version-specific items.
