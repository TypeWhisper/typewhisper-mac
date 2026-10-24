# dictum V0.1.0 Design Spec

This spec and the HTML prototypes in [prototypes/](prototypes/index.html) define the dictum V0.1.0 UI. Build each screen to match its prototype. Where the prototype and this spec disagree, this spec wins. Every prototype has a light/dark toggle and a state switcher in its top-right pill. Open `prototypes/index.html` in a browser to see them all.

Target: macOS 14+, SwiftUI first, AppKit only where SwiftUI cannot do the job (the voice bar panel, the menu bar status item, Fn key capture).

## 1. Design principles

1. **The voice bar is the product.** Most users spend more time looking at the voice bar than at the main window. It gets the most motion, polish, and testing.
2. **Calm by default.** Neutral surfaces, one accent color, no gradients inside the main window, no decorative illustrations. Color carries meaning: blue is the app, red is "recording", purple is "translating", green is "done", amber is "needs attention".
3. **Let the layout explain.** No helper text under every control. A footer note appears only where a setting has a consequence the user cannot guess (privacy, data deletion, fallback order).
4. **Never lose words.** Every failure path keeps the user's speech: a polish failure inserts the raw text, a cancel is undoable for 3 seconds and stays in History, a missing text field copies to the clipboard.
5. **Native first.** Use system controls, system fonts, system materials, and standard macOS idioms (sidebar, grouped forms, sheets, menus). Never build a custom version of a control macOS already has.
6. **Show the result, not the setting.** Settings that change output (polish strength, style) show a live before/after example next to the control.

## 2. Visual system

### 2.1 Color tokens

Define these as named colors in the asset catalog with Any/Dark variants. Use system semantic colors where the table says so.

| Token | Light | Dark | SwiftUI |
|---|---|---|---|
| `accent` | `#3B5BDB` | `#6E8BFF` | Asset color, also set as app `AccentColor` |
| `accentSoft` (History selection, info banner) | `#3B5BDB` @ 10% | `#6E8BFF` @ 16% | `accent.opacity(…)` |
| `selected` (sidebar selection, neutral badge) | black @ 7.5% | white @ 9% | Dynamic color |
| `control` | `#FFFFFF` | `#3A3A3D` | Dynamic color |
| `live` (recording dot) | `#F2423A` | `#FF5A50` | Asset color |
| `translate` | `#8E4FE8` | `#B383FF` | Asset color |
| `translateSoft` | `#8E4FE8` @ 12% | `#B383FF` @ 16% | |
| `success` | `#23A55A` | `#3CCF72` | Asset color |
| `warning` | `#D98A00` | `#FFB340` | Asset color |
| `danger` | `#E0434B` | `#FF6369` | Asset color |
| `windowBackground` | `#FFFFFF` | `#1E1E20` | `Color(nsColor: .windowBackgroundColor)` is acceptable |
| `card` (stat tiles, grouped boxes) | `#F6F6F8` | `#262629` | Asset color |
| `inset` (search field, segmented track, preview well) | `#F1F1F4` | `#18181A` | Asset color |
| `textPrimary` | `#1D1D1F` | `#F2F2F4` | `.primary` |
| `textSecondary` | `#6E6E73` | `#A1A1A8` | `.secondary` |
| `textTertiary` | `#A1A1A6` | `#6C6C72` | `.tertiary` |
| `separator` | black @ 8.5% | white @ 8% | `Color(nsColor: .separatorColor)` |
| `heat0…heat4` | `#ECECF0` `#CDD6F6` `#9AAEEE` `#6A86E3` `#3B5BDB` | `#2C2C30` `#283463` `#34479A` `#4E67D1` `#7B94FF` | Asset colors |

Voice bar colors are fixed and do not follow system appearance (see 6.1).

### 2.2 Typography

System fonts only: SF Pro for UI, PingFang SC is picked up automatically for Chinese. Numbers on stats and timers use SF Pro Rounded with monospaced digits.

| Role | Size / weight | SwiftUI |
|---|---|---|
| Onboarding title | 24 bold | `.system(size: 24, weight: .bold)` |
| Toolbar title | 15 semibold | `.system(size: 15, weight: .semibold)` |
| Section header | 13 semibold | `.headline` sized to 13 |
| Body | 13 regular | `.body` (13 on macOS) |
| Secondary | 12 regular, `textSecondary` | `.callout` |
| Caption | 11 regular, `textTertiary` | `.caption` |
| Stat number | 28 semibold rounded | `.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit()` |
| Reading text (History detail) | 15, line spacing 1.75× | `.system(size: 15)` + `.lineSpacing(10)` |
| Voice bar text | 15, line height 22 | `.system(size: 15)` |
| Voice bar timer | 13 rounded, monospaced digits | |

### 2.3 Spacing, radii, shadows

- Spacing scale: 2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28, 32. Content padding is 28 left and right, 4 top, 28 bottom.
- Grid gap between cards: 12. Gap between page sections: 26.
- Radii: control 6, list row 8, card 12, grouped form box 10, sheet 12, voice bar 22 (collapsed) and 20 (expanded), app icons 5 (20pt) or 7 (28pt).
- Shadows: the main window uses the system shadow. Popovers and menus use system menus (no custom shadow). The voice bar uses `0 14 36 black@30%` plus `0 3 8 black@18%` and a 0.5pt inner white @14% stroke.

### 2.4 Materials

- Sidebar: `NavigationSplitView` sidebar default material (`.sidebar` vibrancy). Do not paint it.
- Content: opaque `windowBackground`.
- Voice bar: `NSVisualEffectView` with `.hudWindow` material, `.dark` appearance forced, plus a black @ 55% tint layer. The text stays legible over any app.
- Menus: native `NSMenu`.

### 2.5 Motion

| Token | Value | Use |
|---|---|---|
| `fast` | 0.12 s ease-out | hover, button press, row highlight |
| `base` | 0.20 s ease-out `(0.22, 1, 0.36, 1)` | fades, popovers, sheet content |
| `spring` | `.spring(response: 0.42, dampingFraction: 0.78)` | voice bar size changes, switch thumb |
| `enter` | 0.34 s spring, from y +10, scale 0.92, opacity 0 | voice bar appears |
| `exit` | 0.20 s ease-in, to y +6, scale 0.96, opacity 0 | voice bar disappears |
| `pop` | 0.38 s spring overshoot, scale 0.3 → 1 | green check on "Inserted" |

Respect `accessibilityReduceMotion`: replace springs and scales with 0.15 s opacity fades and freeze the waveform at a static shape.

### 2.6 Sounds

Played by `SoundService`, all gated by the General → Sounds → "Interaction sounds" switch. Volume 0.35. Bundle short custom sounds (under 150 ms, soft attack); until those exist, use the listed system sounds.

| Event | Sound | Fallback |
|---|---|---|
| Recording starts | soft rising two-note tone | `Tink` |
| Recording stops (Fn pressed again) | soft falling tone | `Pop` |
| Cancelled | none | |
| Error that needs action | low single tone | `Funk` |
| Inserted | none (the bar confirms it) | |

## 3. App structure and navigation

### 3.1 Main window

- `WindowGroup` with a single main window. Default size 1040 × 680, minimum 860 × 560. Title bar is hidden and merged (`.windowStyle(.hiddenTitleBar)`, `.toolbar` with `.navigationTitle`), traffic lights sit over the sidebar.
- `NavigationSplitView` with a fixed 212pt sidebar (`.navigationSplitViewColumnWidth(212)`), not collapsible in V0.1.0.
- Every page has a 52pt toolbar row: page title on the left (15 semibold), page actions on the right.
- Closing the window keeps dictum running in the menu bar. Dock icon is hidden by default (General → App → "Show in Dock").

### 3.2 Sidebar

Order is fixed. SF Symbols in parentheses.

