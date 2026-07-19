#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/TypeWhisper.xcodeproj"
scheme="TypeWhisper"
team_id="2D8ALY3LCL"
bundle_id="com.typewhisper.mac"
icloud_container="iCloud.com.typewhisper.sync"
archive_path=""
export_path=""
profile_path="${MACOS_DEVELOPER_ID_PROVISIONING_PROFILE_PATH:-}"
release_tag=""
release_channel=""
build_number=""
signing_identity="${MACOS_SIGNING_IDENTITY:-}"
without_icloud=false

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/archive_release.sh \
  --archive-path PATH \
  --export-path PATH \
  --release-tag TAG \
  --build-number NUMBER \
  (--profile PATH | --without-icloud) \
  [--release-channel CHANNEL] \
  [--signing-identity IDENTITY]
USAGE
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive-path) archive_path="${2:-}"; shift 2 ;;
    --export-path) export_path="${2:-}"; shift 2 ;;
    --profile) profile_path="${2:-}"; shift 2 ;;
    --release-tag) release_tag="${2:-}"; shift 2 ;;
    --release-channel) release_channel="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    --signing-identity) signing_identity="${2:-}"; shift 2 ;;
    --without-icloud) without_icloud=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for required_value in archive_path export_path release_tag build_number; do
  if [[ -z "${!required_value}" ]]; then
    echo "error: --${required_value//_/-} is required" >&2
    usage
    exit 2
  fi
done

if [[ "$without_icloud" == true && -n "$profile_path" ]]; then
  echo "error: --profile and --without-icloud cannot be combined" >&2
  exit 2
fi
if [[ "$without_icloud" == false && -z "$profile_path" ]]; then
  echo "error: --profile or MACOS_DEVELOPER_ID_PROVISIONING_PROFILE_PATH is required" >&2
  exit 2
fi
if [[ "$without_icloud" == false && ! -f "$profile_path" ]]; then
  echo "error: provisioning profile not found: $profile_path" >&2
  exit 2
fi
if [[ -e "$archive_path" || -e "$export_path" ]]; then
  echo "error: archive and export paths must not already exist" >&2
  exit 2
fi
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "error: build number must be numeric" >&2
  exit 2
fi

raw_version="${release_tag#v}"
marketing_version="${raw_version%%-*}"
if [[ ! "$marketing_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "error: release tag does not contain a valid marketing version: $release_tag" >&2
  exit 2
fi
if [[ -z "$release_channel" ]]; then
  if [[ "$raw_version" == *"-daily"* ]]; then
    release_channel="daily"
  elif [[ "$raw_version" == *-* ]]; then
    release_channel="release-candidate"
  else
    release_channel="stable"
  fi
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(
    security find-identity -v -p codesigning |
      awk -F'"' '/Developer ID Application/{ print $2; exit }'
  )"
fi
if [[ -z "$signing_identity" ]]; then
  echo "error: no Developer ID Application identity is available" >&2
  exit 2
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/typewhisper-release.XXXXXX")"
installed_profile=""
installed_profile_backup=""
cleanup() {
  if [[ -n "$installed_profile" ]]; then
    if [[ -n "$installed_profile_backup" && -f "$installed_profile_backup" ]]; then
      cp "$installed_profile_backup" "$installed_profile"
    else
      rm -f "$installed_profile"
    fi
  fi
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

decoded_profile="$temporary_dir/profile.plist"
profile_name=""
main_entitlements="$repo_root/TypeWhisper/Resources/TypeWhisper.entitlements"
icloud_enabled="YES"

if [[ "$without_icloud" == true ]]; then
  main_entitlements="$temporary_dir/TypeWhisper-NoICloud.entitlements"
  cp "$repo_root/TypeWhisper/Resources/TypeWhisper.entitlements" "$main_entitlements"
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-container-identifiers' "$main_entitlements"
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-services' "$main_entitlements"
  /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.ubiquity-container-identifiers' "$main_entitlements"
  icloud_enabled="NO"
  echo "Building without iCloud entitlements or a provisioning profile"
else
  security cms -D -i "$profile_path" > "$decoded_profile"

  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$decoded_profile")"
  profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded_profile")"
  profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded_profile")"
  profile_app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded_profile")"
  profile_expiration="$(plutil -extract ExpirationDate raw -o - "$decoded_profile")"
  profile_all_devices="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$decoded_profile" 2>/dev/null || true)"

  if [[ "$profile_team" != "$team_id" ]]; then
    echo "error: profile team is '$profile_team', expected '$team_id'" >&2
    exit 1
  fi
  if [[ "$profile_app_id" != "$team_id.$bundle_id" ]]; then
    echo "error: profile application identifier is '$profile_app_id', expected '$team_id.$bundle_id'" >&2
    exit 1
  fi
  if [[ "$profile_all_devices" != "true" ]]; then
    echo "error: profile is not a Developer ID provisioning profile" >&2
    exit 1
  fi
  if ! plist_array_contains \
    "$decoded_profile" \
    "Entitlements:com.apple.developer.icloud-container-identifiers" \
    "$icloud_container"; then
    echo "error: profile does not contain iCloud container '$icloud_container'" >&2
    exit 1
  fi
  expiration_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiration" '+%s')"
  if (( expiration_epoch <= $(date '+%s') )); then
    echo "error: provisioning profile expired at $profile_expiration" >&2
    exit 1
  fi

  profile_directory="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$profile_directory"
  installed_profile="$profile_directory/$profile_uuid.provisionprofile"
  if [[ -f "$installed_profile" ]]; then
    installed_profile_backup="$temporary_dir/existing-profile.provisionprofile"
    cp "$installed_profile" "$installed_profile_backup"
  fi
  cp "$profile_path" "$installed_profile"

  echo "Using profile: $profile_name ($profile_uuid, expires $profile_expiration)"
fi

echo "Using signing identity: $signing_identity"
echo "Archiving $release_tag (build $build_number, channel $release_channel)"

set -o pipefail
archive_arguments=(
  archive
  -project "$project" \
  -scheme "$scheme" \
  -configuration Release \
  -archivePath "$archive_path" \
  -destination 'generic/platform=macOS' \
  ENABLE_CODE_COVERAGE=NO \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$signing_identity" \
  TYPEWHISPER_DEVELOPER_ID_PROFILE_SPECIFIER="$profile_name"
  TYPEWHISPER_MAIN_ENTITLEMENTS="$main_entitlements"
  TYPEWHISPER_ICLOUD_ENABLED="$icloud_enabled"
  TYPEWHISPER_RELEASE_CHANNEL="$release_channel" \
  TYPEWHISPER_RELEASE_TAG="$release_tag" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  OTHER_CODE_SIGN_FLAGS="--timestamp"
)
xcodebuild "${archive_arguments[@]}"

export_options="$temporary_dir/ExportOptions.plist"
plutil -create xml1 "$export_options"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$export_options"
/usr/libexec/PlistBuddy -c 'Add :destination string export' "$export_options"
/usr/libexec/PlistBuddy -c "Add :teamID string $team_id" "$export_options"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$export_options"
/usr/libexec/PlistBuddy -c 'Add :signingCertificate string Developer ID Application' "$export_options"
if [[ "$without_icloud" == false ]]; then
  /usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$export_options"
  /usr/libexec/PlistBuddy \
    -c "Add :provisioningProfiles:$bundle_id string $profile_name" \
    "$export_options"
fi

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options"

app_path="$export_path/TypeWhisper.app"
if [[ ! -d "$app_path" ]]; then
  echo "error: exported app not found: $app_path" >&2
  exit 1
fi

echo "Exported Developer ID app: $app_path"
