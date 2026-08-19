import Foundation
import TypeWhisperPluginSDK

#if DEBUG
@MainActor
extension ServiceContainer {
    func prepareScreenshotFixtures() {
        let language = ScreenshotFixtureLanguage.current
        let content = language.content
        let variant = ScreenshotFixtureVariant.current

        licenseService.usageIntent = variant.hasPremiumAccess ? .workSolo : .personalOSS
        licenseService.licenseStatus = variant.hasPremiumAccess ? .active : .unlicensed
        licenseService.licenseTier = variant.hasPremiumAccess ? .individual : nil
        licenseService.licenseIsLifetime = variant.hasPremiumAccess
        licenseService.supporterStatus = .unlicensed
        licenseService.supporterTier = nil
        premiumAccountService.prepareScreenshotFixture(hasPremiumAccess: variant.hasPremiumAccess)
        cloudFolderSyncController.prepareScreenshotFixture(hasPremiumAccess: variant.hasPremiumAccess)
        calendarMeetingAutomationController.prepareScreenshotFixture(
            hasPremiumAccess: variant.hasPremiumAccess,
            calendars: language.calendars
        )
        targetAppCorrectionLearningService.prepareScreenshotFixture(hasPremiumAccess: variant.hasPremiumAccess)
        UserDefaults.standard.set(
            variant.hasPremiumAccess,
            forKey: UserDefaultsKeys.targetAppCorrectionLearningEnabled
        )
        if ["indicator-settings", "indicator"].contains(AppConstants.screenshotState) {
            dictationViewModel.prepareScreenshotIndicatorFixture()
        }

        seedScreenshotHistory(content.history, languageCode: language.rawValue)
        usageStatisticsService.replaceWithHistoryRecords(historyService.records)

        dictionaryService.addEntries(
            content.terms.map {
                (type: DictionaryEntryType.term, original: $0, replacement: nil, caseSensitive: true)
            } + content.corrections.map {
                (
                    type: DictionaryEntryType.correction,
                    original: $0.original,
                    replacement: Optional($0.replacement),
                    caseSensitive: false
                )
            }
        )

        for snippet in content.snippets {
            snippetService.addSnippet(trigger: snippet.trigger, replacement: snippet.replacement)
        }

        for (index, workflow) in content.workflows.enumerated() {
            _ = workflowService.addWorkflow(
                name: workflow.name,
                template: workflow.template,
                trigger: workflow.trigger,
                behavior: WorkflowBehavior(fineTuning: workflow.instruction),
                sortOrder: index
            )
        }

        seedScreenshotPluginRegistry()
        seedScreenshotTermPacks()
        DictionaryViewModel.shared.filterTab = AppConstants.screenshotState == "dictionary-term-packs"
            ? .termPacks
            : .all
        pluginManager.setRuleNamesProvider { [weak self] in
            self?.workflowService.availableRuleNames ?? []
        }
        pluginManager.setWorkflowProvider { [weak self] in
            self?.workflowService.workflows.map(\.pluginWorkflowInfo) ?? []
        }
        pluginManager.scanAndLoadPlugins()

        statisticsViewModel.refresh()
        homeViewModel.refresh()
    }

    private func seedScreenshotHistory(
        _ samples: [ScreenshotHistorySample],
        languageCode: String
    ) {
        historyService.clearAll()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let referenceDate = AppConstants.screenshotFixtureReferenceDate
        for index in 0..<14 {
            let sample = samples[index % samples.count]
            let dayOffset = index / 2
            let hour = index.isMultiple(of: 2) ? 9 : 15
            let day = calendar.date(
                byAdding: .day,
                value: -dayOffset,
                to: referenceDate
            ) ?? referenceDate
            let timestamp = calendar.date(
                bySettingHour: hour,
                minute: 10 + index,
                second: 0,
                of: day
            ) ?? day

            _ = historyService.addRecord(
                timestamp: timestamp,
                rawText: sample.text,
                finalText: sample.text,
                appName: sample.appName,
                appBundleIdentifier: sample.bundleIdentifier,
                durationSeconds: 5.5 + Double(index % 5),
                language: languageCode,
                engineUsed: index.isMultiple(of: 3) ? "parakeet" : "whisper",
                modelUsed: index.isMultiple(of: 3) ? "Parakeet TDT 0.6B v3" : "Large v3 Turbo"
            )
        }
    }

