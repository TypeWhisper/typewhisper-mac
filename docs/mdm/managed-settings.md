# dictum 托管设置

dictum 从 macOS 配置描述文件读取组织设置。正式版的偏好域为 `com.schneidervvv.dictum`，开发版为 `com.schneidervvv.dictum.dev`。仓库保留的 App Store 构建使用 `com.typewhisper.typewhisper-app` 和 `com.typewhisper.typewhisper-app.dev`。插件标识继续使用其原有名称。

应用在启动、重新激活、系统唤醒、用户会话切换时读取配置，并每 30 秒检查一次。设置的高级页面显示实际读取的键、强制值、建议值和配置问题，可以手动刷新。

## 配置作用

- 描述文件顶层的设置为强制值。相关控件显示组织管理提示，并保留用户原先的选择。
- `Recommended` 字典中的设置为建议值。优先级依次为强制值、用户选择、建议值、应用默认值。
- `defaults write` 写入的同名值不具有组织管理效力。应用会报告这些值并忽略其托管作用。
- 键名区分大小写。未知键、错误类型、缺少配对值会出现在配置问题中。
- 无法读取配置时，应用保留此前读取的值并暂停受影响的功能。无效建议值会被忽略；无效强制值会暂停对应功能。

## 支持的键

| 键 | 类型 | 范围 | 行为 |
| --- | --- | --- | --- |
| `TranscriptionProviderId` | 字符串 | 强制或建议 | 语音识别供应商的插件标识。一个插件包含多个供应商时使用 `<插件标识>:<供应商标识>`。与 `TranscriptionModelId` 在同一范围内设置。 |
| `TranscriptionModelId` | 字符串 | 强制或建议 | 供应商模型目录中的模型标识，例如 `qwen3-asr-1.7b-6bit`。 |
| `LlmProviderId` | 字符串 | 强制或建议 | 语言模型供应商的插件标识或限定供应商标识。Apple Intelligence 使用 `com.typewhisper.apple-intelligence`。与 `LlmModelId` 在同一范围内设置。 |
| `LlmModelId` | 字符串 | 强制或建议 | 语言模型供应商列出的模型标识。 |
| `AllowedTranscriptionProviders` | 字符串数组 | 强制 | 允许接收音频的插件或限定供应商标识。空数组禁止所有语音识别供应商。 |
| `AllowedLlmProviders` | 字符串数组 | 强制 | 允许接收文本的语言模型供应商标识。Apple Intelligence 也受此项限制。空数组禁止所有语言模型供应商。 |
| `AllowedPlugins` | 字符串数组 | 强制 | 允许加载和启用的内置插件标识。空数组禁止所有插件。 |
| `AllowCloudTranscription` | 布尔值 | 强制 | `false` 仅允许声明 `local` 的引擎处理音频。 |
| `AllowCloudTextProcessing` | 布尔值 | 强制 | `false` 仅允许声明 `local` 的插件处理文本、提示词、词库和上下文。 |
| `AllowModelDownloads` | 布尔值 | 强制 | `false` 禁止下载模型文件，已安装模型可以继续使用。 |
| `LaunchAtLogin` | 布尔值 | 强制或建议 | 注册或移除应用的登录项。强制值锁定控件；macOS 仍可能要求用户批准登录项。 |
| `SkipOnboardingWhenReady` | 布尔值 | 强制 | 引擎、麦克风、辅助功能权限和听写快捷键均已就绪时，关闭自动上手引导。缺少条件时打开对应步骤，已有进度保留。 |

字符串会去除首尾空白，长度上限为 1024 个字符，禁止空值和控制字符。数组上限为 256 项，移除重复项后保留顺序。供应商和插件标识匹配时忽略大小写。

`local` 表示内容在本机处理。`cloud`、`configurable` 和未知分类在禁止云端处理时均会受到限制。对同时提供多种能力的插件，应用还会在每次实际使用时检查相应限制。

## 生成描述文件

生成器从固定键目录校验输入。命令失败时保留现有输出文件。使用 `--domain` 指定目标偏好域，多次提供该参数会产生多个独立的设置载荷。

```sh
python3 deployment/macos/make-typewhisper-profile.py \
  --domain com.schneidervvv.dictum \
  --set AllowCloudTranscription=false \
  --set AllowCloudTextProcessing=false \
  --set TranscriptionProviderId=com.typewhisper.qwen3 \
  --set TranscriptionModelId=qwen3-asr-1.7b-6bit \
  --recommend LaunchAtLogin=true \
  --identifier com.example.dictum.local \
  --name 'dictum 本地处理' \
  --output dictum-LocalOnly.mobileconfig
```

- 使用 `--set KEY=VALUE` 设置强制值。
- 使用 `--recommend KEY=VALUE` 设置建议值。
- 数组使用逗号分隔，空值生成空数组，例如 `--set AllowedPlugins=`。
- 布尔值使用 `true` 或 `false`。
- 部署时保持 `--identifier` 不变，以替换此前的描述文件。

配置供应商与模型不会提供凭据、授予系统权限或下载模型。相关条件需要在目标 Mac 上完成。

## 应用与插件分发

dictum 0.1.0 由负责人在本机构建和安装，更新由负责人手动部署。开发验证使用 `scripts/dictum-verify.sh`，签名与辅助功能授权要求见仓库 [README](../../README.md)。部署到其他 Mac 时，应根据实际构建的签名和标识配置系统权限。

语音引擎与语言模型供应商随应用内置。设置侧栏提供各内置插件的配置页面。插件的加载、启用、模型下载和实际处理仍受上述组织策略限制。插件代码随应用版本更新。

## 网络访问

- 本地模型供应商可能从模型托管网站下载模型文件。
- 云端语音和语言模型供应商访问用户配置的 API 地址。
- OpenAI 兼容供应商访问用户配置的自定义端点。
- 社区词库使用词库服务的地址。禁止云端文本处理不会自动禁止词库文件下载。

网络白名单应依据实际启用的供应商和模型设置制定。组织可以通过 `AllowedPlugins`、供应商白名单和云端处理开关限制内容去向。

## 管理控制台文件

`deployment/macos/jamf/` 的 JSON Schema 和 `deployment/macos/ProfileManifests/` 的配置清单由同一个键目录生成。更新键目录后执行：

```sh
python3 scripts/update_macos_mdm_schemas.py
python3 scripts/update_macos_mdm_schemas.py --check
python3 scripts/test_macos_managed_settings.py
```

生成器文件名与 Swift 模块名保留上游名称。应用和当前描述文件中的显示名称为 dictum。
