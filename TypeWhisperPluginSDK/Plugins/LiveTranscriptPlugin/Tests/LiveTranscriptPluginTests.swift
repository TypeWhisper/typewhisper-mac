import Foundation
import TypeWhisperPluginSDKTesting
import XCTest
@testable import LiveTranscriptPlugin

@MainActor
final class LiveTranscriptPluginTests: XCTestCase {
    private func displayedText(from viewModel: LiveTranscriptViewModel) -> String {
        viewModel.paragraphs.map(\.text).joined(separator: " ")
    }

    private func paragraphTexts(from viewModel: LiveTranscriptViewModel) -> [String] {
        viewModel.paragraphs.map(\.text)
    }

    func testAutoOpenDefaultsToDisabledWhenUnset() throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertNil(host.userDefault(forKey: "autoOpen"))
        XCTAssertEqual(host.streamingDisplayActiveValues, [])
        XCTAssertEqual(eventBus.subscriberCount, 1)
    }

    func testStoredAutoOpenTrueIsPreservedOnActivation() throws {
        let host = try PluginTestHostServices(defaults: ["autoOpen": true])
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testEnablingAutoOpenRegistersStreamingDisplayExactlyOnce() throws {
        let host = try PluginTestHostServices()
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.updateAutoOpenPreference(true)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(host.userDefault(forKey: "autoOpen") as? Bool, true)
        XCTAssertEqual(host.streamingDisplayActiveValues, [true])
    }

    func testDeactivationUnsubscribesAndClearsStreamingDisplay() throws {
        let eventBus = PluginTestEventBus()
        let host = try PluginTestHostServices(eventBus: eventBus)
        let plugin = LiveTranscriptPlugin()

        plugin.activate(host: host)
        plugin.updateAutoOpenPreference(true)

        XCTAssertEqual(eventBus.subscriberCount, 1)

        plugin.deactivate()

        XCTAssertEqual(host.streamingDisplayActiveValues, [true, false])
        XCTAssertEqual(eventBus.subscriberCount, 0)
    }

    func testViewModelPreservesCumulativeTranscriptUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence.", isFinal: false)
        viewModel.updateText("First sentence. Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }

    func testViewModelAppendsDisjointSegmentUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence.", isFinal: false)
        viewModel.updateText("Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }

    func testViewModelMergesOverlappingSlidingWindowUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("Second sentence. Third sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence. Third sentence.")
    }

    func testViewModelKeepsThreeSentenceParagraphsForCumulativeUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence. Third sentence.", isFinal: false)
        viewModel.updateText("First sentence. Second sentence. Third sentence. Fourth sentence.", isFinal: false)

        XCTAssertEqual(paragraphTexts(from: viewModel), [
            "First sentence. Second sentence. Third sentence.",
            "Fourth sentence.",
        ])
    }

    func testViewModelMergesTwoSentenceSlidingWindowUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence. Third sentence. Fourth sentence.", isFinal: false)
        viewModel.updateText("Third sentence. Fourth sentence. Fifth sentence.", isFinal: false)

        XCTAssertEqual(
            displayedText(from: viewModel),
            "First sentence. Second sentence. Third sentence. Fourth sentence. Fifth sentence."
        )
    }

    func testViewModelDeduplicatesCleanedSegmentUpdatesAfterAppend() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("This is a test sentence.", isFinal: false)
        viewModel.updateText("This is test sentence. Now the next sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "This is a test sentence. Now the next sentence.")
    }

    func testViewModelDropsNoisyReporterSlidingWindowPrefix() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText(
            "Das hier ist das klassische DJI-Setup. Also das sieht aus wie beim Mini 1, einfach dass die Dinger 2 sind. Das ueberrascht mich ein bisschen.",
            isFinal: false
        )
        viewModel.updateText(
            "Mini 1, einlech dass sie Dinge 2 ist. Aber jetzt muessen wir nichts anderes angucken.",
            isFinal: false
        )

        XCTAssertEqual(
            displayedText(from: viewModel),
            "Das hier ist das klassische DJI-Setup. Also das sieht aus wie beim Mini 1, einfach dass die Dinger 2 sind. Das ueberrascht mich ein bisschen. Aber jetzt muessen wir nichts anderes angucken."
        )
    }

    func testViewModelPreservesLegitimateShortRepetitions() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("Eins. Eins. Zwei.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "Eins. Eins. Zwei.")
    }

    func testViewModelReplacesLiveTailWithCompletedSentence() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("This is a partial", isFinal: false)
        viewModel.updateText("This is a partial sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "This is a partial sentence.")
    }

    func testViewModelAllowsRecentVolatileSentencesToBeCorrected() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText(
            "Ich bin in Koeln geboren und auch mit ganzem Herzen an Koin. Und jetzt sind sie wieder in einer Stadt. Am proben Fluss gelandes.",
            isFinal: false
        )
        viewModel.updateText(
            "Ich bin in Koeln geboren und auch mit ganzem Herzen an Koeln. Und jetzt sind sie wieder. Wieder in einer Stadt am grossen Fluss gelandet. Genau.",
            isFinal: false
        )

        XCTAssertEqual(
            displayedText(from: viewModel),
            "Ich bin in Koeln geboren und auch mit ganzem Herzen an Koeln. Und jetzt sind sie wieder. Wieder in einer Stadt am grossen Fluss gelandet. Genau."
        )
    }

    func testViewModelDoesNotReplaceConfirmedTextWhenLaterWindowRepeatsOldSentences() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText(
            "First sentence. Second sentence. Third sentence. Fourth sentence. Fifth sentence. Sixth sentence.",
            isFinal: false
        )
        viewModel.updateText(
            "First sentence. Second sentence. New quoted sentence.",
            isFinal: false
        )

        XCTAssertEqual(
            displayedText(from: viewModel),
            "First sentence. Second sentence. Third sentence. Fourth sentence. Fifth sentence. Sixth sentence. New quoted sentence."
        )
    }

    func testViewModelIgnoresShorterResetUpdates() {
        let viewModel = LiveTranscriptViewModel()

        viewModel.updateText("First sentence. Second sentence.", isFinal: false)
        viewModel.updateText("Second sentence.", isFinal: false)

        XCTAssertEqual(displayedText(from: viewModel), "First sentence. Second sentence.")
    }
}
