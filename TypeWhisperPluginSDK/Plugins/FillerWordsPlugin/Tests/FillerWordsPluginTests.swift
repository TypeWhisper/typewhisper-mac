import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import FillerWordsPlugin

final class FillerWordsPluginTests: XCTestCase {
    func testMetadataPlacesProcessorBeforePromptProcessing() {
        let plugin = FillerWordsPlugin()

        XCTAssertEqual(FillerWordsPlugin.pluginId, "com.typewhisper.filler-words")
        XCTAssertEqual(plugin.processorName, "Filler Words")
        XCTAssertLessThan(plugin.priority, 300)
    }

    func testRemovesBuiltInFillerWordsCaseInsensitively() async throws {
        let plugin = FillerWordsPlugin()

        let result = try await plugin.process(
            text: "Ähm, um uh hello?",
            context: PostProcessingContext(language: "en")
        )

        XCTAssertEqual(result, "Hello?")
    }

    func testKeepsLanguageBoundFillersThatAreRealWordsInTheConfiguredLanguage() async throws {
        let plugin = FillerWordsPlugin()

        let result = try await plugin.process(
            text: "Wir treffen uns um 10 Uhr, äh, das ist eh klar.",
            context: PostProcessingContext(language: "de")
        )

        XCTAssertEqual(result, "Wir treffen uns um 10 Uhr, das ist eh klar.")
    }

