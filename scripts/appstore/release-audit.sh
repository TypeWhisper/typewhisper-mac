#!/bin/bash
# Builds the unsigned universal Release app and runs the App Store audit,
# like .github/workflows/build.yml. Works from any checkout or worktree.
#
# Usage: scripts/appstore/release-audit.sh [--clean]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output_root="$repo_root/build/appstore-release"
derived_data="$output_root/DerivedData"
app_path="$derived_data/Build/Products/Release/TypeWhisper.app"
log_path="$output_root/build.log"

case "${1:-}" in
    "") ;;
    --clean) rm -rf "$output_root" ;;
    *) echo "Usage: $0 [--clean]" >&2; exit 1 ;;
esac

mkdir -p "$output_root"
"$repo_root/scripts/appstore/generate_project.sh"
# Xcode keeps bundles of plugins that were removed from the project; embed
# the current set from scratch.
rm -rf "$app_path/Contents/PlugIns"

echo "Building the universal Release app (log: ${log_path#"$repo_root/"})..."
if ! xcodebuild -project "$repo_root/TypeWhisperAppStore.xcodeproj" \
    -scheme TypeWhisperAppStore -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    build >"$log_path" 2>&1; then
    grep -E ' error:' "$log_path" | sort -u | head -20 >&2 || true
    echo "Build failed; see ${log_path#"$repo_root/"}." >&2
    exit 1
fi

"$repo_root/scripts/appstore/audit_app_store_binary.sh" --allow-unsigned --require-universal "$app_path"
du -sh "$app_path"
