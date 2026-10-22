import AppKit
import AVFoundation
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
        if ["indicator-settings", "indicator", "indicator-model-menu"].contains(AppConstants.screenshotState) {
            dictationViewModel.prepareScreenshotIndicatorFixture()
        }
        if AppConstants.screenshotState == "recorder-queue" {
            audioRecorderViewModel.prepareScreenshotQueueFixture()
        }
        if AppConstants.screenshotState == "recorder-meetings" {
            SettingsNavigationCoordinator.shared.recorderPart = .meetings
        }
        seedScreenshotRecorderFolders(state: AppConstants.screenshotState)

        if AppConstants.screenshotState != "correct-last-dictation-empty" {
            seedScreenshotHistory(content.history, languageCode: language.rawValue)
        }
        if AppConstants.screenshotState?.hasPrefix("correct-last-dictation") == true {
            prepareScreenshotLastDictationCorrection()
        }
        usageStatisticsService.replaceWithHistoryRecords(historyService.allRecords())
        seedScreenshotFileTranscriptionQueue(languageCode: language.rawValue)

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
        seedScreenshotLocalTermPacks()
        DictionaryViewModel.shared.filterTab = Self.termPackScreenshotStates.contains(AppConstants.screenshotState ?? "")
            ? .termPacks
            : .all
        pluginManager.setRuleNamesProvider { [weak self] in
            self?.workflowService.availableRuleNames ?? []
        }
        pluginManager.setWorkflowProvider { [weak self] in
            self?.workflowService.workflows.map(\.pluginWorkflowInfo) ?? []
        }
        seedScreenshotPluginSettings(language: language)
        // Screenshot runs skip initialize(), so apply the plugin restrictions and provider pairs of
        // an installed profile here, before the scan, as a normal launch does.
        pluginManager.applyProviderPolicy(ManagedProviderPolicy(snapshot: managedPolicyService.current))
        pluginManager.applySelectionPolicy(ManagedSelectionPolicy(snapshot: managedPolicyService.current))
        pluginManager.scanAndLoadPlugins()

        statisticsViewModel.refresh()
        homeViewModel.refresh()
    }

    /// Every screenshot run starts with the default Recorder folder, because runs share their
    /// preferences. In "recorder-folders", new recordings go to `~/Recordings`, and the default
    /// folder holds an earlier recording and stays listed. "recorder-folder-unavailable" removes
    /// `~/Recordings` again, as when its disk is disconnected.
    private func seedScreenshotRecorderFolders(state: String?) {
        for key in [
            UserDefaultsKeys.recorderFolderBookmark,
            UserDefaultsKeys.recorderFolderPath,
            UserDefaultsKeys.recorderEarlierFolders,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // The Recorder listed its recordings at launch, before the folders were reset or seeded.
        defer { audioRecorderViewModel.loadRecordings() }

        let chosenFolderIsGone = state == "recorder-folder-unavailable"
        // The fixture writes into the home folder, so only into a screenshot run's own home.
        guard state == "recorder-folders" || chosenFolderIsGone,
              ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { return }
        let fileManager = FileManager.default
        let chosenFolder = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true)
        let referenceDate = AppConstants.screenshotFixtureReferenceDate
        do {
            try writeScreenshotRecording(
                baseName: CalendarMeetingRecordingFilename.preferredBaseName(
                    title: "Team Sync",
                    date: referenceDate.addingTimeInterval(-6 * 86_400)
                ),
                in: recorderFolderStore.defaultDirectory,
                seconds: 42,
                createdAt: referenceDate.addingTimeInterval(-6 * 86_400)
            )
            try fileManager.createDirectory(at: chosenFolder, withIntermediateDirectories: true)
            try writeScreenshotRecording(
                baseName: CalendarMeetingRecordingFilename.preferredBaseName(title: "", date: referenceDate),
                in: chosenFolder,
                seconds: 95,
                createdAt: referenceDate
            )
            try recorderFolderStore.chooseFolder(chosenFolder)
            if chosenFolderIsGone {
                try fileManager.removeItem(at: chosenFolder)
                recorderFolderStore.refreshAvailability()
            }
        } catch {
            fputs("Could not seed the Recorder folder screenshot fixture: \(error)\n", stderr)
        }
    }

    private func writeScreenshotRecording(baseName: String, in folder: URL, seconds: Int, createdAt: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(baseName).appendingPathExtension("wav")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 16_000)) else {
            return
        }
        buffer.frameLength = buffer.frameCapacity
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
    }

    private func seedScreenshotPluginSettings(language: ScreenshotFixtureLanguage) {
        switch AppConstants.screenshotPluginId {
        case "com.typewhisper.obsidian":
            let vaultName = language == .german ? "Wissensbibliothek" : "Knowledge Library"
            UserDefaults.standard.set(
                "/Users/demo/Documents/Obsidian/\(vaultName)",
                forKey: "plugin.com.typewhisper.obsidian.vaultPath"
            )
            // Shows the export choices for dictations and Recorder transcripts (#1083).
            UserDefaults.standard.set(true, forKey: "plugin.com.typewhisper.obsidian.autoExportEnabled")
            UserDefaults.standard.set(true, forKey: "plugin.com.typewhisper.obsidian.exportDictations")
            UserDefaults.standard.set(true, forKey: "plugin.com.typewhisper.obsidian.exportRecordings")
        case "com.typewhisper.mcp-client":
            let configuration: [String: Any] = [
                "servers": [[
                    "id": "4CF83F6E-7A32-4A97-8A97-A9C4BD8CC5B3",
                    "name": language == .german ? "Projektwissen" : "Project Knowledge",
                    "transport": "streamableHTTP",
                    "endpoint": "https://mcp.example.com/mcp",
                    "launchAcknowledged": false,
                    "createdAt": 0,
                    "updatedAt": 0,
                ]],
                "actions": [],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: configuration) {
                UserDefaults.standard.set(data, forKey: "plugin.com.typewhisper.mcp-client.configuration-v1")
            }
        default:
            break
        }
        seedScreenshotPluginData(language: language)
    }

    private func seedScreenshotPluginData(language: ScreenshotFixtureLanguage) {
        guard AppConstants.isScreenshotAutomation,
              let pluginId = AppConstants.screenshotPluginId else { return }

        let fixture = ScreenshotPluginDataFixture(
            isGerman: language == .german,
            referenceDate: AppConstants.screenshotFixtureReferenceDate
        )
        for (key, value) in fixture.defaults(pluginId: pluginId) {
            UserDefaults.standard.set(value, forKey: "plugin.\(pluginId).\(key)")
        }

        let dataDirectory = AppConstants.appSupportDirectory
            .appendingPathComponent("PluginData", isDirectory: true)
            .appendingPathComponent(pluginId, isDirectory: true)
        for file in fixture.files(pluginId: pluginId) {
            let destination = dataDirectory.appendingPathComponent(file.relativePath)
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? file.data.write(to: destination, options: .atomic)
        }
    }

    /// Correct Last Dictation copies the corrected text, which must not replace the clipboard
    /// of the Mac the screenshots are taken on. The newest dictation was post-processed, so
    /// the editor also shows its original transcript.
    private func prepareScreenshotLastDictationCorrection() {
        let clipboard = NSPasteboard(name: NSPasteboard.Name("com.typewhisper.screenshots.clipboard"))
        dictationViewModel.pasteboardProvider = { clipboard }
        guard AppConstants.screenshotState == "correct-last-dictation" else { return }
        _ = historyService.addRecord(
            timestamp: Date().addingTimeInterval(-120),
            rawText: "please deploy the release build to kubernetis after the review",
            finalText: "Please deploy the release build to Kubernetis after the review.",
            appName: "Slack",
            appBundleIdentifier: "com.tinyspeck.slackmacgap",
            durationSeconds: 4.5,
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "Parakeet TDT 0.6B v3"
        )
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

            let source: RecordingSource = switch index % 7 {
            case 0: .appleWatch
            case 2: .iPhone
            case 3: .keyboard
            case 5: .shortcut
            default: .mac
            }
            let recordID = UUID()
            let includesAudio = index.isMultiple(of: 4)

            _ = historyService.addRecord(
                id: recordID,
                timestamp: timestamp,
                rawText: sample.text,
                finalText: sample.text,
                appName: sample.appName,
                appBundleIdentifier: sample.bundleIdentifier,
                durationSeconds: 5.5 + Double(index % 5),
                language: languageCode,
                engineUsed: index.isMultiple(of: 3) ? "parakeet" : "whisper",
                modelUsed: index.isMultiple(of: 3) ? "Parakeet TDT 0.6B v3" : "Large v3 Turbo",
                audioSamples: includesAudio ? Array(repeating: Float.zero, count: 1_600) : nil
            )

            guard let record = historyService.record(withID: recordID) else {
                continue
            }
            record.source = source
            record.originDeviceID = source == .mac
                ? historySyncPreferences.deviceID
                : "screenshot-iphone-history"
            record.originPlatformRaw = switch source {
            case .appleWatch: "watchOS"
            case .iPhone, .keyboard, .shortcut: "iOS"
            default: "macOS"
            }
            if index < 3 {
                record.inboxState = .open
                record.inboxCompletionPolicyRaw = UserDataSyncHistoryCompletionPolicy.explicit.rawValue
            }
            if index == 6 {
                record.processingState = .failed
                record.processingFailureMessage = "The source device could not finish this transcription."
            }
        }

        if AppConstants.screenshotState == "history",
           let selectedRecord = historyService.allRecords().first(where: { $0.processingState == .ready }) {
            // Listed under Details, which stays collapsed in the default capture.
            selectedRecord.llmUsage = HistoryLLMUsage(entries: [
                HistoryLLMUsage.Entry(
                    providerId: "Claude",
                    providerName: "Claude",
                    model: "claude-haiku-4-5",
                    inputTokens: 1_284,
                    outputTokens: 18
                ),
            ])
            historyViewModel.requestRecordSelection([selectedRecord.id])
        }
        if AppConstants.screenshotState == "history-speakers" {
            seedScreenshotSpeakerRecord(languageCode: languageCode, timestamp: referenceDate)
        }
        if AppConstants.screenshotState?.hasPrefix("history-comparison") == true,
           let record = historyService.allRecords().first(where: { historyService.audioFileURL(for: $0) != nil }) {
            let text = languageCode == "de"
                ? "Wir verschieben die Veröffentlichung auf Freitag. Bitte prüfe vorher die deutsche Übersetzung."
                : "We will move the release to Friday. Please check the German translation first."
            let version = HistoryTranscriptionVersion(
                createdAt: referenceDate.addingTimeInterval(120),
                rawText: text, finalText: text, engineID: "parakeet", engineName: "Parakeet",
                modelID: "parakeet-tdt-0.6b-v3", modelName: "Parakeet TDT 0.6B v3",
                language: languageCode, workflowRecorded: true
            )
            if AppConstants.screenshotState != "history-comparison-first" {
                try? historyService.appendTranscriptionVersion(version, to: record, expected: .capture(record))
            }
            if AppConstants.screenshotState == "history-comparison-after" {
                try? historyService.promoteTranscriptionVersion(version.id, in: record)
            }
            historyViewModel.requestRecordSelection([record.id])
        }
    }

    /// A meeting recording with a speaker transcript, selected in History.
    /// `--screenshot-speaker-audio <file>` uses that recording's audio
    /// instead of a generated tone.
    private func seedScreenshotSpeakerRecord(languageCode: String, timestamp: Date) {
        let isGerman = languageCode == "de"
        let lines: [(speaker: String, start: Double, end: Double, text: String)] = isGerman ? [
            ("S1", 0.0, 7.4, "Guten Morgen zusammen. Ich schlage vor, wir beginnen mit dem Budget für das nächste Quartal."),
            ("S1", 9.6, 13.8, "Danach gehen wir die offenen Punkte durch."),
            ("S2", 14.2, 21.0, "Gerne. Die Kosten für die Server sind um zwölf Prozent gestiegen, dafür sparen wir bei den Lizenzen."),
            ("S1", 21.4, 26.9, "Können wir die Einsparungen genauer beziffern, bevor wir etwas entscheiden?"),
            ("S2", 27.3, 33.5, "Ja, das sind ungefähr viertausend Euro im Monat. Ich schicke die Aufstellung nach dem Termin."),
            ("S3", 34.0, 40.8, "Eine Frage dazu: Sind die Kosten für den Umzug der Datenbank schon enthalten?"),
            ("S2", 41.1, 44.6, "Noch nicht, die kommen im Mai dazu."),
            ("S1", 45.2, 51.0, "Gut. Dann weiter mit dem Zeitplan für die neue Version. Wie weit ist die Entwicklung?"),
            ("S3", 51.6, 60.3, "Wir liegen eine Woche hinter dem Plan, weil die Tests länger gedauert haben."),
            ("S3", 62.4, 68.0, "Ende des Monats sollten wir aber fertig sein."),
            ("S1", 68.5, 72.0, "Danke, dann halten wir das so fest."),
        ] : [
            ("S1", 0.0, 7.4, "Good morning, everyone. I suggest we start with the budget for next quarter."),
            ("S1", 9.6, 13.8, "After that we go through the open items."),
            ("S2", 14.2, 21.0, "Sure. Server costs went up by twelve percent, but we save on licenses."),
            ("S1", 21.4, 26.9, "Can we put a number on those savings before we decide anything?"),
            ("S2", 27.3, 33.5, "Yes, that is about four thousand euros a month. I will send the breakdown after the meeting."),
            ("S3", 34.0, 40.8, "One question: does that already include the cost of moving the database?"),
            ("S2", 41.1, 44.6, "Not yet, that comes on top in May."),
            ("S1", 45.2, 51.0, "Good. Then on to the schedule for the new version. How far along is development?"),
            ("S3", 51.6, 60.3, "We are a week behind plan because testing took longer."),
            ("S3", 62.4, 68.0, "We should still be done by the end of the month."),
            ("S1", 68.5, 72.0, "Thanks, then let us record it that way."),
        ]
        let duration = 72.0
        let recordID = UUID()

        var samples: [Float] = []
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--screenshot-speaker-audio"),
           arguments.indices.contains(index + 1),
           let file = try? AVAudioFile(forReading: URL(fileURLWithPath: arguments[index + 1])),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
           (try? file.read(into: buffer)) != nil,
           file.processingFormat.sampleRate == SpeakerAudioWriter.sampleRate,
           let channel = buffer.floatChannelData?[0] {
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        if samples.isEmpty {
            samples = (0..<Int(duration * SpeakerAudioWriter.sampleRate)).map {
                Float(sin(Double($0) * 0.06)) * 0.05
            }
        }
        guard (try? SpeakerAudioWriter.writeAAC(
            samples: samples,
            to: historyService.speakerAudioFileURL(forRecordID: recordID)
        )) != nil else { return }

        let transcript = SpeakerTranscript(
            source: .localDiarizer,
            segments: lines.map {
                SpeakerTranscriptSegment(text: $0.text, start: $0.start, end: $0.end, speakerID: $0.speaker, speakerConfidence: 1)
            }
        )
        var location = 0
        let timedText = lines.map { line in
            let length = (line.text as NSString).length
            defer { location += length + 1 }
            return TimedTextEntry(text: line.text, start: line.start, end: line.end, utf16Location: location, utf16Length: length)
        }
        guard historyService.addSpeakerRecord(
            id: recordID,
            timestamp: timestamp,
            text: lines.map(\.text).joined(separator: " "),
            title: isGerman ? "Budgetrunde.m4a" : "Budget meeting.m4a",
            source: .recorder,
            durationSeconds: duration,
            language: languageCode,
            engineUsed: "parakeet",
            modelUsed: "Parakeet TDT 0.6B v3",
            timedText: timedText,
            granularity: .segment,
            transcript: transcript
        ) else { return }
        historyService.setSpeakerName("Anna", for: "S1", inRecordID: recordID)
        // The microphone's speaker, as detection names it in a Recorder recording.
        historyService.setSpeakerName(String(localized: "speakers.me"), for: "S2", inRecordID: recordID)
        // Anna has a voice profile; the third speaker is recognized as Lena and waits for confirmation.
        let voices = speakerVoiceProfileService
        if voices.store.profiles.isEmpty {
            voices.store.enroll(name: "Lena", embedding: [0, 0, 1], model: "screenshot-embedding", seconds: 95)
        }
        voices.recordVoices(
            ["S1": [1, 0, 0], "S2": [0, 1, 0], "S3": [0.05, 0, 1]],
            model: "screenshot-embedding",
            of: transcript,
            recordID: recordID
        )
        voices.enroll("S1", inRecordID: recordID)
        historyViewModel.requestRecordSelection([recordID])
    }

    /// A file waiting in the File Transcription queue, so the page shows the
    /// engine and model pickers that only appear next to queued files.
    private func seedScreenshotFileTranscriptionQueue(languageCode: String) {
        guard AppConstants.screenshotState == "file-transcription-queue" else { return }
        let url = AppConstants.appSupportDirectory
            .appendingPathComponent("ScreenshotMedia", isDirectory: true)
            .appendingPathComponent(languageCode == "de" ? "Wochenplanung.m4a" : "Weekly planning.m4a")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let samples = (0..<Int(12 * SpeakerAudioWriter.sampleRate)).map {
            Float(sin(Double($0) * 0.06)) * 0.05
        }
        guard (try? SpeakerAudioWriter.writeAAC(samples: samples, to: url)) != nil else { return }
        fileTranscriptionViewModel.addFiles([url])
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
                categories: ["transcription"],
                hosting: .cloud
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
                categories: ["transcription"],
                hosting: .cloud
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
                categories: ["llm"],
                hosting: .cloud
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
                categories: ["tts"],
                hosting: .cloud
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
                categories: ["memory"],
                hosting: .local
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
                categories: ["action"],
                hosting: .local,
                locality: .configurable
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.parakeet",
                name: "Parakeet",
                description: "Local speech-to-text powered by NVIDIA Parakeet TDT. Fast and accurate, 25 languages.",
                descriptions: [
                    "de": "Lokale Spracherkennung mit NVIDIA Parakeet TDT. Schnell und präzise, 25 Sprachen.",
                    "ja": "NVIDIA Parakeet TDTによるローカル音声認識です。高速かつ高精度で、25言語に対応します。",
                ],
                categories: ["transcription"],
                hosting: .local
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.whisperkit",
                name: "WhisperKit",
                description: "Local speech-to-text powered by WhisperKit. 8 model sizes, 99 languages, streaming support.",
                descriptions: [
                    "de": "Lokale Spracherkennung mit WhisperKit. 8 Modellgrößen, 99 Sprachen, Streaming-Unterstützung.",
                    "ja": "WhisperKitによるローカル音声認識です。8種類のモデルサイズ、99言語、ストリーミングに対応します。",
                ],
                categories: ["transcription"],
                hosting: .local
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.qwen3",
                name: "Qwen3 ASR",
                description: "Local Qwen3-ASR speech-to-text powered by MLX on Apple Silicon. 30 languages plus Chinese dialect coverage, no API key required.",
                descriptions: [
                    "de": "Lokale Qwen3-ASR-Spracherkennung mit MLX auf Apple Silicon. 30 Sprachen plus chinesische Dialektabdeckung, kein API-Key nötig.",
                    "ja": "Apple Silicon上のMLXで動作するローカルQwen3-ASR音声認識です。30言語と中国語方言に対応し、APIキーは不要です。",
                ],
                categories: ["transcription"],
                hosting: .local
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.local-llm-mlx",
                name: "Local LLM (MLX)",
                description: "Local LLM on Apple Silicon via MLX with Gemma 4, Qwen3.5, and LFM2.5 models. No API key required.",
                descriptions: [
                    "de": "Lokales LLM auf Apple Silicon via MLX mit Gemma-4-, Qwen3.5- und LFM2.5-Modellen. Kein API-Key erforderlich.",
                    "ja": "Apple Silicon上でMLX経由で動作するローカルLLM。Gemma 4、Qwen3.5、LFM2.5モデルに対応。APIキーは不要です。",
                ],
                categories: ["llm"],
                hosting: .local
            ),
            screenshotRegistryPlugin(
                id: "com.typewhisper.filler-words",
                name: "Filler Words",
                description: "Removes filler words like \"um\" and \"uh\" from transcribed text.",
                descriptions: [
                    "de": "Entfernt Füllwörter wie „ähm“ und „äh“ aus transkribiertem Text.",
                ],
                categories: ["post-processor"],
                hosting: .local
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
        categories: [String],
        hosting: PluginHosting,
        locality: PluginLocality? = nil
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
            requiresAPIKey: hosting == .cloud,
            hosting: hosting,
            descriptions: descriptions,
            downloadCount: 1_250,
            locality: (locality ?? (hosting == .cloud ? .cloud : .local)).rawValue
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

    private static let localTermPackScreenshotStates: Set<String> = [
        "dictionary-local-term-packs",
        "dictionary-local-term-pack-error",
        "dictionary-local-term-pack-replace",
    ]

    private static let termPackScreenshotStates = localTermPackScreenshotStates.union(["dictionary-term-packs"])

    /// An imported local pack that is turned on. The error state adds a rejected import, the
    /// replace state an import of an edited file with the same id.
    private func seedScreenshotLocalTermPacks() {
        guard let state = AppConstants.screenshotState,
              Self.localTermPackScreenshotStates.contains(state) else { return }

        let file = LocalTermPackFile(
            id: "acme-team-terms",
            name: "Acme Team Terms",
            description: "Product names and internal tools of the Acme team.",
            icon: "person.3",
            version: "1.0.0",
            author: "Acme Docs Team",
            terms: ["Acme Cloud", "Roadrunner", "QuickShip", "Coyote API"],
            corrections: [TermPackCorrection(original: "quick ship", replacement: "QuickShip", caseSensitive: false)],
            names: ["de": "Acme-Teambegriffe", "ja": "Acme チーム用語", "zh": "Acme 团队词汇"],
            descriptions: [
                "de": "Produktnamen und interne Tools des Acme-Teams.",
                "ja": "Acme チームの製品名と社内ツールです。",
                "zh": "Acme 团队的产品名称和内部工具。",
            ]
        )
        try? localTermPackStore.save(file)
        DictionaryViewModel.shared.activatePack(file.termPack)

        switch state {
        case "dictionary-local-term-pack-error":
            // A real import of a file that reuses a built-in pack's ID.
            let rejected = #"{"id": "web-dev", "name": "My Web Terms", "description": "Web words", "icon": "globe", "version": "1.0.0", "author": "Acme Docs Team", "terms": ["Remix"]}"#
            DictionaryViewModel.shared.importLocalTermPack(data: Data(rejected.utf8))
        case "dictionary-local-term-pack-replace":
            let edited = LocalTermPackFile(
                id: file.id,
                name: file.name,
                description: file.description,
                icon: file.icon,
                version: "1.1.0",
                author: file.author,
                terms: file.terms + ["Anvil"],
                corrections: file.corrections,
                names: file.names,
                descriptions: file.descriptions
            )
            if let data = try? edited.encodedData() {
                DictionaryViewModel.shared.importLocalTermPack(data: data)
            }
        default:
            break
        }
    }
}

/// Example data for add-on settings windows that would otherwise open empty.
/// Everything here is invented; nothing is read from the user's TypeWhisper data.
struct ScreenshotPluginDataFixture {
    struct File {
        let relativePath: String
        let data: Data
    }

    let isGerman: Bool
    let referenceDate: Date

    func defaults(pluginId: String) -> [String: Any] {
        switch pluginId {
        case "com.typewhisper.memory.openai-vector":
            ["vectorStoreId": "vs_example_typewhisper"]
        case "com.typewhisper.improve":
            ["collectCorrections": true]
        default:
            [:]
        }
    }

    func files(pluginId: String) -> [File] {
        let files: [File?] = switch pluginId {
        case "com.typewhisper.memory.file":
            [encoded(memories, as: "memories.json")]
        case "com.typewhisper.memory.openai-vector":
            [encoded(memories, as: "entries.json")]
        case "com.typewhisper.script":
            [serialized(scripts, as: "scripts.json")]
        case "com.typewhisper.webhook":
            [serialized(webhooks, as: "webhooks.json")]
        case "com.typewhisper.improve":
            corrections.map { correction in
                let id = (correction["id"] as? String ?? "correction").lowercased()
                return serialized(correction, as: "pending/\(id).json")
            }
        default:
            []
        }
        return files.compactMap { $0 }
    }

    private var memories: [MemoryEntry] {
        let samples: [(id: String, content: String, type: MemoryType, appName: String, hoursAgo: Double)] = isGerman
            ? [
                ("5B0B0E4C-2D0B-4C0E-9A55-0B6C1F0A7D01", "Release Notes nennen sichtbare Änderungen zuerst und bleiben unter zehn Zeilen.", .instruction, "Notizen", 2),
                ("5B0B0E4C-2D0B-4C0E-9A55-0B6C1F0A7D02", "Der Produktname wird in einem Wort geschrieben: TypeWhisper.", .correction, "Mail", 26),
                ("5B0B0E4C-2D0B-4C0E-9A55-0B6C1F0A7D03", "Das wöchentliche Team-Review findet donnerstags um 10:00 Uhr statt.", .fact, "Slack", 74),
            ]
            : [
                ("5B0B0E4C-2D0B-4C0E-9A55-0B6C1F0A7D01", "Release notes list user-facing changes first and stay under ten lines.", .instruction, "Notes", 2),
                ("5B0B0E4C-2D0B-4C0E-9A55-0B6C1F0A7D02", "The product name is written as one word: TypeWhisper.", .correction, "Mail", 26),
                ("5B0B0E4C-2D0B-4C0E-9A55-0B6C1F0A7D03", "The weekly team review takes place on Thursdays at 10:00.", .fact, "Slack", 74),
            ]

        // The memory list shows relative dates, so these are anchored to the capture time.
        let now = Date()
        return samples.map { sample in
            let createdAt = now.addingTimeInterval(-sample.hoursAgo * 3_600)
            return MemoryEntry(
                id: UUID(uuidString: sample.id) ?? UUID(),
                content: sample.content,
                type: sample.type,
                source: MemorySource(appName: sample.appName, timestamp: createdAt),
                createdAt: createdAt,
                lastAccessedAt: createdAt
            )
        }
    }

    private var scripts: [[String: Any]] {
        [
            [
                "id": "8E4C6B52-1F3A-4F0B-8C11-52A7D9E31A01",
                "name": isGerman ? "Leerzeichen am Zeilenende entfernen" : "Trim trailing spaces",
                "command": "sed 's/[[:space:]]*$//'",
                "isEnabled": true,
                "profileFilter": [String](),
            ],
            [
                "id": "8E4C6B52-1F3A-4F0B-8C11-52A7D9E31A02",
                "name": isGerman ? "Bei 80 Zeichen umbrechen" : "Wrap at 80 characters",
                "command": "fold -s -w 80",
                "isEnabled": true,
                "profileFilter": [String](),
            ],
        ]
    }

    private var webhooks: [[String: Any]] {
        [
            [
                "id": "C2A1F7D4-6B3E-4D5A-9E20-7F4B1C8D2E01",
                "name": isGerman ? "Team-Notizen" : "Team Notes",
                "url": "https://example.com/hooks/typewhisper",
                "httpMethod": "POST",
                "headers": ["Content-Type": "application/json"],
                "secretHeaderNames": [String](),
                "isEnabled": true,
                "profileFilter": [String](),
            ],
            [
                "id": "C2A1F7D4-6B3E-4D5A-9E20-7F4B1C8D2E02",
                "name": isGerman ? "Besprechungsarchiv" : "Meeting Archive",
                "url": "https://example.com/hooks/meetings",
                "httpMethod": "POST",
                "headers": ["Content-Type": "application/json"],
                "secretHeaderNames": [String](),
                "isEnabled": true,
                "profileFilter": [isGerman ? "Besprechungsnotizen" : "Meeting Notes"],
            ],
        ]
    }

    private var corrections: [[String: Any]] {
        let samples: [(id: String, original: String, corrected: String, daysAgo: Double)] = isGerman
            ? [
                ("3F9D2A10-7C4E-4B8A-A6D3-1E5B9C0F4A01", "Bitte prüfe vor dem Release das Fast-Lane-Setup.", "Bitte prüfe vor dem Release das Fastlane-Setup.", 0),
                ("3F9D2A10-7C4E-4B8A-A6D3-1E5B9C0F4A02", "Das Team Review ist am Donnerstag um zehn.", "Das Team-Review ist am Donnerstag um 10:00 Uhr.", 1),
                ("3F9D2A10-7C4E-4B8A-A6D3-1E5B9C0F4A03", "Die Notizen liegen in Type Whisper bereit.", "Die Notizen liegen in TypeWhisper bereit.", 3),
            ]
            : [
                ("3F9D2A10-7C4E-4B8A-A6D3-1E5B9C0F4A01", "Please check the fast lane setup before the release.", "Please check the Fastlane setup before the release.", 0),
                ("3F9D2A10-7C4E-4B8A-A6D3-1E5B9C0F4A02", "The team review is on Thursday at ten.", "The team review is on Thursday at 10:00.", 1),
                ("3F9D2A10-7C4E-4B8A-A6D3-1E5B9C0F4A03", "The notes are ready in Type Whisper.", "The notes are ready in TypeWhisper.", 3),
            ]

        let formatter = ISO8601DateFormatter()
        return samples.map { sample in
            [
                "schemaVersion": 1,
                "id": sample.id,
                "capturedAt": formatter.string(
                    from: referenceDate.addingTimeInterval(-sample.daysAgo * 86_400)
                ),
                "originalText": sample.original,
                "correctedText": sample.corrected,
                "language": isGerman ? "de" : "en",
                "engineId": "parakeet",
                "modelId": "parakeet-tdt-0.6b-v3",
                "appVersion": "1.7.0",
                "appBuild": "1",
                "platformVersion": "macOS 26.0",
                "sourceChannel": "production",
                "status": "local",
                "qualityCredit": 0,
            ]
        }
    }

    private func encoded(_ memories: [MemoryEntry], as relativePath: String) -> File? {
        guard let data = try? JSONEncoder.memoryEncoder.encode(memories) else { return nil }
        return File(relativePath: relativePath, data: data)
    }

    private func serialized(_ object: Any, as relativePath: String) -> File? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return File(relativePath: relativePath, data: data)
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
    case spanish = "es"

    static var current: ScreenshotFixtureLanguage {
        let preferred = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
            ?? Locale.preferredLanguages.first
            ?? "en"
        let normalized = preferred.lowercased()
        if normalized.hasPrefix("de") { return .german }
        if normalized.hasPrefix("ja") { return .japanese }
        if normalized.hasPrefix("zh") { return .simplifiedChinese }
        if normalized.hasPrefix("es") { return .spanish }
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
        case .spanish:
            [("Calendario del equipo", "Google Workspace"), ("Calendario personal", "iCloud")]
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

        case .spanish:
            ScreenshotFixtureContent(
                history: [
                    .init(appName: "Notas", bundleIdentifier: "com.apple.Notes", text: "Termina las notas de la versión y revisa todas las capturas localizadas antes de publicarlas."),
                    .init(appName: "Mail", bundleIdentifier: "com.apple.mail", text: "Envía al equipo el resumen actualizado del lanzamiento antes de la revisión de mañana."),
                    .init(appName: "Safari", bundleIdentifier: "com.apple.Safari", text: "Compara la página del producto en todos los idiomas compatibles y reúne los últimos comentarios."),
                    .init(appName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", text: "Ejecuta las pruebas de macOS y confirma que la compilación final no tiene advertencias."),
                    .init(appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", text: "La versión candidata está lista. Avisa si algo debería bloquear el lanzamiento."),
                    .init(appName: "Pages", bundleIdentifier: "com.apple.iWork.Pages", text: "Convierte las notas de la reunión en un resumen breve con responsables y próximos pasos."),
                    .init(appName: "Terminal", bundleIdentifier: "com.apple.Terminal", text: "Crea el archivo final, verifica su firma y anota la suma de comprobación."),
                ],
                terms: ["TypeWhisper", "Fastlane", "SwiftUI", "App Store Connect", "versión candidata"],
                corrections: [
                    .init(original: "Type Whisper", replacement: "TypeWhisper"),
                    .init(original: "fast lane", replacement: "Fastlane"),
                    .init(original: "swift UI", replacement: "SwiftUI"),
                ],
                snippets: [
                    .init(trigger: "/gracias", replacement: "Gracias por los comentarios detallados. Los reviso hoy mismo."),
                    .init(trigger: "/reunion", replacement: "Notas de la reunión del {date}:\n\n- Decisión\n- Responsable\n- Próximo paso"),
                    .init(trigger: "/version", replacement: "La versión candidata está lista para la revisión final."),
                ],
                workflows: [
                    .init(name: "Pulir dictado", template: .cleanedText, trigger: .global(), instruction: "Mantén un tono directo y conserva los nombres de productos."),
                    .init(name: "Notas de reunión", template: .meetingNotes, trigger: .app("com.apple.Notes"), instruction: "Extrae decisiones, responsables y próximos pasos."),
                    .init(name: "Traducir al inglés", template: .translation, trigger: .manual(), instruction: "Traduce al inglés de forma natural."),
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