    private func seedScreenshotPluginRegistry() {
        pluginRegistryService.registry = [
            screenshotRegistryPlugin(
                id: "com.typewhisper.deepgram",
                name: "Deepgram",
                description: "Fast cloud transcription with multilingual model support.",
                descriptions: [
                    "de": "Schnelle Cloud-Transkription mit mehrsprachigen Modellen.",
                    "ja": "多言語モデルに対応した高速なクラウド文字起こし。",
                    "zh": "支持多语言模型的快速云端转写。",
                ],
                categories: ["transcription"]
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.assemblyai",
                name: "AssemblyAI",
                description: "Cloud speech recognition with speaker and language features.",
                descriptions: [
                    "de": "Cloud-Spracherkennung mit Sprecher- und Sprachfunktionen.",
                    "ja": "話者識別と言語機能を備えたクラウド音声認識。",
                    "zh": "具备说话人和语言功能的云端语音识别。",
                ],
                categories: ["transcription"]
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.openrouter",
                name: "OpenRouter",
                description: "Use a broad catalog of language models in your workflows.",
                descriptions: [
                    "de": "Nutze eine große Auswahl an Sprachmodellen in deinen Workflows.",
                    "ja": "豊富な言語モデルをワークフローで利用できます。",
                    "zh": "在工作流中使用丰富的语言模型。",
                ],
                categories: ["llm"]
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.elevenlabs",
                name: "ElevenLabs",
                description: "Natural text-to-speech voices for spoken feedback.",
                descriptions: [
                    "de": "Natürliche Stimmen für gesprochenes Feedback.",
                    "ja": "読み上げフィードバック向けの自然な音声。",
                    "zh": "用于语音反馈的自然文本转语音。",
                ],
                categories: ["tts"]
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.file-memory",
                name: "File Memory",
                description: "Give workflows local context from selected documents.",
                descriptions: [
                    "de": "Gib Workflows lokalen Kontext aus ausgewählten Dokumenten.",
                    "ja": "選択した書類のローカル情報をワークフローで利用できます。",
                    "zh": "让工作流使用所选文档中的本地上下文。",
                ],
                categories: ["memory"]
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.obsidian",
                name: "Obsidian",
                description: "Send processed notes directly to an Obsidian vault.",
                descriptions: [
                    "de": "Sende bearbeitete Notizen direkt an einen Obsidian-Vault.",
                    "ja": "処理したメモをObsidianの保管庫へ直接送信します。",
                    "zh": "将处理后的笔记直接发送到 Obsidian 仓库。",
                ],
                categories: ["action"]
            ),
        ]
        pluginRegistryService.fetchState = .loaded
        pluginRegistryService.updateAvailableUpdatesCount()
    }

    private func screenshotRegistryPlugin(
        id: String,
        name: String,
        description: String,
        descriptions: [String: String],
        categories: [String]
    ) -> RegistryPlugin {
        RegistryPlugin(
            id: id,
            source: .official,
            name: name,
            version: "1.0.0",
            minHostVersion: "0.0.0",
            sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
            minOSVersion: "14.0",
            supportedArchitectures: nil,
            author: "TypeWhisper",
            description: description,
            category: categories[0],
            categories: categories,
            capabilities: [],
            size: 1_800_000,
            downloadURL: "https://github.com/TypeWhisper/typewhisper-mac/releases/download/screenshot-fixture/plugin.zip",
            iconSystemName: "puzzlepiece.extension",
            requiresAPIKey: false,
            hosting: nil,
            descriptions: descriptions,
            downloadCount: 1_250
        )
    }

