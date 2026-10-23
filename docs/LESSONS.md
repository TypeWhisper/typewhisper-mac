# Lessons

Agents write, review, merge and release this project's code. Each time an agent does something wrong, add a lesson below with what went wrong, the evidence, and the fix. "Seen" lists each distinct date the mistake occurred. When a lesson has been seen on 3 or more dates, move it into [CODE STANDARDS](CODE_STANDARDS.md) and delete it from this file.

- [Lesson title] (Seen x2: YYYY-MM-DD, YYYY-MM-DD)
  - What went wrong:
  - Evidence:
  - Fix:

- 使用版本输出确认 Metal 组件已安装 (Seen x1: 2026-10-22)
  - 问题：系统可以在 Metal 组件安装完成前返回工具路径，提前运行的 SwiftPM 构建还会保留安装前的失败状态。
  - 证据：工具路径可查询时，首次 SDK 构建仍报告 Metal 组件缺失；组件安装完成后，`xcrun metal --version` 正常输出 Apple Metal 版本，SDK 构建通过。
  - 方法：使用 `xcrun metal --version` 确认组件可执行，等待现有构建进程结束后，再重新运行受安装状态影响的构建。

- Keep running shell scripts unchanged (Seen x1: 2026-10-23)
  - What went wrong: The verification script was edited while its long test command was running.
  - Evidence: Xcode and SDK tests finished successfully, then Bash resumed at a changed file offset and reported an unexpected EOF. The current file passed `bash -n`.
  - Fix: Finish script edits before starting verification. Wait for that invocation to exit before editing the script again, then rerun the complete verification command.

- Check the launch Apple Event at both launch callbacks (Seen x1: 2026-10-23)
  - What went wrong: Reading the login-item event only in `applicationWillFinishLaunching` missed a login launch on the test Mac.
  - Evidence: The early callback had no current event; `applicationDidFinishLaunching` received the open-application event with the login-item property. The login-style launch then logged `loginItem=true` and had no visible windows.
  - Fix: Preserve an early positive detection and check again in `applicationDidFinishLaunching` before presenting the initial window. Verify with a real launch Apple Event and window metadata.

- Create lazily initialised singletons before a test replaces what they overwrite (Seen x1: 2026-10-24)
  - What went wrong: `testExpandedPluginFallbackIncludesAdditionalTranscriptionEngine` installed its own `PluginManager.shared`, then `unloadPlugin` touched `ServiceContainer.shared` for the first time. The container's initialiser assigns `PluginManager.shared` and `EventBus.shared`, so the test's manager was replaced by an empty one in the middle of the test. The failure was blamed on shared preferences, but the test host already runs on its own per-process preferences domain.
  - Evidence: Run alone, the test failed with `("[]") is not equal to (["com.typewhisper.mock.transcription"])` and `XCTAssertNil failed: "mock"`, and took 9.2 s, about 6 s of it the container's creation inside `unloadPlugin`. In full runs where earlier tests had created the container it passed in 0.3 s. A full run in which the test host was killed and restarted by Xcode (`Test crashed with signal term`) runs the remaining tests, this one included, in a fresh host with no container. After `TestHostDefaultsGuard` creates the container at bundle start, the test passes alone in 0.4 s and in two full runs.
  - Fix: Create `ServiceContainer.shared` in `testBundleWillStart`. A test that depends on a process-wide singleton must also pass when run alone.

- Keep the test host away from system-wide input state (Seen x1: 2026-10-24)
  - What went wrong: The test host has the live Dev app's bundle identifier and signing identity, so it inherits the Accessibility grant. Every `HotkeyService.updateHotkey` in a test installed a real head-inserted active event tap on the session and registered Carbon hotkeys, so a full verification run could swallow or delay Fn and Esc and lose clicks in a live session. Tests also wrote and cleared the real clipboard, and about 33,000 preference suites stayed in `~/Library/Preferences`.
  - Evidence: Sampling `CGGetEventTapList` every second found an ACTIVE session tap (mask keyDown, keyUp, flagsChanged) owned by 24 different test-host processes, some for more than three minutes, and the logs of those processes repeat `Using head-inserted CGEventTap`. The same sampling of a test host with this fix shows only listen-only taps. With the guard removed, `TestHostIsolationTests/testHotkeyEventTapOnlyListens` fails with `The test host must not hold an active tap`.
  - Fix: In the test host the hotkey tap is listen-only, Carbon hotkeys and synthetic key posting are skipped, `NSPasteboard.general` is a private pasteboard, and suites created by tests are removed when the bundle finishes. List the event taps of a process with `CGGetEventTapList` before trusting that a test does not touch other apps.

- Wait for the run command before starting dependent live checks (Seen x1: 2026-10-23)
  - What went wrong: The dictation harness and process inspection started while `dictum-verify.sh run` was still building and launching the app. Its initial window then took focus from the test document.
  - Evidence: `/tmp/dictum-fix-output/r1-early-start-runtime.log` records dictation starting before the initial window became key. The receipt in `r1-final-cold-zh/proof.json` has a correct transcript, zero document bytes and `insertion=not-inserted`. Process inspection reported `launched-suspended`.
  - Fix: Wait for the run command's terminal exit result before launching the harness or inspecting the app PID. Confirm the target application is in front. The fresh cold run in `r1-final-verified-zh/proof.json` passed with one 54-byte insertion.
