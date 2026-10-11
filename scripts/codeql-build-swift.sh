#!/usr/bin/env bash
# Builds first-party Swift targets for CodeQL Swift extraction.
#
# Run inside an initialized CodeQL tracing environment (github/codeql-action/init
# with build-mode: manual). Builds the targets in CODEQL_SWIFT_TARGETS
# (space-separated); without it, every target from
# `scripts/codeql_swift_targets.py all`: the app targets plus one target per
# plugin directory that has a manifest.json, so a new plugin is analyzed without
# editing a list. A plugin directory without a matching Xcode target fails the
# build. See docs/codeql-swift.md.
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

if [[ -n "${CODEQL_SWIFT_TARGETS:-}" ]]; then
  read -r -a targets <<<"$CODEQL_SWIFT_TARGETS"
else
  selection="$(python3 "$repo_root/scripts/codeql_swift_targets.py" all)"
  read -r -a targets <<<"$(sed -n 's/^targets=//p' <<<"$selection")"
fi

if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "error: no targets to build" >&2
  exit 1
fi

if [[ "$print_only" -eq 1 ]]; then
  printf '%s\n' "${targets[@]}"
  exit 0
fi

target_args=()
for target in "${targets[@]}"; do
  target_args+=(-target "$target")
done

echo "Building ${#targets[@]} targets for CodeQL: ${targets[*]}"

cd "$repo_root"
# One xcodebuild invocation keeps shared Swift packages (MLX, FluidAudio,
# WhisperKit, ...) in a single build graph instead of compiling them per plugin.
# The package flags keep xcodebuild from resolving or fetching packages again;
# every git and manifest process it starts here would run under CodeQL tracing.
# Debug arm64 only: CodeQL needs every source compiled once, not a release binary.
# Explicit module builds (the Xcode 26 default) leave the CodeQL Swift extractor
# with almost no app files: 1 of 226 in a traced build, against 226 of 226 with
# SWIFT_ENABLE_EXPLICIT_MODULES=NO.
xcodebuild build \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  -scmProvider xcode \
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