    private func seedScreenshotTermPacks() {
        termPackRegistryService.communityPacks = [
            TermPack(
                id: "screenshot-product-writing",
                name: "Product Writing",
                description: "Product, launch, and release vocabulary for clear dictation.",
                icon: "shippingbox",
                terms: ["TypeWhisper", "Fastlane", "release candidate", "localization"],
                corrections: [],
                version: "1.0.0",
                author: "TypeWhisper Community",
                localizedNames: [
                    "de": "Produkttexte",
                    "ja": "プロダクトライティング",
                    "zh": "产品写作",
                ],
                localizedDescriptions: [
                    "de": "Begriffe für Produkt, Launch und Release.",
                    "ja": "製品、公開、リリースに関する語彙集です。",
                    "zh": "用于产品、发布和版本说明的词汇。",
                ]
            ),
        ]
        termPackRegistryService.fetchState = .loaded
    }
}

private enum ScreenshotFixtureVariant {
    case free
    case premium

    static var current: ScreenshotFixtureVariant {
        ProcessInfo.processInfo.arguments.contains("--screenshot-premium") ? .premium : .free
    }

    var hasPremiumAccess: Bool { self == .premium }
}

private enum ScreenshotFixtureLanguage: String {
    case english = "en"
    case german = "de"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"

    static var current: ScreenshotFixtureLanguage {
        let preferred = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
            ?? Locale.preferredLanguages.first
            ?? "en"
        let normalized = preferred.lowercased()
        if normalized.hasPrefix("de") { return .german }
        if normalized.hasPrefix("ja") { return .japanese }
        if normalized.hasPrefix("zh") { return .simplifiedChinese }
        return .english
    }

    var calendars: [CalendarMeetingCalendar] {
        let titles: [(title: String, source: String)] = switch self {
        case .english:
            [("Team Calendar", "Google Workspace"), ("Personal Calendar", "iCloud")]
        case .german:
            [("Teamkalender", "Google Workspace"), ("Privater Kalender", "iCloud")]
        case .japanese:
            [("チームカレンダー", "Google Workspace"), ("個人用カレンダー", "iCloud")]
        case .simplifiedChinese:
            [("团队日历", "Google Workspace"), ("个人日历", "iCloud")]
        }

        return [
            CalendarMeetingCalendar(
                id: "screenshot-team",
                title: titles[0].title,
                sourceTitle: titles[0].source
            ),
            CalendarMeetingCalendar(
                id: "screenshot-personal",
                title: titles[1].title,
                sourceTitle: titles[1].source
            ),
        ]
    }