| # | zh-Hans | English | Symbol | Prototype |
|---|---|---|---|---|
| 1 | 首页 | Home | `house` | home.html |
| 2 | 历史 | History | `clock` | history.html |
| 3 | 词典 | Dictionary | `book` | dictionary.html |
| 4 | 风格 | Style | `wand.and.sparkles` | style.html |
| | *section* 设置 | *section* Settings | | |
| 5 | 通用 | General | `gearshape` | settings-general.html |
| 6 | 语音识别 | Speech | `waveform` | settings-models.html |
| 7 | AI 模型 | AI Models | `sparkles` | settings-providers.html |

The selected item tints its symbol with `accent`. A status row is pinned to the bottom of the sidebar: a 7pt dot, a short label, and the engine name in caption style. Clicking it opens Speech. States:

| State | Dot | zh-Hans | English | Right caption |
|---|---|---|---|---|
| Ready | success | 就绪 | Ready | engine short name, e.g. `Qwen3-ASR` |
| Model downloading | warning | 正在下载 | Downloading | `62%` |
| Model loading or optimizing | warning | 正在加载模型 | Loading model | engine short name |
| No model | danger | 需要语音模型 | Speech model needed | |
| Download failed | danger | 下载失败 | Download failed | |
| Model load failed | danger | 模型加载失败 | Model load failed | |
| No AI provider | warning | 未接入 AI 模型 | No AI model | |
| First AI provider failing | warning | 使用备用模型 | Using backup model | |

The TypeWhisper settings window with its power-user tabs (workflows, snippets, plugins, API server, error log, and so on) stays available as "Advanced Settings" from General → App and from the menu bar. It is not in the sidebar.

### 3.3 Menu bar

See section 7.

### 3.4 Global keyboard

| Key | Action |
|---|---|
| Fn (tap) | Start dictation; tap again to stop and insert |
| Fn (hold > 0.35 s) | Push to talk: release to stop and insert |
| Fn + Left Shift | Start translation; Fn stops |
| Esc | Cancel while the voice bar is listening or processing |
| ⌘1 … ⌘7 | Switch sidebar pages when the main window is key |
| ⌘, | Open General |

## 4. Shared components

| Component | Spec | SwiftUI |
|---|---|---|
| Stat tile | `card` background, radius 12, padding 14/16, key label 12 secondary, value 28 rounded, unit 13 secondary, delta 11.5 success or tertiary | `VStack` in `RoundedRectangle` |
| Grouped form | max width 600–620, centered; sections with 13 semibold header, rows 44pt min, 0.5pt inset separators | `Form { Section { … } }.formStyle(.grouped)` |
| Segmented picker | inset track, raised selected segment | `Picker(…).pickerStyle(.segmented)` |
| Popup | standard pop-up button | `Picker(…).pickerStyle(.menu)` |
| Switch | standard | `Toggle(…).toggleStyle(.switch)` |
| Key cap | 22pt high, radius 5, 0.5pt stroke plus 1.5pt bottom edge | custom `KeyCapView` |
| App icon | real app icon from `NSWorkspace.shared.icon(forFile:)` at 20 or 28pt | `Image(nsImage:)` (prototypes use monogram tiles as stand-ins) |
| Badge | 18pt high, radius 5, 11 medium, soft tinted background | custom |
| Banner | radius 9, soft tinted background, leading SF Symbol, trailing small button | custom |
| Empty state | 52pt rounded glyph tile, 15 semibold title, one 13 secondary line, optional buttons | `ContentUnavailableView` with custom actions |
| Toast | capsule, black @ 92%, white 12.5 text, bottom center of the content area, 1.4 s | overlay with `.transition(.opacity.combined(with: .offset(y: 8)))` |

Format numbers with the user's locale. Durations: under 1 hour show `42 分钟` / `42 min`; 1 hour or more show `3 小时 12 分` / `3 h 12 min`; 100 hours or more show `128 小时` / `128 h`. Clip lengths in History show `m:ss`.

## 5. Screens

### 5.1 Home 首页 (`home.html`)

**Purpose.** Show that dictum is working and saving time, and get back to recent text quickly.

**Layout.** Toolbar: title, then a segmented period picker on the right (7 天 / 30 天 / 全部, default 30 天). Content, top to bottom:

1. Four stat tiles in a 4-column grid: Words dictated, Time saved, Average speed, Dictation time. Each shows the change against the previous period of the same length (`↑ 18%`, or `与上期持平` when the change is under 2%). The "全部" period hides the delta.
2. Section "活动 Activity" with the streak on the right (flame symbol in orange `#F07A2A`, `连续 9 天`, caption `最长 21 天`). Below it, a card with a 52-week heatmap: 11pt cells, 3pt gap, radius 2.5, weeks run left to right, Monday at the top, weekday labels for Mon/Wed/Fri, month labels above the first week of each month (labels never wrap), legend `少 … 多` bottom right. Hover shows a tooltip `10月14日 · 1,240 字`. The heatmap always shows the last 52 weeks and ignores the period picker.
3. Section "最近 Recent" with a `全部历史 All history` link. A card with the 5 latest records: 44pt rows with app icon, a 译 badge for translations, one line of final text, and time (today: `14:32`, yesterday: `昨天`, older: `10月20日`). Hovering a row swaps the time for a copy button. Clicking a row opens it in History.

**Metrics.**
- Words: `summary.words`. For Chinese, one character counts as one word (TypeWhisper `wordsCount` already does this).
- Time saved: `words / 45 − dictationMinutes`, floored at 0 (`UsageStatisticsSummary.rawSavedMinutes`).
- Average speed: `words / dictationMinutes` (`rawWPM`), unit `字/分` / `WPM`.
- Dictation time: `summary.durationSeconds`.
- Streak: consecutive days up to today (or up to yesterday if today has no activity yet) with `transcriptionCount > 0`; longest streak over all stored days.
- Heat level by words that day: 0, 1–249, 250–599, 600–1099, 1100+.

**States.**

| State | Behavior |
|---|---|
| Normal | as above |
| New user (no records) | Stat values show `0` (speed shows `—`), deltas show `—`, the period picker hides, the heatmap shows empty cells, and a card replaces Recent: large `fn` key cap, title `按一下 fn，说出第一句话`, line `在任何输入框里都可以用。说完再按一下 fn，文字就会出现在光标处。`, button `练习一次` that opens onboarding at the practice step. |
| Missing permission | Warning banner above the stats: `dictum 需要辅助功能权限，才能把文字输入到其他应用。` with button `打开系统设置`. Same for microphone with its own text. |

**Copy.**

| zh-Hans | English |
|---|---|
| 首页 | Home |
| 7 天 / 30 天 / 全部 | 7 days / 30 days / All |
| 听写字数 · 字 | Words dictated · words |
| 节省时间 | Time saved |
| 平均速度 · 字/分 | Average speed · WPM |
| 听写时长 | Dictation time |
| 与上期持平 | Same as last period |
| 活动 | Activity |
| 连续 N 天 / 最长 N 天 | N-day streak / Longest N days |
| 少 / 多 | Less / More |
| 没有听写 | No dictation |
| 最近 / 全部历史 | Recent / All history |
| 按一下 fn，说出第一句话 | Press fn and say your first sentence |
| 在任何输入框里都可以用。说完再按一下 fn，文字就会出现在光标处。 | Works in any text field. Press fn again when you're done and the text appears at the cursor. |
| 练习一次 | Try it |
| dictum 需要辅助功能权限，才能把文字输入到其他应用。 | dictum needs Accessibility access to type into other apps. |
| dictum 需要麦克风权限才能听写。 | dictum needs microphone access to dictate. |
| 打开系统设置 | Open System Settings |

**SwiftUI.** `ScrollView` + `LazyVGrid(columns: 4)` for tiles; the heatmap is a `Canvas` (364 cells; a grid of views is too heavy) with an `.onContinuousHover` tooltip; Recent rows are a `VStack` of buttons inside a card. Swift Charts is not needed.

