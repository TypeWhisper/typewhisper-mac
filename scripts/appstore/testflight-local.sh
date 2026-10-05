#!/bin/bash
# Archives, signs, audits and exports the Mac App Store edition on this Mac and
# optionally uploads it to App Store Connect (TestFlight). Mirrors
# .github/workflows/testflight.yml with the local login keychain.
#
# Usage: scripts/appstore/testflight-local.sh [--upload] [--build-number N]
#
# Requirements:
#   - "Apple Distribution" and "3rd Party Mac Developer Installer" (or "Mac
#     Installer Distribution") identities in the login keychain
#   - ASC_API_KEY_PATH pointing to the App Store Connect API key JSON
#     (key_id, issuer_id, key); the key needs access to profiles
#
# Without --upload the script stops after exporting the signed .pkg.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output_root="$repo_root/build/appstore-testflight"
archive_path="$output_root/TypeWhisper.xcarchive"
export_path="$output_root/export"
team_id="2D8ALY3LCL"
apple_id="6759319267"
bundle_id="com.typewhisper.typewhisper-app"
upload=false
build_number="$(( $(date +%s) / 60 ))"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload) upload=true; shift ;;
        --build-number) [[ $# -ge 2 ]] || exit 1; build_number="$2"; shift 2 ;;
        *) echo "Usage: $0 [--upload] [--build-number N]" >&2; exit 1 ;;
    esac
done

[[ -n "${ASC_API_KEY_PATH:-}" && -f "$ASC_API_KEY_PATH" ]] || {
    echo "Set ASC_API_KEY_PATH to the App Store Connect API key JSON." >&2
    exit 1
}
asc_value() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]].strip(), end="")' "$ASC_API_KEY_PATH" "$1"
}

