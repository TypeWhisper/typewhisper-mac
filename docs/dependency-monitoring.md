# Dependency monitoring

Dependabot checks Swift and release-tool Python dependencies weekly. Its configuration also retains the GitHub Actions ecosystem. Each ecosystem permits three open version-update PRs and groups minor and patch updates. Major upgrades require a compatibility review.

`scripts/dependency_coverage.rb check` verifies the tracked dependency inventory and Dependabot configuration. The inventory contains the app and SDK Swift lockfiles, the SDK package, the Xcode project, and `.github/release-tools/requirements.txt`.

```sh
ruby scripts/dependency_coverage.rb check
```

The `snapshot SHA refs/heads/BRANCH` command produces a dependency snapshot from both committed Swift lockfiles. It preserves each pinned version and revision without resolving packages or inventing dependency edges.

The `sbom FILE SHA` command checks a saved GitHub SBOM against both lockfiles at the specified commit. It requires Ruby 2.7 or later. These commands read local files and Git history. Uploading a snapshot requires a separate, explicit action.

Security updates depend on repository settings and GitHub advisory coverage. A submitted revision does not establish that advisory matching or automatic remediation is available.
