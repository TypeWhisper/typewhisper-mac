#!/bin/bash
# Audits a built TypeWhisper.app for the Mac App Store boundary.
#
# Usage:
#   scripts/appstore/audit_app_store_binary.sh [--allow-unsigned] [--require-universal]
#       [--catalog AppStorePluginCatalog.json] /path/to/TypeWhisper.app
#
# --allow-unsigned     Accept unsigned or ad-hoc signed builds (CI compile checks).
#                      Entitlement checks are skipped for such builds.
# --require-universal  The main executable and Contents/Frameworks must contain
#                      arm64 and x86_64; plugin bundles and plugin-only
#                      frameworks must contain arm64.
#
# Failures exit with status 1. Process-launch symbols in the host app are only
# reported, because some shared code paths are compiled in but unreachable in
# the App Store edition. The same symbols in plugin bundles and plugin-only
# frameworks are failures.

set -o pipefail

EXPECTED_BUNDLE_ID="com.typewhisper.typewhisper-app"
FORBIDDEN_INFO_KEYS=(SUFeedURL SUPublicEDKey NSAppleEventsUsageDescription)
REQUIRED_ENTITLEMENTS=(
    com.apple.security.app-sandbox
    com.apple.security.network.client
    com.apple.security.device.audio-input
)
FORBIDDEN_ENTITLEMENTS=(
    com.apple.security.cs.disable-library-validation
    com.apple.security.automation.apple-events
)
# Undefined symbols that indicate launching other processes.
# shellcheck disable=SC2016 # the dollar sign is part of the ObjC class symbol
PROCESS_SYMBOL_PATTERN='^_(posix_spawn|posix_spawnp|execve|execv|execvp|fork|vfork|system|popen)$|^_OBJC_CLASS_\$_NSTask$'
# Reviewed process-launch imports that come from third-party libraries linked
# into plugins. Format: "<plugin bundle>:<sorted symbols>". A plugin passes only
# if its imports match its entry exactly; any new symbol fails the audit.
#   _popen: MLX CPU JIT compiler (mlx-swift Cmlx, mlx/backend/cpu/jit_compiler.cpp).
KNOWN_PLUGIN_PROCESS_IMPORTS=(
    "CanaryPlugin.bundle:_popen"
    "GranitePlugin.bundle:_popen"
    "LocalLLMPlugin.bundle:_popen"
    "Qwen3Plugin.bundle:_popen"
    "VoxtralPlugin.bundle:_popen"
)
# Frameworks in Contents/Frameworks that only plugin bundles link. They are
# arm64-only like those plugins, so the app and its extensions must not link
# them, and their process-launch imports are enforced like the plugins'.
#   TypeWhisperONNXRuntime: the one ONNX Runtime of the GigaAM and Supertonic plugins.
PLUGIN_ONLY_FRAMEWORKS=(TypeWhisperONNXRuntime.framework)

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

usage() {
    echo "Usage: $0 [--allow-unsigned] [--require-universal] [--catalog path] /path/to/TypeWhisper.app" >&2
    exit 64
}

allow_unsigned=0
require_universal=0
catalog_path="$repo_root/AppStore/Resources/AppStorePluginCatalog.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-unsigned) allow_unsigned=1; shift ;;
        --require-universal) require_universal=1; shift ;;
        --catalog) [[ $# -ge 2 ]] || usage; catalog_path="$2"; shift 2 ;;
        -*) usage ;;
        *) break ;;
    esac
