#!/usr/bin/env bash
# Builds every first-party Swift target for CodeQL Swift extraction.
#
# Run inside an initialized CodeQL tracing environment (github/codeql-action/init
# with build-mode: manual). Targets come from the Xcode project: the app scheme's
# targets plus one target per plugin directory that has a manifest.json, so a new
# plugin is analyzed without editing this list. A plugin directory without a
# matching Xcode target fails the build. See docs/codeql-swift.md.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
print_only=0
if [[ "${1:-}" == "--print-targets" ]]; then
  print_only=1
  shift
fi
build_root="${1:-$repo_root/codeql-build}"
# Reuse packages resolved before CodeQL initialization; resolving under tracing is slow.
source_packages="${SOURCE_PACKAGES_DIR:-$build_root/SourcePackages}"

app_targets=(
  TypeWhisper
  typewhisper-cli
  TypeWhisperICloudBridge
  TypeWhisperWidgetExtension
  TypeWhisperTranscribeAction
)

plugin_targets=()
for manifest in "$repo_root"/TypeWhisperPluginSDK/Plugins/*/manifest.json; do
  plugin_targets+=("$(basename "$(dirname "$manifest")")")
done

if [[ "${#plugin_targets[@]}" -eq 0 ]]; then
  echo "error: no plugin manifests found" >&2
  exit 1
fi

if [[ "$print_only" -eq 1 ]]; then
  printf '%s\n' "${app_targets[@]}" "${plugin_targets[@]}"
  exit 0
fi

target_args=()
for target in "${app_targets[@]}" "${plugin_targets[@]}"; do
  target_args+=(-target "$target")
done

echo "Building ${#app_targets[@]} app targets and ${#plugin_targets[@]} plugin targets for CodeQL"

cd "$repo_root"
# One xcodebuild invocation keeps shared Swift packages (MLX, FluidAudio,
# WhisperKit, ...) in a single build graph instead of compiling them per plugin.
# Debug arm64 only: CodeQL needs every source compiled once, not a release binary.
# Explicit module builds (the Xcode 26 default) leave the CodeQL Swift extractor
# with almost no app files: 1 of 226 in a traced build, against 226 of 226 with
# SWIFT_ENABLE_EXPLICIT_MODULES=NO.
xcodebuild build \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -project TypeWhisper.xcodeproj \
  "${target_args[@]}" \
  -configuration Debug \
  -clonedSourcePackagesDirPath "$source_packages" \
  SYMROOT="$build_root/Build/Products" \
  OBJROOT="$build_root/Build/Intermediates.noindex" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  COMPILER_INDEX_STORE_ENABLE=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO
