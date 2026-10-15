#!/bin/bash
# Opt-in hardware smoke test for #1605. Requires installed Parakeet v2 and v3.
# Usage: scripts/test-parakeet-coreml-cache-recovery.sh [--skip-build]
# Model files are read from TYPEWHISPER_PARAKEET_MODEL_ROOT or FluidAudio's
# normal Application Support directory. Only a disposable test cache is purged.
# Core ML may retain live resources after deletion. Timings alone do not prove
# the issue's slow recompilation was reproduced; deterministic tests cover it.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
model_root="${TYPEWHISPER_PARAKEET_MODEL_ROOT:-$HOME/Library/Application Support/FluidAudio/Models}"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
    echo "Usage: $0 [--skip-build]" >&2
    exit 2
fi
for version in v2 v3; do
    if [[ ! -d "$model_root/parakeet-tdt-0.6b-$version-coreml" ]]; then
        echo "Install Parakeet $version first: $model_root" >&2
        exit 1
    fi
done

if [[ "${1:-}" != "--skip-build" ]]; then
    swift test --package-path "$repo_root/TypeWhisperPluginSDK" --filter ParakeetPluginTests
fi

coreml_test_home="$(mktemp -d "${TMPDIR:-/tmp}/typewhisper-coreml-1605-XXXXXX")"
trap 'rm -rf "$coreml_test_home"' EXIT
mkdir -p "$coreml_test_home/Library/Application Support/FluidAudio" "$coreml_test_home/Library/Caches"
ln -s "$model_root" "$coreml_test_home/Library/Application Support/FluidAudio/Models"
fixture="$coreml_test_home/02-release-readiness-19.8s.wav"
# The XCTest verifies the pinned fixture's SHA-256 before inference.
curl --fail --location --silent --show-error \
    'https://raw.githubusercontent.com/FluidInference/FluidAudio/v0.15.7/Tests/FluidAudioTests/ASR/Parakeet/SlidingWindow/Fixtures/02-release-readiness-19.8s.wav' \
    --output "$fixture"

CFFIXED_USER_HOME="$coreml_test_home" \
TYPEWHISPER_PARAKEET_CACHE_PURGE=1 \
TYPEWHISPER_PARAKEET_REGRESSION_WAV="$fixture" \
swift test --package-path "$repo_root/TypeWhisperPluginSDK" --skip-build \
    --filter testInstalledModelsPreserveTranscriptAfterCoreMLCachePurge