**Data.** `UsageStatisticsService` (`days`, `summary(from:)`, `previousPeriodSummary(days:)`, `dailyWordCounts(days:)`), `HomeViewModel.recentTranscriptions` from `HistoryService.recentRecords`. Existing views to replace: `HomeSettingsView`, `StatisticsView`.

### 5.2 History 历史 (`history.html`)

**Layout.** Toolbar: title; right side has a segmented filter (全部 / 听写 / 翻译), a 200pt search field, and a `…` menu (`导出为 Markdown…`, `在 Finder 中显示同步文件夹`, separator, `删除全部历史…` in red). Below, a two-pane split with a 0.5pt separator:

- **List pane**, 316pt wide. Records grouped by day with sticky headers (`今天`, `昨天`, `10月20日`). Each row: 20pt app icon, two lines of final text, meta line with time and badges (`译` translate badge; `未润色` warning badge when polishing failed). Selected row uses `accentSoft`. A 34pt footer shows sync status: cloud symbol + `已同步到 iCloud Drive · 2 分钟前`; on failure it turns `danger`: `无法同步：找不到 iCloud Drive 文件夹`, and clicking it opens General → History & Sync. When sync is off the footer is hidden.
- **Detail pane.** Header: 28pt app icon, app name, date and time; on the right a segmented `润色后 / 原文` switch (dictation only). Body: the text in a `card` well at reading size, selectable. Translation records show two wells: `译文 · English` and `原话`. Meta line: `时长 0:12`, `字数 31`, `Qwen3-ASR · DeepSeek` (engine · AI provider). Actions: `复制`, `重试`, `播放录音` (hidden when no audio is stored), and a trailing trash button. Delete asks for confirmation only when the record has audio.

**Interactions.**
- `重试 Retry` re-runs the stored audio with current settings and replaces the final text (keeps the old version in `transcriptionVersionsData`). While running, show a toast `正在用当前设置重新处理…`; when done, `已重新润色`.
- Polish failure records show a warning banner on top of the detail: `润色没有完成：DeepSeek 请求超时。已插入识别原文。` with a `重试` button.
- ⌘C copies the selected record's visible text. Arrow keys move selection. Delete key deletes with undo (⌘Z).
- Search matches raw and final text, case-insensitive, and highlights matches in the detail.

**States.** Normal; empty (`还没有听写记录` / `按一下 fn 开始说话，记录会出现在这里。`, filter, search and menu hidden); no search results (`没有找到“周报模板”` / `换个关键词试试。`); sync failed (footer). Loading more than 2,000 records pages in lazily with no spinner.

**Copy.**

| zh-Hans | English |
|---|---|
| 历史 | History |
| 全部 / 听写 / 翻译 | All / Dictation / Translation |
| 搜索 | Search |
| 导出为 Markdown… | Export as Markdown… |
| 在 Finder 中显示同步文件夹 | Show Sync Folder in Finder |
| 删除全部历史… | Delete All History… |
| 今天 / 昨天 | Today / Yesterday |
| 润色后 / 原文 | Polished / Original |
| 译文 · English / 原话 | Translation · English / What you said |
| 时长 / 字数 | Duration / Words |
| 复制 / 重试 / 播放录音 | Copy / Retry / Play Recording |
| 已复制 | Copied |
| 未润色 | Not polished |
| 润色没有完成：{provider} 请求超时。已插入识别原文。 | Polishing didn't finish: {provider} timed out. The original text was inserted. |
| 正在用当前设置重新处理… | Reprocessing with current settings… |
| 已同步到 iCloud Drive · {time} | Synced to iCloud Drive · {time} |
| 无法同步：找不到 iCloud Drive 文件夹 | Can't sync: iCloud Drive folder not found |
| 还没有听写记录 | No dictations yet |
| 按一下 fn 开始说话，记录会出现在这里。 | Press fn and start talking. Your dictations show up here. |
| 没有找到“{query}” / 换个关键词试试。 | No results for "{query}" / Try a different word. |
| 删除这条记录和录音？ | Delete this record and its recording? |

**SwiftUI.** `HSplitView` is not needed; use an `HStack` with a fixed-width `List(selection:)` (`.listStyle(.plain)`, `Section` per day) and a detail `ScrollView`. `.searchable` is not used because the search field sits in the custom toolbar; use `NativeSearchField` from the existing code.

**Data.** `HistoryService`, `HistoryViewModel`, `TranscriptionRecord` (`rawText`, `finalText`, `appName`, `appBundleIdentifier`, `durationSeconds`, `wordsCount`, `engineUsed`, `modelUsed`, `audioFileName`, `processingStateRaw`, `processingFailureMessage`). Retry: `HistoryRetranscriptionService`. Sync status: `HistoryUserDataSync`, `CloudFolderSyncEngine`. Translation records need a mode and target language on the record; phase 3 adds them if `pipelineSteps` cannot carry them. Existing views to replace: `HistoryView`, `HistoryRecordViews`.

### 5.3 Dictionary 词典 (`dictionary.html`)

**Layout.** Toolbar: title; right side: search field, `导入` button, primary `添加词` button. Row below: segmented filter (全部 / 手动添加 / 自动学习) and a count on the right (`1,204 个词`). Then, when the app learned words since the user last looked, an `accentSoft` strip: sparkle symbol, `刚学会`, chips (`Kubernetes ← 酷伯尼特斯`) each with a remove button, and a trailing `好的` button that dismisses the strip. Then the table.

**Table columns.** Checkbox (visible on hover or while selecting) · 词 Word (500 weight) · 常被听成 Heard as (secondary, `—` when empty) · 来源 Source badge (`手动` neutral, `自动学习` accent) · 使用 Uses (right aligned) · 添加于 Added (right aligned; replaced by edit and delete icons on hover). Zebra rows using `card`, 38pt height.

**Interactions.**
- Clicking a row toggles its checkbox. When one or more rows are selected, a floating bar rises from the bottom: `已选 N 个`, `取消选择`, red `删除`. Deleting more than one asks `删除 N 个词？此操作无法撤销。`.
- `添加词` opens a sheet: `词或短语` field (focused), `常被听成（可选，用逗号分隔）`, buttons `取消` / `添加`. Return submits. Duplicate words show inline `词典里已经有这个词` under the field.
- `导入` opens a sheet with a drop zone (`把 CSV 文件拖到这里，或 选择文件`, caption `第一列是词，第二列可选，写常被听成的写法`). After a file is chosen, show a summary (`248 个新词，12 个已存在会跳过`, first few words) and the primary button becomes `导入 248 个词`. Limits: 5 MB, 3,000 words per import; over the limit, show `文件太大，最多 5 MB` or `一次最多导入 3000 个词` in `danger` and keep the button disabled.
- Searching with no match shows `没有找到“{query}”` and a button `把“{query}”添加到词典` that opens the add sheet prefilled.

**States.** Normal; empty (glyph, `词典还是空的`, `添加人名、产品名和专业术语，dictum 会把它们写对。你在别的应用里改正过的词，也会自动加到这里。`, buttons `导入 CSV` and `添加词`; toolbar buttons hidden); no search results; import sheet before and after file selection.

**Copy.**

| zh-Hans | English |
|---|---|
| 词典 | Dictionary |
| 搜索词 | Search words |
| 导入 / 导入 CSV | Import / Import CSV |
| 添加词 | Add Word |
| 全部 / 手动添加 / 自动学习 | All / Added by you / Learned |
| {n} 个词 | {n} words |
| 刚学会 / 好的 | Just learned / OK |
| 词 / 常被听成 / 来源 / 使用 / 添加于 | Word / Heard as / Source / Uses / Added |
| 手动 / 自动学习 | Manual / Learned |
| 已选 {n} 个 / 取消选择 / 删除 | {n} selected / Deselect / Delete |
| 词或短语 | Word or phrase |
| 常被听成（可选，用逗号分隔） | Often heard as (optional, comma separated) |
| 取消 / 添加 | Cancel / Add |
| 把 CSV 文件拖到这里，或 选择文件 | Drop a CSV file here, or choose a file |
| 第一列是词，第二列可选，写常被听成的写法 | First column: the word. Optional second column: how it's often heard. |
| {n} 个新词，{m} 个已存在会跳过 | {n} new words, {m} already in your dictionary will be skipped |
| 导入 {n} 个词 | Import {n} Words |
| 词典还是空的 | Your dictionary is empty |
| 添加人名、产品名和专业术语…… | Add names, product names, and jargon so dictum spells them right. Words you correct in other apps are added here automatically. |
| 把“{query}”添加到词典 | Add "{query}" to Dictionary |
| 删除 {n} 个词？此操作无法撤销。 | Delete {n} words? This can't be undone. |