rm -rf "$output_root"
mkdir -p "$output_root"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Newest Apple Distribution certificate of the login keychain.
read -r signing_sha1 certificate_serial < <(
    security find-certificate -a -Z -c "Apple Distribution: " -p 2>/dev/null | python3 -c '
import re, subprocess, sys
from datetime import datetime
text = sys.stdin.read()
best = None
for sha1, pem in re.findall(r"SHA-1 hash: ([0-9A-F]+).*?(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", text, re.S):
    out = subprocess.run(["openssl", "x509", "-noout", "-serial", "-enddate"],
                         input=pem, capture_output=True, text=True).stdout
    serial = re.search(r"serial=([0-9A-F]+)", out).group(1)
    end = datetime.strptime(" ".join(re.search(r"notAfter=(.*)", out).group(1).split()), "%b %d %H:%M:%S %Y %Z")
    if best is None or end > best[2]:
        best = (sha1, serial, end)
if best:
    print(best[0], best[1])
'
)
[[ -n "${signing_sha1:-}" ]] || { echo "No Apple Distribution identity in the login keychain." >&2; exit 1; }
installer_identity="$(security find-identity -v -p basic \
    | sed -nE 's/.*"((3rd Party Mac Developer Installer|Mac Installer Distribution):[^"]*)".*/\1/p' | head -n 1)"
[[ -n "$installer_identity" ]] || { echo "No Mac installer identity in the login keychain." >&2; exit 1; }
echo "Signing with Apple Distribution ${signing_sha1:0:8}…, installer: $installer_identity"

# One App Store profile per signed bundle with an embedded provisioning profile.
profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$profiles_dir"
profile_name_for() {
    local identifier="$1" label="$2"
    local output="$work_dir/$label.provisionprofile"
    ASC_KEY_ID="$(asc_value key_id)" \
    ASC_ISSUER_ID="$(asc_value issuer_id)" \
    ASC_PRIVATE_KEY="$(asc_value key)" \
    CERTIFICATE_SERIAL="$certificate_serial" \
    BUNDLE_IDENTIFIER="$identifier" \
    PROFILE_NAME="TypeWhisper Mac AppStore ${certificate_serial: -8} $label" \
    PROFILE_TYPE=MAC_APP_STORE \
    RECREATE_PROFILE=1 \
    OUTPUT_PATH="$output" \
        ruby "$repo_root/scripts/appstore/create_app_store_profile.rb" >&2
    security cms -D -i "$output" > "$work_dir/$label.plist"
    local uuid
    uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$work_dir/$label.plist")"
    cp "$output" "$profiles_dir/$uuid.provisionprofile"
    /usr/libexec/PlistBuddy -c 'Print :Name' "$work_dir/$label.plist"
}
app_profile="$(profile_name_for "$bundle_id" App)"
widget_profile="$(profile_name_for "$bundle_id.widget" Widget)"
transcribe_profile="$(profile_name_for "$bundle_id.transcribe-action" TranscribeAction)"

"$repo_root/scripts/appstore/generate_project.sh"

echo "Archiving build $build_number (log: build/appstore-testflight/archive.log)..."
if ! xcodebuild archive \
    -project "$repo_root/TypeWhisperAppStore.xcodeproj" \
    -scheme TypeWhisperAppStore \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    -skipPackagePluginValidation -skipMacroValidation \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_IDENTITY="$signing_sha1" \
    CURRENT_PROJECT_VERSION="$build_number" \
    TW_APPSTORE_PROFILE="$app_profile" \
    TW_APPSTORE_WIDGET_PROFILE="$widget_profile" \
    TW_APPSTORE_TRANSCRIBE_PROFILE="$transcribe_profile" \
    >"$output_root/archive.log" 2>&1; then
    grep -E ' error: ' "$output_root/archive.log" | sort -u | head -30 >&2 || true
    tail -n 20 "$output_root/archive.log" >&2
    exit 1
fi

app_path="$archive_path/Products/Applications/TypeWhisper.app"
"$repo_root/scripts/appstore/audit_app_store_binary.sh" --require-universal "$app_path"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"

options="$work_dir/ExportOptions.plist"
plutil -create xml1 "$options"
plutil -insert method -string app-store-connect "$options"
plutil -insert teamID -string "$team_id" "$options"
plutil -insert signingStyle -string manual "$options"
plutil -insert signingCertificate -string "$signing_sha1" "$options"
plutil -insert installerSigningCertificate -string "$installer_identity" "$options"
plutil -insert uploadSymbols -bool YES "$options"
plutil -insert provisioningProfiles -dictionary "$options"
/usr/libexec/PlistBuddy \
    -c "Add :provisioningProfiles:$bundle_id string '$app_profile'" \
    -c "Add :provisioningProfiles:$bundle_id.widget string '$widget_profile'" \
    -c "Add :provisioningProfiles:$bundle_id.transcribe-action string '$transcribe_profile'" \
    "$options"

echo "Exporting signed package..."
xcodebuild -exportArchive -archivePath "$archive_path" -exportOptionsPlist "$options" \
    -exportPath "$export_path" >"$output_root/export.log" 2>&1 || {
    tail -n 30 "$output_root/export.log" >&2
    exit 1
}
package_path="$(find "$export_path" -maxdepth 1 -name '*.pkg' -print -quit)"
[[ -n "$package_path" ]] || { echo "Export did not create a pkg." >&2; exit 1; }
pkgutil --check-signature "$package_path" | head -n 4
echo "Package: ${package_path#"$repo_root/"} ($marketing_version, build $build_number)"

if ! $upload; then
    echo "Not uploaded. Run again with --upload to send it to App Store Connect."
    exit 0
fi

key_id="$(asc_value key_id)"
keys_dir="$work_dir/private_keys"
mkdir -p "$keys_dir"
( umask 077; asc_value key > "$keys_dir/AuthKey_$key_id.p8" )
echo "Uploading to App Store Connect app $apple_id..."
upload_output="$(API_PRIVATE_KEYS_DIR="$keys_dir" xcrun altool --upload-package "$package_path" \
    --type macos \
    --apple-id "$apple_id" \
    --bundle-id "$bundle_id" \
    --bundle-version "$build_number" \
    --bundle-short-version-string "$marketing_version" \
    --apiKey "$key_id" \
    --apiIssuer "$(asc_value issuer_id)" 2>&1)" || { echo "$upload_output" >&2; exit 1; }
echo "$upload_output"
if grep -Eq "UPLOAD FAILED|Validation failed" <<<"$upload_output"; then
    echo "App Store Connect rejected the upload." >&2
    exit 1
fi
echo "Uploaded build $build_number. It appears in TestFlight after Apple's processing."
