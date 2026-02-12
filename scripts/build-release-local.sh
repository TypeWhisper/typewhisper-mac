#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="TypeWhisper"
PROJECT="TypeWhisper.xcodeproj"
APP_NAME="TypeWhisper"
BUILD_DIR="$PROJECT_DIR/build-release"

SIGN=false
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN=true ;;
    *) echo "Unknown option: $arg"; echo "Usage: $0 [--sign]"; exit 1 ;;
  esac
done

echo "=== TypeWhisper Local Release Build ==="
echo "Sign: $SIGN"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"

# Resolve packages
echo "--- Resolving Swift packages ---"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME"

# Build
echo "--- Building Release ---"
xcodebuild -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: App not found at $APP_PATH"
  exit 1
fi

echo "--- App built at $APP_PATH ---"

# Sign if requested
if [ "$SIGN" = true ]; then
  echo "--- Signing App ---"

  # Find Developer ID identity
  IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
  if [ -z "$IDENTITY" ]; then
    echo "ERROR: No Developer ID Application certificate found in keychain"
    exit 1
  fi
  echo "Using identity: $IDENTITY"

  find "$APP_PATH" -name '._*' -delete
  xattr -cr "$APP_PATH"
  codesign --force --deep --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/TypeWhisper/Resources/TypeWhisper.entitlements" \
    --sign "$IDENTITY" \
    "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  echo "--- App signed ---"
fi

# Create DMG
echo "--- Creating DMG ---"

# Check for dmgbuild
if ! command -v dmgbuild &> /dev/null; then
  echo "dmgbuild not found. Installing..."
  pip3 install dmgbuild
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "dev")
DMG_NAME="TypeWhisper-v${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

dmgbuild -s "$PROJECT_DIR/.github/dmgbuild-settings.py" \
  -D app="$APP_NAME" \
  -D app_path="$APP_PATH" \
  -D background="$PROJECT_DIR/.github/dmg-background.png" \
  "$APP_NAME" \
  "$DMG_PATH"

echo ""
echo "=== Done ==="
echo "DMG: $DMG_PATH"

if [ "$SIGN" = true ]; then
  echo ""
  echo "To notarize, run:"
  echo "  xcrun notarytool submit \"$DMG_PATH\" --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_PASSWORD --wait"
  echo "  xcrun stapler staple \"$DMG_PATH\""
fi
