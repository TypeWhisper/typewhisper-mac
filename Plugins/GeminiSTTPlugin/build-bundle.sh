#!/usr/bin/env bash
# Build GeminiSTTPlugin.bundle directly with swiftc — no Xcode, no SPM.
#
# Links against the TypeWhisperPluginSDK.framework shipped inside the
# installed TypeWhisper.app, so the plugin binds to the exact same SDK
# symbols the host already has in memory. This is the pattern that was
# proven to work for STTFixerPlugin on 2026-04-10.
#
# Output: dist/GeminiSTTPlugin.bundle (ad-hoc signed, ready to install)
#
# Usage:
#   ./build-bundle.sh                # build + sign + leave in dist/
#   ./build-bundle.sh --install      # build + copy to ~/Library/Application Support/TypeWhisper/Plugins/
#   ./build-bundle.sh --app-path /path/TypeWhisper.app   # override framework source
set -euo pipefail

PLUGIN_ID="GeminiSTTPlugin"
APP_PATH="/Applications/TypeWhisper.app"
INSTALL=false
CONFIG="release"  # kept for future -Onone toggle; swiftc -O is the default here

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --app-path) shift; APP_PATH="$1" ;;
    --app-path=*) APP_PATH="${arg#*=}" ;;
    --debug) CONFIG="debug" ;;
    --help|-h) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

FRAMEWORK_DIR="$APP_PATH/Contents/Frameworks"
SDK_FRAMEWORK="$FRAMEWORK_DIR/TypeWhisperPluginSDK.framework"

if [[ ! -d "$SDK_FRAMEWORK" ]]; then
  echo "ERROR: TypeWhisperPluginSDK.framework not found at $SDK_FRAMEWORK" >&2
  echo "       Install TypeWhisper.app first, or pass --app-path /path/to/TypeWhisper.app" >&2
  exit 1
fi

ARCH="$(uname -m)"
SDK_PATH="$(xcrun --show-sdk-path)"
DEPLOYMENT_TARGET="14.0"
SOURCES=(Sources/GeminiSTTPlugin/*.swift)
SDK_SOURCES=(../../TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/*.swift)

echo "=== Building $PLUGIN_ID ($ARCH, linking against $APP_PATH) ==="

OUT="dist/${PLUGIN_ID}.bundle"
SDK_BUILD="build/sdk"
rm -rf dist build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$SDK_BUILD"

OPTIMIZATION=(-O -whole-module-optimization)
if [[ "$CONFIG" == "debug" ]]; then
  OPTIMIZATION=(-Onone -g)
fi

# Step 1: build the SDK .swiftmodule from source. Required because the shipped
# TypeWhisperPluginSDK.framework inside TypeWhisper.app is binary-only (no
# Modules/ dir), so swiftc can't `import TypeWhisperPluginSDK` from it.
echo "--- Compiling SDK .swiftmodule (for import resolution only) ---"
swiftc "${OPTIMIZATION[@]}" \
  -module-name TypeWhisperPluginSDK \
  -target "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}" \
  -sdk "$SDK_PATH" \
  -emit-module \
  -emit-module-path "$SDK_BUILD/TypeWhisperPluginSDK.swiftmodule" \
  -parse-as-library \
  "${SDK_SOURCES[@]}"

# Step 2: compile + link the plugin. Use -I for the SDK module interface and
# -F/-framework to bind link-time symbols against the framework that
# TypeWhisper.app already has loaded. @executable_path resolves relative to
# the HOST app's executable — for TypeWhisper.app that's
# /Applications/TypeWhisper.app/Contents/MacOS/, so ../Frameworks lands us
# on the correct embedded framework. We add a second fallback rpath for
# cases where the plugin happens to live inside a host bundle directly.
echo "--- Compiling plugin + linking against TypeWhisper framework ---"
swiftc "${OPTIMIZATION[@]}" \
  -module-name "$PLUGIN_ID" \
  -target "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}" \
  -sdk "$SDK_PATH" \
  -emit-library \
  -I "$SDK_BUILD" \
  -F "$FRAMEWORK_DIR" \
  -framework TypeWhisperPluginSDK \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -Xlinker -rpath -Xlinker "@loader_path/../../../../Frameworks" \
  -o "$OUT/Contents/MacOS/$PLUGIN_ID" \
  "${SOURCES[@]}"

# Self-referential install name
install_name_tool -id "@loader_path/$PLUGIN_ID" "$OUT/Contents/MacOS/$PLUGIN_ID"

# Copy TypeWhisper's manifest (principalClass, version, etc.)
cp manifest.json "$OUT/Contents/Resources/manifest.json"

# Read version from manifest so Info.plist stays in sync
VERSION="$(python3 -c "import json; print(json.load(open('manifest.json'))['version'])")"
BUNDLE_ID="$(python3 -c "import json; print(json.load(open('manifest.json'))['id'])")"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${PLUGIN_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${PLUGIN_ID}</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>NSPrincipalClass</key>
    <string>${PLUGIN_ID}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF

# Strip Finder-set xattrs that would upset codesign
find "$OUT" -exec xattr -c {} + 2>/dev/null || true

# Ad-hoc sign — required for Bundle.load() in sandboxed host apps on macOS 13+
codesign --force --sign - --timestamp=none "$OUT"
codesign --verify --strict --verbose=2 "$OUT" 2>&1 | sed 's/^/  /'

echo "✓ Built $OUT"
echo "  Size: $(du -sh "$OUT" | cut -f1)"

# Sanity check the link: confirm we reference the framework install name, not a dylib
LINK=$(otool -L "$OUT/Contents/MacOS/$PLUGIN_ID" | awk '/TypeWhisperPluginSDK/ {print $1; exit}')
echo "  Linked against: $LINK"
if [[ "$LINK" != *"TypeWhisperPluginSDK.framework"* ]]; then
  echo "  WARNING: linkage looks wrong — should reference TypeWhisperPluginSDK.framework" >&2
fi

if $INSTALL; then
  TARGET_DIR="$HOME/Library/Application Support/TypeWhisper/Plugins"
  mkdir -p "$TARGET_DIR"
  INSTALLED="$TARGET_DIR/${PLUGIN_ID}.bundle"

  rm -rf "$INSTALLED"
  cp -R "$OUT" "$INSTALLED"

  echo "✓ Installed to $INSTALLED"
  echo "  Restart TypeWhisper and enable 'Gemini STT' in Settings → Integrations."
fi
