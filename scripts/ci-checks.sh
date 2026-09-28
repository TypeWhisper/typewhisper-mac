#!/usr/bin/env bash
# Platform-independent checks shared by scripts/pr-preflight.sh and the CI checks job.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() {
  printf '[ci-checks] %s\n' "$*"
}

cd "$repo_root"

log "checking shell scripts parse"
while IFS= read -r script_file; do
  [[ -n "$script_file" ]] || continue
  bash -n "$script_file"
done < <(git ls-files 'scripts/*.sh')

log "running Python script tests"
for test_script in scripts/test_*.py; do
  log "  $test_script"
  python3 "$test_script"
done

log "checking plugin release policy"
python3 scripts/validate_plugin_release_manifest.py TypeWhisperPluginSDK/Plugins/*/manifest.json

log "validating community plugin registry"
python3 scripts/assemble_community_plugin_registry.py

log "checking localization completeness"
python3 scripts/check_localization_completeness.py

log "checks complete"
