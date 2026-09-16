# Secret scanning and credential incidents

## Repository settings

Keep **Secret Protection / secret scanning** and **Push protection** enabled in
[Advanced Security settings](https://github.com/TypeWhisper/typewhisper-mac/settings/security_analysis).
These are repository settings, not workflow YAML, and must be checked separately
from CI. Dependabot alerts do not replace credential scanning.

Enable validity checks and non-provider patterns when GitHub makes them available
for this repository. On 2026-09-16, both remained disabled after REST update requests
and neither option appeared in repository settings. Do not interpret a successful
PATCH response as proof that an option was enabled; read the settings back:

```bash
gh api repos/TypeWhisper/typewhisper-mac --jq '.security_and_analysis'
```

See GitHub's [validity-check availability](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/customize-leak-detection/enable-validity-checks).
An unavailable or unknown validity result is not evidence that a credential is safe.

## Alert triage

Review [secret scanning alerts](https://github.com/TypeWhisper/typewhisper-mac/security/secret-scanning)
after enablement and whenever GitHub reports a new finding. Review every location,
including historical commits. Do not bulk-dismiss historical alerts.

For a metadata-only inventory that does not print credential values:

```bash
gh api 'repos/TypeWhisper/typewhisper-mac/secret-scanning/alerts?per_page=100' \
  --paginate --jq 'map({number,state,resolution,secret_type_display_name,validity,html_url})'
```

The unfiltered API response includes secret values. Never paste it into public
issues, PRs, CI logs, screenshots, or support diagnostics. Record only alert IDs,
affected paths, owners, and remediation status in public updates. Use the private
alert or private vulnerability reporting for sensitive details.

Classify each finding from evidence:

- **Real or uncertain credential:** treat it as exposed and follow rotation below.
  Close as revoked only after confirming revocation with the issuer.
- **Test fixture:** verify that it was never issued and cannot authenticate before
  closing as used in tests. Replace realistic tokens with obvious placeholders
  where the format is unnecessary.
- **False positive:** confirm the matched text is not a credential and record the
  reason before closing as false positive.

## Rotation and remediation

1. Revoke or disable the exposed credential at its issuer immediately. Deleting a
   file or rewriting Git history does not revoke access.
2. Create a replacement with the minimum required permissions. Update its intended
   consumers through Keychain, GitHub Actions secrets, or the applicable secret
   store. Never place the replacement in source, logs, or an incident comment.
3. Verify the old credential is unusable and the updated consumer works. Review
   provider audit logs and investigate suspicious use during the exposure window.
4. Remove the credential from source and any generated fixtures or artifacts.
   For an unpushed commit, amend it; for earlier unpushed commits, edit each affected
   commit with interactive rebase. A later removal commit is insufficient.
5. If published history or artifacts require cleanup, coordinate it privately with
   repository administrators and follow GitHub's
   [sensitive-data removal guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
   Coordinate any history rewrite with collaborators; copies and forks may persist.
6. Resolve the alert with the verified outcome and a credential-free explanation.

## Blocked pushes and emergency bypasses

Normally, remove the finding from all commits being pushed and retry. Never disable
repository protection to unblock a release.

A bypass is exceptional: a maintainer must verify a non-functional test value or
false positive, or confirm that a real credential has already been revoked. Never
bypass an active or uncertain credential for a deadline.

1. Review every location shown by the blocked push and record the justification
   privately, including the owner and any cleanup deadline.
2. Open the unblock URL supplied by GitHub while signed in as the pushing user.
   Select the truthful reason (used in tests, false positive, or will fix later).
   If GitHub requires a reviewer, request approval and wait for it.
3. Retry only the intended push within GitHub's displayed bypass window. This is
   a specific exception, not authorization to bypass future findings.
4. Review any resulting alert, complete cleanup by the recorded deadline, and
   confirm repository scanning and push protection remain enabled.

See [GitHub's blocked-push instructions](https://docs.github.com/en/code-security/how-tos/secure-your-secrets/work-with-leak-prevention/push-protection-on-the-command-line).

## Safe verification

Use only the deliberately non-functional **GitHub Secret Scanning** dummy token in
GitHub's [Storing your secrets safely tutorial](https://docs.github.com/en/get-started/learning-to-code/storing-your-secrets-safely#2-committing-a-dummy-token).
Do not use an actual credential, even temporarily. Do not commit the canary value
to this runbook or to a normal development branch.

1. Create a disposable detached worktree based on `origin/main`.
2. Put the documented dummy token in `.secret-scanning-canary.txt` and make one
   local commit with `[skip ci]` in its message.
3. Check that `refs/heads/seofood/issue-1255-secret-canary` does not already exist,
   then attempt `git push origin HEAD:refs/heads/seofood/issue-1255-secret-canary`.
4. Expect a nonzero exit and `GH013`, `GITHUB PUSH PROTECTION`, and the
   `GitHub Secret Scanning` finding. An unrelated rejection is not a passing test.
   Do not follow the bypass link.
5. Verify `git ls-remote origin refs/heads/seofood/issue-1255-secret-canary` returns
   no ref, then remove the disposable worktree. If GitHub unexpectedly accepted
   the push, remove only the test ref you just created, review any resulting alert,
   and investigate the protection settings before calling the test successful.

### Initial verification: 2026-09-16

- Secret scanning and push protection read back as enabled.
- GitHub rejected the documented dummy-token push with `GH013` and
  `GITHUB PUSH PROTECTION`; the test ref was absent afterward. No bypass was used.
- The alerts API returned an empty list; the UI showed 0 open and 0 closed alerts.
  No alert was dismissed. This is a point-in-time observation, not proof that every
  future scan is complete. The scan-history API returned `404: Advanced Security
  is disabled on this repository`, so scan completion could not be verified there.
- A targeted current-tree check found obvious test placeholders such as `test-key`,
  `sk-test`, and `hf_test_token`. The screenshot service-account fixture in
  `TypeWhisper/Services/HostServicesImpl.swift` contains the literal `SCREENSHOT FIXTURE`
  in place of private-key material. No fixture change or scanning exclusion was
  needed. This check does not replace GitHub's historical scanning.
