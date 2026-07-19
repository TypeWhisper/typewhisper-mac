#!/usr/bin/env bash
set -euo pipefail

team_id="2D8ALY3LCL"
bundle_id="com.typewhisper.mac"
widget_bundle_id="com.typewhisper.mac.widgets"
app_group="$team_id.com.typewhisper.mac"
icloud_container="iCloud.com.typewhisper.sync"
require_notarization=false
spawn_test=false
app_path=""

usage() {
  echo "Usage: $0 [--require-notarization] [--spawn] <TypeWhisper.app> | --self-test" >&2
}

contains_unresolved_variable() {
  # shellcheck disable=SC2016 # The build-setting marker must remain literal.
  grep -F '$(' >/dev/null
}

plist_array_contains() {
  local plist_path="$1"
  local key_path="$2"
  local expected_value="$3"
  local index=0
  local value

  while value="$(
    /usr/libexec/PlistBuddy -c "Print :$key_path:$index" "$plist_path" 2>/dev/null
  )"; do
    if [[ "$value" == "$expected_value" ]]; then
      return 0
    fi
    index=$((index + 1))
  done
  return 1
}

plist_array_equals_single_value() {
  local plist_path="$1"
  local key_path="$2"
  local expected_value="$3"
  local first_value

  first_value="$(
    /usr/libexec/PlistBuddy -c "Print :$key_path:0" "$plist_path" 2>/dev/null
  )" || return 1
  [[ "$first_value" == "$expected_value" ]] || return 1
  ! /usr/libexec/PlistBuddy -c "Print :$key_path:1" "$plist_path" >/dev/null 2>&1
}

widget_has_forbidden_entitlement() {
  grep -Eq \
    'com\.apple\.developer\.(applesignin|icloud|ubiquity)|com\.apple\.security\.(automation|cs\.disable-library-validation|device\.audio-input|network)' \
    >/dev/null
}

self_test() {
  # shellcheck disable=SC2016 # Exercise the literal unresolved marker.
  if printf '%s\n' '<string>$(ICLOUD_CONTAINER_ID)</string>' | contains_unresolved_variable; then
    :
  else
    echo "self-test failed: unresolved build setting was not detected" >&2
    return 1
  fi
  if printf '%s\n' '<string>iCloud.com.typewhisper.sync</string>' | contains_unresolved_variable; then
    echo "self-test failed: resolved value was rejected" >&2
    return 1
  fi
  if ! printf '%s\n' '<key>com.apple.developer.icloud-services</key>' | widget_has_forbidden_entitlement; then
    echo "self-test failed: forbidden widget entitlement was not detected" >&2
    return 1
  fi
  if printf '%s\n' '<key>com.apple.security.application-groups</key>' | widget_has_forbidden_entitlement; then
    echo "self-test failed: allowed widget entitlement was rejected" >&2
    return 1
  fi
  echo "release signing self-test passed"
}

if [[ $# -eq 1 && "$1" == "--self-test" ]]; then
  self_test
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-notarization) require_notarization=true; shift ;;
    --spawn) spawn_test=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ -n "$app_path" ]]; then
        echo "error: multiple app paths provided" >&2
        usage
        exit 2
      fi
      app_path="$1"
      shift
      ;;
  esac
done

if [[ -z "$app_path" || ! -d "$app_path" ]]; then
  usage
  exit 2
fi

widget_path="$app_path/Contents/PlugIns/TypeWhisperWidgetExtension.appex"
profile_path="$app_path/Contents/embedded.provisionprofile"
info_plist="$app_path/Contents/Info.plist"
if [[ ! -d "$widget_path" ]]; then
  echo "error: widget extension is missing" >&2
  exit 1
fi
if [[ ! -f "$profile_path" ]]; then
  echo "error: Developer ID provisioning profile is missing from the main app" >&2
  exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/typewhisper-signing-check.XXXXXX")"
