import Foundation

/// Content-free timings of one dictation, from the start request to verified insertion and
/// clipboard restoration. The local API returns it with the dictation session and it is
/// logged once per dictation, so latency benchmarks never need transcript text or audio.
struct DictationLatencyTrace: Sendable, Equatable {
    enum Insertion: String, Sendable {
        /// Set via Accessibility and verified by reading the field back.
        case accessibility
        /// Applied to the live-field transcript session, which verifies every mutation.
        case liveField = "live-field"
        /// Synthetic paste; see `PasteVerification` for whether it landed.
        case paste
        /// Routed to an action plugin instead of the focused app.
        case actionPlugin = "action-plugin"
        /// The dictation finished without inserting text.
        case notInserted = "not-inserted"
    }

    enum PasteVerification: Equatable, Sendable {
        case verified
        case unverified(String)
        /// Nothing checked whether the paste landed, e.g. clipboard preservation was off.
        case notChecked

        var name: String {
            switch self {
            case .verified: "verified"
            case .unverified: "unverified"
            case .notChecked: "not-checked"
            }
        }
    }

    let requestUptimeNanoseconds: UInt64
    var inputTransport: String?
    /// Whether `readinessEngine` had its model ready when recording started. Nil when the
    /// transcript came from another engine, e.g. after a website workflow or a recovery
    /// fallback switched it, since that engine's state was not sampled.
    private(set) var engineReadyAtStart: Bool?
    private(set) var readinessEngine: String?
    /// For Bluetooth input, when the stream was confirmed ready. Buffers staged before that
    /// are kept, but the start cue waits for readiness, so that is when dictation can begin.
    var firstAudioBufferUptimeNanoseconds: UInt64?
    /// Milliseconds of audio older than the start request that the microphone pre-roll
    /// prepended to the recording. Zero when the pre-roll is off or was not armed.
    var prerollMs: Double = 0
    var stopUptimeNanoseconds: UInt64?
    var recordingSeconds: Double?
    var finalTranscriptUptimeNanoseconds: UInt64?
    var postProcessingDoneUptimeNanoseconds: UInt64?
    var insertionUptimeNanoseconds: UInt64?
    var verifiedInsertionUptimeNanoseconds: UInt64?
    var clipboardRestoredUptimeNanoseconds: UInt64?
    var engine: String?
    var model: String?
    var usedLiveResult: Bool?
    var llmPostProcessing: Bool?
    var insertion: Insertion?
    var pasteVerification: PasteVerification?
    var failed = false
    /// False while paste verification or the clipboard restore is still pending.
    var isComplete = false

    init(requestUptimeNanoseconds: UInt64) {
        self.requestUptimeNanoseconds = requestUptimeNanoseconds
    }

    mutating func recordEngineReadiness(_ isReady: Bool, engine: String?) {
        engineReadyAtStart = isReady
        readinessEngine = engine
    }

    mutating func recordFinalEngine(_ finalEngine: String) {
        engine = finalEngine
        if readinessEngine != finalEngine {
            engineReadyAtStart = nil
        }
    }

    mutating func recordInsertion(
        _ result: TextInsertionService.InsertionResult,
        timing: TextInsertionService.InsertionTiming
    ) {
        insertionUptimeNanoseconds = timing.insertedUptimeNanoseconds
        let verifiedUptime = timing.verifiedUptimeNanoseconds ?? timing.insertedUptimeNanoseconds
        switch result {
        case .insertedViaAccessibility:
            insertion = .accessibility
            verifiedInsertionUptimeNanoseconds = verifiedUptime
        case .pasted(let verification):
            insertion = .paste
            recordPasteVerification(verification, at: verifiedUptime)
        }
    }

    mutating func recordPasteVerification(
        _ verification: TextInsertionService.PasteVerification,
        at uptimeNanoseconds: UInt64
    ) {
        switch verification {
        case .verified:
            pasteVerification = .verified
            verifiedInsertionUptimeNanoseconds = uptimeNanoseconds
        case .unverified(let failure):
            pasteVerification = .unverified(failure.rawValue)
        case .notAwaited:
            pasteVerification = .notChecked
        }
    }

    var requestToFirstAudioBufferMs: Double? {
        Self.milliseconds(from: requestUptimeNanoseconds, to: firstAudioBufferUptimeNanoseconds)
    }

    var stopToFinalTranscriptMs: Double? {
        Self.milliseconds(from: stopUptimeNanoseconds, to: finalTranscriptUptimeNanoseconds)
    }

    var postProcessingMs: Double? {
        Self.milliseconds(from: finalTranscriptUptimeNanoseconds, to: postProcessingDoneUptimeNanoseconds)
    }

    var stopToInsertionMs: Double? {
        Self.milliseconds(from: stopUptimeNanoseconds, to: insertionUptimeNanoseconds)
    }

    var stopToVerifiedInsertionMs: Double? {
        Self.milliseconds(from: stopUptimeNanoseconds, to: verifiedInsertionUptimeNanoseconds)
    }

    var stopToClipboardRestoredMs: Double? {
        Self.milliseconds(from: stopUptimeNanoseconds, to: clipboardRestoredUptimeNanoseconds)
    }

    var logDescription: String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "nil" }
        func flag(_ value: Bool?) -> String { value.map(String.init) ?? "nil" }
        return [
            "failed=\(failed)",
            "engineReadyAtStart=\(flag(engineReadyAtStart))",
            "inputTransport=\(inputTransport ?? "nil")",
            "requestToFirstAudioBufferMs=\(ms(requestToFirstAudioBufferMs))",
            "prerollMs=\(ms(prerollMs))",
            "recordingSeconds=\(recordingSeconds.map { String(format: "%.2f", $0) } ?? "nil")",
            "stopToFinalTranscriptMs=\(ms(stopToFinalTranscriptMs))",
            "postProcessingMs=\(ms(postProcessingMs))",
            "llmPostProcessing=\(flag(llmPostProcessing))",
            "stopToInsertionMs=\(ms(stopToInsertionMs))",
            "insertion=\(insertion?.rawValue ?? "nil")",
            "pasteVerification=\(pasteVerification?.name ?? "nil")",
            "stopToVerifiedInsertionMs=\(ms(stopToVerifiedInsertionMs))",
            "stopToClipboardRestoredMs=\(ms(stopToClipboardRestoredMs))",
            "engine=\(engine ?? "nil")",
            "model=\(model ?? "nil")",
            "usedLiveResult=\(flag(usedLiveResult))",
        ].joined(separator: ", ")
    }

    private static func milliseconds(from start: UInt64?, to end: UInt64?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return Double(end - start) / 1_000_000
    }
}