**SwiftUI.** `Table` with `TableColumn`s and multi-selection (`Set<DictionaryEntry.ID>`), `.sheet` for add and import, `.dropDestination(for: URL.self)` for CSV, `.fileImporter` for "choose a file".

**Data.** `DictionaryService`, `DictionaryViewModel`, `DictionaryEntry`. Map a `.correction` entry to Word = `replacement`, Heard as = `original`; a `.term` entry to Word = `original`. Source from `source` (`.manual` / `.autoLearned`), Uses from `usageCount`, Added from `createdAt`. Auto-learning comes from `TargetAppCorrectionLearningService`. CSV import is new (phase 4). Existing view to replace: `DictionarySettingsView`.

### 5.4 Style 风格 (`style.html`)

**Layout.** Max width 760, centered.

1. **Global style card.** Two columns. Left: four rows with separators: `正式程度` segmented (随意 / 适中 / 正式), `语气` segmented (温和 / 直接 / 热情), `表情符号` segmented (不用 / 偶尔 / 常用), `署名` text field (180pt). Right, 300pt, `inset` background: `你说` with a raw spoken sample, `dictum 写出` with the output in a raised well. The output updates 120 ms after any control changes, with a quick opacity dip.
2. **Per-app section.** Header `按应用` with a small `添加应用` button that opens a menu of running apps plus `从“应用程序”中选择…`. A card of rows; each row: stacked app icons (up to 4, overlapping by 6pt), name, a one-line summary (`正式 · 温和 · 不用表情 · 署名 · {extra}`), chevron. Clicking a row expands it in place: the same three segmented controls, `结尾加署名` switch, a `补充要求` text area (placeholder `补充要求，例如：多用列表`), and a footer with `内置：N 个应用` and `恢复默认` (built-in) or `移除` (user-added). The expanded row shows its own `示例` preview on the right.

**Built-in groups** (shipped defaults, editable, cannot be removed):

| Group | Apps (bundle IDs resolved at runtime) | Default |
|---|---|---|
| 聊天 Chat | WeChat, Slack, Lark/Feishu, Telegram, Messages, DingTalk, Discord, WhatsApp | 随意 · 温和 · 偶尔用表情 |
| 邮件 Mail | Mail, Outlook, Spark, Gmail in browsers (URL `mail.google.com`) | 正式 · 温和 · 不用表情 · 署名 |
| 文档 Docs | Notion, Notes, Word, Pages, Obsidian, Google Docs (URL) | 适中 · 直接 · 不用表情 · 能分点的地方用列表 |
| 编程 Code | Cursor, Xcode, VS Code, Terminal, iTerm | 适中 · 直接 · 不用表情 · 保留英文技术名词，不翻译代码标识符 |

Apps not covered use the global style. A per-app row wins over a group that contains the same app.

**Copy.**

| zh-Hans | English |
|---|---|
| 风格 | Style |
| 正式程度：随意 / 适中 / 正式 | Formality: Casual / Balanced / Formal |
| 语气：温和 / 直接 / 热情 | Tone: Warm / Direct / Upbeat |
| 表情符号：不用 / 偶尔 / 常用 | Emoji: None / Sometimes / Often |
| 署名 | Sign-off |
| 你说 / dictum 写出 / 示例 | You said / dictum writes / Example |
| 按应用 / 添加应用 | Per app / Add App |
| 正在运行 / 从“应用程序”中选择… | Running / Choose from Applications… |
| 聊天 / 邮件 / 文档 / 编程 | Chat / Mail / Docs / Code |
| 结尾加署名 | Add sign-off |
| 补充要求，例如：多用列表 | Extra instructions, e.g. use bullet lists |
| 内置：{n} 个应用 | Built-in: {n} apps |
| 恢复默认 / 移除 | Restore Default / Remove |

**SwiftUI.** `ScrollView`; the global card is an `HStack` of a `Grid` and a preview `VStack`; per-app rows use `DisclosureGroup` with a custom label, animated with `spring`. The preview text in the app comes from a fixed sample matrix bundled with the app (3 formality × 3 tone × emoji), not from a live LLM call.

**Data.** New `StyleSettings` (global) and `AppStyle` (per group or app) models in phase 2. `Profile` (`bundleIdentifiers`, `urlPatterns`) provides app matching; `PromptProcessingService` consumes the resolved style. Profiles are edited today in `WorkflowsSettingsView`, which stays reachable in Advanced Settings.

### 5.5 General 通用 (`settings-general.html`)

**Layout.** Grouped form, max width 600, sections in this order:

1. **快捷键 Shortcuts.** `听写` [fn] · `翻译` [fn][左 ⇧] · `取消` [esc] (fixed) · `按住快捷键` popup (`按住说话，松开结束` / `不使用`) · `外接键盘` [右 ⌥] with a remove button, or an `添加备用快捷键` button when empty. Footer: `外接键盘没有 fn 键时，用这个备用快捷键听写。` Clicking a key cap enters recording: accent ring, caps dim, caption `按下新快捷键`; Esc or 3 s without input restores the old value. Conflicts show inline `这个快捷键已被“{app}”使用` in `danger`.
2. **润色强度 Polish strength.** Three selectable option cards in a row: `轻度` (`去掉口头禅和重复，其余保留原话`), `标准` (`再处理改口、分段和列表`, default), `重写` (`按风格设置重新组织措辞`). Below, a well with `你说：…` and `写出：…` for the selected level.
3. **翻译语言 Translation languages.** First row `说话语言` popup: `自动识别` plus every language the speech engine supports, default `中文（简体）`. Below it, `翻译成`: a reorderable target list with drag grips; the first row carries a `默认` badge; hover shows a remove button; last row `添加语言` (the spoken language is not offered as a target). Default list: `English`. Footer: `第一个是默认目标语言。拖动可以调整顺序，语音条上按这个顺序显示。`
4. **声音 Sound.** `麦克风` with a 12-segment live level meter and device popup (`自动（{device}）`); `提示音` switch; `听写时暂停其他声音` switch.
5. **历史与同步 History & Sync.** `同步到 iCloud Drive` switch with status underneath (`2 分钟前已同步 · 1,286 条`, or `已关闭`); `同步文件夹` path (`iCloud Drive › dictum`) with `更改…`; `保留历史` popup (永久 / 1 年 / 1 个月 / 1 周 / 24 小时 / 不保留, default 1 年); `保存录音` switch. Footer: `同步文件夹里只有文字，录音只保存在这台 Mac 上。` Turning sync off asks: `关闭同步后，这台 Mac 上的历史会保留，同步文件夹里的文件不会删除。` Shortening retention asks `将删除 {n} 条早于 {date} 的记录。`
6. **应用 App.** `开机时启动`, `在 Dock 中显示`, `界面语言` popup (跟随系统 / 简体中文 / English), `高级设置` with an `打开 ↗` button that opens the TypeWhisper settings window.

**Copy.**

