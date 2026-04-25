#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# TypeWhisper Screenshot Automation
# Takes screenshots of the 1.3 Settings tabs + indicator window
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="TypeWhisper"
PROJECT="TypeWhisper.xcodeproj"
APP_NAME="TypeWhisper"
BUILD_DIR="$PROJECT_DIR/build-screenshots"
SCREENSHOT_DIR="$PROJECT_DIR/.github/screenshots"
PROCESS_NAME="TypeWhisper"

# Tabs to screenshot (in sidebar order)
# Format: "tab_label:filename" - tab_label must match the sidebar text exactly
TABS=(
    "Home:home"
    "General:general"
    "Recording:recording"
    "Hotkeys:hotkeys"
    "File Transcription:file-transcription"
    "Recorder:recorder"
    "History:history"
    "Dictionary:dictionary"
    "Snippets:snippets"
    "Workflows:workflows"
    "Legacy:legacy"
    "Integrations:plugins"
    "Advanced:advanced"
    "License:license"
    "About:about"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "--- $* ---"; }

get_settings_window_id() {
    # Settings window has name="Settings" - layer may be 0 or 3 (floating)
    swift -e '
import CoreGraphics
import Foundation
let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as NSArray? ?? []
for case let w as NSDictionary in windowList {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    let name = w["kCGWindowName"] as? String ?? ""
    if owner == "TypeWhisper" && name == "Settings" {
        print(w["kCGWindowNumber"] as? Int ?? 0)
        break
    }
}
'
}

get_notch_window_id() {
    # NotchIndicatorPanel: 500x500, positioned at top of screen (Y=0)
    swift -e '
import CoreGraphics
import Foundation
let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as NSArray? ?? []
for case let w as NSDictionary in windowList {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    let bounds = w["kCGWindowBounds"] as? NSDictionary ?? [:]
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    if owner == "TypeWhisper" && width == 500 && height == 500 {
        print(w["kCGWindowNumber"] as? Int ?? 0)
        break
    }
}
'
}

list_app_windows() {
    swift -e '
import CoreGraphics
import Foundation
let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as NSArray? ?? []
for case let w as NSDictionary in windowList {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    if owner == "TypeWhisper" {
        let id = w["kCGWindowNumber"] as? Int ?? 0
        let layer = w["kCGWindowLayer"] as? Int ?? 0
        let name = w["kCGWindowName"] as? String ?? "(none)"
        let bounds = w["kCGWindowBounds"] as? NSDictionary ?? [:]
        let onScreen = w["kCGWindowIsOnscreen"] as? Bool ?? false
        print("  ID=\(id) layer=\(layer) onScreen=\(onScreen) name=\"\(name)\" bounds=\(bounds)")
    }
}
'
}

click_sidebar_tab() {
    local tab_label="$1"
    osascript <<EOF
tell application "System Events"
    tell process "$PROCESS_NAME"
        set frontmost to true
        delay 0.2
        tell window "Settings"
            tell outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1
                set rowList to rows
                repeat with r in rowList
                    try
                        set cellText to value of static text 1 of UI element 1 of r
                        if cellText is "$tab_label" then
                            select r
                            exit repeat
                        end if
                    end try
                end repeat
            end tell
        end tell
    end tell
end tell
EOF
}

open_settings_via_menu() {
    osascript <<'EOF'
tell application "System Events"
    tell process "TypeWhisper"
        click menu bar item 1 of menu bar 2
        delay 0.3
        click menu item "Settings..." of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

SKIP_BUILD=false
NOTCH_ONLY=false
TABS_ONLY=false
EXPLORE=false

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --notch-only) NOTCH_ONLY=true ;;
        --tabs-only) TABS_ONLY=true ;;
        --explore) EXPLORE=true ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-build   Skip building the app (use existing build)"
            echo "  --notch-only   Only capture the notch indicator"
            echo "  --tabs-only    Only capture settings tabs"
            echo "  --explore      Dump accessibility hierarchy and exit"
            echo "  --help         Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 1: Build (Debug for speed)
# ---------------------------------------------------------------------------

if [ "$SKIP_BUILD" = false ]; then
    log "Building Debug app"
    xcodebuild -project "$PROJECT_DIR/$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR" \
        -destination 'platform=macOS' \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tail -5

    echo "Build complete."
fi

if [ "$SKIP_BUILD" = true ]; then
    # Use the already-running instance
    if ! pgrep -x "$PROCESS_NAME" >/dev/null; then
        echo "ERROR: App is not running. Start it first or run without --skip-build."
        exit 1
    fi
    echo "Using running instance."
