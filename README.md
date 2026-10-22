# dictum

dictum is a free macOS dictation app with local and cloud transcription engines, text workflows, speaker recognition, and folder sync across Macs.

It is a GPL-3.0 fork of [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac). The original contributors retain their copyright. See [LICENSE](LICENSE).

Build with Xcode on an Apple silicon Mac:

```bash
scripts/dictum-signing-identity.sh
scripts/dictum-verify.sh build
scripts/dictum-verify.sh test
scripts/dictum-verify.sh run
scripts/dictum-verify.sh stop
scripts/dictum-verify.sh all
```

The signing script creates the reusable `dictum Local Signing` identity in your login keychain. Builds use it for the app and embedded bundles. If it is missing, builds warn and use ad-hoc signing. macOS may require permission again after an ad-hoc rebuild.

If keychain authorization needs the owner, stop the signing command and handle the prompt locally. While that authorization is pending, `DICTUM_SIGNING_AUTHORIZATION_PENDING=1 scripts/dictum-verify.sh build` explicitly uses the warned ad-hoc fallback. Test execution builds the test host, signs it, then runs tests without rebuilding so it retains the same identity.

`run` installs `~/Applications/dictum Dev.app` and holds `/tmp/dictum-run.lock` for the running app. The lock records the worktree, process ID, and start time. Another worktree waits until the holder stops the app. `stop` refuses another worktree's lock unless called with `--force`. Stale locks are recovered automatically. Process selection uses the installed executable's full path and leaves XCTest hosts running.

`test` and `all` print current, known, resolved, and new failures. They return 0 when all failures are listed with reasons in [known-test-failures.txt](scripts/known-test-failures.txt). New failures, build errors, or incomplete results return 1. Tests in the known-failure list still run. `python3 scripts/check-localized-keys.py` checks literal keys in `String(localized:)` and `Text("…")` against the catalogs.

Launch in Simplified Chinese with `scripts/dictum-verify.sh run -AppleLanguages '(zh-Hans)'`.

`DICTUM_VERIFY_APPSTORE=1 scripts/dictum-verify.sh build` also compiles the App Store configuration without signing. This check requires `xcodegen` on `PATH`.

Build products and verification logs are stored in `.build/`. Swift modules, targets, folders, schemes, and plugin identifiers retain their upstream names for compatibility.

## 中文

dictum 是免费的 macOS 听写应用，支持本地与云端转录、文本工作流、说话人识别，以及多台 Mac 之间的文件夹同步。

本项目基于 [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac)，遵循 GPL-3.0 许可证。原始贡献者保留其版权，详见 [LICENSE](LICENSE)。

在 Apple 芯片 Mac 上安装 Xcode 后，使用上面的命令创建本地签名身份、构建、测试、启动和停止应用。`all` 执行构建和测试。

签名脚本会在登录钥匙串中创建可重复使用的 `dictum Local Signing` 身份。应用与嵌入组件使用同一身份签名；身份缺失时显示警告并使用临时签名，重新构建后可能需要重新授予系统权限。

如果钥匙串授权需要所有者处理，请停止签名命令并在本机处理提示。等待期间可使用 `DICTUM_SIGNING_AUTHORIZATION_PENDING=1 scripts/dictum-verify.sh build` 明确启用带警告的临时签名。测试先构建并签名测试宿主，再执行测试，保持宿主身份一致。

`run` 将应用安装到 `~/Applications/dictum Dev.app`，通过 `/tmp/dictum-run.lock` 记录工作树、应用进程和开始时间。其他工作树等待持有者完成验证。`stop` 拒绝停止其他工作树的应用，明确需要接管时可使用 `stop --force`。进程退出后遗留的锁会自动清理。应用进程按安装目录中的完整可执行文件路径选择，测试宿主保持运行。

`test` 和 `all` 输出当前、已知、已消失和新增失败集合。所有失败均在 [已知失败清单](scripts/known-test-failures.txt) 中时返回 0；新增失败、构建失败或测试结果不完整时返回 1。清单内的测试照常运行。使用 `python3 scripts/check-localized-keys.py` 检查 `String(localized:)` 和 `Text("…")` 中的字面量键是否存在于字符串目录。

使用 `scripts/dictum-verify.sh run -AppleLanguages '(zh-Hans)'` 以简体中文启动应用。

使用 `DICTUM_VERIFY_APPSTORE=1 scripts/dictum-verify.sh build` 同时检查 App Store 配置的无签名编译，需要在 `PATH` 中提供 `xcodegen`。

构建产物与验证日志位于 `.build/`。Swift 模块、目标、文件夹、方案和插件标识保留上游名称，以维持兼容性。
