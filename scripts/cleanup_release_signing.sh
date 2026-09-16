#!/usr/bin/env bash
# Fixed paths also cover failures before a step can write GITHUB_ENV.
set -euo pipefail
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
keychain="$RUNNER_TEMP/typewhisper-signing.keychain-db"
status=0
if [[ -f "$keychain" ]]; then
  security delete-keychain "$keychain" || status=$?
fi
# Also remove the database if the security command could not delete it.
rm -f "$keychain" "$RUNNER_TEMP/typewhisper-signing.p12" \
  "$RUNNER_TEMP/typewhisper-notary-app.p8" \
  "$RUNNER_TEMP/typewhisper-notary-dmg.p8" \
  "$RUNNER_TEMP/TypeWhisperICloudBridge.provisionprofile" || {
  removal_status=$?
  if [[ "$status" -eq 0 ]]; then
    status="$removal_status"
  fi
}
exit "$status"
