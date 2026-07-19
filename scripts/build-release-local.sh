#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(dirname "$script_dir")"
build_dir="$project_dir/build-release"
profile_path="${MACOS_DEVELOPER_ID_PROVISIONING_PROFILE_PATH:-}"
release_tag=""
build_number=""
skip_dmg=false

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/build-release-local.sh \
  --profile PATH \
  [--release-tag TAG] \
  [--build-number NUMBER] \
  [--skip-dmg]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) profile_path="${2:-}"; shift 2 ;;
    --release-tag) release_tag="${2:-}"; shift 2 ;;
    --build-number) build_number="${2:-}"; shift 2 ;;
    --skip-dmg) skip_dmg=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$profile_path" ]]; then
  echo "error: --profile or MACOS_DEVELOPER_ID_PROVISIONING_PROFILE_PATH is required" >&2
  exit 2
fi
if [[ -z "$release_tag" ]]; then
  version="$(
    sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' \
      "$project_dir/TypeWhisper.xcodeproj/project.pbxproj" |
      head -1
  )"
  release_tag="v${version}-local.$(date -u '+%Y%m%d%H%M%S')"
fi
if [[ -z "$build_number" ]]; then
  build_number="$(git -C "$project_dir" rev-list --count HEAD)"
fi

archive_path="$build_dir/TypeWhisper.xcarchive"
export_path="$build_dir/export"
app_path="$export_path/TypeWhisper.app"

if [[ -d "$build_dir" ]]; then
  rm -rf "$build_dir"
fi
mkdir -p "$build_dir"

echo "=== TypeWhisper Local Developer ID Release ==="
echo "Tag: $release_tag"
echo "Build: $build_number"

xcodebuild -resolvePackageDependencies \
  -project "$project_dir/TypeWhisper.xcodeproj" \
  -scheme TypeWhisper

set -o pipefail
bash "$script_dir/archive_release.sh" \
  --archive-path "$archive_path" \
  --export-path "$export_path" \
  --profile "$profile_path" \
  --release-tag "$release_tag" \
  --build-number "$build_number" |
  tee "$build_dir/build.log"

bash "$script_dir/check_first_party_warnings.sh" "$build_dir/build.log"
bash "$script_dir/check_release_binary_instrumentation.sh" \
  "$app_path/Contents/MacOS/typewhisper-cli"
bash "$script_dir/check_release_signing.sh" "$app_path"

if [[ "$skip_dmg" == false ]]; then
  if ! command -v dmgbuild >/dev/null 2>&1; then
    echo "error: dmgbuild is required to create the local DMG" >&2
    exit 2
  fi
  dmg_path="$build_dir/TypeWhisper-${release_tag}.dmg"
  dmgbuild \
    -s "$project_dir/.github/dmgbuild-settings.py" \
    -D app=TypeWhisper \
    -D app_path="$app_path" \
    -D background="$project_dir/.github/dmg-background.png" \
    TypeWhisper \
    "$dmg_path"
  echo "DMG: $dmg_path"
fi

echo "App: $app_path"