    var content: ScreenshotFixtureContent {
        switch self {
        case .english:
            ScreenshotFixtureContent(
                history: [
                    .init(appName: "Notes", bundleIdentifier: "com.apple.Notes", text: "Finalize the release notes and verify every localized screenshot before publishing."),
                    .init(appName: "Mail", bundleIdentifier: "com.apple.mail", text: "Please send the updated launch brief to the team before tomorrow's review."),
                    .init(appName: "Safari", bundleIdentifier: "com.apple.Safari", text: "Compare the product page in all supported languages and collect the final feedback."),
                    .init(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", text: "Run the macOS test suite and confirm that the release build stays free of warnings."),
                    .init(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", text: "The candidate is ready. Please report anything that should block the release."),
                    .init(appName: "Pages", bundleIdentifier: "com.apple.iWork.Pages", text: "Turn the meeting notes into a concise summary with owners and next steps."),
                    .init(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", text: "Create the final archive, verify its signature, and record the checksum."),
                ],
                terms: ["TypeWhisper", "Fastlane", "SwiftUI", "App Store Connect", "release candidate"],
                corrections: [
                    .init(original: "Type Whisper", replacement: "TypeWhisper"),
                    .init(original: "fast lane", replacement: "Fastlane"),
                    .init(original: "swift UI", replacement: "SwiftUI"),
                ],
                snippets: [
                    .init(trigger: "/thanks", replacement: "Thanks for the detailed feedback — I will take a look today."),
                    .init(trigger: "/meeting", replacement: "Meeting notes for {date}:\n\n- Decision\n- Owner\n- Next step"),
                    .init(trigger: "/release", replacement: "The release candidate is ready for the final review."),
                ],
                workflows: [
                    .init(name: "Polish Dictation", template: .cleanedText, trigger: .global(), instruction: "Keep the tone direct and preserve product names."),
                    .init(name: "Meeting Notes", template: .meetingNotes, trigger: .app("com.apple.Notes"), instruction: "Extract decisions, owners, and next steps."),
                    .init(name: "Translate to English", template: .translation, trigger: .manual(), instruction: "Translate naturally into English."),
                ]
            )

        case .german:
            ScreenshotFixtureContent(
                history: [
                    .init(appName: "Notizen", bundleIdentifier: "com.apple.Notes", text: "Finalisiere die Release Notes und prüfe vor der Veröffentlichung alle lokalisierten Screenshots."),
                    .init(appName: "Mail", bundleIdentifier: "com.apple.mail", text: "Bitte sende dem Team vor dem morgigen Review die aktualisierte Launch-Zusammenfassung."),
                    .init(appName: "Safari", bundleIdentifier: "com.apple.Safari", text: "Vergleiche die Produktseite in allen unterstützten Sprachen und sammle das letzte Feedback."),
                    .init(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", text: "Führe die macOS-Tests aus und bestätige, dass der Release-Build ohne Warnungen bleibt."),
                    .init(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", text: "Der Kandidat ist bereit. Bitte melde alles, was den Release noch blockieren sollte."),
                    .init(appName: "Pages", bundleIdentifier: "com.apple.iWork.Pages", text: "Fasse die Besprechung mit Entscheidungen, Verantwortlichen und nächsten Schritten zusammen."),
                    .init(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", text: "Erstelle das finale Archiv, prüfe die Signatur und dokumentiere die Prüfsumme."),
                ],
                terms: ["TypeWhisper", "Fastlane", "SwiftUI", "App Store Connect", "Release-Kandidat"],
                corrections: [
                    .init(original: "Type Whisper", replacement: "TypeWhisper"),
                    .init(original: "Fast Lane", replacement: "Fastlane"),
                    .init(original: "Swift UI", replacement: "SwiftUI"),
                ],
                snippets: [
                    .init(trigger: "/danke", replacement: "Danke für das ausführliche Feedback — ich schaue es mir heute an."),
                    .init(trigger: "/meeting", replacement: "Besprechungsnotizen vom {date}:\n\n- Entscheidung\n- Verantwortlich\n- Nächster Schritt"),
                    .init(trigger: "/release", replacement: "Der Release-Kandidat ist bereit für das finale Review."),
                ],
                workflows: [
                    .init(name: "Diktat glätten", template: .cleanedText, trigger: .global(), instruction: "Formuliere direkt und behalte Produktnamen bei."),
                    .init(name: "Besprechungsnotizen", template: .meetingNotes, trigger: .app("com.apple.Notes"), instruction: "Extrahiere Entscheidungen, Verantwortliche und nächste Schritte."),
                    .init(name: "Ins Englische übersetzen", template: .translation, trigger: .manual(), instruction: "Übersetze natürlich ins Englische."),
                ]
            )

        case .japanese:
            ScreenshotFixtureContent(
                history: [
                    .init(appName: "メモ", bundleIdentifier: "com.apple.Notes", text: "リリースノートを仕上げ、公開前にすべての言語のスクリーンショットを確認する。"),
                    .init(appName: "メール", bundleIdentifier: "com.apple.mail", text: "明日のレビューまでに、更新したローンチ概要をチームへ送ってください。"),
                    .init(appName: "Safari", bundleIdentifier: "com.apple.Safari", text: "対応するすべての言語で製品ページを比較し、最終フィードバックをまとめる。"),
                    .init(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", text: "macOSのテストを実行し、リリースビルドに警告がないことを確認する。"),
                    .init(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", text: "候補版の準備ができました。リリースを止める問題があれば報告してください。"),
                    .init(appName: "Pages", bundleIdentifier: "com.apple.iWork.Pages", text: "会議メモを決定事項、担当者、次のステップに整理する。"),
                    .init(appName: "ターミナル", bundleIdentifier: "com.apple.Terminal", text: "最終アーカイブを作成し、署名を確認してチェックサムを記録する。"),
                ],
                terms: ["TypeWhisper", "Fastlane", "SwiftUI", "App Store Connect", "リリース候補"],
                corrections: [
                    .init(original: "タイプウィスパー", replacement: "TypeWhisper"),
                    .init(original: "ファストレーン", replacement: "Fastlane"),
                    .init(original: "スウィフトUI", replacement: "SwiftUI"),
                ],
                snippets: [
                    .init(trigger: "/arigato", replacement: "詳しいフィードバックをありがとうございます。今日中に確認します。"),
                    .init(trigger: "/kaigi", replacement: "{date} の会議メモ:\n\n- 決定事項\n- 担当者\n- 次のステップ"),
                    .init(trigger: "/release", replacement: "リリース候補版は最終レビューの準備ができています。"),
                ],
                workflows: [
                    .init(name: "音声入力を整える", template: .cleanedText, trigger: .global(), instruction: "簡潔な文体に整え、製品名は変更しない。"),
                    .init(name: "会議メモ", template: .meetingNotes, trigger: .app("com.apple.Notes"), instruction: "決定事項、担当者、次のステップを抽出する。"),
                    .init(name: "英語に翻訳", template: .translation, trigger: .manual(), instruction: "自然な英語に翻訳する。"),
                ]
            )

        case .simplifiedChinese:
            ScreenshotFixtureContent(
                history: [
                    .init(appName: "备忘录", bundleIdentifier: "com.apple.Notes", text: "完成发布说明，并在发布前检查所有语言的截图。"),
                    .init(appName: "邮件", bundleIdentifier: "com.apple.mail", text: "请在明天评审之前把更新后的发布摘要发送给团队。"),
                    .init(appName: "Safari", bundleIdentifier: "com.apple.Safari", text: "比较所有支持语言的产品页面，并整理最终反馈。"),
                    .init(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", text: "运行 macOS 测试并确认发布版本没有警告。"),
                    .init(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", text: "候选版本已经准备好，如有阻止发布的问题请及时报告。"),
                    .init(appName: "Pages", bundleIdentifier: "com.apple.iWork.Pages", text: "把会议记录整理为决定事项、负责人和后续步骤。"),
                    .init(appName: "终端", bundleIdentifier: "com.apple.Terminal", text: "创建最终归档，验证签名并记录校验和。"),
                ],
                terms: ["TypeWhisper", "Fastlane", "SwiftUI", "App Store Connect", "候选版本"],
                corrections: [
                    .init(original: "因该", replacement: "应该"),
                    .init(original: "在次", replacement: "再次"),
                    .init(original: "帐户", replacement: "账户"),
                ],
                snippets: [
                    .init(trigger: "/ganxie", replacement: "感谢你的详细反馈，我会在今天查看。"),
                    .init(trigger: "/huiyi", replacement: "{date} 会议记录：\n\n- 决定事项\n- 负责人\n- 后续步骤"),
                    .init(trigger: "/fabu", replacement: "候选版本已准备好进行最终评审。"),
                ],
                workflows: [
                    .init(name: "润色听写", template: .cleanedText, trigger: .global(), instruction: "保持表达直接，并保留产品名称。"),
                    .init(name: "会议记录", template: .meetingNotes, trigger: .app("com.apple.Notes"), instruction: "提取决定事项、负责人和后续步骤。"),
                    .init(name: "翻译成英语", template: .translation, trigger: .manual(), instruction: "自然地翻译成英语。"),
                ]
            )
        }
    }
}

private struct ScreenshotFixtureContent {
    let history: [ScreenshotHistorySample]
    let terms: [String]
    let corrections: [ScreenshotCorrectionSample]
    let snippets: [ScreenshotSnippetSample]
    let workflows: [ScreenshotWorkflowSample]
}

private struct ScreenshotHistorySample {
    let appName: String
    let bundleIdentifier: String
    let text: String
}

private struct ScreenshotCorrectionSample {
    let original: String
    let replacement: String
}

private struct ScreenshotSnippetSample {
    let trigger: String
    let replacement: String
}

private struct ScreenshotWorkflowSample {
    let name: String
    let template: WorkflowTemplate
    let trigger: WorkflowTrigger
    let instruction: String
}
#endif
