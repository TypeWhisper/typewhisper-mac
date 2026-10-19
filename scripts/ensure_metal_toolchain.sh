#!/usr/bin/env bash
# Makes sure `xcrun metal` works before MLX compiles its shaders.
#
# The xcode-27 runner image ships without the Metal Toolchain
# (actions/runner-images#14548). After -downloadComponent the toolchain is
# mounted asynchronously, and xcrun may still have the failed lookup cached, so
# poll with a fresh xcrun cache until the compiler answers.
set -euo pipefail

if xcrun metal -v >/dev/null 2>&1; then
  xcrun metal -v
  exit 0
fi

xcodebuild -downloadComponent MetalToolchain

for _ in $(seq 1 30); do
  xcrun --kill-cache >/dev/null 2>&1 || true
  if xcrun metal -v >/dev/null 2>&1; then
    xcrun metal -v
    exit 0
  fi
  sleep 5
done

xcodebuild -showComponent MetalToolchain || true
echo "error: the Metal Toolchain is still unavailable after downloading it" >&2
exit 1
