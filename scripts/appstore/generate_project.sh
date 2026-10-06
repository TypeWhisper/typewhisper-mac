#!/bin/bash
# Generates TypeWhisperAppStore.xcodeproj from appstore-project.yml.
set -euo pipefail

cd "$(dirname "$0")/../.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi

xcodegen generate --spec appstore-project.yml --project . --quiet
echo "Generated TypeWhisperAppStore.xcodeproj"

# Resolve packages to the same versions as the direct-distribution app.
resolved_source="TypeWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
resolved_target="TypeWhisperAppStore.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
if [ -f "$resolved_source" ]; then
    mkdir -p "$resolved_target"
    cp "$resolved_source" "$resolved_target/Package.resolved"
fi
