#!/usr/bin/env bash
set -euo pipefail

DEV_SUPPORT="${DEV_SUPPORT:-$HOME/Library/Application Support/TypeWhisper-Dev}"
SEED_SUPPORT="${SEED_SUPPORT:-$HOME/Library/Application Support/TypeWhisper-Dev-Seed}"
SEED_DEFAULTS_PLIST="${SEED_DEFAULTS_PLIST:-$SEED_SUPPORT/defaults/com.typewhisper.mac.dev.plist}"
DEV_DEFAULTS="${DEV_DEFAULTS:-com.typewhisper.mac.dev}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Library/Application Support/TypeWhisper-Dev-Backups}"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir="$BACKUP_ROOT/$timestamp"

log() {
  printf '[typewhisper-dev-sync] %s\n' "$*"
}

table_for_store() {
  case "$1" in
    dictionary.store) printf 'ZDICTIONARYENTRY' ;;
    snippets.store) printf 'ZSNIPPET' ;;
    profiles.store) printf 'ZPROFILE' ;;
    prompt-actions.store) printf 'ZPROMPTACTION' ;;
    workflows.store) printf 'ZWORKFLOW' ;;
    history.store) printf 'ZTRANSCRIPTIONRECORD' ;;
    *) printf '' ;;
  esac
}

store_count() {
  local store="$1"
  local table="$2"
  if [[ ! -f "$store" ]]; then
    printf '0'
    return
  fi
  if [[ -z "$table" ]]; then
    printf '0'
    return
  fi
  sqlite3 "$store" "select count(*) from $table;"
}

backup_path() {
  local path="$1"
  local rel="${path#$DEV_SUPPORT/}"
  mkdir -p "$backup_dir/$(dirname "$rel")"
  if [[ -e "$path" ]]; then
    cp -a "$path" "$backup_dir/$rel"
  fi
}

copy_store_if_dev_empty() {
  local name="$1"
  local source_base="$SEED_SUPPORT/$name"
  local dev_base="$DEV_SUPPORT/$name"
  local table
  table="$(table_for_store "$name")"

  if [[ ! -f "$source_base" ]]; then
    log "skip $name: source missing"
    return
  fi

  local source_count dev_count
  if ! source_count="$(store_count "$source_base" "$table" 2>/dev/null)"; then
    log "skip $name: source store could not be read"
    return
  fi
  if ! dev_count="$(store_count "$dev_base" "$table" 2>/dev/null)"; then
    log "skip $name: dev store could not be read"
    return
  fi

  if [[ "$source_count" == "0" ]]; then
    log "skip $name: source has no entries"
    return
  fi

  if [[ "$dev_count" != "0" ]]; then
    log "keep $name: dev already has $dev_count entries"
    return
  fi

  mkdir -p "$DEV_SUPPORT"
  mkdir -p "$backup_dir"
  for suffix in "" "-shm" "-wal"; do
    backup_path "$dev_base$suffix"
    if [[ -e "$source_base$suffix" ]]; then
      cp -a "$source_base$suffix" "$dev_base$suffix"
    else
      rm -f "$dev_base$suffix"
    fi
  done
  log "copied $name: source entries=$source_count"
}