| zh-Hans | English |
|---|---|
| 通用 | General |
| 快捷键 / 听写 / 翻译 / 取消 | Shortcuts / Dictate / Translate / Cancel |
| 按住快捷键：按住说话，松开结束 / 不使用 | When held: Push to talk / Off |
| 外接键盘 / 添加备用快捷键 | External keyboard / Add Backup Shortcut |
| 外接键盘没有 fn 键时，用这个备用快捷键听写。 | Use this shortcut on keyboards without an fn key. |
| 按下新快捷键 | Press new shortcut |
| 这个快捷键已被“{app}”使用 | "{app}" already uses this shortcut |
| 润色强度：轻度 / 标准 / 重写 | Polish: Light / Standard / Rewrite |
| 去掉口头禅和重复，其余保留原话 | Removes fillers and repeats, keeps your words |
| 再处理改口、分段和列表 | Also fixes self-corrections, paragraphs, and lists |
| 按风格设置重新组织措辞 | Rewrites in your style |
| 翻译语言 / 说话语言 / 自动识别 | Translation languages / Spoken language / Detect automatically |
| 翻译成 / 默认 / 添加语言 | Translate to / Default / Add Language |
| 第一个是默认目标语言…… | The first language is the default. Drag to reorder; the voice bar uses this order. |
| 声音 / 麦克风 / 自动（{device}） | Sound / Microphone / Automatic ({device}) |
| 提示音 | Interaction sounds |
| 听写时暂停其他声音 | Pause other audio while dictating |
| 历史与同步 / 同步到 iCloud Drive | History & Sync / Sync to iCloud Drive |
| {time}已同步 · {n} 条 / 已关闭 | Synced {time} · {n} records / Off |
| 同步文件夹 / 更改… | Sync folder / Change… |
| 保留历史：永久 / 1 年 / 1 个月 / 1 周 / 24 小时 / 不保留 | Keep history: Forever / 1 year / 1 month / 1 week / 24 hours / Don't keep |
| 保存录音 | Keep recordings |
| 同步文件夹里只有文字，录音只保存在这台 Mac 上。 | Only text goes to the sync folder. Recordings stay on this Mac. |
| 应用 / 开机时启动 / 在 Dock 中显示 / 界面语言 / 跟随系统 | App / Launch at login / Show in Dock / Language / System |
| 高级设置 / 打开 | Advanced settings / Open |

**SwiftUI.** `Form` + `.formStyle(.grouped)`; option cards are custom buttons in a `Grid`; translation languages use `List` with `.onMove` inside the form section; launch at login uses `SMAppService.mainApp`.

**Data.** `HotkeyService` / `HotkeyRecorderView`, `PromptProcessingService` (polish level, new), `TranslationService` (targets), `AudioDeviceService`, `SoundService`, `AudioDuckingService`, `HistorySyncPreferences` / `CloudFolderSyncSettingsView`, `HistoryService` retention, `GeneralSettingsView` (launch at login, Dock). Existing views to replace: `GeneralSettingsView`, `HotkeySettingsView`, `HistorySettingsView`, `CloudFolderSyncSettingsView` in the main window.

### 5.6 Speech 语音识别 (`settings-models.html`)

**Layout.** Grouped form, max width 620.

1. **本机 On this Mac.** A radio row for `Qwen3-ASR 1.7B` with a `推荐` badge and subtitle `中英混说准确，不联网也能用 · 3.4 GB`. Right side by state (table below). Indented row `精度` popup (`8-bit · 更快` / `bf16 · 更准`; phase 1 decides the default). Disclosure `更多本机模型` reveals Whisper Large v3 Turbo and Parakeet TDT 0.6B rows with `下载` buttons.
2. **云端 Cloud.** Radio rows for cloud ASR providers with a status badge (`未配置` neutral, `已连接` success, `密钥无效` danger). Clicking an unconfigured row expands an inline key row: secure field `粘贴 {provider} API 密钥` and `测试并使用`. Footer: `使用云端识别时，录音会发送给所选服务商。`
3. **识别 Recognition.** `说话语言` popup (自动检测 / 中文 / English / …), `说话时显示文字` switch (streaming preview on the voice bar, default on).

**Qwen3 row states.**

| State | Right side | Sidebar status |
|---|---|---|
| Ready | `已下载` + `…` menu (`在 Finder 中显示`, `删除模型（3.4 GB）`) | Ready |
| Downloading | 150pt progress bar, caption `64% · 2.2 / 3.4 GB` and `约 1 分钟`, cancel button | Downloading 64% |
| Not downloaded | primary `下载` | Speech model needed |
| Failed | `网络中断，已下载 1.2 GB` in danger + `继续下载` (resumes) | Download failed |
| Offline | local unchanged; cloud rows dim to 45% and footer `现在没有网络，云端识别暂时不可用。` in warning | Ready |

**Copy.**

| zh-Hans | English |
|---|---|
| 语音识别 | Speech |
| 本机 / 云端 / 识别 | On this Mac / Cloud / Recognition |
| 推荐 | Recommended |
| 中英混说准确，不联网也能用 | Accurate for mixed Chinese and English, works offline |
| 已下载 / 下载 / 继续下载 | Downloaded / Download / Resume |
| 约 {n} 分钟 | About {n} min |
| 网络中断，已下载 {size} | Connection lost, {size} downloaded |
| 在 Finder 中显示 / 删除模型（{size}） | Show in Finder / Delete Model ({size}) |
| 精度：8-bit · 更快 / bf16 · 更准 | Precision: 8-bit · Faster / bf16 · More accurate |
| 更多本机模型 | More local models |
| 未配置 / 已连接 / 密钥无效 | Not set up / Connected / Invalid key |
| 粘贴 {provider} API 密钥 / 测试并使用 | Paste {provider} API key / Test and Use |
| 使用云端识别时，录音会发送给所选服务商。 | With cloud recognition, audio is sent to the provider you choose. |
| 现在没有网络，云端识别暂时不可用。 | You're offline. Cloud recognition is unavailable. |
| 说话语言 / 自动检测 | Spoken language / Detect automatically |
| 说话时显示文字 | Show text while speaking |

**SwiftUI.** `Form` with custom radio rows (`Picker(.radioGroup)` cannot hold the trailing status views), `ProgressView(value:)` linear, `SecureField`.

**Data.** `ModelManagerService`, `PluginManager` (`TranscriptionEnginePlugin`), `Qwen3Plugin`, `WhisperKitPlugin`, `ParakeetPlugin`, `GroqPlugin`, `OpenAIPlugin`, `DeepgramPlugin`; keys in `KeychainService`. A DashScope Paraformer engine does not exist yet; phase 1 adds it or the row is dropped. Streaming toggle maps to `StreamingHandler`. Existing views to replace in the main window: the engine parts of `PluginSettingsView` and `SetupWizardView`'s engine step.

### 5.7 AI Models AI 模型 (`settings-providers.html`)

**Layout.** Toolbar: title, `添加` button with a menu of all providers (configured ones carry a check). Content: two columns.

- **Left, 276pt.** Ordered list card. Row: drag grip (on hover), order number, 28pt provider tile, name, current model in caption, status dot (success or danger). Footer: `润色和翻译使用第一个；它出错时，自动换下一个。拖动调整顺序。`
- **Right.** Detail card: 40pt tile, name, role caption (`首选` / `备用 1`), `…` menu (`设为首选`, `自定义接口地址…`, separator, red `移除`). Fields: `API 密钥` secure field with `粘贴` button; `模型` popup filled from the provider's model list. A separator, then a test row: result on the left, `测试连接` button on the right. Results: spinner + `正在测试…`; success `✓ 已连接 · 响应 0.6 秒`; failure `⚠ 密钥无效（401），请检查后重新粘贴` with the key field outlined in `danger`. Other failures: `无法连接，请检查网络或接口地址`, `额度不足（402）`, `请求太频繁（429）`.
- **OpenAI-compatible** adds `接口地址` (placeholder `https://api.example.com/v1`) above the key field and a free-text model field when the server has no model list.

**Providers and presets.**

