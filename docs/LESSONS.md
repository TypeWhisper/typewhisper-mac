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
  - Fix: In the test host the hotkey tap is listen-only, Carbon hotkeys and synthetic key posting are skipped, `NSPasteboard.general` is a private pasteboard, and the suites created by test code are emptied when the bundle finishes. Objects still alive in the host write an empty plist again after the file is deleted, so the host writes the suite names to a manifest keyed by its process ID, and the next test host deletes those files once that process has ended. List the event taps of a process with `CGGetEventTapList` before trusting that a test does not touch other apps.

- Wait for the run command before starting dependent live checks (Seen x1: 2026-10-23)
  - What went wrong: The dictation harness and process inspection started while `dictum-verify.sh run` was still building and launching the app. Its initial window then took focus from the test document.
  - Evidence: `/tmp/dictum-fix-output/r1-early-start-runtime.log` records dictation starting before the initial window became key. The receipt in `r1-final-cold-zh/proof.json` has a correct transcript, zero document bytes and `insertion=not-inserted`. Process inspection reported `launched-suspended`.
  - Fix: Wait for the run command's terminal exit result before launching the harness or inspecting the app PID. Confirm the target application is in front. The fresh cold run in `r1-final-verified-zh/proof.json` passed with one 54-byte insertion.

- 真实字段测试依赖辅助功能授权，宿主没有授权时整个测试类会被静默跳过 (Seen x1: 2026-10-24)
  - 问题：`DuplicateInsertionRealFieldTests` 在测试宿主没有辅助功能授权时用 `XCTSkip` 跳过，换一台 Mac 运行时这组覆盖会无声消失，容易误以为修复仍被测试覆盖。
  - 证据：测试文件 `setUp` 中的 `throw XCTSkip("测试宿主没有辅助功能授权，无法通过 AX 操作本进程的文本字段")` 是唯一的授权门槛，跳过只出现在跳过计数里，不产生任何失败。
  - 方法：在新环境运行验证时，检查跳过数量并确认这 3 个真实字段测试是执行还是跳过；需要覆盖时先给测试宿主授予辅助功能权限，再单独运行 `scripts/dictum-verify.sh test -only-testing:"TypeWhisperTests/DuplicateInsertionRealFieldTests"`。
  - 锁屏：屏幕锁定时测试窗口无法获得焦点，这 3 个测试不会跳过，而是都返回 `.notAwaited` 并失败；只在屏幕解锁时运行这组测试和 `all`。

- 没有持有运行锁时产生了全局按键事件 (Seen x1: 2026-10-24)
  - 问题：为了观察测试宿主，一次发送了 F19 探测按键，另外三次对照运行真实发出了回车和 Cmd+V，当时都没有持有 `/tmp/dictum-run.lock`，这些事件会进入正在使用这台 Mac 的人的前台应用。
  - 证据：三次对照运行的测试宿主进程号为 12468、14761、17350，作者的时间线 `/tmp/dictum-fix-test-isolation/TIMELINE.md` 记录了这些运行。
  - 方法：没有运行锁时只做构建、单元测试和读文件。观察测试宿主是否影响其他进程时，读取 `CGGetEventTapList` 的结果，不发送任何按键、鼠标、粘贴或文本插入事件，包括探测事件。

- 验证仍在运行时删除了验证槽目录 (Seen x1: 2026-10-24)
  - 问题：第二次完整验证被终止后，对 `/tmp/dictum-verify-slot-1` 执行了两次 `rm -rf`，第一次删除时它的测试进程仍在运行。槽目录是整台 Mac 同时只运行一个完整验证的凭据，运行仍在进行时删除它，等于提前放开了这把锁。
  - 证据：时间线记录了对进程 22098、21587、21586 发出的 `kill` 没有结束它们，随后的 `rm -rf` 在进程仍存活时执行。
  - 方法：槽目录由 `verify-detached.py` 创建和释放，其他人不删除它。只停止自己启动并记录了进程号的进程，确认进程已退出后让 `verify-detached.py` 自己释放槽。

- 在 `dictum-verify.sh` 之外直接启动 dictum Dev 做诊断 (Seen x1: 2026-10-24)
  - 问题：测试宿主卡住后，为了诊断直接启动了 `dictum Dev` 并设置 `XCTestBundlePath`，应用把自己当作测试宿主，启动时的清理删除了已结束进程留下的 `com.schneidervvv.dictum.dev.tests.<进程号>.plist`。
  - 证据：这一次启动（进程 40840）删除了约 189 个这类文件，时间线记录于 03:20。
  - 方法：只通过 `scripts/dictum-verify.sh build` 和 `test` 启动应用和测试宿主；诊断卡住的测试宿主时对它运行 `sample`，不另行启动应用。

- 复制了其他工作区的 SourcePackages (Seen x1: 2026-10-24)
  - 问题：为了省去依赖下载，把另一个工作区的 `.build/DerivedData/SourcePackages` 克隆到自己的工作区，并复制了它的 `mlx-c` 子模块，两个工作区的构建缓存因此不再互相独立。
  - 证据：时间线记录了对 fix-double-paste 的 `cp -Rc`，那一侧只读，但复制违反了每个单元只使用自己工作区的规则。
  - 方法：在自己的工作区里由 `xcodebuild` 解析和下载依赖，不复制其他工作区的任何文件。
