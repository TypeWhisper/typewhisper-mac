# Release tooling and signing credentials

The release workflow prepares tools before importing signing credentials. The
runner image, Xcode, Python's bundled pip, and SHA-pinned Actions remain trusted
inputs. This change does not sandbox reviewed build scripts or dependencies.

## Locked tools

- `.github/release-tools/requirements.txt` pins `dmgbuild` and its complete
  required dependency set (`ds-store`, `mac-alias`). Installation requires SHA-256
  hashes and wheels; source builds and an unpinned pip upgrade are not allowed.
  `pip check` and a CLI smoke test run before signing credentials are imported.
- `.github/release-tools/sparkle.json` pins the Sparkle tools archive. Its version
  must equal the app's `Package.resolved` version. The initial SHA-256 was checked
  against the `digest` published by the GitHub API for the
  [Sparkle 2.9.6 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6).
  Downloads require HTTPS, fail on HTTP errors, and are hashed before extraction
  or execution. The trusted checksum is committed; CI never fetches its expected
  value alongside the archive.
- Swift packages resolve from the committed lockfile before certificate import.
  The archive command disables automatic resolution and requires locked versions.
- Checkout credentials are not persisted. Jobs default to `contents: read`; only
  the release/appcast publisher has `contents: write`. Appcast Git authentication
  is provided through process-local configuration in the publication step.

When updating a tool, review its upstream release and dependencies first. Obtain
wheel SHA-256 values from the version-specific PyPI JSON endpoints recorded in
the requirements file and independently hash the downloaded wheels. For Sparkle,
inspect `gh api repos/sparkle-project/Sparkle/releases/tags/VERSION`, compare the
asset's published digest with `shasum -a 256 Sparkle-VERSION.tar.xz`, and update the
app dependency and tooling lock together. A mismatch must stop the release;
never regenerate a lock automatically inside the signing job or disable hash
verification to recover a failed build. See pip's
[secure installation guidance](https://pip.pypa.io/en/stable/topics/secure-installs/).

Validate changes without production keys:

```sh
python3 scripts/test_release_tooling.py
python3 scripts/test_icloud_release_policy.py
bash scripts/check_release_signing.sh --self-test
bash scripts/check_release_binary_instrumentation.sh --self-test
actionlint -ignore SC2001 .github/workflows/release.yml .github/workflows/release-tooling-policy.yml
git diff --check
```

`SC2001` is an existing style suggestion in release-note parsing; other
ShellCheck diagnostics remain enabled.

On macOS, also run the real download/install smoke in a new temporary directory:

```sh
tool_test_root=$(mktemp -d)
python3 scripts/prepare_release_tools.py --tools-dir "$tool_test_root/tools"
```

A real signed and notarized release remains the integration check for Apple
credentials, provisioning, Sparkle update acceptance, and publication.

## Secret lifetime and cleanup

The certificate and each notarization key are created under `RUNNER_TEMP` with
`umask 077`. Step-local exit and termination traps remove P12/P8 files, including
when a command fails. App and DMG notarization use separate short-lived P8 files.
The keychain password is masked and never exported through `GITHUB_ENV`.

An `always()` cleanup step deletes the temporary keychain and any remaining
P12/P8/profile files using fixed paths, including partial-import failures. It
still attempts file cleanup when keychain deletion fails, and reports failure
instead of silently publishing. Sparkle receives its secret through a pipe;
no private key file is written. These steps cover normal success, failure and
cancellation. Hard termination or runner loss can prevent any trap from running;
the hosted ephemeral runner is the final containment boundary. Do not move this
signing workflow onto a persistent worker without isolated runner disposal and
independent cleanup.

## Rotation after suspected exposure

Use a trusted workstation and record the affected run IDs, time range, secret
names, certificate fingerprints/key IDs, and replacement validation results in a
private incident record. Never put private keys or P12 passwords in issues, logs,
artifacts, or command-line arguments. Stop release publication and cancel affected
runs while investigating; retain the necessary evidence before removing artifacts.

1. **Developer ID certificate:** generate a new private key and Developer ID
   Application certificate. Export a new password-protected P12 and replace
   `MACOS_SIGNING_P12`, `MACOS_SIGNING_PASSWORD`, and, if its name changes,
   `MACOS_SIGNING_IDENTITY` in GitHub Actions secrets. Regenerate the production
   iCloud helper profile for the new certificate and replace
   `MACOS_ICLOUD_HELPER_DEVELOPER_ID_PROVISIONING_PROFILE`. Request revocation of
   the compromised Developer ID certificate through Apple's documented process;
   changing the P12 password alone does not rotate the private key. Apple directs
   Developer ID revocation requests to `product-security@apple.com` in its
   [revocation guidance](https://developer.apple.com/help/account/reference/revoking-privileges).
2. **App Store Connect API key:** revoke the affected key in App Store Connect,
   Users and Access, Integrations. Create a replacement with only the required
   access, download its P8 once, and replace `APP_STORE_CONNECT_API_KEY_P8`,
   `APP_STORE_CONNECT_API_KEY_ID`, and the associated issuer ID if it changes.
   Verify notarization using the replacement. See Apple's
   [API key management guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api).
3. **Sparkle EdDSA key:** generate a fresh key on the trusted workstation using
   the verified `generate_keys` tool with a distinct account name. Store the
   exported private key in `SPARKLE_EDDSA_KEY` and its public key in
   `TypeWhisper/Resources/Info.plist` (`SUPublicEDKey`). Plan and test the migration
   from currently installed versions before resuming automatic updates. Sparkle
   supports rotating either EdDSA or Developer ID identity while the other remains
   trusted; do not assume an update that changes both will be accepted. If both
   are compromised, coordinate a trusted manual reinstall/recovery path instead
   of relying on the compromised identities to establish trust. See
   [Sparkle's key rotation rules](https://sparkle-project.org/documentation/#rotating-signing-keys).
4. **Publication credentials:** revoke and replace `WEBSITE_DEPLOY_TOKEN` and
   `HOMEBREW_TAP_TOKEN` if their jobs or outputs were affected. Cancel compromised
   jobs to end their short-lived `GITHUB_TOKEN` use, audit releases, tags, appcasts
   and tap changes, and remove unauthorized publications after preserving evidence.
5. **Resume:** run signing self-tests, produce a reviewed candidate with the new
   credentials, verify Developer ID signature and notarization, and test Sparkle
   updates from representative installed stable/RC versions. Resume scheduled
   publication only after the affected credentials are invalidated and the
   migration/recovery path is verified. Update other repositories or local release
   environments that shared the revoked credentials.