| Provider | zh-Hans name | Base URL preset | Plugin |
|---|---|---|---|
| OpenAI | OpenAI | api.openai.com/v1 | `OpenAIPlugin` |
| Anthropic | Anthropic | api.anthropic.com | `ClaudePlugin` |
| Gemini | Gemini | generativelanguage.googleapis.com | `GeminiPlugin` |
| OpenRouter | OpenRouter | openrouter.ai/api/v1 | `OpenRouterPlugin` |
| Groq | Groq | api.groq.com/openai/v1 | `GroqPlugin` |
| DeepSeek | DeepSeek | api.deepseek.com/v1 | `OpenAICompatiblePlugin` preset |
| Qwen / DashScope | 通义千问 | dashscope.aliyuncs.com/compatible-mode/v1 | `OpenAICompatiblePlugin` preset |
| Kimi | Kimi | api.moonshot.cn/v1 | `OpenAICompatiblePlugin` preset |
| Zhipu | 智谱 | open.bigmodel.cn/api/paas/v4 | `OpenAICompatiblePlugin` preset |
| SiliconFlow | 硅基流动 | api.siliconflow.cn/v1 | `OpenAICompatiblePlugin` preset |
| Custom | OpenAI 兼容 | user entered | `OpenAICompatiblePlugin` |

Phase 2 confirms each preset URL against the provider's docs before shipping.

**States.** Normal; first provider failing (red dot in list, sidebar shows `使用备用模型`); none configured: centered empty state with sparkle glyph, `接入一个 AI 模型`, `AI 模型负责去掉口头禅、整理段落和翻译。没有接入时，dictum 只插入识别出的原文。`, and a 4-column grid of provider tiles; clicking a tile adds it and opens its detail with the key field focused.

**Copy.**

| zh-Hans | English |
|---|---|
| AI 模型 / 添加 | AI Models / Add |
| 润色和翻译使用第一个；它出错时，自动换下一个。拖动调整顺序。 | Polishing and translation use the first one. If it fails, the next one takes over. Drag to reorder. |
| 首选 / 备用 {n} | Primary / Backup {n} |
| 设为首选 / 自定义接口地址… / 移除 | Make Primary / Custom Endpoint… / Remove |
| API 密钥 / 粘贴 / 模型 / 接口地址 | API key / Paste / Model / Endpoint |
| 测试连接 / 正在测试… | Test Connection / Testing… |
| 已连接 · 响应 {t} 秒 | Connected · {t} s response |
| 密钥无效（401），请检查后重新粘贴 | Invalid key (401). Check it and paste again. |
| 无法连接，请检查网络或接口地址 | Can't connect. Check your network or endpoint. |
| 额度不足（402） / 请求太频繁（429） | Out of credit (402) / Too many requests (429) |
| 接入一个 AI 模型 | Connect an AI model |
| AI 模型负责去掉口头禅、整理段落和翻译。没有接入时，dictum 只插入识别出的原文。 | The AI model removes fillers, organizes paragraphs, and translates. Without one, dictum inserts exactly what it heard. |

**SwiftUI.** `HStack` of a `List` with `.onMove` (or `Table` without headers) and a detail `Form`; `Menu` for add; keys in `KeychainService`, never shown in clear text after save.

**Data.** `LLMProviderPlugin` plugins listed above, `PluginManager`, `KeychainService`, `PromptProcessingService` for the fallback chain (new in phase 2). Existing views to replace in the main window: provider parts of `PluginSettingsView`.

### 5.8 Onboarding 上手引导 (`onboarding.html`)

A separate 640 × 540 window, centered, shown on first launch and from Home's `练习一次`. Close and minimize are disabled until the last step (traffic lights greyed except close, which asks `稍后再设置？` and leaves the app usable in the menu bar). Top: 8 progress dots (current is an 18pt accent pill, past dots tertiary). Bottom bar: `返回` (plain, hidden on first and last step), `跳过` (practice steps only), primary `继续`, disabled until the step's goal is met. Steps slide in from the right (0.35 s ease-out, 14pt offset).

| # | Step | Content | Goal to continue |
|---|---|---|---|
| 0 | 欢迎 Welcome | 96pt app icon, `说话，就能打字`, lead text, three key caps with labels (fn 听写, fn + 左 ⇧ 翻译, esc 取消). Model download starts silently here. | none, button `开始` |
| 1 | 权限 Permissions | `开启权限`, lead `录音和文字只在你按下快捷键时处理。` Three rows with icon tile, title, subtitle, action: 麦克风 (`允许` triggers the system prompt), 辅助功能 (`打开系统设置` deep-links to the Accessibility pane, row shows spinner `等待开启` and polls `AXIsProcessTrusted()` every second), fn 键 (only shown when the system Fn action is not "Do Nothing": subtitle names the current setting, `打开键盘设置`). Each turns into `✓ 已开启`. | all shown rows done |
| 2 | 麦克风 Mic test | `说句话试试`, hint `比如：“今天天气不错。”`, 32-bar centered level meter in accent, status `等待声音…` → `✓ 听得很清楚` after 1.2 s of speech, device popup. If no signal for 8 s: `没有听到声音，换一个麦克风试试` in warning. | speech detected |
| 3 | 模型 Model | `准备语音模型`, Qwen3 card with progress, size, time left; link `改用云端识别` opens Speech. When done: `已就绪`. | download complete or cloud engine configured |
| 4 | 练习听写 Practice | `练习听写`, instruction, an accent-soft card with the sentence to read (contains fillers and a self-correction), a text area that receives the result, the real voice bar appears at the window bottom. On success: `✓ 口头禅和改口都处理好了`. | one dictation inserted, or `跳过` |
| 5 | 练习翻译 Practice | same with a translate-soft card `中文 → English` and a Chinese sentence. Success note `在语音条上点语言，可以换成其他目标语言`. | one translation inserted, or `跳过` |
| 6 | 同步 Sync | `同步历史`, lead `听写记录存进 iCloud Drive 里的 dictum 文件夹。换一台 Mac 或清空数据后，可以从这里找回。` One form row: cloud icon tile, `同步到 iCloud Drive` with the folder path `iCloud Drive › dictum` underneath, and a switch that is on when the step opens. Footnote: `同步文件夹里只有文字，录音只保存在这台 Mac 上。` and `以后可以在 通用 → 历史与同步 里修改。` `继续` applies the switch: on turns on sync to the default iCloud Drive folder (the same action as General → History & Sync → `同步到 iCloud Drive`), off leaves sync off; either way the choice is recorded, so General shows no sync prompt afterwards. When iCloud Drive is not available on this Mac, the switch is off and disabled and the subtitle reads `这台 Mac 没有开启 iCloud Drive，可以以后在 通用 → 历史与同步 选择其他文件夹。` When sync is already on (onboarding opened again from Home), the switch shows on and `继续` changes nothing. | none |
| 7 | 完成 Done | green check icon, `准备好了`, cheat sheet of the three shortcuts. | button `开始使用` closes the window and opens Home |

**Copy.**

