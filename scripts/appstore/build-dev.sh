#!/bin/bash
# Builds and launches the Mac App Store edition for local testing.
#
# Works from any checkout or worktree: it builds into that checkout's build/
# folder and launches the result.
#
# The app is signed with an Apple Development identity and runs in the App
# Sandbox, like the store build. Without a provisioning profile it uses
# TypeWhisperAppStore-Local.entitlements, so iCloud, Sign in with Apple and real
# purchases are unavailable; test those with TestFlight.
#
# Usage:
#   scripts/appstore/build-dev.sh [--run] [--clean] [--reset-permissions]
#                                 [--language en|de|ja|zh-Hans] [--install-plugin <id>]...
#   scripts/appstore/build-dev.sh --relaunch [--reset-permissions] [--language ...]
#   scripts/appstore/build-dev.sh --check
#
#   --run                 build, then quit a running copy and launch the new build
#   --relaunch            launch the existing build without building
#   --check               unsigned compile check only (fast, nothing is launched)
#   --clean               remove the build output first
#   --reset-permissions   reset Accessibility, Input Monitoring, microphone and other
#                         privacy decisions for the App Store bundle ID before launch
#   --language <code>     app language for this launch only
#   --install-plugin <id> treat a bundled plugin as installed for this launch only
#
# Environment:
#   TYPEWHISPER_CODE_SIGN_IDENTITY   signing identity if several are installed
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
bundle_id="com.typewhisper.typewhisper-app.dev"
team_id="2D8ALY3LCL"

run=false
relaunch=false
check=false
clean=false
reset_permissions=false
language=""
plugins=()

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run) run=true; shift ;;
        --relaunch) relaunch=true; shift ;;
        --check) check=true; shift ;;
        --clean) clean=true; shift ;;
        --reset-permissions) reset_permissions=true; shift ;;
        --language) [[ $# -ge 2 ]] || usage; language="$2"; shift 2 ;;
        --install-plugin) [[ $# -ge 2 ]] || usage; plugins+=("$2"); shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if $relaunch && ($clean || $check); then
    echo "--relaunch cannot be combined with --clean or --check." >&2
    exit 1
fi

# Unsigned check builds use their own folder so they never replace the signed app.
if $check; then
    output_root="$repo_root/build/appstore-check"
else
    output_root="$repo_root/build/appstore-dev"
fi
derived_data="$output_root/DerivedData"
app_path="$derived_data/Build/Products/Debug/TypeWhisper App Store Dev.app"
log_path="$output_root/build.log"

signing_identity() {
    if [[ -n "${TYPEWHISPER_CODE_SIGN_IDENTITY:-}" ]]; then
        echo "$TYPEWHISPER_CODE_SIGN_IDENTITY"
        return
    fi
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | awk '!seen[$0]++')"
    local count
    count="$(printf '%s' "$identities" | grep -c . || true)"
    if [[ "$count" -eq 1 ]]; then
        echo "$identities"
    elif [[ "$count" -gt 1 ]]; then
        echo "Several Apple Development identities found; set TYPEWHISPER_CODE_SIGN_IDENTITY:" >&2
        printf '  %s\n' "$identities" >&2
        exit 1
    else
        echo "No Apple Development identity found. An ad-hoc build would lose its privacy permissions on every rebuild." >&2
        exit 1
    fi
}

build() {
    $clean && rm -rf "$output_root"
    mkdir -p "$output_root"
    "$repo_root/scripts/appstore/generate_project.sh"
    # Xcode keeps bundles of plugins that were removed from the project; embed
    # the current set from scratch.
    rm -rf "$app_path/Contents/PlugIns"

    local signing_args
    if $check; then
        signing_args=(CODE_SIGNING_ALLOWED=NO)
    else
        signing_args=(
            CODE_SIGN_STYLE=Manual
            "CODE_SIGN_IDENTITY=$(signing_identity)"
            PROVISIONING_PROFILE_SPECIFIER=
            "DEVELOPMENT_TEAM=$team_id"
            TYPEWHISPER_APPSTORE_ENTITLEMENTS=AppStore/Resources/TypeWhisperAppStore-Local.entitlements
        )
    fi

    echo "Building TypeWhisper App Store Dev (log: ${log_path#"$repo_root/"})..."
    if ! xcodebuild -project "$repo_root/TypeWhisperAppStore.xcodeproj" \
        -scheme TypeWhisperAppStore -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath "$derived_data" \
        -skipPackagePluginValidation -skipMacroValidation \
        "${signing_args[@]}" build >"$log_path" 2>&1; then
        grep -E ' error:' "$log_path" | sort -u | head -20 >&2 || true
        echo "Build failed; see ${log_path#"$repo_root/"}." >&2
        exit 1
    fi

    if ! $check; then
        codesign --verify --deep --strict "$app_path"
    fi
    echo "Built ${app_path#"$repo_root/"}"
}

# Every worktree builds the same executable name, so match on it rather than
# on the path; Launch Services lookups by bundle ID proved unreliable.
running_pid() {
    pgrep -f "/Contents/MacOS/TypeWhisper App Store Dev$" | head -1
}

launch() {
    [[ -d "$app_path" ]] || { echo "No build found; run without --relaunch first." >&2; exit 1; }

    # Every worktree builds the same bundle ID, so quit every running copy,
    # whichever checkout it was built from.
    if [[ -n "$(running_pid)" ]]; then
        echo "Quitting the running TypeWhisper App Store Dev..."
        osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
            [[ -z "$(running_pid)" ]] && break
            sleep 0.5
        done
        pkill -f "/Contents/MacOS/TypeWhisper App Store Dev\$" 2>/dev/null || true
    fi

    if $reset_permissions; then
        tccutil reset All "$bundle_id" >/dev/null
        echo "Reset privacy permissions for $bundle_id."
    fi

    local args=()
    if [[ -n "$language" ]]; then
        args+=(-AppleLanguages "($language)" -preferredAppLanguage "$language")
    fi
    if [[ ${#plugins[@]} -gt 0 ]]; then
        local joined
        joined="$(IFS=,; echo "${plugins[*]}")"
        args+=(-appStore.installedPluginIDs "(com.typewhisper.speechanalyzer,$joined)")
    fi

    if [[ ${#args[@]} -gt 0 ]]; then
        open "$app_path" --args "${args[@]}"
    else
        open "$app_path"
    fi
    echo "Launched TypeWhisper App Store Dev ($bundle_id)."
}

if $relaunch; then
    launch
    exit 0
fi

build
if $run && ! $check; then
    launch
fi
