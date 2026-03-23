#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <xcodebuild-log>" >&2
  exit 2
fi

LOG_FILE="$1"

if [ ! -f "$LOG_FILE" ]; then
  echo "Log file not found: $LOG_FILE" >&2
  exit 2
fi

filtered=()
while IFS= read -r line; do
  case "$line" in
    *"Disabling hardened runtime with ad-hoc codesigning"*)
      ;;
    *)
      filtered+=("$line")
      ;;
  esac
done < <(
  grep -n "warning:" "$LOG_FILE" | grep -E \
    "from project 'TypeWhisper'|/TypeWhisper/|/TypeWhisperTests/|/typewhisper-cli/|/TypeWhisperWidgetExtension/" || true
)

if [ "${#filtered[@]}" -gt 0 ]; then
  echo "First-party warnings detected:" >&2
  printf '%s\n' "${filtered[@]}" >&2
  exit 1
fi

echo "No first-party warnings found in $LOG_FILE"