else
    APP_PATH="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"

    if [ ! -d "$APP_PATH" ]; then
        echo "ERROR: App not found at $APP_PATH"
        echo "Run without --skip-build first."
        exit 1
    fi

    # Kill existing instance and start fresh
    log "Starting app"
    pkill -x "$PROCESS_NAME" 2>/dev/null || true
    sleep 1

    open "$APP_PATH"
    sleep 3

    echo "App started. Waiting for UI..."
fi

# ---------------------------------------------------------------------------
# Open Settings via menu bar extra
# ---------------------------------------------------------------------------

WINDOW_ID=$(get_settings_window_id)
if [ -z "$WINDOW_ID" ]; then
    log "Opening Settings"
    open_settings_via_menu
    sleep 2

    WINDOW_ID=$(get_settings_window_id)
    if [ -z "$WINDOW_ID" ]; then
        echo "ERROR: Settings window did not open"
        exit 1
    fi
fi
echo "Settings window found (ID=$WINDOW_ID)"

# ---------------------------------------------------------------------------
# Explore mode: dump accessibility hierarchy and exit
# ---------------------------------------------------------------------------

if [ "$EXPLORE" = true ]; then
    log "Exploring accessibility hierarchy"
    osascript <<'EXPLORE_EOF' 2>&1 || true
tell application "System Events"
    tell process "TypeWhisper"
        tell window "Settings"
            set allElements to entire contents
            repeat with elem in allElements
                try
                    set elemClass to class of elem as text
                    set elemRole to role of elem
                    set elemDesc to description of elem
                    set elemVal to ""
                    try
                        set elemVal to value of elem as text
                    end try
                    set elemTitle to ""
                    try
                        set elemTitle to title of elem as text
                    end try
                    log elemClass & " | role=" & elemRole & " | desc=" & elemDesc & " | val=" & elemVal & " | title=" & elemTitle
                end try
            end repeat
        end tell
    end tell
end tell
EXPLORE_EOF

    echo ""
    log "Windows"
    list_app_windows

    pkill -x "$PROCESS_NAME" 2>/dev/null || true
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 4: Take Settings Tab Screenshots
# ---------------------------------------------------------------------------

if [ "$NOTCH_ONLY" = false ]; then
    mkdir -p "$SCREENSHOT_DIR"

    log "Capturing settings tabs"

    for entry in "${TABS[@]}"; do
        tab_label="${entry%%:*}"
        filename="${entry##*:}"

        echo "  Tab: $tab_label -> $filename.png"

        click_sidebar_tab "$tab_label"
        sleep 1

        WINDOW_ID=$(get_settings_window_id)
        if [ -z "$WINDOW_ID" ]; then
            echo "  WARNING: Could not find settings window ID, skipping $tab_label"
            continue
        fi

        screencapture -l "$WINDOW_ID" -x "$SCREENSHOT_DIR/$filename.png"
        echo "  Captured (window $WINDOW_ID)"
    done
fi

# ---------------------------------------------------------------------------
# Step 5: Take Notch Indicator Screenshot
# ---------------------------------------------------------------------------

if [ "$TABS_ONLY" = false ]; then
    log "Capturing notch indicator"

    echo "  Checking for notch panel..."

    NOTCH_ID=$(get_notch_window_id)
    if [ -n "$NOTCH_ID" ]; then
        echo "  Found notch panel (window $NOTCH_ID)"
        screencapture -l "$NOTCH_ID" -x "$SCREENSHOT_DIR/notch.png"
        echo "  Captured notch indicator"
    else
        echo "  NOTE: Notch panel not visible (only appears during recording or with 'Always' visibility)."
        echo "  To capture the notch:"
        echo "    1. Set Notch Indicator visibility to 'Always' in General settings"
        echo "    2. Re-run with: $0 --skip-build --notch-only"
        echo ""
        echo "  Alternatively, start a recording and run:"
        echo "    screencapture -l <NOTCH_WINDOW_ID> -o -x $SCREENSHOT_DIR/notch.png"
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

log "Done"
echo ""
echo "Screenshots saved to: $SCREENSHOT_DIR"
ls -la "$SCREENSHOT_DIR/"*.png 2>/dev/null || true
echo ""

# Don't kill the app - user might want to manually adjust and re-run
echo "App is still running. Kill manually when done: pkill -x $PROCESS_NAME"
