#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
README_FILE="$PROJECT_DIR/README.md"
SCREENSHOT_DIR=".github/screenshots"
WIDTH="270"

START_MARKER="<!-- readme-screenshots:start -->"
END_MARKER="<!-- readme-screenshots:end -->"

MODE="write"
case "${1:-}" in
    ""|--write)
        MODE="write"
        ;;
    --check)
        MODE="check"
        ;;
    --help|-h)
        echo "Usage: $0 [--write|--check]"
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
esac

# Format per row:
#   "Alt text|filename.png|Alt text|filename.png|..."
ROWS=(
    "Home Dashboard|home.png|Recording|recording.png|Recovery|recovery.png"
    "Hotkeys|hotkeys.png|Workflows|workflows.png|File Transcription|file-transcription.png"
    "Recorder API|recorder.png|History|history.png|Dictionary|dictionary.png"
    "Dictionary Term Packs|dictionary-term-packs.png|Snippets|snippets.png|Installed Integrations|plugins.png"
    "Integration Marketplace|integrations-available.png|Premium|premium.png|License|license.png"
    "General Settings|general.png|Advanced Settings|advanced.png|About|about.png"
)

html_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//\"/&quot;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

generate_block() {
    local missing=0

    echo "$START_MARKER"
    echo

    for row in "${ROWS[@]}"; do
        IFS='|' read -r -a parts <<< "$row"
        if (( ${#parts[@]} == 0 || ${#parts[@]} % 2 != 0 )); then
            echo "Invalid row definition: $row" >&2
            return 1
        fi

        echo '<p align="center">'
        for (( i = 0; i < ${#parts[@]}; i += 2 )); do
            local alt="${parts[$i]}"
            local file="${parts[$((i + 1))]}"
            local path="$SCREENSHOT_DIR/$file"

            if [[ ! -f "$PROJECT_DIR/$path" ]]; then
                echo "Missing screenshot: $path" >&2
                missing=1
            fi

            printf '  <a href="%s"><img src="%s" width="%s" alt="%s"></a>\n' \
                "$path" \
                "$path" \
                "$WIDTH" \
                "$(html_escape "$alt")"
        done
        echo '</p>'
        echo
    done

    echo "$END_MARKER"

    if (( missing != 0 )); then
        return 1
    fi
}

replace_block() {
    local block_file="$1"
    local output_file="$2"

    awk -v start="$START_MARKER" -v end="$END_MARKER" -v block_file="$block_file" '
        BEGIN {
            while ((getline line < block_file) > 0) {
                replacement = replacement line ORS
            }
            close(block_file)
        }
        $0 == start {
            printf "%s", replacement
            in_block = 1
            found_start = 1
            next
        }
        $0 == end {
            in_block = 0
            found_end = 1
            next
        }
        !in_block {
            print
        }
        END {
            if (!found_start || !found_end) {
                exit 42
            }
        }
    ' "$README_FILE" > "$output_file"
}

block_file="$(mktemp)"
output_file="$(mktemp)"
trap 'rm -f "$block_file" "$output_file"' EXIT

generate_block > "$block_file"

if ! replace_block "$block_file" "$output_file"; then
    echo "Could not find README screenshot markers in $README_FILE" >&2
    echo "Expected markers:" >&2
    echo "  $START_MARKER" >&2
    echo "  $END_MARKER" >&2
    exit 1
fi

if [[ "$MODE" == "check" ]]; then
    if cmp -s "$README_FILE" "$output_file"; then
        echo "README screenshot block is up to date."
        exit 0
    fi

    echo "README screenshot block is out of date." >&2
    diff -u "$README_FILE" "$output_file" || true
    exit 1
fi

mv "$output_file" "$README_FILE"
echo "Updated README screenshot block."
