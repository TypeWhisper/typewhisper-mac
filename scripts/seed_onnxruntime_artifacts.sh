#!/usr/bin/env bash
# Puts the onnxruntime binary archives into SwiftPM's shared artifact cache.
#
# onnxruntime-swift-package-manager downloads them from download.onnxruntime.ai.
# On 2026-11-21 that server answered with a certificate for *.azureedge.net, and
# every build without a restored package cache failed. Copies of the archives
# are release assets of TypeWhisper/onnxruntime-swift-package-manager. This
# script checks them against the checksums from the package's Package.swift
# before it caches them, and SwiftPM checks them again.
#
# Nothing here fails the job: on any problem SwiftPM downloads as before.
set -uo pipefail

version="1.24.2"
mirror="https://github.com/TypeWhisper/onnxruntime-swift-package-manager/releases/download/$version"
cache="${SWIFTPM_ARTIFACT_CACHE:-$HOME/Library/Caches/org.swift.swiftpm/artifacts}"
resolved="TypeWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# Upstream URL and SHA256, as in Package.swift of onnxruntime-swift-package-manager $version.
archives=(
  "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54"
  "https://download.onnxruntime.ai/pod-archive-onnxruntime-extensions-c-0.13.0.zip 346522d1171d4c99cb0908fa8e4e9330a4a6aad39cd83ce36eb654437b33e6b5"
)

warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=onnxruntime mirror::$1"
  else
    echo "warning: $1" >&2
  fi
}

if [[ -f "$resolved" ]]; then
  pinned=$(python3 -c 'import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
print(next((p["state"].get("version", "") for p in pins if p["identity"] == "onnxruntime-swift-package-manager"), ""))' "$resolved")
  if [[ -n "$pinned" && "$pinned" != "$version" ]]; then
    warn "Package.resolved pins onnxruntime $pinned, the mirror has $version. Update scripts/seed_onnxruntime_artifacts.sh."
    exit 0
  fi
fi

mkdir -p "$cache" || { warn "Cannot create $cache."; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for entry in "${archives[@]}"; do
  read -r url checksum <<<"$entry"
  name="${url##*/}"
  # SwiftPM names cached artifacts after their URL with every other character replaced by "_".
  target="$cache/$(printf '%s' "$url" | LC_ALL=C sed 's/[^A-Za-z0-9]/_/g')"

  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$checksum" ]]; then
    echo "$name is already cached."
    continue
  fi

  if ! curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
    -o "$work/$name" "$mirror/$name"; then
    warn "Could not download $name from the mirror; SwiftPM will try $url."
    continue
  fi
  actual=$(shasum -a 256 "$work/$name" | cut -d' ' -f1)
  if [[ "$actual" != "$checksum" ]]; then
    warn "$name from the mirror has SHA256 $actual, expected $checksum. Not cached."
    continue
  fi
  mv "$work/$name" "$target"
  echo "Cached $name ($checksum)."
done
