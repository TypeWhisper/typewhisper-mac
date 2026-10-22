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
    awk 'index($0, "\"dictum Local Signing\"") && !found++ { print $2 }')"
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
  if [[ "${DICTUM_VERIFY_APPSTORE:-0}" == 1 ]]; then
    "$repo_root/scripts/appstore/build-dev.sh" --check >"$receipts/appstore-build.log" 2>&1 || {
      tail -60 "$receipts/appstore-build.log" >&2
      return 1
    }
  fi
  printf '%s\n' "$app"
}

test_all() {
  local xcode_status=0 sdk_status=0 summary_status=0
  python3 "$repo_root/scripts/check-localized-keys.py" || return 1
  rm -rf "$receipts/tests.xcresult"
  rm -f "$receipts/test-summary.json"
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
      >"$receipts/test-summary.json" || summary_status=$?
    cat "$receipts/test-summary.json"
  fi
  tail -8 "$receipts/sdk-test.log"
  printf 'Xcode exit=%s; SDK exit=%s; logs=%s\n' "$xcode_status" "$sdk_status" "$receipts"
  python3 "$repo_root/scripts/check-test-failures.py" "$receipts" \
    "$xcode_status" "$sdk_status" "$summary_status"
}

running_pids() {
  ps -axww -o pid=,comm= | awk -v executable="$installed_app/Contents/MacOS/dictum Dev" '
    { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid }
  '
}

quit_app() {
  local pids pid attempt
  pids="$(running_pids)"
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    printf '请求 dictum Dev 正常退出，PID %s。\n' "$pid"
    /usr/bin/osascript -l JavaScript -e \
      "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" \
      >/dev/null || printf '警告：PID %s 的正常退出请求未成功。\n' "$pid" >&2
  done <<< "$pids"
  for ((attempt=0; attempt<40; attempt++)); do
    if [[ -z "$(running_pids)" ]]; then
      printf 'dictum Dev 已正常退出。\n'
      return 0
    fi
    sleep 0.25
  done
  pids="$(running_pids)"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    printf '警告：PID %s 在 10 秒内未正常退出，发送 SIGTERM。\n' "$pid" >&2
    kill -TERM "$pid" 2>/dev/null || true
  done <<< "$pids"
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
  local holder_pid
  lock_token="$$-$(date +%s)"
  if ! mkdir "$run_lock" 2>/dev/null; then
    holder_pid="$(cat "$run_lock/pid" 2>/dev/null || true)"
    if [[ "$holder_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
      rm -rf "$run_lock"
      mkdir "$run_lock" || return 1
    else
      print_lock_holder
      return 1
    fi
  fi
  printf '%s\n' "$lock_token" >"$run_lock/token"
  printf '%s\n' "$repo_root" >"$run_lock/worktree"
  date '+%Y-%m-%d %H:%M:%S %Z' >"$run_lock/since"
  printf '%s\n' "$$" >"$run_lock/pid"
  printf 'building\n' >"$run_lock/state"
  trap 'release_owned_lock' EXIT
}

run() {
  local app_pid attempt
  acquire_lock
  quit_app
  build
  mkdir -p "$HOME/Applications"
  rm -rf "$installed_app"
  ditto "$app" "$installed_app"
  open "$installed_app" --args "$@"
  app_pid=""
  for ((attempt=0; attempt<40; attempt++)); do
    app_pid="$(running_pids | awk 'NR == 1 { print }')"
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
  local holder_path
  holder_path="$(cat "$run_lock/worktree" 2>/dev/null || true)"
  if [[ -d "$run_lock" && "$holder_path" != "$repo_root" && "${1:-}" != --force ]]; then
    print_lock_holder
    printf '拒绝停止其他工作区的应用。仅在明确需要接管时使用 stop --force。\n' >&2
    return 1
  fi
  quit_app
  rm -rf "$run_lock"
  printf 'dictum Dev 已停止，运行锁已释放。\n'
}

print_lock_holder() {
  printf '运行锁已占用。工作区 %s，PID %s，自 %s 起持有。请等待持有者完成验证并停止应用。\n' \
    "$(cat "$run_lock/worktree" 2>/dev/null || printf '未知')" \
    "$(cat "$run_lock/pid" 2>/dev/null || printf '未知')" \
    "$(cat "$run_lock/since" 2>/dev/null || stat -f '%Sm' "$run_lock" 2>/dev/null || printf '未知')" >&2
}

case "${1:-}" in
  build) build ;;
  test) test_all ;;
  run|stop)
    command="$1"
    shift
    status=0
    /usr/bin/lockf -k -s -t 0 "$run_lock.guard" \
      /bin/bash "$repo_root/scripts/dictum-verify.sh" "locked-$command" "$@" || status=$?
    if [[ "$status" -eq 75 ]]; then print_lock_holder; fi
    exit "$status"
    ;;
  locked-run) shift; run "$@" ;;
  locked-stop) shift; stop "$@" ;;
  all) build; test_all ;;
  *) printf '用法：%s {build|test|all|run [应用参数...]|stop [--force]}\n' "$0" >&2; exit 2 ;;
esac
