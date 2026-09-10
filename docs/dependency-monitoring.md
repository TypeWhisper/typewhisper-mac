# Dependency monitoring

Dependabot checks GitHub Actions, Swift and Bundler weekly. Each ecosystem has a
minor/patch version-update group and a limit of three open version-update PRs.
Routine major upgrades are maintainer-led changes with a separate compatibility
review. No dependency PR is automatically merged.

The `allow.update-types` rule only restricts scheduled version updates. Security
updates remain individual PRs and may propose a major upgrade when required for
a fix. Do not replace this rule with a blanket `ignore`, which can also prevent
security updates. Security updates and alerts must remain enabled in repository
settings; `dependabot.yml` alone does not enable them.

## Coverage

| Files | Dependabot entry | Dependency graph source |
| --- | --- | --- |
| `.github/workflows/*.yml` | `github-actions`, `/` | GitHub static analysis |
| `Gemfile`, `Gemfile.lock` | `bundler`, `/` | GitHub static analysis |
| `TypeWhisper.xcodeproj/project.pbxproj` and `TypeWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | `swift`, `/` | Committed lockfile submission |
| `TypeWhisperPluginSDK/Package.swift`, `TypeWhisperPluginSDK/Package.resolved` | `swift`, `/TypeWhisperPluginSDK` | Committed lockfile submission |

The root Swift entry discovers the Xcode project; the SDK requires its own
directory. The current upstream Swift updater handles Xcode manifests and
lockfiles. Confirm the first hosted Dependabot runs after merging: upstream
support alone is not proof that this repository's update jobs succeed.

Both Swift locks use format 3. On 2026-09-08 GitHub's static SBOM contained Ruby
and Actions but no Swift packages. `Dependency Coverage` therefore submits both
committed locks on every main push and on manual runs from main. It also checks
the inventory on every PR, so a newly tracked Swift/Bundler manifest or Xcode
project requires an explicit coverage decision.

Snapshots retain each lockfile's path and all pinned versions, including
different versions of the same package between app and SDK. Revision-only pins
use their exact commit SHA. The script does not resolve packages, execute Swift
manifests, or invent dependency edges, direct/transitive labels or runtime scope
that `Package.resolved` does not contain.

Swift advisories depend on GitHub's advisory data and recognizable affected
versions. Revision-only dependencies require manual advisory and upstream review;
a submitted SHA does not prove advisory matching or automatic remediation.
Exact pins and cross-package compatibility constraints also require review of
proposed updates. Validate app and SDK together when shared dependencies change.

The submission appears in the repository dependency graph and SBOM. GitHub does
not expose API-submitted dependencies in organization-level dependency insights.

## Verification

Run from the repository root, with Ruby and `actionlint` available:

```sh
ruby scripts/dependency_coverage.rb check
ruby scripts/test_dependency_coverage.rb
actionlint .github/workflows/dependency-coverage.yml
git diff --check
```

The check covers all tracked Swift/Bundler manifests and locks, the Xcode
manifest, and the Actions workflow directory. When adding a dependency ecosystem,
extend the inventory and check rather than assuming this inventory covers it.

Verify settings and the complete Swift/Ruby inventory against the current main
commit (authenticated GitHub CLI required):

```sh
gh api repos/TypeWhisper/typewhisper-mac/automated-security-fixes
gh api --include repos/TypeWhisper/typewhisper-mac/vulnerability-alerts
git fetch origin main
dependency_sha=$(git rev-parse origin/main)
gh api repos/TypeWhisper/typewhisper-mac/dependency-graph/sbom > /tmp/typewhisper-sbom.json
ruby scripts/dependency_coverage.rb sbom /tmp/typewhisper-sbom.json "$dependency_sha"
```

Expected settings: `enabled: true`, `paused: false`, and HTTP 204 for alerts.
The SBOM check must pass for every Swift pin in both locks and every locked Ruby
gem, not merely find one package from each ecosystem. The workflow retries this
check for up to 100 seconds after submission to allow GitHub indexing to finish.

If the graph needs refreshing, run `Dependency Coverage` on main. For a one-off
bootstrap before the workflow is merged, generate a snapshot for the verified
current main SHA and submit it using the same detector/correlator as the workflow:

```sh
ruby scripts/dependency_coverage.rb snapshot "$dependency_sha" refs/heads/main > /tmp/typewhisper-swift-snapshot.json
gh api --method POST repos/TypeWhisper/typewhisper-mac/dependency-graph/snapshots --input /tmp/typewhisper-swift-snapshot.json
```

On 2026-09-08, snapshot `98538250` for main commit
`09ac5a1186556c472018ef598c8a0c8c037e3ad3` was accepted. The subsequent SBOM check
confirmed all 24 app pins, all 20 SDK pins, and all 97 Ruby dependencies. Security
updates were enabled and verified with `enabled: true`, `paused: false`.
The configuration and ongoing submission workflow only become active after merge.

References:

- [Dependabot options, including version-only allow rules](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference#update-types-allow)
- [Supported ecosystems](https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories)
- [Swift Xcode file discovery](https://github.com/dependabot/dependabot-core/blob/main/swift/lib/dependabot/swift/file_fetcher.rb)
- [Dependency submission API and limitations](https://docs.github.com/en/rest/dependency-graph/dependency-submission)
