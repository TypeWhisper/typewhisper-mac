#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xcodebuild build \
  -project "$repo_root/TypeWhisper.xcodeproj" \
  -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

"$repo_root/scripts/sync-dev-data-local.sh"

app_path="$HOME/Library/Developer/Xcode/DerivedData/TypeWhisper-blctgsqwodthsydjmlajcmlwqoin/Build/Products/Debug/TypeWhisper.app"
if [[ -d "$app_path" ]]; then
  printf '[typewhisper-dev-build] app: %s\n' "$app_path"
else
  found_app="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/TypeWhisper.app' -type d -print -quit 2>/dev/null || true)"
  if [[ -n "$found_app" ]]; then
    printf '[typewhisper-dev-build] app: %s\n' "$found_app"
  fi
fi
