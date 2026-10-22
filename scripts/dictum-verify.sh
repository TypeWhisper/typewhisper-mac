#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
receipts="$repo_root/.build/verification"
app="$derived_data/Build/Products/Debug/dictum Dev.app"
installed_app="$HOME/Applications/dictum Dev.app"
run_lock="/tmp/dictum-run.lock"
keychain="$HOME/Library/Keychains/login.keychain-db"
mkdir -p "$receipts"

sign_app() {
  local identity
  identity="$(security find-identity -p codesigning "$keychain" |
    awk 'index($0, "\"dictum Local Signing\"") { print $2; exit }')"
  if [[ "${DICTUM_SIGNING_AUTHORIZATION_PENDING:-0}" == 1 ]]; then
    identity="-"
    printf '警告：稳定签名正在等待所有者的钥匙串授权，本次使用临时签名。\n' >&2
  fi
  if [[ -z "$identity" ]]; then
    identity="-"
    printf '警告：缺少 dictum Local Signing，使用临时签名。运行 scripts/dictum-signing-identity.sh 创建稳定身份。\n' >&2
  fi
  find "$app" -name '*.cstemp' -type f -delete
  codesign --force --deep --sign "$identity" --timestamp=none "$app"
  codesign --verify --deep --strict "$app"
  codesign -dr - "$app" 2>&1 | tee "$receipts/designated-requirement.txt"
}

xcode() {
  xcodebuild "$@" -project "$repo_root/TypeWhisper.xcodeproj" \
    -scheme TypeWhisper -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
}

build() {
  xcode build >"$receipts/build.log" 2>&1 || {
    tail -60 "$receipts/build.log" >&2
    return 1
  }
  sign_app
  printf '%s\n' "$app"
}

test_all() {
  local xcode_status=0 sdk_status=0
  rm -rf "$receipts/tests.xcresult"
  if xcode build-for-testing >"$receipts/test-build.log" 2>&1; then
    sign_app
    xcode test-without-building -parallel-testing-enabled NO \
      -resultBundlePath "$receipts/tests.xcresult" >"$receipts/test.log" 2>&1 || xcode_status=$?
  else
    xcode_status=$?
    tail -60 "$receipts/test-build.log" >&2
  fi
  swift test --package-path "$repo_root/TypeWhisperPluginSDK" \
    --scratch-path "$repo_root/.build/spm" >"$receipts/sdk-test.log" 2>&1 || sdk_status=$?
  if [[ -d "$receipts/tests.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$receipts/tests.xcresult" \
      >"$receipts/test-summary.json"
    cat "$receipts/test-summary.json"
  fi
  tail -8 "$receipts/sdk-test.log"
  printf 'Xcode exit=%s; SDK exit=%s; logs=%s\n' "$xcode_status" "$sdk_status" "$receipts"
  [[ "$xcode_status" -eq 0 && "$sdk_status" -eq 0 ]]
}

running_pids() {
  pgrep -x 'dictum Dev' || true
}

quit_app() {
  local pids
  pids="$(running_pids)"
  [[ -n "$pids" ]] || return 0
  osascript -e 'tell application id "com.schneidervvv.dictum.dev" to quit' >/dev/null 2>&1 || true
  for ((attempt=0; attempt<40; attempt++)); do
    [[ -n "$(running_pids)" ]] || return 0
    sleep 0.25
  done
  printf 'dictum Dev 尚未退出，保留运行锁。PID %s\n' "$(running_pids)" >&2
  return 1
}

release_owned_lock() {
  if [[ -f "$run_lock/token" && "$(cat "$run_lock/token")" == "$lock_token" ]]; then
    rm -rf "$run_lock"
  fi
}

acquire_lock() {
  local holder_pid holder_path
  lock_token="$$-$(date +%s)"
  if ! mkdir "$run_lock" 2>/dev/null; then
    holder_pid="$(cat "$run_lock/pid" 2>/dev/null || true)"
    holder_path="$(cat "$run_lock/worktree" 2>/dev/null || true)"
    if [[ "$holder_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      rm -rf "$run_lock"
      mkdir "$run_lock" || return 1
    else
      printf '运行锁已占用。工作区 %s，PID %s。使用 scripts/dictum-verify.sh stop 释放。\n' "$holder_path" "$holder_pid" >&2
      return 1
    fi
  fi
  printf '%s\n' "$lock_token" >"$run_lock/token"
  printf '%s\n' "$repo_root" >"$run_lock/worktree"
  printf '%s\n' "$$" >"$run_lock/pid"
  printf 'building\n' >"$run_lock/state"
  trap 'release_owned_lock' EXIT
}

run() {
  local app_pid
  acquire_lock
  quit_app
  build
  mkdir -p "$HOME/Applications"
  rm -rf "$installed_app"
  ditto "$app" "$installed_app"
  open "$installed_app"
  app_pid=""
  for ((attempt=0; attempt<40; attempt++)); do
    app_pid="$(running_pids | head -1)"
    [[ -z "$app_pid" ]] || break
    sleep 0.25
  done
  [[ -n "$app_pid" ]] || { printf '应用未启动。\n' >&2; return 1; }
  printf '%s\n' "$app_pid" >"$run_lock/pid"
  printf 'running\n' >"$run_lock/state"
  trap - EXIT
  printf '已启动 %s，PID %s。\n' "$installed_app" "$app_pid"
}

stop() {
  local holder_pid state
  holder_pid="$(cat "$run_lock/pid" 2>/dev/null || true)"
  state="$(cat "$run_lock/state" 2>/dev/null || true)"
  if [[ "$state" == building && "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
    printf '构建仍在运行，PID %s。请等待构建结束后停止应用。\n' "$holder_pid" >&2
    return 1
  fi
  quit_app
  rm -rf "$run_lock"
  printf 'dictum Dev 已停止，运行锁已释放。\n'
}

case "${1:-}" in
  build) build ;;
  test) test_all ;;
  run|stop)
    exec /usr/bin/lockf -k -t 0 "$run_lock.guard" \
      /bin/bash "$repo_root/scripts/dictum-verify.sh" "locked-$1"
    ;;
  locked-run) run ;;
  locked-stop) stop ;;
  all) build; test_all ;;
  *) printf '用法：%s {build|test|run|stop|all}\n' "$0" >&2; exit 2 ;;
esac
