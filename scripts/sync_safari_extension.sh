#!/usr/bin/env bash
# Copies the Safari package of the TypeWhisper browser extension into the Safari web
# extension target. Run it after changing the browser extension:
#
#   scripts/sync_safari_extension.sh /path/to/typewhisper-browser-extension
#
# It builds the extension (npm ci must have run there), replaces
# TypeWhisperSafariExtension/Resources and records the source commit. TypeWhisper.xcodeproj
# and appstore-project.yml list the top-level files and folders of that directory one by
# one; the script stops when they change, so both can be updated with them.
set -euo pipefail

extension_repo="${1:?Path to the typewhisper-browser-extension checkout}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
target="$repo_root/TypeWhisperSafariExtension/Resources"
expected_entries="_locales api.js background.js content context.js icons manifest.json mic-setting.js popup settings.js"

(cd "$extension_repo" && npm run --silent build >/dev/null)
source_dir="$extension_repo/dist/safari"

actual_entries="$(cd "$source_dir" && ls -1 | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "The Safari package's top-level entries changed." >&2
  echo "Expected: $expected_entries" >&2
  echo "Found:    $actual_entries" >&2
  echo "Add or remove them in the TypeWhisperSafariExtension target, then update expected_entries." >&2
  exit 1
fi

rm -rf "$target"
mkdir -p "$target"
cp -R "$source_dir"/. "$target"/
commit="$(git -C "$extension_repo" rev-parse --short HEAD)"
dirty="$(git -C "$extension_repo" status --porcelain --untracked-files=no | head -1)"
echo "typewhisper-browser-extension ${commit}${dirty:+ (uncommitted changes)}" > "$repo_root/TypeWhisperSafariExtension/SOURCE"
echo "Synced $source_dir at $commit into TypeWhisperSafariExtension/Resources"