done
[[ $# -eq 1 ]] || usage

app_path="${1%/}"
contents="$app_path/Contents"
info_path="$contents/Info.plist"
[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 1; }
[[ -f "$info_path" ]] || { echo "Info.plist not found: $info_path" >&2; exit 1; }
[[ -f "$catalog_path" ]] || { echo "Plugin catalog not found: $catalog_path" >&2; exit 1; }

failures=0
warnings=0
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
warn() { echo "  WARN  $*"; warnings=$((warnings + 1)); }
pass() { echo "  ok    $*"; }
section() { echo; echo "== $* =="; }
relative() { echo "${1#"$app_path"/}"; }

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

is_macho() { file -b "$1" 2>/dev/null | grep -q 'Mach-O'; }

# Lists every Mach-O file below a directory, NUL separated.
find_machos() {
    find "$1" -type f -print0 2>/dev/null | while IFS= read -r -d '' candidate; do
        is_macho "$candidate" && printf '%s\0' "$candidate"
    done
}

# Prints the executable of a framework bundle when it exists and is Mach-O.
framework_executable() {
    local name
    name=$(plist_value "$1/Resources/Info.plist" CFBundleExecutable)
    [[ -n "$name" ]] || name=$(basename "$1" .framework)
    [[ -f "$1/$name" ]] && is_macho "$1/$name" && printf '%s' "$1/$name"
}

# Whether a file belongs to one of PLUGIN_ONLY_FRAMEWORKS.
in_plugin_only_framework() {
    local framework
    for framework in "${PLUGIN_ONLY_FRAMEWORKS[@]}"; do
        [[ "$1" == "$contents/Frameworks/$framework/"* ]] && return 0
    done
    return 1
}

# --- Bundle -----------------------------------------------------------------
section "Bundle"
bundle_id=$(plist_value "$info_path" CFBundleIdentifier)
if [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]]; then
    pass "bundle identifier $bundle_id"
else
    fail "unexpected bundle identifier: ${bundle_id:-<missing>}"
fi

executable_name=$(plist_value "$info_path" CFBundleExecutable)
executable_path="$contents/MacOS/$executable_name"
if [[ -n "$executable_name" && -x "$executable_path" ]]; then
    pass "executable $(relative "$executable_path")"
else
    fail "executable not found: $executable_path"
fi

# --- Info.plist ---------------------------------------------------------------
section "Info.plist"
for key in "${FORBIDDEN_INFO_KEYS[@]}"; do
    if plist_value "$info_path" "$key" >/dev/null; then
        fail "forbidden key present: $key"
    else
        pass "no $key"
    fi
done

# --- Bundled components -------------------------------------------------------
section "Bundled components"
for forbidden_dir in XPCServices Library/LoginItems Helpers; do
    if [[ -e "$contents/$forbidden_dir" ]]; then
        fail "forbidden directory present: Contents/$forbidden_dir"
    else
        pass "no Contents/$forbidden_dir"
    fi
done

forbidden_found=0
while IFS= read -r -d '' forbidden; do
    fail "forbidden component: $(relative "$forbidden")"
    forbidden_found=1
done < <(find "$app_path" \( -iname 'Sparkle.framework' -o -iname 'MediaRemoteAdapter.framework' \
    -o -iname 'typewhisper-cli' -o -iname '*.typewhisperplugin' \) -print0)
[[ "$forbidden_found" -eq 0 ]] && pass "no Sparkle, MediaRemoteAdapter, typewhisper-cli or .typewhisperplugin"

# Allowed plugin bundles come from the catalog that the marketplace uses.
allowed_plugins=()
index=0
while name=$(plutil -extract "plugins.$index.bundleName" raw -o - "$catalog_path" 2>/dev/null); do
    allowed_plugins+=("$name")
    index=$((index + 1))
done
if [[ ${#allowed_plugins[@]} -eq 0 ]]; then
    fail "plugin catalog lists no bundles: $catalog_path"
fi

is_allowed_plugin() {
    local candidate="$1" allowed
    for allowed in "${allowed_plugins[@]}"; do
        [[ "$allowed" == "$candidate" ]] && return 0
    done
    return 1
}

bundled_catalog="$contents/Resources/AppStorePluginCatalog.json"
if [[ ! -f "$bundled_catalog" ]]; then
    fail "bundled plugin catalog missing: Contents/Resources/AppStorePluginCatalog.json"
elif ! cmp -s "$bundled_catalog" "$catalog_path"; then
    fail "bundled plugin catalog differs from $catalog_path"
else
    pass "bundled plugin catalog matches the repository (${#allowed_plugins[@]} plugins)"
fi

plugin_bundles=()
appex_count=0
if [[ -d "$contents/PlugIns" ]]; then
    for entry in "$contents/PlugIns"/*; do
        [[ -e "$entry" ]] || continue
        name=$(basename "$entry")
        case "$name" in
            *.appex)
                appex_count=$((appex_count + 1))
                ;;
            *)
                if is_allowed_plugin "$name"; then
                    plugin_bundles+=("$entry")
                else
                    fail "plugin not in AppStorePluginCatalog.json: Contents/PlugIns/$name"
                fi
                ;;
        esac
    done
fi
for allowed in "${allowed_plugins[@]}"; do
    [[ -d "$contents/PlugIns/$allowed" ]] || fail "catalog plugin missing from Contents/PlugIns: $allowed"
done
pass "${#plugin_bundles[@]} catalog plugin bundles, $appex_count app extensions in Contents/PlugIns"

# --- Linked libraries ---------------------------------------------------------
section "Linked libraries"
all_machos=()
while IFS= read -r -d '' binary; do
    all_machos+=("$binary")
done < <(find_machos "$app_path")

linked_forbidden=0
for binary in "${all_machos[@]}"; do
    if otool -L "$binary" 2>/dev/null | tail -n +2 | grep -Eiq 'Sparkle|MediaRemote'; then
        fail "links Sparkle or MediaRemote: $(relative "$binary")"
        linked_forbidden=1
    fi
done
[[ "$linked_forbidden" -eq 0 ]] && pass "no Sparkle or MediaRemote references in ${#all_machos[@]} Mach-O files"

# Plugin bundles load @rpath frameworks from the app's Contents/Frameworks or
# their own. The app does not link the plugin-only ones, so a missing one, or
# one without its executable, would only fail when the plugin is installed.
missing_framework=0
onnx_framework_linked=0
for plugin in "${plugin_bundles[@]}"; do
    while IFS= read -r -d '' binary; do
        while IFS= read -r framework; do
            [[ "$framework" == "TypeWhisperONNXRuntime.framework" ]] && onnx_framework_linked=1
            [[ -n "$(framework_executable "$contents/Frameworks/$framework")" ]] && continue
            [[ -n "$(framework_executable "$plugin/Contents/Frameworks/$framework")" ]] && continue
            fail "$(relative "$binary") links $framework, which is not in Contents/Frameworks or has no Mach-O executable"
            missing_framework=1
        done < <(otool -L "$binary" 2>/dev/null | sed -nE 's#^[[:space:]]+@rpath/([^/]+\.framework)/.*#\1#p' | sort -u)
    done < <(find_machos "$plugin")
done
[[ "$missing_framework" -eq 0 ]] && pass "every @rpath framework of the plugin bundles is embedded with its executable"

linked_plugin_only=0
for binary in "${all_machos[@]}"; do
    case "$binary" in
        "$contents/PlugIns/"*.bundle/*) continue ;;
    esac
    in_plugin_only_framework "$binary" && continue
    libraries=$(otool -L "$binary" 2>/dev/null | tail -n +2)
    for framework in "${PLUGIN_ONLY_FRAMEWORKS[@]}"; do
        if grep -Fq "/$framework/" <<<"$libraries"; then
            fail "$(relative "$binary") links $framework, which only plugin bundles may load"
            linked_plugin_only=1
        fi
    done
done
[[ "$linked_plugin_only" -eq 0 ]] && pass "the app and its extensions link no plugin-only framework (${PLUGIN_ONLY_FRAMEWORKS[*]})"

# GigaAM and Supertonic share TypeWhisperONNXRuntime.framework. A plugin that
# linked the static ONNX Runtime package itself would add another copy. When
# the framework is embedded or linked, its executable must be the one binary
# that exports the runtime.
onnx_framework="$contents/Frameworks/TypeWhisperONNXRuntime.framework"
onnx_executable=$(framework_executable "$onnx_framework")
onnx_runtimes=()
onnx_in_framework=0
for binary in "${all_machos[@]}"; do
    exports=$(nm -gUj "$binary" 2>/dev/null)
    grep -qx '_OrtGetApiBase' <<<"$exports" || continue
    onnx_runtimes+=("$(relative "$binary")")
    # -ef compares the files, so the executable's version symlink matches too.
    [[ -n "$onnx_executable" && "$binary" -ef "$onnx_executable" ]] && onnx_in_framework=1
done
if [[ -d "$onnx_framework" || "$onnx_framework_linked" -eq 1 ]]; then
    if [[ -z "$onnx_executable" ]]; then
        fail "$(relative "$onnx_framework") is missing or has no Mach-O executable"
    elif [[ ${#onnx_runtimes[@]} -ne 1 || "$onnx_in_framework" -ne 1 ]]; then
        fail "ONNX Runtime must be exported once, by the executable of $(relative "$onnx_framework"); found ${#onnx_runtimes[@]}: ${onnx_runtimes[*]:-none}"
    else
        pass "ONNX Runtime is exported once, by ${onnx_runtimes[0]}"
    fi
elif [[ ${#onnx_runtimes[@]} -gt 1 ]]; then
    fail "ONNX Runtime is linked into ${#onnx_runtimes[@]} binaries: ${onnx_runtimes[*]}"
else
    pass "ONNX Runtime is linked at most once: ${onnx_runtimes[*]:-not linked}"
fi

# --- Architectures --------------------------------------------------------------
section "Architectures"
check_archs() {
    local binary="$1" archs required
    shift
    archs=$(lipo -archs "$binary" 2>/dev/null)
    for required in "$@"; do
        if ! grep -qw "$required" <<<"$archs"; then
            fail "$(relative "$binary") lacks $required (has: ${archs:-none})"
            return
        fi
    done
    pass "$(relative "$binary"): $archs"
}

if [[ "$require_universal" -eq 1 ]]; then
    [[ -f "$executable_path" ]] && check_archs "$executable_path" arm64 x86_64
    if [[ -d "$contents/Frameworks" ]]; then
        while IFS= read -r -d '' binary; do
            if in_plugin_only_framework "$binary"; then
                check_archs "$binary" arm64
            else
                check_archs "$binary" arm64 x86_64
            fi
        done < <(find_machos "$contents/Frameworks")
    fi
    for plugin in "${plugin_bundles[@]}"; do
        while IFS= read -r -d '' binary; do
            check_archs "$binary" arm64
        done < <(find_machos "$plugin")
    done
else
    echo "  skip  (pass --require-universal to enforce)"
    [[ -f "$executable_path" ]] && echo "  info  $(relative "$executable_path"): $(lipo -archs "$executable_path" 2>/dev/null)"
fi

# --- Process launching ----------------------------------------------------------
# The host app reports these imports as warnings; plugin bundles fail on them.
process_imports() {
    nm -u -j "$1" 2>/dev/null | grep -E "$PROCESS_SYMBOL_PATTERN" | sort -u | paste -sd ' ' -
}

is_known_plugin_import() {
    local entry
    for entry in "${KNOWN_PLUGIN_PROCESS_IMPORTS[@]}"; do
        [[ "$entry" == "$1:$2" ]] && return 0
    done
    return 1
}

section "Process launching: plugin bundles (enforced)"
plugin_code=("${plugin_bundles[@]}")
for framework in "${PLUGIN_ONLY_FRAMEWORKS[@]}"; do
    [[ -d "$contents/Frameworks/$framework" ]] && plugin_code+=("$contents/Frameworks/$framework")
done
plugin_clean=1
for plugin in "${plugin_code[@]}"; do
    while IFS= read -r -d '' binary; do
        symbols=$(process_imports "$binary")
        [[ -n "$symbols" ]] || continue
        plugin_clean=0
        if [[ "$binary" == "$plugin/Contents/MacOS/"* ]] && is_known_plugin_import "$(basename "$plugin")" "$symbols"; then
            echo "  known $(relative "$binary") imports: $symbols (reviewed third-party code)"
        else
            fail "$(relative "$binary") imports: $symbols"
        fi
    done < <(find_machos "$plugin")
done
[[ "$plugin_clean" -eq 1 ]] && pass "no process-launch imports in ${#plugin_bundles[@]} plugin bundles and the plugin-only frameworks"

section "Process launching: host app (report only)"
host_clean=1
for binary in "${all_machos[@]}"; do
    case "$binary" in
        "$contents/PlugIns/"*.bundle/*) continue ;;
    esac
    in_plugin_only_framework "$binary" && continue
    symbols=$(process_imports "$binary")
    if [[ -n "$symbols" ]]; then
        warn "$(relative "$binary") imports: $symbols"
        host_clean=0
    fi
done
[[ "$host_clean" -eq 1 ]] && pass "no process-launch imports in the host app"

# --- Code signature and entitlements --------------------------------------------
section "Code signature and entitlements"
if ! signature_info=$(codesign -dv "$app_path" 2>&1) || grep -q 'Signature=adhoc' <<<"$signature_info"; then
    if [[ "$allow_unsigned" -eq 1 ]]; then
        echo "  skip  app is unsigned or ad-hoc signed (--allow-unsigned)"
    else
        fail "app is not signed with a distribution identity; use --allow-unsigned only for CI compile checks"
    fi
else
    authority=$(grep -m1 '^Authority=' <<<"$signature_info" | cut -d= -f2-)
    pass "signed by ${authority:-unknown authority}"
    if codesign --verify --deep --strict "$app_path" 2>/dev/null; then
        pass "codesign --verify --deep --strict"
    else
        fail "codesign --verify --deep --strict failed"
    fi

    entitlements_path=$(mktemp)
    trap 'rm -f "$entitlements_path"' EXIT
    codesign -d --xml --entitlements - "$app_path" >"$entitlements_path" 2>/dev/null
    if ! plutil -lint -s "$entitlements_path" >/dev/null 2>&1; then
        fail "could not read entitlements of the app"
    else
        for entitlement in "${REQUIRED_ENTITLEMENTS[@]}"; do
            if [[ "$(plist_value "$entitlements_path" "$entitlement")" == "true" ]]; then
                pass "$entitlement"
            else
                fail "required entitlement missing or false: $entitlement"
            fi
        done
        if [[ "$(plist_value "$entitlements_path" com.apple.security.get-task-allow)" == "true" ]]; then
            fail "com.apple.security.get-task-allow is true (development signature)"
        fi
    fi

    # Forbidden entitlements apply to every signed component.
    signed_components=("$app_path")
    while IFS= read -r -d '' component; do
        signed_components+=("$component")
    done < <(find "$contents" \( -name '*.appex' -o -name '*.bundle' -o -name '*.framework' \) -prune -print0)
    for component in "${signed_components[@]}"; do
        keys=$(codesign -d --xml --entitlements - "$component" 2>/dev/null \
            | plutil -convert xml1 -o - - 2>/dev/null \
            | sed -n 's:.*<key>\(.*\)</key>.*:\1:p')
        for entitlement in "${FORBIDDEN_ENTITLEMENTS[@]}"; do
            if grep -qx "$entitlement" <<<"$keys"; then
                fail "forbidden entitlement $entitlement in $(relative "$component")"
            fi
        done
        if grep -q '^com\.apple\.security\.temporary-exception\.' <<<"$keys"; then
            fail "temporary-exception entitlement in $(relative "$component"): $(grep '^com\.apple\.security\.temporary-exception\.' <<<"$keys" | tr '\n' ' ')"
        fi
    done
    pass "checked forbidden entitlements in ${#signed_components[@]} signed components"
fi

# --- Summary --------------------------------------------------------------------
section "Summary"
main_archs=$(lipo -archs "$executable_path" 2>/dev/null)
if [[ "$failures" -gt 0 ]]; then
    echo "App Store binary audit FAILED: $failures failure(s), $warnings warning(s)."
    exit 1
fi
echo "App Store binary audit passed ($bundle_id; ${main_archs:-unknown archs}; $warnings warning(s))."