    func testRemovesLanguageBoundFillersForRegionalEnglish() {
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "So um I think, ah, we should go", language: "en-US"),
            "So I think, we should go"
        )
    }

    func testRecognizesLanguageWhenNoneIsConfigured() {
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Um, can you send me the file?"),
            "Can you send me the file?"
        )
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "um 10 Uhr"), "um 10 Uhr")
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Eu vi um carro na rua ontem."),
            "Eu vi um carro na rua ontem."
        )
    }

    func testDecidesLanguageBoundFillersPerSentence() {
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(
                from: "So I was thinking about the project. Um, we should ship it next week. "
                    + "Wir treffen uns um 10 Uhr. Okay, um, let me check."
            ),
            "So I was thinking about the project. We should ship it next week. "
                + "Wir treffen uns um 10 Uhr. Okay, let me check."
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(
                from: "Wir haben heute viel geschafft und das Team ist zufrieden. Deploy um 5. Danach machen wir Feierabend."
            ),
            "Wir haben heute viel geschafft und das Team ist zufrieden. Deploy um 5. Danach machen wir Feierabend."
        )
    }

    func testKeepsLanguageBoundFillersWhenLanguageIsUncertain() {
        XCTAssertNil(FillerWordsPlugin.recognizedLanguage(of: "um ok"))
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "um ok"), "um ok")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "uhm ok"), "uhm ok")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "hmm ok"), "ok")
    }

    func testRestoresCapitalOnlyWhenRemovedFillerOpenedSentence() {
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Okay. Um, so I think. Uh, yes!", language: "en"),
            "Okay. So I think. Yes!"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "um so I think", language: "en"),
            "so I think"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "I said Um yes", language: "en"),
            "I said yes"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Äh, über den Plan", language: "de"),
            "Über den Plan"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Okay. “Um, so I think.”", language: "en"),
            "Okay. “So I think.”"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Gut. (Äh, morgen.)", language: "de"),
            "Gut. (Morgen.)"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Er sagte „ja“ Äh nein", language: "de"),
            "Er sagte „ja“ nein"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said \"Um, yes\" um no", language: "en"),
            "He said \"Yes\" no"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "(“Um, hello”) and (\"Uh, hi\")", language: "en"),
            "(“Hello”) and (\"Hi\")"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Heading\nUm, next item", language: "en"),
            "Heading\nNext item"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Gut. »Äh, morgen.« Sagte er »ja« äh nein", language: "de"),
            "Gut. »Morgen.« Sagte er »ja« nein"
        )
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "Umm, izmir", language: "tr"), "İzmir")
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "(Okay.) Um, next", language: "en"),
            "(Okay.) Next"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Um, iPhone is ready. Uh, eBay too.", language: "en"),
            "iPhone is ready. eBay too."
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Um, https://example.com. Uh, @openai. Um, --verbose", language: "en"),
            "https://example.com. @openai. --verbose"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Um, \"hello,\" she said. Uh, we're done.", language: "en"),
            "\"Hello,\" she said. We're done."
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said:“Um, hello” —“Uh, bye”", language: "en"),
            "He said:“Hello” —“Bye”"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said “wait—” Um, okay", language: "en"),
            "He said “wait—” okay"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said “wait—”. Um, okay", language: "en"),
            "He said “wait—” okay"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "¿Ehm, vamos? ¡Umm, vamos!", language: "es"),
            "¿Vamos? ¡Vamos!"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(
                from: "<p>Um, hello</p><ul><li>Uh, first</li></ul><p>a > b</p>",
                language: "en"
            ),
            "<p>Hello</p><ul><li>First</li></ul><p>a > b</p>"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(
                from: "<p>Um, &quot;hello&quot;</p><p>&quot;Uh, bye&quot;</p>",
                language: "en"
            ),
            "<p>&quot;Hello&quot;</p><p>&quot;Bye&quot;</p>"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "- Um, hello\n* Uh, world", language: "en"),
            "- Hello\n* World"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "« oui » Euh, non", words: ["euh"], language: "fr"),
            "« oui » non"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Okay. “Um, uh, hello”", language: "en"),
            "Okay. “Hello”"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Uh, « hello »", language: "fr"),
            "« Hello »"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said “wait.”Um, okay", language: "en"),
            "He said “wait.” Okay"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "分かりました。Umm, next", language: "ja"),
            "分かりました。 Next"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said “wait,”Um, okay", language: "en"),
            "He said “wait,” okay"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "He said “wait—”Um, okay", language: "en"),
            "He said “wait—” okay"
        )
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "Umm, hello！", language: "en"), "Hello！")
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Umm, hello—how are you? Umm, check-in works.", language: "en"),
            "Hello—how are you? Check-in works."
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "Umm, ijs is lekker. Umm, in de zon.", language: "nl"),
            "IJs is lekker. In de zon."
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "« Euh, bonjour »", words: ["euh"], language: "fr"),
            "« Bonjour »"
        )
    }

    func testCollapsesWordsRepeatedThreeOrMoreTimes() {
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "I I I think so"), "I think so")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "wh wh wh wh what"), "wh what")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "Ich ich ich\nweiß"), "Ich\nweiß")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "the the cat"), "the the cat")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "No, no, no."), "No, no, no.")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "1 1 1 go"), "1 1 1 go")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "COVID-19 COVID-19 COVID-19 cases"), "COVID-19 cases")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "B2B B2B B2B sales"), "B2B sales")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "Maße Masse Maße"), "Maße Masse Maße")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "ΛΟΓΟΣ λογος λογος"), "ΛΟΓΟΣ")
        XCTAssertEqual(
            FillerWordsPlugin.collapseStutters(in: "state\u{2011}of\u{2011}the\u{2011}art state\u{2011}of\u{2011}the\u{2011}art state\u{2011}of\u{2011}the\u{2011}art tools"),
            "state\u{2011}of\u{2011}the\u{2011}art tools"
        )
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "So so SO so, fine"), "So, fine")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "a a a-ha"), "a a a-ha")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "I'm I'm I'm ready"), "I'm ready")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "check-in check-in check-in done"), "check-in done")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "I'm I'm I am"), "I'm I'm I am")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "'well well well'"), "'well'")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "‘well well well’ he said"), "‘well’ he said")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "don't t t"), "don't t t")
        XCTAssertEqual(FillerWordsPlugin.collapseStutters(in: "नहीं नहीं नहीं पता"), "नहीं पता")
        XCTAssertEqual(
            FillerWordsPlugin.collapseStutters(in: "می\u{200C}روم می\u{200C}روم می\u{200C}روم خانه"),
            "می\u{200C}روم خانه"
        )
        XCTAssertEqual(
            FillerWordsPlugin.collapseStutters(in: "cafe\u{301} cafe\u{301} cafe\u{301} au lait"),
            "cafe\u{301} au lait"
        )
    }

    func testProcessCollapsesStuttersUnlessDisabled() async throws {
        let plugin = FillerWordsPlugin()
        let result = try await plugin.process(
            text: "I I I um think so",
            context: PostProcessingContext(language: "en")
        )
        XCTAssertEqual(result, "I think so")

        let host = try PluginTestHostServices(defaults: ["collapseStutters": false])
        let configuredPlugin = FillerWordsPlugin()
        configuredPlugin.activate(host: host)

        let preserved = try await configuredPlugin.process(
            text: "I I I um think so",
            context: PostProcessingContext(language: "en")
        )
        XCTAssertEqual(preserved, "I I I think so")
    }

    func testRemovesBuiltInJapaneseFillerWordsAtPhraseBoundaries() async throws {
        let plugin = FillerWordsPlugin()

        let result = try await plugin.process(
            text: "えっと友達追加されたのは2月9日で、なんか様子を見たいです。まあ今日から開始してください。",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "友達追加されたのは2月9日で、様子を見たいです。今日から開始してください。")
    }

    func testPreservesMeaningfulJapaneseConnectorsAndDemonstratives() {
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "あと最後に送信確認してください。"),
            "あと最後に送信確認してください。"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "そのまま送信してください。"),
            "そのまま送信してください。"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "あの人に確認してください。"),
            "あの人に確認してください。"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "まあまあです。今日は、まあまあです。"),
            "まあまあです。今日は、まあまあです。"
        )
        XCTAssertEqual(
            FillerWordsPlugin.removeFillerWords(from: "まあまず確認してください。まあまた明日です。"),
            "まず確認してください。また明日です。"
        )
    }

    @MainActor
    func testActivationSeedsPluginScopedDefaultWords() throws {
        let host = try PluginTestHostServices()
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        XCTAssertNotNil(plugin.settingsView)
        XCTAssertEqual(
            host.userDefault(forKey: "words") as? String,
            FillerWordsPlugin.defaultFillerWords.joined(separator: "\n")
        )
    }

    func testActivationMigratesLegacyDefaultsWithoutDroppingCustomWords() throws {
        let host = try PluginTestHostServices(defaults: [
            "words": [
                "ah",
                "ahh",
                "hm",
                "hmm",
                "uh",
                "uhh",
                "um",
                "umm",
                "basically",
            ].joined(separator: "\n")
        ])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let storedWords = host.userDefault(forKey: "words") as? String
        XCTAssertTrue(storedWords?.contains("basically") == true)
        XCTAssertTrue(storedWords?.contains("ähm") == true)
        XCTAssertTrue(storedWords?.contains("えっと") == true)
        XCTAssertEqual(host.userDefault(forKey: "wordsDefaultsVersion") as? Int, 3)
    }

    func testProcessUsesPluginScopedCustomWords() async throws {
        let host = try PluginTestHostServices(defaults: ["words": "basically\nlike"])
        let plugin = FillerWordsPlugin()

        plugin.activate(host: host)

        let result = try await plugin.process(
            text: "basically hello um",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hello um")
    }

    func testPreservesWordBoundariesAndExistingSpacing() {
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "umbrella"), "umbrella")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "summer humor"), "summer humor")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "hello  world"), "hello  world")
        XCTAssertEqual(FillerWordsPlugin.removeFillerWords(from: "\n\num hello", language: "en"), "\n\nhello")
    }
}