| zh-Hans | English |
|---|---|
| 说话，就能打字 | Talk, and it's typed |
| 在任何输入框里按一下 fn，说完再按一下。dictum 会去掉口头禅、整理好段落，把文字放到光标处。 | Press fn in any text field, talk, then press fn again. dictum cleans up filler words, organizes paragraphs, and puts the text at your cursor. |
| 开始 / 继续 / 返回 / 跳过 / 开始使用 | Get Started / Continue / Back / Skip / Start Using dictum |
| 开启权限 | Turn on access |
| 录音和文字只在你按下快捷键时处理。 | Audio and text are only processed when you press the shortcut. |
| 麦克风 / 听你说话 / 允许 | Microphone / To hear you / Allow |
| 辅助功能 / 把文字输入到其他应用，并识别 fn 键 / 打开系统设置 | Accessibility / To type into other apps and detect the fn key / Open System Settings |
| fn 键 / 系统把 fn 设成了“{action}”，需要改为“不执行任何操作” / 打开键盘设置 | fn key / macOS uses fn for "{action}". Change it to "Do Nothing". / Open Keyboard Settings |
| 等待开启 / 已开启 | Waiting… / On |
| 说句话试试 / 比如：“今天天气不错。” | Say something / For example: "Nice weather today." |
| 等待声音… / 听得很清楚 | Listening for sound… / Sounds great |
| 没有听到声音，换一个麦克风试试 | No sound yet. Try another microphone. |
| 准备语音模型 / Qwen3-ASR 在这台 Mac 上识别中英文，不需要联网。 | Getting the speech model ready / Qwen3-ASR recognizes Chinese and English on this Mac, no internet needed. |
| 下载中 / 已就绪 / 改用云端识别 | Downloading / Ready / Use cloud recognition instead |
| 练习听写 / 按一下 fn，读出下面这段话，再按一下 fn。 | Practice dictation / Press fn, read the text below, then press fn again. |
| 照着读，口头禅和改口也读出来 | Read it as written, fillers and all |
| 文字会出现在这里 / 口头禅和改口都处理好了 | Your text appears here / Fillers and corrections handled |
| 练习翻译 / 按 fn + 左 ⇧，用中文说下面这句话，再按一下 fn。 | Practice translation / Press fn + Left ⇧, say this in Chinese, then press fn. |
| 译文会出现在这里 / 在语音条上点语言，可以换成其他目标语言 | The translation appears here / Click the language on the voice bar to switch targets |
| 同步历史 / 听写记录存进 iCloud Drive 里的 dictum 文件夹。换一台 Mac 或清空数据后，可以从这里找回。 | Sync your history / Your dictations are saved to the dictum folder in iCloud Drive. On another Mac, or after clearing data, you can get them back from there. |
| 同步到 iCloud Drive / 以后可以在 通用 → 历史与同步 里修改。 | Sync to iCloud Drive / You can change this later in General → History & Sync. |
| 这台 Mac 没有开启 iCloud Drive，可以以后在 通用 → 历史与同步 选择其他文件夹。 | iCloud Drive is off on this Mac. You can choose another folder later in General → History & Sync. |
| 准备好了 | You're all set |
| 听写，再按一下结束 / 翻译 / 取消，可以在历史里找回 | Dictate, press again to finish / Translate / Cancel, recoverable in History |

**SwiftUI.** `Window` scene with `.windowResizability(.contentSize)`; a `TabView` is not used; switch steps with a `@State` index and `.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))`. The practice text area is a real `TextEditor` so the real insertion path is exercised.

**Data.** `SetupWizardView` steps (`welcome`, `permissions`, `hotkey`, `engineAI`, `finish`) are replaced by this flow. Permissions: `AccessibilityPermissionPane`, `AVCaptureDevice.requestAccess(for: .audio)`. Fn setting: read `AppleFnUsageType` from the `com.apple.HIToolbox` defaults domain (new code; nothing in TypeWhisper reads it yet). Mic level: `AudioRecordingService`. Model: `ModelManagerService`. Sync: the same controller and setting as General → History & Sync (`CloudFolderSyncSettingsView` / `HistorySyncSection`); the onboarding step and the General switch always show the same state.

## 6. Voice bar 语音条 (`voice-bar.html`)

### 6.1 Concept

A dark floating capsule at the bottom center of the screen that has the text cursor. It is small while listening (one 44pt row: live indicator, scrolling waveform, timer, cancel, done) and grows upward into a card when words arrive, showing the streaming transcript in up to three lines. The newest words fade in from a 2px blur; the not-yet-final tail of the transcript is dimmed to 34% white, the committed part is full white. When the user stops, the same card turns into a shimmering "polishing" state, then collapses into a small green-check pill (`已插入 32 字`) and fades out. Every state is a variation of the same capsule, so the bar never jumps between unrelated shapes.

The bar is always dark (HUD material, forced dark appearance) in both system appearances, so it reads the same over any app and the red dot and purple chip keep their contrast.

### 6.2 Window and placement

- `NSPanel`, `.nonactivatingPanel`, `.hudWindow` style off, borderless, `level = .statusBar`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`. It never takes focus from the target app. Host SwiftUI with `NSHostingView`.
- Position: horizontally centered on the screen that contains the focused text field (fall back to the mouse screen), bottom edge 72pt above `visibleFrame.minY`. The panel grows upward; the bottom edge stays fixed.
- Size: collapsed width hugs content (about 200–300pt); with text, fixed 460pt wide. Height 44pt per control row plus the text area (14 top padding, up to 3 × 22 lines).
- Buttons on the bar are clickable without activating dictum (`acceptsFirstMouse`).
- Existing code: `OverlayIndicatorPanel`, `OverlayIndicatorView`, `IndicatorCoordinator`, `FloatingPanelSpacePolicy`. The notch and minimal indicator styles stay available in Advanced Settings; the voice bar becomes the default.

### 6.3 Anatomy

| Part | Spec |
|---|---|
| Container | radius 22 (20 when expanded), HUD material + black @ 55%, inner stroke white @ 14% 0.5pt, shadow per 2.3 |
| Live dot | 8pt `live` circle with a 1.6 s pulse ring (scale 0.6 → 1.6, opacity 0.45 → 0) |
| Waveform | 26 bars, 2.5pt wide, 2.5pt gap, 3–22pt tall, white @ 88%, scrolls right to left at ~18 fps, left 22% faded by a mask. Bar height = RMS level of each 55 ms window. Translation tints bars `#E2D2FF`. |
| Timer | 13 rounded, white @ 58%, `m:ss` |
| Cancel | 30pt circle button, `xmark`, white @ 58%; hover white @ 10% fill; tooltip `esc` |
| Done | 30pt circle, white fill, black `checkmark`; tooltip `fn` |
| Streaming text | 15 / 22, padding 14 18 2, max 3 lines, older lines scroll up under a 18pt top fade mask |
| Language chip | 26pt capsule, `translate` @ 24% fill, `#E6D6FF` text, `{spoken} → {target} ⌄` from the Settings pair (`自动` when the spoken language is set to detect), for example `中文 → English ⌄` |
| Action pill | 26pt capsule, white @ 14% fill, 12.5 text (`重试`, `恢复`, `设置`) |

### 6.4 States

All states are in `voice-bar.html` ("全部状态"). The live demo at the top runs the real sequence: press F (stands in for fn) to start and stop, Shift+F to translate, Esc to cancel.

| # | State | Trigger | Shows | Leaves when |
|---|---|---|---|---|
| 1 | Idle | nothing running | nothing | Fn pressed |
| 2 | Preparing 准备中 | Fn pressed while the engine loads | spinner, `准备中` at 70% white, waveform already live, timer, cancel. Audio is already being captured (pre-roll buffer), nothing is lost. | engine ready → Listening |
| 3 | Listening 聆听 | recording, no words yet | live dot, waveform, timer, cancel, done | first partial text → Listening with text |
| 4 | Listening with text | partial results arrive | bar expands to 460pt with spring; committed text white, tail dimmed | Fn → Polishing; Esc → Cancelled |
| 5 | Translating 翻译 | Fn + Left Shift | language chip replaces the live dot; purple-tinted waveform; Chinese streaming text | Fn → Translating (processing) |
| 6 | Target menu | click chip | dark menu above the bar: target languages in Settings order with a check, separator, `编辑语言…`; recording continues | pick or click outside |
| 7 | Polishing 润色中 / 翻译中 | Fn pressed to stop | three bouncing dots + `润色中` (or `翻译中`), the final transcript with a left-to-right shimmer, cancel only | text inserted → Inserted |
| 8 | Inserted 已插入 | text pasted into the field | collapses to a pill: green check (pop), `已插入` + `32 字` / `18 words` | fades out after 1.2 s |
| 9 | Copied 已复制 | no focused text field | copy symbol, `已复制，没有找到输入框`, key cap `⌘V` | 3 s |
| 10 | Error, recovered | polish or translation failed | warning triangle (amber), `润色失败，已插入原文` (translation: `翻译失败，已插入原话`), `重试` (re-runs polishing or translation and replaces the inserted text when the field still holds it; otherwise copies) | 4 s |
| 11 | Error, blocking | mic unavailable or permission missing | red mic symbol, `无法使用麦克风`, `打开设置`, close button | user closes or acts |
| 12 | No speech 没有声音 | stopped with only silence | dim mic symbol, `没有听到声音`; no history record | 2 s |
| 13 | Model downloading | Fn pressed before the local model is ready and no cloud engine is set | progress ring, `语音模型下载中 62%`, `查看` opens Speech | 3 s; recording does not start |
| 14 | Offline or no AI key | recognition worked but polishing could not run | cloud symbol, `未连接 AI 模型，已插入原文`, `设置` opens AI Models | 4 s |
| 15 | Countdown | recording reaches 8:00 | amber progress ring draining over 60 s, timer turns amber and counts down `0:42` | at 9:00 stops automatically → Polishing, everything kept |
| 16 | Cancelled 已取消 | Esc while listening or polishing | `已取消` + `恢复`, a thin line drains along the bottom over 3 s | 3 s fade; the recording stays in History as a cancelled record; `恢复` processes and inserts it |