cleanup() {
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

decoded_profile="$temporary_dir/profile.plist"
main_entitlements="$temporary_dir/main-entitlements.plist"
widget_entitlements="$temporary_dir/widget-entitlements.plist"
security cms -D -i "$profile_path" > "$decoded_profile"
codesign -d --entitlements :- "$app_path" > "$main_entitlements" 2>/dev/null
codesign -d --entitlements :- "$widget_path" > "$widget_entitlements" 2>/dev/null

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded_profile")"
profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded_profile")"
profile_expiration="$(plutil -extract ExpirationDate raw -o - "$decoded_profile")"
profile_all_devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$decoded_profile" 2>/dev/null || true)"

[[ "$actual_bundle_id" == "$bundle_id" ]] || {
  echo "error: main bundle identifier is '$actual_bundle_id'" >&2
  exit 1
}
[[ "$profile_team" == "$team_id" ]] || {
  echo "error: profile team is '$profile_team'" >&2
  exit 1
}
[[ "$profile_app_id" == "$team_id.$bundle_id" ]] || {
  echo "error: profile application identifier is '$profile_app_id'" >&2
  exit 1
}
[[ "$profile_all_devices" == "true" ]] || {
  echo "error: embedded profile is not a Developer ID profile" >&2
  exit 1
}
plist_array_contains \
  "$decoded_profile" \
  "Entitlements:com.apple.developer.icloud-container-identifiers" \
  "$icloud_container" || {
  echo "error: profile is missing iCloud container '$icloud_container'" >&2
  exit 1
}
expiration_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiration" '+%s')"
(( expiration_epoch > $(date '+%s') )) || {
  echo "error: profile expired at $profile_expiration" >&2
  exit 1
}

main_application_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$main_entitlements")"
main_team="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$main_entitlements")"

[[ "$main_application_id" == "$team_id.$bundle_id" ]] || {
  echo "error: signed application identifier is '$main_application_id'" >&2
  exit 1
}
[[ "$main_team" == "$team_id" ]] || {
  echo "error: signed team identifier is '$main_team'" >&2
  exit 1
}
plist_array_equals_single_value \
  "$main_entitlements" \
  "com.apple.security.application-groups" \
  "$app_group" || {
  echo "error: signed app group is incorrect" >&2
  exit 1
}
if ! plist_array_equals_single_value \
    "$main_entitlements" \
    "com.apple.developer.icloud-container-identifiers" \
    "$icloud_container" ||
  ! plist_array_equals_single_value \
    "$main_entitlements" \
    "com.apple.developer.ubiquity-container-identifiers" \
    "$icloud_container"; then
  echo "error: signed iCloud containers are incorrect" >&2
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.applesignin' "$main_entitlements" >/dev/null 2>&1; then
  echo "error: native Sign in with Apple entitlement must not be signed into the Developer ID app" >&2
  exit 1
fi

widget_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget_path/Contents/Info.plist")"
widget_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$widget_entitlements")"
[[ "$widget_id" == "$widget_bundle_id" ]] || {
  echo "error: widget bundle identifier is '$widget_id'" >&2
  exit 1
}
if [[ "$widget_sandbox" != "true" ]] ||
  ! plist_array_equals_single_value \
    "$widget_entitlements" \
    "com.apple.security.application-groups" \
    "$app_group"; then
  echo "error: widget sandbox or app group entitlement is incorrect" >&2
  exit 1
fi
if plutil -convert xml1 -o - "$widget_entitlements" | widget_has_forbidden_entitlement; then
  echo "error: widget contains main-app-only entitlements" >&2
  exit 1
fi

for plist in "$info_plist" "$main_entitlements" "$widget_entitlements" "$decoded_profile"; do
  if plutil -convert xml1 -o - "$plist" | contains_unresolved_variable; then
    echo "error: unresolved build setting found in $(basename "$plist")" >&2
    exit 1
  fi
done

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign -dvvv "$app_path" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$signature_details" || {
  echo "error: app is not signed with Developer ID Application" >&2
  exit 1
}
grep -Fq "TeamIdentifier=$team_id" <<< "$signature_details" || {
  echo "error: signature team identifier does not match" >&2
  exit 1
}

if [[ "$require_notarization" == true ]]; then
  spctl --assess --type execute --verbose=2 "$app_path"
  xcrun stapler validate "$app_path"
fi

if [[ "$spawn_test" == true ]]; then
  executable="$app_path/Contents/MacOS/TypeWhisper"
  spawn_log="$temporary_dir/spawn.log"
  "$executable" > "$spawn_log" 2>&1 &
  spawned_pid=$!
  sleep 3
  if ! kill -0 "$spawned_pid" 2>/dev/null; then
    echo "error: app did not remain alive after spawn" >&2
    cat "$spawn_log" >&2
    exit 1
  fi
  kill "$spawned_pid"
  wait "$spawned_pid" 2>/dev/null || true
fi

echo "release signing check passed: $app_path"
