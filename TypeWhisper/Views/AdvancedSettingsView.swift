import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @ObservedObject private var viewModel = APIServerViewModel.shared
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var errorLogService = ServiceContainer.shared.errorLogService
    @State private var cliInstalled = false
    @State private var cliSymlinkTarget = ""
    @State private var raycastExtensionInstalled = false
    @AppStorage(UserDefaultsKeys.browserExtensionConnected) private var browserExtensionConnected = false
    @State private var showClearUsageStatisticsConfirmation = false
    @State private var showDiagnosticsExportError = false
    @State private var diagnosticsExportErrorMessage = ""
    @StateObject private var copyConfirmation = ActionConfirmation(duration: .seconds(2))
    @StateObject private var diagnosticsExportConfirmation = ActionConfirmation(duration: .seconds(4))

    @State private var showBackupError = false
    @State private var backupErrorMessage = ""
    @State private var showBackupImportResult = false
    @State private var backupImportResultMessage = ""
    @State private var isImportingBackup = false
    @State private var exportBackupDraft: ExportBackupDraft?
    @State private var showImportSheet = false
    @State private var isExportingAllData = false
    @State private var isDeletingAllData = false
    @State private var showDeleteAllDataConfirmation = false

    private var browserExtensionInfoText: String {
        if browserExtensionConnected {
            return localizedAppText(
                "A browser extension has connected to dictum. It reports the active website, so website workflows match the page you are on.",
                de: "Eine Browser-Erweiterung hat sich mit dictum verbunden. Sie meldet die aktive Website, damit Website-Workflows zur geöffneten Seite passen."
            )
        }
        return localizedAppText(
            "Dictate into text fields in Chrome and Firefox, and let website workflows match the page you are on. Requires the API server to be running.",
            de: "Diktiere in Textfelder in Chrome und Firefox und lass Website-Workflows zur geöffneten Seite passen. Der API-Server muss laufen."
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "Advanced"))
            Divider()

            Form {
                // MARK: - Support Diagnostics
                Section(localizedAppText("Support Diagnostics", de: "Support-Diagnose")) {
                HStack {
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label(
                            localizedAppText("Export Diagnostics", de: "Diagnose exportieren"),
                            systemImage: "square.and.arrow.up"
                        )
                    }

                    SettingsInfoButton(text: localizedAppText(
                        "Creates a JSON support report with app, system, permission, plugin, settings and audio device diagnostics.",
                        de: "Erstellt einen JSON-Supportbericht mit App-, System-, Berechtigungs-, Plugin-, Einstellungs- und Audiogeräte-Diagnose."
                    ), topic: localizedAppText("Export Diagnostics", de: "Diagnose exportieren"))

                    if let message = diagnosticsExportConfirmation.message {
                        ActionConfirmationLabel(message: message)
                    }
                }
            }

                // MARK: - Backup & Restore
                Section(localizedAppText("Backup & Restore", de: "Sicherung & Wiederherstellung")) {
                HStack {
                    Button {
                        beginExport()
                    } label: {
                        Label(
                            localizedAppText("Export Settings", de: "Einstellungen exportieren"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(isImportingBackup || isDeletingAllData)

                    Button {
                        showImportSheet = true
                    } label: {
                        Label(
                            localizedAppText("Import Settings", de: "Einstellungen importieren"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .disabled(isImportingBackup || isDeletingAllData || isExportingAllData)

                    if isImportingBackup {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(localizedAppText(
                                "Importing settings",
                                de: "Einstellungen werden importiert",
                                ja: "設定を読み込み中",
                                zh: "正在导入设置"
                            ))
                    }

                    SettingsInfoButton(text: localizedAppText(
                        "Exports workflows, dictionary entries, snippets, profiles, prompt actions, hotkeys, plugin settings, transcription history without audio, and app preferences to a file you can import on another Mac. Provider API keys, downloaded models, Launch at Login, and other machine-specific settings are not included.",
                        de: "Exportiert Workflows, Wörterbucheinträge, Snippets, Profile, Prompt-Aktionen, Hotkeys, Plugin-Einstellungen, Transkriptionsverlauf ohne Audio und App-Einstellungen in eine Datei für einen anderen Mac. Anbieter-API-Schlüssel, heruntergeladene Modelle, „Bei Anmeldung öffnen“ und andere gerätespezifische Einstellungen sind nicht enthalten.",
                        ja: "ワークフロー、辞書、スニペット、プロファイル、プロンプト操作、ホットキー、プラグイン設定、音声を含まない履歴、アプリ設定を別のMacに読み込めるファイルに書き出します。APIキー、ダウンロードしたモデル、ログイン時に開く設定などの端末固有設定は含まれません。",
                        zh: "将工作流、词典、快捷短语、配置、提示操作、快捷键、插件设置、不含音频的转录历史和应用偏好导出为文件，可在其他 Mac 上导入。不包含提供商 API 密钥、已下载模型、登录时启动等本机设置。"
                    ), topic: localizedAppText("Backup & Restore", de: "Sicherung & Wiederherstellung"))
                }
            }

                // MARK: - Your Data
                Section(localizedAppText("Your Data", de: "Deine Daten", ja: "あなたのデータ", zh: "你的数据")) {
                HStack {
                    Button {
                        exportAllData()
                    } label: {
                        Label(
                            localizedAppText("Export All Data", de: "Alle Daten exportieren"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(isExportingAllData || isDeletingAllData || isImportingBackup)

                    Button(role: .destructive) {
                        showDeleteAllDataConfirmation = true
                    } label: {
                        Label(
                            localizedAppText("Delete All Data…", de: "Alle Daten löschen…"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(isExportingAllData || isDeletingAllData || isImportingBackup)

                    if isExportingAllData || isDeletingAllData {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(isDeletingAllData
                                ? localizedAppText("Deleting all data", de: "Alle Daten werden gelöscht", ja: "すべてのデータを削除中", zh: "正在删除所有数据")
                                : localizedAppText("Exporting all data", de: "Alle Daten werden exportiert", ja: "すべてのデータを書き出し中", zh: "正在导出所有数据"))
                    }

                    SettingsInfoButton(text: localizedAppText(
                        "Export creates a ZIP archive with everything dictum stores on this Mac: history with saved audio, dictionary, snippets, workflows, profiles, plugin data, logs, all preferences and an importable settings backup. API keys, downloaded and imported models and installed plugins are not included. Delete removes all of this data from this Mac, including API keys and downloaded and imported models, and quits dictum.",
                        de: "Der Export erstellt ein ZIP-Archiv mit allem, was dictum auf diesem Mac speichert: Verlauf mit gespeicherten Audioaufnahmen, Wörterbuch, Snippets, Workflows, Profile, Plugin-Daten, Protokolle, alle Einstellungen und eine importierbare Einstellungssicherung. API-Schlüssel, heruntergeladene und importierte Modelle sowie installierte Plugins sind nicht enthalten. Löschen entfernt all diese Daten von diesem Mac, auch API-Schlüssel sowie heruntergeladene und importierte Modelle, und beendet dictum."
                    ), topic: localizedAppText("Your Data", de: "Deine Daten", ja: "あなたのデータ", zh: "你的数据"))
                }
                .confirmationDialog(
                    localizedAppText("Delete All Data?", de: "Alle Daten löschen?"),
                    isPresented: $showDeleteAllDataConfirmation
                ) {
                    Button(localizedAppText("Delete All Data and Quit", de: "Alle Daten löschen und beenden"), role: .destructive) {
                        deleteAllData()
                    }
                } message: {
                    Text(localizedAppText(
                        "dictum deletes its history and audio, dictionary, snippets, workflows, profiles, settings, plugins, downloaded and imported models and API keys on this Mac, then quits. Imported models are not part of the data export. Data in iCloud, a cloud sync folder, on other devices and recordings saved by the recorder stay untouched. This cannot be undone.",
                        de: "dictum löscht Verlauf und Audioaufnahmen, Wörterbuch, Snippets, Workflows, Profile, Einstellungen, Plugins, heruntergeladene und importierte Modelle und API-Schlüssel auf diesem Mac und beendet sich danach. Importierte Modelle sind nicht im Datenexport enthalten. Daten in iCloud, in einem Cloud-Sync-Ordner, auf anderen Geräten und vom Recorder gespeicherte Aufnahmen bleiben erhalten. Das kann nicht rückgängig gemacht werden."
                    ))
                }
            }


                // MARK: - Recording
                Section(String(localized: "Recording")) {
                Picker(selection: Binding(
                    get: { modelManager.autoUnloadSeconds },
                    set: { modelManager.autoUnloadSeconds = $0 }
                )) {
                    Text(String(localized: "Never")).tag(0)
                    Divider()
                    Text(String(localized: "Immediate")).tag(-1)
                    Text(String(localized: "After 2 minutes")).tag(120)
                    Text(String(localized: "After 5 minutes")).tag(300)
                    Text(String(localized: "After 10 minutes")).tag(600)
                    Text(String(localized: "After 30 minutes")).tag(1800)
                    Text(String(localized: "After 1 hour")).tag(3600)
                } label: {
                    SettingsInfoLabel(
                        title: String(localized: "Auto-unload model"),
                        info: String(localized: "Automatically unloads local models from memory after inactivity. It reloads when needed. Does not affect cloud engines.")
                    )
                }

                Toggle(isOn: $dictation.transcribeShortQuietClipsAggressively) {
                    SettingsInfoLabel(
                        title: String(localized: "Transcribe short / quiet clips more aggressively"),
                        info: String(localized: "Still discards accidental ultra-short taps, but keeps more very short or quiet recordings instead of classifying them as no speech.")
                    )
                }

                Picker(selection: $dictation.cancellationBehavior) {
                    ForEach(CancellationBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                } label: {
                    SettingsInfoLabel(
                        title: String(localized: "Cancellation behavior"),
                        info: String(localized: "Double: press Esc twice to cancel. Single: press Esc once. Both show a cancellation banner for 1.5 seconds. Instant: press Esc once without a banner. Disabled: Esc never cancels and passes through to the app. Applies to recording and processing.")
                    )
                }

                // Live updates write into other apps through the Accessibility API.
                Toggle(isOn: $dictation.liveFieldTranscriptEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Show live transcript in the active text field"),
                        info: String(localized: "Supported text fields are updated while you speak. The field focused when recording starts remains the final insertion target, including apps that require paste. If it can no longer be restored safely, the final transcript remains in Recent Transcriptions.")
                    )
                }

                Toggle(isOn: $dictation.microphoneBoostEnabled) {
                    SettingsInfoLabel(
                        title: localizedAppText("Whisper Mode (AGC)", de: "Whisper-Modus (AGC)"),
                        info: localizedAppText(
                            "Automatically raises quiet microphone input before transcription. Useful for low-gain microphones, but very noisy rooms may sound louder too.",
                            de: "Hebt leise Mikrofoneingaben vor der Transkription automatisch an. Hilft bei Mikrofonen mit niedrigem Pegel, kann in lauten Räumen aber auch Störgeräusche verstärken."
                        )
                    )
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        if workflowService.shortTranscriptionMinimumWords > 0 {
                            Text(localizedAppText("under", de: "unter"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        TextField(
                            "",
                            value: $workflowService.shortTranscriptionMinimumWords,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(localizedAppText("Minimum words", de: "Mindestanzahl Wörter"))

                        Text(workflowService.shortTranscriptionMinimumWords == 0
                             ? localizedAppText("Off", de: "Aus")
                             : localizedAppText("words", de: "Wörtern"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                } label: {
                    SettingsInfoLabel(
                        title: localizedAppText(
                            "Skip AI post-processing",
                            de: "KI-Nachbearbeitung überspringen"
                        ),
                        info: localizedAppText(
                            "For short dictations, the matched workflow still controls output and actions, but the AI enhancement step is skipped. Values are limited to 0-10 words; 0 disables the skip.",
                            de: "Bei kurzen Diktaten steuert der erkannte Workflow weiterhin Ausgabe und Aktionen, aber die KI-Nachbearbeitung wird übersprungen. Werte sind auf 0-10 Wörter begrenzt; 0 deaktiviert das Überspringen."
                        )
                    )
                }

            }

                SpokenPunctuationSettingsSection()

                Section(String(localized: "Usage Statistics")) {
                    Button(role: .destructive) {
                        showClearUsageStatisticsConfirmation = true
                    } label: {
                        Label(String(localized: "Clear Usage Statistics"), systemImage: "trash")
                    }
                    .confirmationDialog(
                        String(localized: "Clear Usage Statistics?"),
                        isPresented: $showClearUsageStatisticsConfirmation
                    ) {
                        Button(String(localized: "Clear Statistics"), role: .destructive) {
                            ServiceContainer.shared.usageStatisticsService.clearUsageStatistics()
                        }
                    } message: {
                        Text(String(localized: "This will permanently delete aggregate word, app, time-saved, and activity statistics. Transcription history entries are unchanged."))
                    }
                }

                // MARK: - API Server
                Section(String(localized: "API Server")) {
                Toggle(isOn: $viewModel.isEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Enable API Server"),
                        info: String(localized: "Advanced automation interface for local tools. Disabled by default and bound to 127.0.0.1 only.")
                    )
                }
                    .onChange(of: viewModel.isEnabled) { _, enabled in
                        if enabled {
                            viewModel.startServer()
                        } else {
                            viewModel.stopServer()
                        }
                    }

                Toggle(isOn: $viewModel.requiresAuthentication) {
                    SettingsInfoLabel(
                        title: String(localized: "Require API Token"),
                        info: localizedAppText(
                            "Clients must send the API token as a bearer token. The command line tool, the Raycast extension and other local tools read it from api-discovery.json in dictum's Application Support folder.",
                            de: "Clients müssen den API-Token als Bearer-Token mitschicken. Das Kommandozeilen-Tool, die Raycast-Erweiterung und andere lokale Tools lesen ihn aus api-discovery.json im Application-Support-Ordner von dictum.",
                            ja: "クライアントは API トークンを Bearer トークンとして送信する必要があります。コマンドラインツール、Raycast 拡張機能、その他のローカルツールは、dictum の Application Support フォルダにある api-discovery.json からトークンを読み取ります。",
                            zh: "客户端必须以 Bearer 令牌的形式发送 API 令牌。命令行工具、Raycast 扩展和其他本地工具会从 dictum 的 Application Support 文件夹中的 api-discovery.json 读取令牌。"
                        )
                    )
                }

                if viewModel.isEnabled && !viewModel.requiresAuthentication {
                    Label(
                        localizedAppText(
                            "Without a token, any app on this Mac can start dictation and read your history and settings through the API.",
                            de: "Ohne Token kann jede App auf diesem Mac über die API Diktate starten und deinen Verlauf und deine Einstellungen lesen.",
                            ja: "トークンがない場合、この Mac 上のどのアプリでも API を通じて音声入力を開始し、履歴や設定を読み取れます。",
                            zh: "没有令牌时，这台 Mac 上的任何应用都可以通过 API 开始听写并读取你的历史记录和设置。"
                        ),
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }

                if viewModel.isRunning && viewModel.requiresAuthentication, let apiToken = viewModel.currentAPIToken {
                    HStack {
                        Button(localizedAppText("Copy API Token", de: "API-Token kopieren", ja: "API トークンをコピー", zh: "复制 API 令牌")) {
                            copyToPasteboard(apiToken, source: Self.apiTokenCopySource)
                        }

                        if let message = copyConfirmation.message(for: Self.apiTokenCopySource) {
                            ActionConfirmationLabel(message: message)
                        }
                    }
                }

                if viewModel.isEnabled {
                    let serverStatus = viewModel.isRunning
                        ? String(localized: "Running on port \(String(viewModel.port))")
                        : String(localized: "Not running")
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(viewModel.isRunning ? .green : .orange)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(serverStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    // The status line has no visible subject; name it so
                    // "Not running" is not read out of context.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(localizedAppText(
                        "API server status",
                        de: "Status des API-Servers",
                        ja: "API サーバーの状態",
                        zh: "API 服务器状态"
                    ))
                    .accessibilityValue(serverStatus)

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .accessibilityLabel(String(localized: "Error: \(error)"))
                    }
                }
            }

                // MARK: - Command Line Tool
                Section(String(localized: "Command Line Tool")) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(cliInstalled ? .green : .orange)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    if cliInstalled {
                        Text(String(localized: "Installed at /usr/local/bin/typewhisper"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Not installed"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(localizedAppText(
                    "Command line tool status",
                    de: "Status des Kommandozeilen-Tools",
                    ja: "コマンドラインツールの状態",
                    zh: "命令行工具状态"
                ))
                .accessibilityValue(cliInstalled
                    ? String(localized: "Installed at /usr/local/bin/typewhisper")
                    : String(localized: "Not installed"))

                if cliInstalled {
                    Button(String(localized: "Uninstall")) {
                        uninstallCLI()
                    }
                    .accessibilityLabel(localizedAppText(
                        "Uninstall command line tool",
                        de: "Kommandozeilen-Tool deinstallieren",
                        ja: "コマンドラインツールをアンインストール",
                        zh: "卸载命令行工具"
                    ))
                } else {
                    HStack {
                        Button(String(localized: "Install Command Line Tool")) {
                            installCLI()
                        }

                        SettingsInfoButton(
                            text: String(localized: "Requires the API server to be running. The CLI tool connects to dictum's API for fast transcription without model cold starts."),
                            topic: String(localized: "Command Line Tool")
                        )
                    }
                }
            }

                // MARK: - Usage Examples
                if viewModel.isEnabled {
                    Section(String(localized: "Usage Examples")) {
                    if cliInstalled {
                        cliExamples
                    } else {
                        curlExamples
                    }
                    }
                }

                // MARK: - Integrations
                Section(String(localized: "Integrations")) {
                let raycastTitle = String(localized: "Raycast Extension")
                integrationRow(systemImage: "command.square", title: raycastTitle) {
                    if raycastExtensionInstalled {
                        HStack {
                            Button(String(localized: "Open in Raycast")) {
                                NSWorkspace.shared.open(DictumRaycastExtension.openURL)
                            }

                            SettingsInfoButton(
                                text: DictumRaycastExtension.infoText,
                                topic: raycastTitle
                            )
                        }
                    } else {
                        HStack {
                            Button(String(localized: "Learn More")) {
                                NSWorkspace.shared.open(DictumRaycastExtension.repositoryURL)
                            }
                            .accessibilityLabel(learnMoreAccessibilityLabel(about: raycastTitle))

                            SettingsInfoButton(
                                text: String(localized: "dictum works with Raycast. Start dictation and more directly from your launcher. Requires the API server to be running."),
                                topic: raycastTitle
                            )
                        }
                    }
                }

                let browserExtensionTitle = localizedAppText("Browser Extension", de: "Browser-Erweiterung", ja: "ブラウザ拡張機能", zh: "浏览器扩展")
                integrationRow(systemImage: "globe", title: browserExtensionTitle) {
                    HStack {
                        SettingsInfoButton(text: browserExtensionInfoText, topic: browserExtensionTitle)
                    }
                }

                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            raycastExtensionInstalled = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.raycast.macos"
            ) != nil && DictumRaycastExtension.isInstalled()
            checkCLIInstallation()
        }
        .alert(localizedAppText("Export Failed", de: "Export fehlgeschlagen"), isPresented: $showDiagnosticsExportError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(diagnosticsExportErrorMessage)
        }
        .alert(localizedAppText("Backup Failed", de: "Sicherung fehlgeschlagen"), isPresented: $showBackupError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(backupErrorMessage)
        }
        .alert(localizedAppText("Import Complete", de: "Import abgeschlossen"), isPresented: $showBackupImportResult) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(backupImportResultMessage)
        }
        .sheet(item: $exportBackupDraft) { draft in
            BackupExportSheet(backup: draft.backup) { categories in
                performBackupExport(draft.backup, categories: categories)
            }
        }
        .sheet(isPresented: $showImportSheet) {
            BackupImportSheet { backup, categories, mode in
                isImportingBackup = true
                Task {
                    await performBackupImport(backup, categories: categories, mode: mode)
                    isImportingBackup = false
                }
            }
        }
    }

    // MARK: - Integrations

    /// One integration with its decorative icon hidden; grouped under its
    /// name so VoiceOver announces which integration a "Learn More" belongs to.
    private func integrationRow<Content: View>(
        systemImage: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)

                content()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func learnMoreAccessibilityLabel(about title: String) -> String {
        localizedAppText(
            "Learn More about \(title)",
            de: "Mehr erfahren: \(title)",
            ja: "\(title)の詳細を見る",
            zh: "进一步了解\(title)"
        )
    }

    // MARK: - Examples

    private var cliExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Show help:"), "typewhisper --help")
            Divider()
            exampleRow(String(localized: "Check status:"), "typewhisper status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "typewhisper transcribe audio.wav")
            Divider()
            exampleRow(String(localized: "Transcribe with language:"), "typewhisper transcribe audio.wav --language de")
            Divider()
            exampleRow(String(localized: "JSON output:"), "typewhisper transcribe audio.wav --json")
            Divider()
            exampleRow(String(localized: "Pipe to clipboard:"), "typewhisper transcribe audio.wav | pbcopy")
            Divider()
            exampleRow(String(localized: "List models:"), "typewhisper models")
        }
    }

    private var curlExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.requiresAuthentication {
                exampleRow(
                    localizedAppText("Read the API token:", de: "API-Token auslesen:", ja: "API トークンを読み取る:", zh: "读取 API 令牌："),
                    "export TYPEWHISPER_API_TOKEN=\"$(jq -r .token \"\(apiDiscoveryFilePath)\")\""
                )
                Divider()
            }
            exampleRow(String(localized: "Check status:"), "curl http://127.0.0.1:\(viewModel.port)/v1/status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "curl -X POST http://127.0.0.1:\(viewModel.port)/v1/transcribe \(curlAuthorizationArgument)\\\n  -F \"file=@audio.wav\"")
            Divider()
            exampleRow(String(localized: "List models:"), "curl \(curlAuthorizationArgument)http://127.0.0.1:\(viewModel.port)/v1/models")
        }
    }

    private var apiDiscoveryFilePath: String {
        AppConstants.appSupportDirectory.appendingPathComponent("api-discovery.json").path
    }

    private var curlAuthorizationArgument: String {
        viewModel.requiresAuthentication ? "-H \"Authorization: Bearer $TYPEWHISPER_API_TOKEN\" " : ""
    }

    private func exampleRow(_ label: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                if let message = copyConfirmation.message(for: command) {
                    ActionConfirmationLabel(message: message)
                }
                Button {
                    copyToPasteboard(command, source: command)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy"))
                .accessibilityLabel(copyCommandAccessibilityLabel(for: label))
            }
        }
    }

    /// "Copy Check status command" instead of a row of identical "Copy" buttons.
    private func copyCommandAccessibilityLabel(for label: String) -> String {
        let name = label.trimmingCharacters(in: CharacterSet(charactersIn: ":：").union(.whitespaces))
        return localizedAppText(
            "Copy \(name) command",
            de: "Befehl „\(name)“ kopieren",
            ja: "「\(name)」のコマンドをコピー",
            zh: "复制“\(name)”命令"
        )
    }

    private static let apiTokenCopySource = "api-token"

    /// Confirms the copy next to the button that did it, and for VoiceOver.
    private func copyToPasteboard(_ string: String, source: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        copyConfirmation.show(String(localized: "Copied to clipboard"), source: source)
    }

    // MARK: - Support Diagnostics

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = localizedAppText("Export Diagnostics", de: "Diagnose exportieren")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = diagnosticsFilename()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await errorLogService.exportDiagnostics(to: url)
                    diagnosticsExportConfirmation.show(
                        String(localized: "Diagnostics exported to \(url.lastPathComponent)")
                    )
                } catch {
                    diagnosticsExportErrorMessage = error.localizedDescription
                    showDiagnosticsExportError = true
                }
            }
        }
    }

    private func diagnosticsFilename() -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "typewhisper-diagnostics-\(timestamp).json"
    }

    // MARK: - Backup & Restore

    /// Builds a snapshot of the current live state and opens the category
    /// selection sheet. The backup is built eagerly (rather than in the
    /// sheet's `onExport` callback) so the sheet can show per-category counts
    /// right away.
    private func beginExport() {
        let container = ServiceContainer.shared
        do {
            let backup = try SettingsBackupExporter.buildBackup(
                workflowService: container.workflowService,
                dictionaryService: container.dictionaryService,
                snippetService: container.snippetService,
                profileService: container.profileService,
                promptActionService: container.promptActionService,
                pluginManager: container.pluginManager,
                historyService: container.historyService
            )
            exportBackupDraft = ExportBackupDraft(backup: backup)
        } catch {
            backupErrorMessage = error.localizedDescription
            showBackupError = true
        }
    }

    private func performBackupExport(_ backup: SettingsBackupExporter.SettingsBackup, categories: Set<SettingsBackupExporter.Category>) {
        guard let url = SettingsBackupExporter.presentSavePanel() else { return }
        do {
            try SettingsBackupExporter.saveToFile(SettingsBackupExporter.filtered(backup, to: categories), to: url)
        } catch {
            backupErrorMessage = error.localizedDescription
            showBackupError = true
        }
    }

    private func performBackupImport(
        _ backup: SettingsBackupExporter.SettingsBackup,
        categories: Set<SettingsBackupExporter.Category>,
        mode: SettingsBackupExporter.ImportMode
    ) async {
        let container = ServiceContainer.shared
        let result = await SettingsBackupExporter.importBackup(
            SettingsBackupExporter.filtered(backup, to: categories),
            mode: mode,
            workflowService: container.workflowService,
            dictionaryService: container.dictionaryService,
            snippetService: container.snippetService,
            profileService: container.profileService,
            promptActionService: container.promptActionService,
            pluginManager: container.pluginManager,
            historyService: container.historyService,
            usageStatisticsService: container.usageStatisticsService,
            liveFieldTranscriptEnabledDidChange: { enabled in
                dictation.liveFieldTranscriptEnabled = enabled
            },
            cancellationBehaviorDidChange: { behavior in
                dictation.cancellationBehavior = behavior
            },
            indicatorThemeDidChange: { theme in
                dictation.indicatorTheme = theme
            },
            recoveryRetentionPolicyDidChange: { policy in
                _ = container.audioRecordingService.updateRecoveryRetentionPolicy(policy)
            },
            dictationRecoveryPreferencesDidChange: {
                DictationRecoveryViewModel.shared.reloadPreferencesFromDefaults()
            },
            hotkeysDidChange: {
                dictation.reloadHotkeysFromDefaults()
            }
        )

        backupImportResultMessage = backupImportSummary(result)
        showBackupImportResult = true
    }

    private func backupImportSummary(_ result: SettingsBackupExporter.ImportResult) -> String {
        var lines: [String] = []
        lines.append(String(format: String(localized: "Workflows: %d imported"), result.workflowsImported))
        appendUpdatedAndSkipped(
            to: &lines,
            updated: result.workflowsUpdated,
            skipped: result.workflowsSkipped,
            category: String(localized: "Workflows")
        )
        lines.append(String(format: String(localized: "Dictionary: %d imported, %d skipped (already present)"), result.dictionaryImported, result.dictionarySkipped))
        lines.append(String(format: String(localized: "Snippets: %d imported, %d skipped (already present)"), result.snippetsImported, result.snippetsSkipped))
        lines.append(String(format: String(localized: "Prompt Actions: %d imported"), result.promptActionsImported))
        appendUpdatedAndSkipped(
            to: &lines,
            updated: result.promptActionsUpdated,
            skipped: result.promptActionsSkipped,
            category: String(localized: "Prompt Actions")
        )
        lines.append(String(format: String(localized: "Profiles: %d imported"), result.profilesImported))
        appendUpdatedAndSkipped(
            to: &lines,
            updated: result.profilesUpdated,
            skipped: result.profilesSkipped,
            category: String(localized: "Profiles")
        )
        lines.append(String(format: String(localized: "Hotkeys: %d applied, %d skipped (already bound)"), result.hotkeysApplied, result.hotkeysSkipped))
        lines.append(String(format: localizedAppText(
            "Plugins: %d configured, %d unavailable",
            de: "Plugins: %d konfiguriert, %d nicht verfügbar",
            ja: "プラグイン: %d件を設定、%d件は利用不可",
            zh: "插件：已配置 %d 个，%d 个不可用"
        ), result.pluginsConfigured, result.pluginsSkipped))
        lines.append(String(format: String(localized: "History: %d imported"), result.historyImported))
        if result.historySkippedByRetention > 0 {
            lines.append(String(format: String(localized: "History: %d skipped (older than your retention setting)"), result.historySkippedByRetention))
        }
        if result.historySkippedUnreadableDestination > 0 {
            lines.append(String(format: localizedAppText(
                "History: %d skipped (the existing history could not be read)",
                de: "Verlauf: %d übersprungen (der vorhandene Verlauf konnte nicht gelesen werden)",
                ja: "履歴: %d件をスキップ（既存の履歴を読み込めませんでした）",
                zh: "历史记录：已跳过 %d 条（无法读取现有历史记录）"
            ), result.historySkippedUnreadableDestination))
        }
        if result.historySkippedAsDuplicate > 0 {
            lines.append(String(format: localizedAppText(
                "History: %d skipped (already present)",
                de: "Verlauf: %d übersprungen (bereits vorhanden)",
                ja: "履歴: %d件をスキップ（登録済み）",
                zh: "历史记录：已跳过 %d 条（已存在）"
            ), result.historySkippedAsDuplicate))
        }
        if result.preferencesApplied > 0 {
            lines.append(String(format: String(localized: "Preferences: %d applied"), result.preferencesApplied))
        }
        return lines.joined(separator: "\n")
    }

    private func appendUpdatedAndSkipped(to lines: inout [String], updated: Int, skipped: Int, category: String) {
        guard updated > 0 || skipped > 0 else { return }
        lines.append(String(format: localizedAppText(
            "%@: %d updated, %d skipped (already present)",
            de: "%@: %d aktualisiert, %d übersprungen (bereits vorhanden)",
            ja: "%@: %d件を更新、%d件をスキップ（登録済み）",
            zh: "%@：已更新 %d 个，跳过 %d 个（已存在）"
        ), category, updated, skipped))
    }

    // MARK: - Your Data

    private func exportAllData() {
        guard let url = UserDataExportService.presentSavePanel() else { return }
        let container = ServiceContainer.shared
        let settingsBackup: Data
        do {
            settingsBackup = try SettingsBackupExporter.encodedJSON(SettingsBackupExporter.buildBackup(
                workflowService: container.workflowService,
                dictionaryService: container.dictionaryService,
                snippetService: container.snippetService,
                profileService: container.profileService,
                promptActionService: container.promptActionService,
                pluginManager: container.pluginManager,
                historyService: container.historyService
            ))
        } catch {
            backupErrorMessage = error.localizedDescription
            showBackupError = true
            return
        }

        isExportingAllData = true
        Task {
            defer { isExportingAllData = false }
            do {
                try await UserDataExportService.export(to: url, settingsBackup: settingsBackup)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                backupErrorMessage = error.localizedDescription
                showBackupError = true
            }
        }
    }

    private func deleteAllData() {
        isDeletingAllData = true
        Task {
            let failures = await UserDataEraser.prepareForErase(
                apiServer: viewModel,
                container: ServiceContainer.shared
            )
            UserDataEraser.eraseAllAndQuit(earlierFailures: failures)
        }
    }

    // MARK: - CLI Installation

    private static let symlinkPath = "/usr/local/bin/typewhisper"

    private var cliBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/typewhisper-cli").path
    }

    private func checkCLIInstallation() {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: Self.symlinkPath) else {
            cliInstalled = false
            return
        }
        cliSymlinkTarget = dest
        cliInstalled = dest == cliBinaryPath
    }

    private func installCLI() {
        let target = cliBinaryPath
        let link = Self.symlinkPath
        let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf '\(target)' '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func uninstallCLI() {
        let link = Self.symlinkPath
        let script = """
            do shell script "rm -f '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func runOsascript(_ source: String, completion: @escaping @MainActor @Sendable () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.terminationHandler = { _ in
            Task { @MainActor in completion() }
        }
        try? process.run()
    }

}

/// Wraps a built `SettingsBackup` snapshot with a stable identity so the
/// export sheet can be driven by `.sheet(item:)` instead of a separate
/// `Bool` + optional pair — `.sheet(item:)` never presents until the item is
/// non-nil, which rules out the sheet ever appearing with no content to show.
private struct ExportBackupDraft: Identifiable {
    let id = UUID()
    let backup: SettingsBackupExporter.SettingsBackup
}

struct SettingsInfoLabel: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            SettingsInfoButton(text: info, topic: title)
        }
    }
}

struct SettingsInfoButton: View {
    let text: String
    /// What the button explains, e.g. the setting's title. VoiceOver and other
    /// assistive apps then hear "More information about Enable Memory" instead
    /// of a row of identical "More information" buttons.
    let topic: String?

    @State private var isPresented = false

    init(text: String, topic: String? = nil) {
        self.text = text
        self.topic = topic
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(infoAccessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300, alignment: .leading)
        }
    }

    private var infoAccessibilityLabel: String {
        guard let topic = topic?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty else {
            return localizedAppText("More information", de: "Weitere Informationen", ja: "詳細情報", zh: "更多信息")
        }
        return localizedAppText(
            "More information about \(topic)",
            de: "Weitere Informationen zu \(topic)",
            ja: "\(topic)の詳細情報",
            zh: "关于“\(topic)”的更多信息"
        )
    }
}