Transitions between states animate the container size with `spring` and cross-fade the contents (0.2 s). Never re-create the panel between states.

### 6.5 Copy

| zh-Hans | English |
|---|---|
| 准备中 | Getting ready |
| 润色中 / 翻译中 | Polishing / Translating |
| 已插入 · {n} 字 / {n} 词 | Inserted · {n} characters / {n} words |
| 已复制，没有找到输入框 | Copied. No text field found. |
| 润色失败，已插入原文 · 重试 | Polishing failed. Original inserted. · Retry |
| 翻译失败，已插入原话 · 重试 | Translation failed. What you said was inserted. · Retry |
| 无法使用麦克风 · 打开设置 | Microphone unavailable · Open Settings |
| 没有听到声音 | Didn't hear anything |
| 语音模型下载中 {p}% · 查看 | Downloading speech model {p}% · View |
| 未连接 AI 模型，已插入原文 · 设置 | No AI model connected. Original inserted. · Settings |
| 已取消 · 恢复 | Cancelled · Undo |
| 编辑语言… | Edit Languages… |

### 6.6 Data

`DictationViewModel` state (`idle`, `recording`, `processing`, `inserting`, `error`) drives states 1–4, 7, 8, 10, 11. Partial text: `StreamingHandler`. Levels: `AudioRecordingService` meter. Insertion and the copy fallback: `TextInsertionService`. Cancel and restore: `DictationRecoveryAudioStore`, `DictationRecoveryViewModel`. Timer limits: new constants (warn at 480 s, stop at 540 s). Translation pair: the spoken language and the ordered target list from General → Translation languages; translation runs through the AI model chain with the resolved app style.

## 7. Menu bar 菜单栏 (`menu-bar.html`)

**Icon.** Template SF Symbol `waveform` at 16pt. States: idle (plain); recording (plain with a 6pt `live` dot top right); polishing (icon pulses opacity 1 → 0.35, 1 s); downloading model (a 16pt progress ring in place of the icon); needs attention (6pt `warning` dot).

**Menu** (`NSMenu`, built with SwiftUI `MenuBarExtra(.menu)` if it supports the status header, otherwise AppKit):

1. Status header (disabled): dot + bold label + caption on the right. `就绪 · Qwen3-ASR`, `正在听写 · 0:12`, `正在下载语音模型 · 62%`, `需要辅助功能权限`.
2. When attention is needed: `打开系统设置…` in warning color, then a separator.
3. `开始听写 fn`, `开始翻译 fn ⇧` (disabled while the model downloads). While recording they become `结束听写 fn` and `取消 esc`.
4. Separator. `翻译成 ▸` (target languages with a check), `润色强度 ▸` (轻度 / 标准 / 重写).
5. Separator. Two-line item: caption `复制最近一条 · 14:32`, then the text truncated to one line. Click copies.
6. Separator. `打开 dictum ⌘O`, `设置… ⌘,`.
7. Separator. `退出 dictum ⌘Q`.

Advanced Settings (the TypeWhisper window) is reachable with ⌥ held: `设置…` becomes `高级设置…`.

| zh-Hans | English |
|---|---|
| 就绪 / 正在听写 / 正在下载语音模型 / 需要辅助功能权限 | Ready / Dictating / Downloading speech model / Accessibility access needed |
| 打开系统设置… | Open System Settings… |
| 开始听写 / 开始翻译 / 结束听写 / 取消 | Start Dictation / Start Translation / Finish Dictation / Cancel |
| 翻译成 / 润色强度 | Translate To / Polish Strength |
| 复制最近一条 | Copy Last Dictation |
| 打开 dictum / 设置… / 高级设置… / 退出 dictum | Open dictum / Settings… / Advanced Settings… / Quit dictum |

**Data.** `MenuBarView` (replace its contents), `DictationViewModel`, `HistoryService.recentRecords`, `ModelManagerService`.

## 8. Implementation notes

- Build pages in this order so each one can be checked against its prototype: voice bar, Home, History, Dictionary, General, Speech, AI Models, Style, Onboarding, menu bar.
- Visual comparison: screenshot each SwiftUI screen at 1040 × 680 in light and dark and compare with `prototypes/<page>.html?theme=light|dark` at the same size. The window, sidebar, and toolbar should line up within 2pt.
- Localize every new string through the owning phase's string table with English and zh-Hans values. Prototype sample data is illustrative and never ships.
- Accessibility: every icon-only button has a label (`取消 Cancel`, `完成 Done`, `复制 Copy`, `删除 Delete`); the voice bar posts `NSAccessibility` announcements for "Recording", "Inserted", and errors through `AccessibilityAnnouncementService`; heatmap cells expose their tooltip text as the accessibility value.

### Use the shell

Phases 1, 2, 3, 4, and 5B own their page files and string tables. Keep shared shell files unchanged when adding page content.

- Wrap a page in `DictumPageFrame(page:actions:content:)`. Put search fields, segmented pickers, buttons, and menus in `actions`. The frame places them at the trailing edge of the 52pt title row. Omit `actions` for a title-only page. `GeneralPage` provides an Open Login Items action when macOS requires approval. `AIModelsPage` provides its working provider picker.
- Pass `tableName` to `GroupedFormSection`, `GroupedFormToggle`, `DictumPopup`, `Badge`, `Banner`, `EmptyState`, `OptionCard`, `StatTile`, `Toast`, `KeyCapView`, and `DictumShortcutControl`. It defaults to `DictumShell` for existing shell callers. The section's title and footer share that table. `SoundSection` reads its existing title from `Localizable` and its toggles from `DictumShell`.
- Use `DictumPopup(title:selection:tableName:value:options:)` for a native popup with the prototype's control surface. Tagged options provide the visible title; `value` provides the localized VoiceOver value. Use `DictumControlStyle(kind: .smallButton)` for small neutral buttons.
- Use your own table for page keys. For example, `GroupedFormSection(title: "Polish strength", tableName: "DictumStyle") { ... }` and `GroupedFormToggle(title: "Enabled", isOn: $enabled, tableName: "DictumStyle")` require no shell resource edits. Pass `LocalizedStringKey` for computed keys. `StatTile.value` is an already formatted value. Key caps accept a key name and an optional caller table for translated key names.
- Navigate with `DictumNavigation.shared.open(.speech)` or the matching `DictumPage` case. Add files under `TypeWhisper/Dictum/`; Xcode discovers them through the synchronized folder.
- Check a login launch with `scripts/dictum-verify.sh run --login-item --audio-file <clip>`. This sends the macOS login Apple Event to the app. Normal login launches keep the main window closed. Setup keeps a Dock icon while its window is visible.
