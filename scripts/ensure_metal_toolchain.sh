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

downloaded=0
for attempt in 1 2 3; do
  echo "Downloading the Metal Toolchain, attempt $attempt of 3"
  # macOS has no timeout(1); the alarm survives exec and stops a stalled download after 5 minutes.
  if perl -e 'alarm shift; exec @ARGV' 300 xcodebuild -downloadComponent MetalToolchain; then
    downloaded=1
    break
  fi
  echo "Metal Toolchain download failed, retrying in 10s..."
  sleep 10
done
if [ "$downloaded" -ne 1 ]; then
  echo "error: the Metal Toolchain download failed 3 times" >&2
  exit 1
fi

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
