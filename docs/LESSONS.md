# Lessons

Agents write, review, merge and release this project's code. Each time an agent does something wrong, add a lesson below with what went wrong, the evidence, and the fix. "Seen" lists each distinct date the mistake occurred. When a lesson has been seen on 3 or more dates, move it into [CODE STANDARDS](CODE_STANDARDS.md) and delete it from this file.

- [Lesson title] (Seen x2: YYYY-MM-DD, YYYY-MM-DD)
  - What went wrong:
  - Evidence:
  - Fix:

- 轮询的 SwiftUI 构建器读取值快照 (Seen x1: 2026-10-23)
  - 问题：语音识别页面在嵌套视图构建器里轮询插件引用。侧栏已更新时，模型行和精度选择仍显示旧值。
  - 证据：真实的 Qwen3 下载进行中，侧栏显示 63%，页面仍显示“下载”。修改精度后模型大小已更新，选择器仍显示 6-bit。
  - 方法：在时间线闭包内把活动状态和所选模型读入值快照，再传给行构建器，并用所选模型标识精度选择器。在运行的应用里确认进度和选择的刷新。

- 未读日志就把失败归因给其他单元 (Seen x1: 2026-10-24)
  - 问题：阶段 1 的报告写“插入读回为空”，并归因于文本插入单元。实际是测试驱动让 dictum Dev 自己处于最前，粘贴目标不是 TextEdit。
  - 证据：12 次运行中 9 次精确插入一份；三次失败都是各档的第 0 次，日志为 `reason=no-focused-text-element`、`bundle=com.schneidervvv.dictum.dev`。
  - 方法：报告失败原因前先读同一次运行的日志；确认目标应用在最前后再判断插入结果，不把未核实的原因写进文档。

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

- Wait for the run command before starting dependent live checks (Seen x1: 2026-10-23)
  - What went wrong: The dictation harness and process inspection started while `dictum-verify.sh run` was still building and launching the app. Its initial window then took focus from the test document.
  - Evidence: `/tmp/dictum-fix-output/r1-early-start-runtime.log` records dictation starting before the initial window became key. The receipt in `r1-final-cold-zh/proof.json` has a correct transcript, zero document bytes and `insertion=not-inserted`. Process inspection reported `launched-suspended`.
- Acquire the application lock for tests that insert text (Seen x1: 2026-10-23)
  - What went wrong: A complete test run included integration tests that use the real text insertion service while another phase could own the desktop.
  - Evidence: Existing integration tests call the paste path with text including `transcribed`. The coordinator observed unexpected text in another phase's dictionary field. The exact originating process was not captured.
  - Fix: Hold `/tmp/dictum-run.lock` for the entire test run whenever any test can generate global input. Keep a dedicated document under `/tmp/dictum-<phase>/` as the target, and verify the frontmost application before live dictation.

- Keep preference defaults isolated between test suites (Seen x1: 2026-10-23)
  - What went wrong: Registering the new history retention default affected other UserDefaults suites in the same test process and removed old history in backup tests.
  - Evidence: Six SettingsBackupExporterTests failed in the first phase 4 complete run and passed in the targeted regression run after the default initialization was corrected.
  - Fix: Initialize production defaults only in the standard preferences domain. Apply retention at the history and sync lifecycle boundaries, keeping generic backup mutation restoration independent of retention.
- Serialize verification commands within one worktree (Seen x1: 2026-10-23)
  - What went wrong: A second verification started after an Xcode compilation failure while the first invocation was still running SDK tests. Both commands wrote the same receipts and redirected log.
  - Evidence: The shared log contained sparse bytes and an xcresult reader error, while the later invocation returned zero and its independent Xcode result reported 2,980 passing tests.
  - Fix: Wait for the complete shell invocation to exit before starting another verification in that worktree. Use a distinct redirected log for each attempt and retain the final exit status together with the result bundle summary.

- 真实字段测试依赖辅助功能授权，宿主没有授权时整个测试类会被静默跳过 (Seen x1: 2026-10-24)
  - 问题：`DuplicateInsertionRealFieldTests` 在测试宿主没有辅助功能授权时用 `XCTSkip` 跳过，换一台 Mac 运行时这组覆盖会无声消失，容易误以为修复仍被测试覆盖。
  - 证据：测试文件 `setUp` 中的 `throw XCTSkip("测试宿主没有辅助功能授权，无法通过 AX 操作本进程的文本字段")` 是唯一的授权门槛，跳过只出现在跳过计数里，不产生任何失败。
  - 方法：在新环境运行验证时，检查跳过数量并确认这 3 个真实字段测试是执行还是跳过；需要覆盖时先给测试宿主授予辅助功能权限，再单独运行 `scripts/dictum-verify.sh test -only-testing:"TypeWhisperTests/DuplicateInsertionRealFieldTests"`。
  - 锁屏：屏幕锁定时测试窗口无法获得焦点，这 3 个测试不会跳过，而是都返回 `.notAwaited` 并失败；只在屏幕解锁时运行这组测试和 `all`。

- 用 Python 和 sed 脚本改写源代码与文档 (Seen x1: 2026-10-24)
  - 问题：阶段 4 的修复过程中，源代码和文档被 Python、sed 脚本批量改写，违反代码标准“所有源代码修改都通过编辑工具逐处完成”。
  - 证据：阶段 4 审查第 1 轮的修复由 Python 和 sed 脚本完成，协调者在第 2 轮交接时指出这违反代码标准。
  - 方法：每处源代码和文档修改都用编辑工具完成，每次只改一处并确认上下文。需要批量修改时，使用格式化工具、官方脚手架或代码生成器；没有合适的工具时，列出全部位置后逐处编辑。
