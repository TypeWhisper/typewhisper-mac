# 词典与历史文件格式

核查日期为 2026-10-23。以下结论来自产品官方页面。

| 产品 | 已确认的格式 | 尚未确认的部分 |
| --- | --- | --- |
| [Typeless](https://www.typeless.com/zh-cn/help/quickstart/history-and-dictionary) | 电脑端支持词典 CSV 导入；历史支持复制文字、下载音频。 | 当前帮助页没有定义 CSV 列顺序、表头或历史导入格式。不能据此声称支持双向历史迁移。 |
| [Wispr Flow](https://docs.wisprflow.ai/articles/8955301725-How-Do-I-Bulk-Import-Dictionary-Items-and-Snippets) | 词典使用无表头 CSV。单列为词汇，双列依次为误识别写法和正确写法。包含逗号的字段使用双引号，字段内双引号重复转义。支持 Unicode、Unix 和 Windows 换行。片段导入使用包含 `name`、`text` 的 JSON 对象数组。 | [数据导出说明](https://docs.wisprflow.ai/articles/8254696706-data-requests-get-a-copy-of-your-data-or-ask-us-to-delete-it)提供个人数据归档申请，但未定义可直接导回的历史文件结构。 |
| [Superwhisper 更新记录](https://ai.superwhisper.com/changelog) | 2.14.0 增加词典 CSV 导入，2.18.5 修复 Windows 换行处理。[官方 CLI 介绍](https://superwhisper.com/blog/cli-mcp)说明转录可导出 JSON 或 Markdown。 | `https://superwhisper.com/docs/settings/vocabulary` 无法读取，未据此推断 CSV 列顺序。更新记录没有定义完整 CSV 结构。 |

dictum 的词典导出使用无表头 UTF-8 CSV，列顺序采用 Wispr Flow 已公开的“误识别写法、正确写法”；普通词只有第一列。导入窗口默认使用设计稿的“词、常被听成”顺序，也可以切换到 Wispr Flow 顺序，说明文字和前几行“词 ← 常被听成”的预览随所选顺序变化，避免猜测双列含义。CSV 读写使用 Apple TabularData。导入限制为 5 MB、3000 行，词典总条目上限为 3000。Wispr Flow 文档写明词典 CSV 和片段 JSON 每个文件最多 3 MB，每次导入最多 1,000 个有效条目（去掉无效行、文件内重复和已有重复后计数），所以要导入 Wispr Flow 的文件时，从 dictum 导出的词典超过 1,000 条需要分多个文件。重复项按条目类型和原文忽略大小写判断，导入结果包含新增、跳过重复项和拒绝行原因。

历史导出使用 UTF-8 Markdown，包含 ISO 8601 时间和最终文字。上述已读取页面未提供历史导入格式，故不声明导出的历史能直接导入这些产品。

同步文件夹默认位于 `~/Library/Mobile Documents/com~apple~CloudDocs/dictum/`。其内部沿用 `dictum-sync/manifest.json`、`dictum-sync/devices/` 和 `dictum-sync/ops/`。操作按设备与条目保存为 JSON，已有同步引擎按操作标识去重并合并各数据组件，重复同步不重复创建词条。历史、词典和片段通过此机制恢复；应用的同步快照不发布录音文件或音频描述。

两台 Mac 同时修改同一条目或同一历史组件时，同步引擎优先采用更新时间较新的操作。时间相同时，先比较词典字段完整性，再按设备标识和操作标识的固定顺序决定结果。删除也作为操作参与合并。历史内容与收件箱状态按组件分别合并，重复读取同一组操作得到相同结果。

历史保留期限使用六个明确选项，分别为永久、默认一年、一个月、一周、24 小时和不保留。一年和一个月按日历计算，24 小时按实际秒数计算。旧版本保存的其他天数（例如 60、90、180）归入不短于它的最近一档，不会多删记录。自动学习提示按词条创建时间与本机最后确认时间比较，确认提示后保存该时间。
