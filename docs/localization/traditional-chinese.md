# Traditional Chinese (zh-Hant) localization

Traditional Chinese is a required app language, like Simplified Chinese and Spanish. CI fails
when a key in a bundled string catalog has no `zh-Hant` value or when a translation uses other
format specifiers than its English text (`scripts/check_localization_completeness.py`).

Text passed to `localizedAppText(_:de:ja:zh:zhHant:es:)` needs a `zh-Hant` value in
`TypeWhisper/Resources/Localizable.xcstrings` under the English text, or an inline `zhHant:`
argument when the English literal interpolates values (`scripts/check_localized_app_text.py`).
`zh:` stays Simplified Chinese; a Traditional Chinese app language never falls back to it while a
`zhHant:` value or a catalog entry exists.

The app language is `zh-Hant`. `isTraditionalChineseLanguageCode(_:)` also maps the system
languages `zh-Hant-*`, `zh-TW`, `zh-HK` and `zh-MO` to it, so a Mac set to Traditional Chinese
opens in Traditional Chinese on first launch.

The first Traditional Chinese translation was converted from the reviewed Simplified Chinese text
with OpenCC (`s2twp`) and then edited to Taiwan usage with AI assistance; it has not been
reviewed in full by a native speaker yet.

## Style

- Taiwan usage, which Hong Kong and Macau readers also read without trouble.
- Second person 你, as in the Simplified Chinese text.
- Corner brackets 「」 for quoted UI names and 『』 inside them, not “ ”.
- Full-width punctuation between Chinese characters (，。：；？！（）).
- A space between Chinese and Latin letters, digits or placeholders, as in the Simplified Chinese
  text ("已安裝 %lld 個外掛").
- Language names in the app language picker stay in their own script ("简体中文", "繁體中文").
- Keep product, provider, model and plugin names, code, URLs, file extensions, format
  specifiers (`%@`, `%lld`, `%1$@`) and key symbols (⌘ ⌥ ⌃ ⇧) unchanged.
- Use macOS's own Traditional Chinese names for system places: 系統設定, 隱私權與安全性,
  輔助使用, 輸入監控, 螢幕錄製, 鑰匙圈, 行事曆, 捷徑.

## Glossary

| English | Traditional Chinese |
| --- | --- |
| dictation / dictate | 聽寫 |
| transcription, transcript / transcribe | 轉錄 / 轉錄文字 |
| speech recognition | 語音辨識 |
| engine / model / provider | 引擎 / 模型 / 供應商 |
| plugin / integration | 外掛 / 整合 |
| workflow / trigger | 工作流程 / 觸發條件 |
| prompt (prompt action) | 提示詞（提示詞操作） |
| snippet / dictionary / term / term pack / correction | 快捷短語 / 詞典 / 詞條 / 術語包 / 修正 |
| history / statistics | 歷史記錄 / 統計資料 |
| Recorder / recording | 錄音器 / 錄音 |
| speaker (person) / speaker detection | 說話者 / 說話者偵測 |
| shortcut, hotkey | 快速鍵 |
| clipboard / paste | 剪貼簿 / 貼上 |
| file / folder | 檔案 / 資料夾 |
| item | 項目 (project: 專案) |
| settings / profile | 設定 / 設定檔 |
| Settings / System Settings | 設定 / 系統設定 |
| Privacy & Security / Accessibility / Input Monitoring | 隱私權與安全性 / 輔助使用 / 輸入監控 |
| Screen Recording / Microphone | 螢幕錄製 / 麥克風 |
| Keychain | 鑰匙圈 |
| audio / video | 音訊 / 影片 |
| text | 文字 |
| default / custom | 預設 / 自訂 |
| fallback | 備用 |
| live / real-time | 即時 |
| local / cloud / on-device | 本機 / 雲端 / 裝置端 |
| API key / endpoint / token | API 金鑰 / 端點 / 權杖 |
| detect | 偵測 |
| load / unload a model | 載入 / 卸載模型 |
| restart | 重新啟動 |
| license / activation / Supporter / Premium | 授權 / 啟用 / 支援者 / Premium |
| Whisper Mode | Whisper 模式 |
| This can't be undone. | 此操作無法復原。 |
