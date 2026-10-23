#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
receipts="$repo_root/.build/verification"
configuration="${DICTUM_VERIFY_CONFIGURATION:-Debug}"
case "$configuration" in
  Debug) product_name='dictum Dev' ;;
  Release) product_name='dictum' ;;
  *) printf '不支持的构建配置：%s\n' "$configuration" >&2; exit 2 ;;
esac
app="$derived_data/Build/Products/$configuration/$product_name.app"
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
    -scheme TypeWhisper -configuration "$configuration" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
}

build() {
  if [[ -d "$app/Contents/PlugIns" ]]; then
    find "$app/Contents/PlugIns" -maxdepth 1 \( -name '*.bundle' -o -name '*.xctest' \) \
      -type d -exec /bin/rm -r {} +
  fi
  xcode build >"$receipts/build.log" 2>&1 || {
    tail -60 "$receipts/build.log" >&2
    return 1
  }
  python3 "$repo_root/scripts/check-qwen-runtime.py" "$app" || return 1
  sign_app
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
      "$@" \
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
    if [[ "$(cat "$run_lock/worktree" 2>/dev/null || true)" == "$repo_root" &&
          -n "$holder_pid" && "$holder_pid" == "$(running_pids | awk 'NR == 1 { print }')" ]]; then
      lock_token="$(cat "$run_lock/token")"
      printf '%s\n' "$$" >"$run_lock/pid"
      printf 'building\n' >"$run_lock/state"
      trap 'release_owned_lock' EXIT
      return 0
    fi
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
  local app_pid attempt login_item=0
  [[ "$configuration" == Debug ]] || { printf '实机验证请使用 Debug 配置。\n' >&2; return 2; }
  if [[ "${1:-}" == --login-item ]]; then login_item=1; shift; fi
  if [[ "${1:-}" == --audio-file ]]; then
    [[ -n "${2:-}" && -r "$2" ]] || { printf '音频文件不可读取。\n' >&2; return 2; }
    set -- --audio-file "$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$2")" "${@:3}"
  fi
  acquire_lock
  quit_app
  build
  mkdir -p "$HOME/Applications"
  rm -rf "$installed_app"
  ditto "$app" "$installed_app"
  if [[ "$login_item" == 1 ]]; then
    swift -e '
import AppKit
import Carbon
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.arguments = Array(CommandLine.arguments.dropFirst(2))
let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                                 targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                 transactionID: AETransactionID(kAnyTransactionID))
event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
configuration.appleEvent = event
NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: configuration) { app, error in
    if let error { fputs("\(error)\n", stderr); exit(1) }
    exit(app == nil ? 1 : 0)
}
RunLoop.main.run()
' "$installed_app" "$@"
  else
    open "$installed_app" --args "$@"
  fi
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

dictate() {
  local audio_file="${1:-}" mode="${2:-live}" result_file url attempt
  [[ "$mode" == live || "$mode" == hotkey || "$mode" == paste ]] || return 2
  [[ -n "$audio_file" && -r "$audio_file" ]] || { printf '请提供可读取的音频文件。\n' >&2; return 2; }
  if [[ ! -d "$run_lock" ]]; then
    printf '请先运行 scripts/dictum-verify.sh run --audio-file <音频文件>，再将光标放进目标输入框。\n' >&2
    return 1
  fi
  [[ "$(cat "$run_lock/worktree" 2>/dev/null || true)" == "$repo_root" && -n "$(running_pids)" ]] || {
    print_lock_holder
    return 1
  }
  result_file="$(mktemp /tmp/dictum-dictate-XXXXXXXX)"
  url="$(python3 -c 'import pathlib,sys,urllib.parse; q={"file":str(pathlib.Path(sys.argv[1]).resolve()),"result":sys.argv[2]}; q.update({"mode":sys.argv[3]} if sys.argv[3]!="live" else {}); print("dictum://dictate?"+urllib.parse.urlencode(q))' "$audio_file" "$result_file" "$mode")"
  open -g -a "$installed_app" "$url"
  for ((attempt=0; attempt<1900; attempt++)); do
    if [[ -s "$result_file" ]]; then
      cp "$result_file" "$receipts/dictation-result.json"
      python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(r,ensure_ascii=False,indent=2)); sys.exit(0 if r["status"]=="completed" and r.get("inserted") else 1)' "$result_file"
      return $?
    fi
    [[ -n "$(running_pids)" ]] || { printf '听写过程中应用退出。\n' >&2; return 1; }
    sleep 0.1
  done
  printf '等待听写结果超时，结果路径 %s。\n' "$result_file" >&2
  return 1
}

case "${1:-}" in
  build) build ;;
  test) shift; test_all "$@" ;;
  dictate) shift; dictate "$@" ;;
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
  *) printf '用法：%s {build|test|all|run [--login-item] [--audio-file 路径] [应用参数...]|dictate 文件 [live|hotkey|paste]|stop [--force]}\n' "$0" >&2; exit 2 ;;
esac
