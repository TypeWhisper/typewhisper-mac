#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

VERSION="v1.13.2"
ARCHIVE_NAME="sherpa-onnx-${VERSION}-macos-xcframework-static.tar.bz2"
DOWNLOAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/${ARCHIVE_NAME}"
VENDOR_ROOT="$PROJECT_DIR/TypeWhisperPluginSDK/Vendor/SherpaONNX"
XCFRAMEWORK_PATH="$VENDOR_ROOT/sherpa-onnx.xcframework"
STAMP_PATH="$VENDOR_ROOT/.version"

if [ -d "$XCFRAMEWORK_PATH" ] && [ -f "$STAMP_PATH" ] && [ "$(cat "$STAMP_PATH")" = "$VERSION" ]; then
  exit 0
fi

mkdir -p "$VENDOR_ROOT"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typewhisper-sherpa-onnx.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Bootstrapping Sherpa-ONNX ${VERSION}..."
curl -L --fail --retry 3 -o "$TMP_DIR/$ARCHIVE_NAME" "$DOWNLOAD_URL"
tar xjf "$TMP_DIR/$ARCHIVE_NAME" -C "$TMP_DIR"

EXTRACTED="$TMP_DIR/sherpa-onnx-${VERSION}-macos-xcframework-static/sherpa-onnx.xcframework"
if [ ! -d "$EXTRACTED" ]; then
  echo "ERROR: Sherpa-ONNX XCFramework was not found in archive" >&2
  exit 1
fi

rm -rf "$XCFRAMEWORK_PATH"
cp -R "$EXTRACTED" "$XCFRAMEWORK_PATH"
echo "$VERSION" > "$STAMP_PATH"
echo "Sherpa-ONNX ready at $XCFRAMEWORK_PATH"