copy_dir_if_dev_missing() {
  local rel="$1"
  local source_dir="$SEED_SUPPORT/$rel"
  local dev_dir="$DEV_SUPPORT/$rel"

  if [[ ! -d "$source_dir" ]]; then
    log "skip $rel: source missing"
    return
  fi

  if [[ -d "$dev_dir" ]] && [[ -n "$(find "$dev_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "keep $rel: dev already populated"
    return
  fi

  mkdir -p "$(dirname "$dev_dir")"
  mkdir -p "$backup_dir"
  backup_path "$dev_dir"
  rm -rf "$dev_dir"
  cp -a "$source_dir" "$dev_dir"
  log "copied $rel"
}

copy_default_if_dev_missing() {
  local key="$1"
  if [[ ! -f "$SEED_DEFAULTS_PLIST" ]]; then
    return
  fi
  if defaults read "$DEV_DEFAULTS" "$key" >/dev/null 2>&1; then
    return
  fi

  local value_xml
  value_xml="$(/usr/libexec/PlistBuddy -x -c "Print :$key" "$SEED_DEFAULTS_PLIST" 2>/dev/null || true)"
  if [[ -z "$value_xml" ]]; then
    return
  fi

  case "$value_xml" in
    *"<true/>"*)
      defaults write "$DEV_DEFAULTS" "$key" -bool true
      ;;
    *"<false/>"*)
      defaults write "$DEV_DEFAULTS" "$key" -bool false
      ;;
    *"<integer>"*)
      local int_value
      int_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$SEED_DEFAULTS_PLIST")"
      defaults write "$DEV_DEFAULTS" "$key" -int "$int_value"
      ;;
    *"<real>"*)
      local float_value
      float_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$SEED_DEFAULTS_PLIST")"
      defaults write "$DEV_DEFAULTS" "$key" -float "$float_value"
      ;;
    *"<data>"*)
      local data_hex
      data_hex="$(
        printf '%s\n' "$value_xml" \
          | sed -n '/<data>/,/<\/data>/p' \
          | sed -e 's/<[^>]*>//g' -e 's/[[:space:]]//g' \
          | tr -d '\n' \
          | base64 --decode \
          | xxd -p -c 256 \
          | tr -d '\n'
      )"
      if [[ -z "$data_hex" ]]; then
        log "skip default $key: empty data"
        return
      fi
      defaults write "$DEV_DEFAULTS" "$key" -data "$data_hex"
      ;;
    *"<string>"*)
      local string_value
      string_value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$SEED_DEFAULTS_PLIST")"
      defaults write "$DEV_DEFAULTS" "$key" -string "$string_value"
      ;;
    *)
      log "skip default $key: unsupported type"
      return
      ;;
  esac
  log "copied default $key"
}

create_seed_if_missing() {
  if [[ -d "$SEED_SUPPORT" ]] && [[ -n "$(find "$SEED_SUPPORT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    return
  fi

  if [[ ! -d "$DEV_SUPPORT" ]] || [[ -z "$(find "$DEV_SUPPORT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "seed missing and dev support is empty; nothing to seed"
    return
  fi

  mkdir -p "$SEED_SUPPORT/defaults"
  cp -a "$DEV_SUPPORT/." "$SEED_SUPPORT/"
  if defaults export "$DEV_DEFAULTS" "$SEED_DEFAULTS_PLIST" >/dev/null 2>&1; then
    log "created seed from current dev data: $SEED_SUPPORT"
  else
    log "created seed from current dev data without defaults export: $SEED_SUPPORT"
  fi
}

ensure_dev_defaults() {
  defaults write "$DEV_DEFAULTS" selectedEngine qwen3
  defaults write "$DEV_DEFAULTS" "plugin.com.typewhisper.qwen3.enabled" -bool true

  if ! defaults read "$DEV_DEFAULTS" "plugin.com.typewhisper.qwen3.selectedModel" >/dev/null 2>&1; then
    copy_default_if_dev_missing "plugin.com.typewhisper.qwen3.selectedModel"
  fi
  if ! defaults read "$DEV_DEFAULTS" "plugin.com.typewhisper.qwen3.loadedModel" >/dev/null 2>&1; then
    copy_default_if_dev_missing "plugin.com.typewhisper.qwen3.loadedModel"
  fi

  copy_default_if_dev_missing selectedLanguage
  copy_default_if_dev_missing preferredAppLanguage
  copy_default_if_dev_missing pttHotkey
  copy_default_if_dev_missing pttHotkeys
  copy_default_if_dev_missing toggleHotkey
  copy_default_if_dev_missing toggleHotkeys
  copy_default_if_dev_missing setupWizardCompleted
  copy_default_if_dev_missing workUsagePromptDismissed
}

mkdir -p "$DEV_SUPPORT"
create_seed_if_missing

copy_store_if_dev_empty dictionary.store
copy_store_if_dev_empty snippets.store
copy_store_if_dev_empty profiles.store
copy_store_if_dev_empty prompt-actions.store
copy_store_if_dev_empty workflows.store

copy_dir_if_dev_missing "PluginData/com.typewhisper.qwen3"
copy_dir_if_dev_missing "Plugins/Qwen3Plugin.bundle"

ensure_dev_defaults

dev_dictionary_count="$(store_count "$DEV_SUPPORT/dictionary.store" "$(table_for_store dictionary.store)" 2>/dev/null || printf 'unreadable')"
dev_model="$(defaults read "$DEV_DEFAULTS" "plugin.com.typewhisper.qwen3.selectedModel" 2>/dev/null || true)"

log "done: dev dictionary entries=$dev_dictionary_count, qwen3 selectedModel=${dev_model:-unset}"
if [[ -d "$backup_dir" ]]; then
  log "backup: $backup_dir"
fi
