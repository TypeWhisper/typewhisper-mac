import AVFoundation
import Foundation
import os

// MARK: - Host Services

public protocol HostServices: Sendable {
    // Keychain
    func storeSecret(key: String, value: String) throws
    func loadSecret(key: String) -> String?

    // UserDefaults (plugin-scoped)
    func userDefault(forKey: String) -> Any?
    func setUserDefault(_ value: Any?, forKey: String)

    // Plugin data directory
    var pluginDataDirectory: URL { get }

    // App context
    var activeAppBundleId: String? { get }
    var activeAppName: String? { get }

    // Event bus
    var eventBus: EventBusProtocol { get }

    // Available rule names
    var availableRuleNames: [String] { get }

    // Available user workflows
    var availableWorkflows: [PluginWorkflowInfo] { get }

    // Notify host that plugin capabilities changed (e.g. model loaded/unloaded)
    func notifyCapabilitiesChanged()

    // Present this plugin's host-managed settings window, when available.
    func openPluginSettings()

    // Open a settings-sidebar page contributed by this plugin.
    func openSettingsSidebarItem(_ itemId: String)

    // Add media produced by one of this plugin's importers to TypeWhisper's
    // transcription queue. Returns false when the plugin/importer is inactive
    // or the media is rejected.
    func enqueueImportedMediaForTranscription(
        _ media: PluginImportedMedia,
        fromMediaImporterId mediaImporterId: String
    ) async -> Bool

    // Streaming display: call with true when the plugin provides its own streaming text UI,
    // so the built-in indicator suppresses its streaming text display.
    func setStreamingDisplayActive(_ active: Bool)
}

public protocol HostModelLifecyclePolicyProviding: Sendable {
    var shouldRestoreLoadedModelsPassively: Bool { get }
}

public extension HostServices {
    var shouldRestoreLoadedModelsPassively: Bool {
        (self as? any HostModelLifecyclePolicyProviding)?.shouldRestoreLoadedModelsPassively ?? true
    }

    var availableWorkflows: [PluginWorkflowInfo] { [] }

    func openPluginSettings() {}

    func openSettingsSidebarItem(_ itemId: String) {}

    func enqueueImportedMediaForTranscription(
        _ media: PluginImportedMedia,
        fromMediaImporterId mediaImporterId: String
    ) async -> Bool { false }

    @available(*, deprecated, renamed: "availableRuleNames")
    var availableProfileNames: [String] { availableRuleNames }
}

// MARK: - HTTP Client (Reusable Ephemeral Session)

@_spi(Testing) public protocol PluginHTTPClientSession: AnyObject {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func finishTasksAndInvalidate()
}

@_spi(Testing) extension URLSession: PluginHTTPClientSession {}

/// Whether a request rides the transient-failure retry ladder.
///
/// Retries are ON BY DEFAULT, so an ordinary plugin call rides out a brief upstream
/// failure without changing. `.disabled` restores exactly the behaviour that existed
/// before the ladder: one immediate retry after a session reset on a stale-connection
/// error, and nothing else.
///
/// Opt out where the caller is already looping, already retrying, or is holding
/// something the user is waiting on:
/// - polling loops that re-issue on a non-200 anyway, where a ladder multiplies the
///   loop's own bound;
/// - callers with their own retry, where two layers compound;
/// - teardown that a finished result is blocked behind.
public struct PluginHTTPRetryPolicy: Sendable, Equatable {
    public let laddersTransientFailures: Bool

    public static let `default` = PluginHTTPRetryPolicy(laddersTransientFailures: true)
    public static let disabled = PluginHTTPRetryPolicy(laddersTransientFailures: false)

    public init(laddersTransientFailures: Bool) {
        self.laddersTransientFailures = laddersTransientFailures
    }
}

/// Drop-in replacement for `URLSession.shared.data(for:)` that reuses one ephemeral
/// session so fast plugin requests can keep DNS/TLS/HTTP connections warm.
public enum PluginHTTPClient {
    private static let logger = Logger(subsystem: "com.typewhisper.sdk", category: "HTTP")
    private static let defaultRequestTimeout: TimeInterval = 30
    private static let longRunningResourceTimeout: TimeInterval = 600
    private static let lock = NSLock()

    /// Budget for retry SCHEDULING, not for the whole operation.
    ///
    /// It bounds the sum of the backoff sleeps: no retry sleep begins after it. It
    /// does NOT bound elapsed time, and calling it a wall-clock budget would be wrong.
    /// A request started just inside the deadline still runs its own timeout, so the
    /// true worst case is this budget plus one request timeout (30 s by default, and
    /// some callers set 120 s or 600 s). Bounding in-flight time would mean cancelling
    /// live requests, which is a larger change than this one.
    ///
    /// 25 s sits above Nielsen's 10 s "you owe a progress indicator" threshold and
    /// below the roughly 30 s at which users report frustration. No primary source
    /// gives a ceiling for a user-facing retry, so this is a synthesis, and it is
    /// deliberately conservative because a failed dictation preserves its recording.
    static let retrySchedulingBudget: Duration = .seconds(25)
    static let retryBaseDelay: Duration = .milliseconds(500)
    /// Per-delay ceiling. Note the ladder `retryMaxAttempts` permits ends at
    /// exactly this value (0.5s * 2^4), so under the current bound the cap never
    /// actually binds and is carried defensively, for if that bound is raised.
    static let retryMaxDelay: Duration = .seconds(8)
    /// Total attempts, initial included, so at most five retries.
    ///
    /// The budget alone is not a sufficient bound: full jitter draws from
    /// `random(0, capped)`, so an endpoint that fails instantly can draw a run of
    /// near-zero delays and burn a great many attempts inside 25 s. Un-jittered the
    /// ladder here is 0.5 + 1 + 2 + 4 + 8 = 15.5 s, comfortably inside the budget, so
    /// in practice attempts bind first and the budget catches the slow cases: a
    /// long-running request, or a `Retry-After` that would overshoot.
    static let retryMaxAttempts = 6

    /// Injectable so tests assert the SCHEDULE without sleeping through it.
    nonisolated(unsafe) private static var _sleeper: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    private static var sleeper: @Sendable (Duration) async throws -> Void {
        lock.withLock { _sleeper }
    }
    /// Injectable so tests see a deterministic ladder instead of jittered values.
    nonisolated(unsafe) private static var _jitterFraction: @Sendable () -> Double = {
        Double.random(in: 0...1)
    }
    private static var jitterFraction: @Sendable () -> Double {
        lock.withLock { _jitterFraction }
    }
    nonisolated(unsafe) private static var sharedSession: (any PluginHTTPClientSession)?
    nonisolated(unsafe) private static var sessionFactory: (URLSessionConfiguration) -> any PluginHTTPClientSession = {
        URLSession(configuration: $0)
    }

    /// Kept as a distinct one-argument overload, NOT collapsed into a defaulted
    /// parameter on the call below. Nine call sites pass `PluginHTTPClient.data` as an
    /// unapplied function reference typed
    /// `@Sendable (URLRequest) async throws -> (Data, URLResponse)`, and a defaulted
    /// parameter does not preserve that type.
    public static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, retry: .default)
    }

    public static func data(
        for request: URLRequest,
        retry policy: PluginHTTPRetryPolicy
    ) async throws -> (Data, URLResponse) {
        try ensureNetworkAccessIsAllowed()
        return try await dataWithRetries(for: request, policy: policy)
    }

    public static func data(
        for request: URLRequest,
        resourceTimeout: TimeInterval?
    ) async throws -> (Data, URLResponse) {
        try ensureNetworkAccessIsAllowed()
        guard let resourceTimeout, resourceTimeout > longRunningResourceTimeout else {
            return try await dataWithRetries(for: request, policy: .default)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = resourceTimeout
        config.timeoutIntervalForResource = resourceTimeout
        let session = sessionFactory(config)
        defer { session.finishTasksAndInvalidate() }

        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        logger.info("\(method) \(url) (dedicated session, resourceTimeout=\(resourceTimeout))")
        return try await session.data(for: request)
    }

    public static func ensureNetworkAccessIsAllowed() throws {
        try ensureNetworkAccessIsAllowed(arguments: ProcessInfo.processInfo.arguments)
    }

    @_spi(Testing) public static func ensureNetworkAccessIsAllowed(arguments: [String]) throws {
        guard networkAccessAllowed(arguments: arguments) else {
            throw URLError(.notConnectedToInternet)
        }
    }

    static func networkAccessAllowed(arguments: [String]) -> Bool {
        #if DEBUG
        return !arguments.contains("--store-screenshots")
        #else
        return true
        #endif
    }

    public static func resetSharedSession(reason: String? = nil) {
        let session = lock.withLock {
            let existing = sharedSession
            sharedSession = nil
            return existing
        }

        session?.finishTasksAndInvalidate()
        if let reason {
            logger.info("Reset shared plugin HTTP session: \(reason)")
        } else {
            logger.info("Reset shared plugin HTTP session")
        }
    }

    @_spi(Testing) public static func configureForTesting(
        _ factory: @escaping (URLSessionConfiguration) -> any PluginHTTPClientSession
    ) {
        resetSharedSession(reason: "test reconfiguration")
        lock.withLock {
            sessionFactory = factory
        }
    }

    /// Replaces the sleep and jitter sources so a test asserts the retry SCHEDULE
    /// deterministically instead of sleeping through it. `jitterFraction` returning 1
    /// gives the un-jittered upper bound of the ladder, which is the readable case to
    /// assert against.
    @_spi(Testing) public static func configureRetryForTesting(
        sleeper newSleeper: @escaping @Sendable (Duration) async throws -> Void,
        jitterFraction newJitter: @escaping @Sendable () -> Double = { 1.0 }
    ) {
        lock.withLock {
            _sleeper = newSleeper
            _jitterFraction = newJitter
        }
    }

    @_spi(Testing) public static func resetTestingHooks() {
        resetSharedSession(reason: "test cleanup")
        lock.withLock {
            sessionFactory = { URLSession(configuration: $0) }
            _sleeper = { try await Task.sleep(for: $0) }
            _jitterFraction = { Double.random(in: 0...1) }
        }
    }

    /// Runs `request` against the shared session, retrying transient failures.
    ///
    /// Two failure shapes reach this and they are not the same:
    ///
    /// - A thrown `URLError`. The first retry is IMMEDIATE after resetting the shared
    ///   session, and only for the stale-pooled-connection codes that reset actually
    ///   fixes. This is the behaviour that existed before the ladder and is preserved
    ///   verbatim, including under `.disabled`.
    /// - A delivered response carrying a retryable status. This never threw, so before
    ///   the ladder it went straight back to the plugin. That is the gap that let a
    ///   Cloudflare 522 in front of a transcription API fail a dictation with no retry.
    ///
    /// On exhaustion the last response is RETURNED, not thrown, so the caller still
    /// sees the real status and body. Note two in-repo callers ignore the response
    /// entirely, so an exhausted 503 reads to them as success; that predates this and
    /// is called out in the pull request rather than silently relied upon.
    private static func dataWithRetries(
        for request: URLRequest,
        policy: PluginHTTPRetryPolicy
    ) async throws -> (Data, URLResponse) {
        let deadline = ContinuousClock.now + retrySchedulingBudget
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "unknown"
        var attempt = 0
        var usedRetryAfterGrace = false

        while true {
            let session = sharedOrCreateSession()
            logger.info("\(method) \(url) (attempt \(attempt + 1))")
            let start = ContinuousClock.now

            do {
                let (data, response) = try await session.data(for: request)
                let elapsed = ContinuousClock.now - start
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.info("\(method) \(url) -> \(status) (\(elapsed))")

                guard policy.laddersTransientFailures,
                      let http = response as? HTTPURLResponse
                else {
                    return (data, response)
                }

                let decision = retryAfterDecision(from: http)

                // A well-formed Retry-After beyond the honoured ceiling is a refusal, not
                // a delay: the server is asking us to stay away for longer than we are
                // ever willing to sleep. Stop, rather than falling through to the ladder
                // and retrying almost immediately.
                if case .refusal = decision {
                    logger.warning("\(method) \(url) -> \(status), Retry-After beyond the honoured ceiling, treating as a refusal and not retrying")
                    return (data, response)
                }

                let retryAfter: Duration?
                if case let .after(delay) = decision {
                    retryAfter = delay
                } else {
                    retryAfter = nil
                }

                // 429: one retry, only on an explicit Retry-After that fits.
                if isRetryAfterOnlyStatus(http.statusCode) {
                    guard !usedRetryAfterGrace,
                          attempt + 1 < retryMaxAttempts,
                          let retryAfter,
                          retryAfter <= deadline - ContinuousClock.now
                    else {
                        return (data, response)
                    }
                    usedRetryAfterGrace = true
                    attempt += 1
                    logger.warning("\(method) \(url) -> 429, honouring Retry-After \(retryAfter) once")
                    try await sleeper(retryAfter)
                    continue
                }

                guard isRetryableStatus(http.statusCode, method: method) else {
                    return (data, response)
                }
                guard attempt + 1 < retryMaxAttempts,
                      let delay = backoffDelay(forAttempt: attempt, deadline: deadline, retryAfter: retryAfter)
                else {
                    logger.warning("\(method) \(url) -> \(status), retries exhausted after \(attempt + 1) attempt(s)")
                    return (data, response)
                }

                attempt += 1
                logger.warning("\(method) \(url) -> \(status), retrying in \(delay) (attempt \(attempt + 1))")
                try await sleeper(delay)
            } catch {
                let elapsed = ContinuousClock.now - start
                guard isTransientNetworkError(error) else {
                    logger.error("\(method) \(url) failed after \(elapsed): \(error.localizedDescription)")
                    throw error
                }

                resetSharedSession(matching: session, reason: "transient network error")

                // Compatibility, and it applies under BOTH policies: one immediate
                // retry after the reset, for ANY transient error. This is exactly what
                // this client did before the ladder existed, and narrowing it would be
                // an alteration rather than an addition. A poll loop that opts out with
                // `.disabled` therefore behaves precisely as it did before.
                if attempt == 0 {
                    attempt += 1
                    logger.warning("\(method) \(url) transient failure after \(elapsed), reset session, retrying immediately: \(error.localizedDescription)")
                    continue
                }

                // Everything past that first retry is new, and is gated the same way
                // the status ladder is. A POST can time out AFTER the origin processed
                // it, so laddering a non-idempotent request risks duplicating the work.
                guard policy.laddersTransientFailures,
                      isIdempotentMethod(method),
                      attempt + 1 < retryMaxAttempts,
                      let delay = backoffDelay(forAttempt: attempt, deadline: deadline, retryAfter: nil)
                else {
                    logger.error("\(method) \(url) transient failure after \(elapsed), not retrying further: \(error.localizedDescription)")
                    throw error
                }

                attempt += 1
                logger.warning("\(method) \(url) transient failure after \(elapsed), retrying in \(delay) (attempt \(attempt + 1)): \(error.localizedDescription)")
                try await sleeper(delay)
            }
        }
    }

    /// Whether a delivered status is worth retrying FOR THIS REQUEST'S METHOD.
    ///
    /// The axis is not "is this a server error" but "could the origin already have
    /// applied the request". This client is shared by plugins that POST
    /// side-effecting requests: `WebhookPlugin` delivers a user-configured method,
    /// `LinearPlugin` runs GraphQL mutations, `OpenAIVectorMemoryPlugin` uploads and
    /// attaches files. Duplicating those is worse than failing.
    ///
    /// - Always safe: the request provably never reached a working origin. 408 was
    ///   never received; Cloudflare 521 (origin down), 522 (connection timed out),
    ///   523 (origin unreachable) and 525/526 (TLS handshake failed) all fail before
    ///   the origin sees a byte. The failure that motivated this work was a 522 on a
    ///   POST, and it stays retried for every method.
    /// - Idempotent methods only: 502, 503, 504, 520 and 524 do NOT establish that
    ///   the origin skipped the work. Cloudflare documents 524 as the connection
    ///   having been established with no timely answer, so the origin may still
    ///   complete it.
    ///
    ///   503 sits here rather than above, which is a change of mind. Its semantics do
    ///   say the origin declined to handle the request, and on that reasoning it was
    ///   originally any-method. But two independent reviewers pointed at the same
    ///   concrete exposure: `AssemblyAIPlugin.submitTranscription` POSTs job creation
    ///   through the default policy, so a 503 returned after the job was created would
    ///   resubmit it, and Linear mutations and vector-store uploads have the same
    ///   shape. A semantic argument does not outweigh a duplicate transcription job,
    ///   and the outage case this work exists for is a 52x, which is unaffected.
    /// - Never: 500, which can mean the origin accepted the work and then failed
    ///   partway, and 429, which is a deliberate refusal the origin explained. See
    ///   `retryAfterOnlyStatuses` for how 429 is handled instead.
    static func isRetryableStatus(_ status: Int, method: String) -> Bool {
        switch status {
        case 408, 521, 522, 523, 525, 526:
            return true
        case 502, 503, 504, 520, 524:
            return isIdempotentMethod(method)
        default:
            return false
        }
    }

    /// RFC 9110 section 9.2.2: these are safe to repeat. POST and PATCH are not.
    static func isIdempotentMethod(_ method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE":
            return true
        default:
            return false
        }
    }

    /// 429 gets exactly one retry, and only when the origin said when to come back.
    ///
    /// Not laddered. The plugins above already map 429 to a rate-limit or quota error,
    /// and a quota will not clear inside this budget. But a provider that sends
    /// `Retry-After: 2` on a burst throttle is telling us something actionable, and
    /// ignoring it is pessimistic. No header means no retry.
    static func isRetryAfterOnlyStatus(_ status: Int) -> Bool {
        status == 429
    }

    /// Full jitter: `random(0, min(cap, base * 2^attempt))`, the shipped consensus.
    /// Returns nil when nothing more fits inside the budget, which is the signal to
    /// stop. A `Retry-After` longer than the remaining budget also stops rather than
    /// sleeping past the deadline.
    static func backoffDelay(
        forAttempt attempt: Int,
        deadline: ContinuousClock.Instant,
        retryAfter: Duration?
    ) -> Duration? {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return nil }

        if let retryAfter {
            return retryAfter <= remaining ? retryAfter : nil
        }

        // Arithmetic in seconds rather than on Duration: explicit, and it keeps the
        // jitter multiply off Duration's operator surface.
        let base = seconds(of: retryBaseDelay)
        let cap = seconds(of: retryMaxDelay)
        // Bounded shift so a long-lived ladder cannot overflow; the cap makes it moot.
        let growth = Double(1 << min(max(attempt, 0), 20))
        let capped = min(base * growth, cap)
        let jittered = Duration.seconds(capped * jitterFraction())
        guard jittered <= remaining else { return nil }
        return jittered
    }

    static func seconds(of duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    /// Parses the delta-seconds form of `Retry-After`.
    ///
    /// Parsed as an INTEGER, which is what RFC 9110 defines delta-seconds to be, and
    /// clamped. That is not tidiness: `Double("999999999999999999999999")` is finite
    /// and non-negative, passes an `isFinite` guard, and then TRAPS inside
    /// `Duration.seconds(_:)` with an overflow in multiplication, killing the process.
    /// A hostile or merely broken origin could crash the app from a response header.
    ///
    /// The HTTP-date form is not honoured. It needs clock-skew handling to be safe and
    /// falls through to the ordinary ladder instead.
    /// How to treat a `Retry-After` on a retryable response.
    enum RetryAfterDecision: Equatable {
        /// No usable header: absent, empty, non-integer, or negative. Fall through to
        /// the ordinary backoff ladder.
        case none
        /// A usable delay. Honour it, subject to the remaining budget.
        case after(Duration)
        /// A well-formed delta-seconds beyond `maxHonouredRetryAfterSeconds`. This is a
        /// refusal, not a delay, so we do not retry at all.
        case refusal
    }

    static func retryAfterDecision(from response: HTTPURLResponse) -> RetryAfterDecision {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces),
            let seconds = Int(raw),
            seconds >= 0
        else {
            // Absent, empty, non-integer, or negative. Note an oversized value like
            // "999999999999999999999999" also lands here: it overflows Int and parses
            // as nil, so it is treated as an unusable header, not a refusal.
            return .none
        }
        if seconds > maxHonouredRetryAfterSeconds {
            return .refusal
        }
        return .after(.seconds(seconds))
    }

    /// A day. Anything longer is not a delay, it is a refusal, and we do not sleep on
    /// it. Also keeps the value far below the range where Duration arithmetic traps.
    static let maxHonouredRetryAfterSeconds = 86_400
    private static func sharedOrCreateSession() -> any PluginHTTPClientSession {
        lock.withLock {
            if let sharedSession {
                return sharedSession
            }

            let session = sessionFactory(makeConfiguration())
            sharedSession = session
            return session
        }
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaultRequestTimeout
        config.timeoutIntervalForResource = longRunningResourceTimeout
        return config
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
    private static func resetSharedSession(matching session: any PluginHTTPClientSession, reason: String) {
        let didRemoveSharedSession = lock.withLock {
            guard let current = sharedSession, current === session else {
                return false
            }
            sharedSession = nil
            return true
        }

        session.finishTasksAndInvalidate()
        if didRemoveSharedSession {
            logger.info("Reset shared plugin HTTP session: \(reason)")
        } else {
            logger.info("Invalidated plugin HTTP session after \(reason)")
        }
    }

}

// MARK: - WAV Encoder Utility

public struct PluginWavEncoder {
    public static func encode(_ samples: [Float], sampleRate: Int = 16000) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(blockAlign))
        let fileSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Fill the PCM payload in one allocation instead of appending each sample.
        data.count = 44 + Int(dataSize)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (index, sample) in samples.enumerated() {
                let clamped = max(-1.0, min(1.0, sample))
                let value = UInt16(bitPattern: Int16(clamped * 32767))
                // Explicit bytes avoid alignment assumptions and preserve little endian PCM.
                bytes[44 + index * 2] = UInt8(truncatingIfNeeded: value)
                bytes[45 + index * 2] = UInt8(truncatingIfNeeded: value >> 8)
            }
        }

        return data
    }
}

public struct PluginAudioUploadFile: Sendable, Equatable {
    public let data: Data
    public let filename: String
    public let contentType: String
    public let format: String

    public init(data: Data, filename: String, contentType: String, format: String) {
        self.data = data
        self.filename = filename
        self.contentType = contentType
        self.format = format
    }
}

/// Preserves the raw HTTP response used to classify an upload retry while
/// keeping the user-facing error bounded and provider-specific.
public struct PluginAudioUploadHTTPFailure: Error, @unchecked Sendable {
    public let statusCode: Int
    public let responseData: Data
    public let underlyingError: any Error

    public init(statusCode: Int, responseData: Data, underlyingError: any Error) {
        self.statusCode = statusCode
        self.responseData = responseData
        self.underlyingError = underlyingError
    }
}

public enum PluginAudioUploadEncoder {
    public static let sampleRate = 16_000
    public static let minimumUploadDuration: TimeInterval = 1.0
    private static let compressedUploadChunkFrames = 16_000 * 30

    public static func normalizedAudioForUpload(_ audio: AudioData) -> AudioData {
        guard audio.duration < minimumUploadDuration else { return audio }

        let paddedSamples = PluginAudioUtils.paddedSamples(
            audio.samples,
            minimumDuration: minimumUploadDuration,
            sampleRate: sampleRate
        )
        guard paddedSamples.count != audio.samples.count else { return audio }

        return AudioData(
            samples: paddedSamples,
            wavData: PluginWavEncoder.encode(paddedSamples, sampleRate: sampleRate),
            duration: Double(paddedSamples.count) / Double(sampleRate)
        )
    }

    public static func wavUpload(from audio: AudioData) -> PluginAudioUploadFile {
        PluginAudioUploadFile(
            data: audio.wavData,
            filename: "audio.wav",
            contentType: "audio/wav",
            format: "wav"
        )
    }

    public static func wavUpload(from samples: [Float], sampleRate: Int = 16_000) -> PluginAudioUploadFile {
        PluginAudioUploadFile(
            data: PluginWavEncoder.encode(samples, sampleRate: sampleRate),
            filename: "audio.wav",
            contentType: "audio/wav",
            format: "wav"
        )
    }

    public static func compressedM4AUpload(from audio: AudioData) throws -> PluginAudioUploadFile {
        try compressedM4AUpload(from: audio.samples)
    }

    public static func compressedM4AUpload(from samples: [Float]) throws -> PluginAudioUploadFile {
        PluginAudioUploadFile(
            data: try compressedM4AData(from: samples),
            filename: "audio.m4a",
            contentType: "audio/mp4",
            format: "m4a"
        )
    }

    public static func withCompressedM4AUploadWavFallback<Result>(
        from audio: AudioData,
        operation: (PluginAudioUploadFile) async throws -> Result
    ) async throws -> Result {
        let uploadAudio = normalizedAudioForUpload(audio)
        let preferredUpload: PluginAudioUploadFile
        do {
            preferredUpload = try compressedM4AUpload(from: uploadAudio)
        } catch {
            do {
                return try await operation(wavUpload(from: uploadAudio))
            } catch {
                throw underlyingUploadError(error)
            }
        }

        do {
            return try await operation(preferredUpload)
        } catch {
            let shouldRetry: Bool
            if let failure = error as? PluginAudioUploadHTTPFailure {
                shouldRetry = shouldRetryWithWavUpload(
                    statusCode: failure.statusCode,
                    responseData: failure.responseData
                )
            } else {
                shouldRetry = shouldRetryWithWavUpload(error: error)
            }

            guard shouldRetry else {
                throw underlyingUploadError(error)
            }

            do {
                return try await operation(wavUpload(from: uploadAudio))
            } catch {
                throw underlyingUploadError(error)
            }
        }
    }

    private static func underlyingUploadError(_ error: any Error) -> any Error {
        (error as? PluginAudioUploadHTTPFailure)?.underlyingError ?? error
    }

    public static func shouldRetryWithWavUpload(statusCode: Int, responseData: Data) -> Bool {
        guard statusCode != 415 else { return true }

        let message = String(data: responseData, encoding: .utf8) ?? ""
        let candidates = audioUploadErrorMessageCandidates(from: message)
        if [400, 422].contains(statusCode) {
            return candidates.contains { indicatesUnsupportedAudioUpload($0) }
        }

        if statusCode == 500 {
            return candidates.contains { indicatesMediaProbeFailure($0) }
        }

        return false
    }

    public static func shouldRetryWithWavUpload(error: Error) -> Bool {
        guard case PluginTranscriptionError.apiError(let message) = error else {
            return false
        }

        if message.localizedCaseInsensitiveContains("Failed to encode compressed upload") {
            return true
        }

        if message.contains("HTTP 415:") {
            return true
        }

        let candidates = audioUploadErrorMessageCandidates(from: message)
        if message.contains("HTTP 500:") {
            return candidates.contains { indicatesMediaProbeFailure($0) }
        }

        guard message.contains("HTTP 400:") || message.contains("HTTP 422:") else { return false }

        return candidates.contains { indicatesUnsupportedAudioUpload($0) }
    }

    private static func audioUploadErrorMessageCandidates(from responseText: String) -> [String] {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonStart = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return [trimmed]
        }

        let jsonText = String(trimmed[jsonStart...])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [trimmed]
        }

        return extractAudioUploadErrorMessages(from: object)
    }

    private static func extractAudioUploadErrorMessages(from object: Any) -> [String] {
        let messageKeys = ["error", "message", "err_msg", "error_message", "detail", "description"]

        if let message = object as? String {
            return [message]
        }

        if let dictionary = object as? [String: Any] {
            return messageKeys.flatMap { key -> [String] in
                guard let value = dictionary[key] else { return [] }
                return extractAudioUploadErrorMessages(from: value)
            }
        }

        if let array = object as? [Any] {
            return array.flatMap { extractAudioUploadErrorMessages(from: $0) }
        }

        return []
    }

    private static func indicatesUnsupportedAudioUpload(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let rejectionTerms = [
            "unsupported", "not supported", "does not support", "invalid", "unrecognized", "unknown",
            "could not process", "failed to process", "corrupt",
        ]
        let mediaTerms = [
            "format", "media", "mime", "content-type", "content type",
            "codec", "container", "file type", "audio",
            "m4a", "mp4", "aac", "wav",
        ]
        return rejectionTerms.contains { lowercased.contains($0) }
            && mediaTerms.contains { lowercased.contains($0) }
    }

    private static func indicatesMediaProbeFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let probeFailures = [
            "ffprobe failed",
            "ffprobe error",
            "ffprobe returned",
            "ffprobe exited",
            "ffmpeg failed",
            "ffmpeg error",
            "ffmpeg returned",
            "ffmpeg exited",
            "moov atom not found",
            "invalid data found when processing input",
        ]
        return probeFailures.contains { lowercased.contains($0) }
    }

    private static func compressedM4AData(from samples: [Float]) throws -> Data {
        guard !samples.isEmpty else {
            throw PluginTranscriptionError.apiError("Cannot encode empty audio upload")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typewhisper-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw PluginTranscriptionError.apiError("Failed to create compressed upload format")
        }

        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            var offset = 0
            while offset < samples.count {
                let count = min(compressedUploadChunkFrames, samples.count - offset)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(count)
                ) else {
                    throw PluginTranscriptionError.apiError("Failed to create compressed upload buffer")
                }
                buffer.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { pointer in
                    buffer.floatChannelData?[0].update(from: pointer.baseAddress! + offset, count: count)
                }
                try file.write(from: buffer)
                offset += count
            }
        }

        return try Data(contentsOf: url)
    }
}

// MARK: - OpenAI-Compatible Transcription Helper

public enum PluginTranscriptionError: LocalizedError, Sendable {
    case notConfigured
    case noModelSelected
    case invalidApiKey
    case rateLimited
    case fileTooLarge
    case apiError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud provider not configured. Please set an API key."
        case .noModelSelected:
            "No cloud model selected."
        case .invalidApiKey:
            "Invalid API key. Please check your API key and try again."
        case .rateLimited:
            "Rate limit exceeded. Please wait and try again."
        case .fileTooLarge:
            "Audio file too large for the API."
        case .apiError(let message):
            "API error: \(message)"
        case .networkError(let message):
            "Network error: \(message)"
        }
    }
}

public struct PluginOpenAITranscriptionHelper: Sendable {
    public let baseURL: String
    public let responseFormat: String
    private static let defaultRequestTimeout: TimeInterval = 30
    static let minimumUploadDuration: TimeInterval = 1.0
    static let uploadSampleRate = 16000

    public init(baseURL: String, responseFormat: String = "verbose_json") {
        self.baseURL = baseURL
        self.responseFormat = responseFormat
    }

    func normalizedAudioForUpload(_ audio: AudioData) -> AudioData {
        guard audio.duration < Self.minimumUploadDuration else { return audio }

        let paddedSamples = PluginAudioUtils.paddedSamples(
            audio.samples,
            minimumDuration: Self.minimumUploadDuration,
            sampleRate: Self.uploadSampleRate
        )
        guard paddedSamples.count != audio.samples.count else { return audio }

        return AudioData(
            samples: paddedSamples,
            wavData: PluginWavEncoder.encode(paddedSamples, sampleRate: Self.uploadSampleRate),
            duration: Double(paddedSamples.count) / Double(Self.uploadSampleRate)
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            apiVersion: nil
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        responseFormat: String? = nil,
        apiVersion: String?
    ) async throws -> PluginTranscriptionResult {
        try await performTranscribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: Self.defaultRequestTimeout,
            apiVersion: apiVersion
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: requestTimeout,
            responseFormat: responseFormat,
            apiVersion: nil
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        apiVersion: String?
    ) async throws -> PluginTranscriptionResult {
        try await performTranscribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout,
            apiVersion: apiVersion
        )
    }

    public func transcribeCompressedAudio(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        try await transcribeCompressedAudio(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: requestTimeout,
            responseFormat: responseFormat,
            apiVersion: nil
        )
    }

    public func transcribeCompressedAudio(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        apiVersion: String?
    ) async throws -> PluginTranscriptionResult {
        let uploadAudio = normalizedAudioForUpload(audio)
        let uploadFile: PluginAudioUploadFile
        do {
            uploadFile = try PluginAudioUploadEncoder.compressedM4AUpload(from: uploadAudio)
        } catch {
            throw PluginTranscriptionError.apiError(
                "Failed to encode compressed upload: \(error.localizedDescription)"
            )
        }

        return try await performTranscribe(
            audio: uploadAudio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout,
            uploadFile: uploadFile,
            apiVersion: apiVersion
        )
    }

    public func transcribeCompressedAudioWithWavFallback(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil
    ) async throws -> PluginTranscriptionResult {
        try await transcribeCompressedAudioWithWavFallback(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: requestTimeout,
            responseFormat: responseFormat,
            apiVersion: nil
        )
    }

    public func transcribeCompressedAudioWithWavFallback(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        apiVersion: String?
    ) async throws -> PluginTranscriptionResult {
        let uploadAudio = normalizedAudioForUpload(audio)
        let preferredUpload: PluginAudioUploadFile
        do {
            preferredUpload = try PluginAudioUploadEncoder.compressedM4AUpload(from: uploadAudio)
        } catch {
            return try await performTranscribe(
                audio: uploadAudio,
                apiKey: apiKey,
                modelName: modelName,
                language: language,
                translate: translate,
                prompt: prompt,
                responseFormat: responseFormat,
                requestTimeout: requestTimeout,
                apiVersion: apiVersion
            )
        }

        return try await performTranscribe(
            audio: uploadAudio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout,
            uploadFile: preferredUpload,
            apiVersion: apiVersion,
            allowsWavFallback: true
        )
    }

    public func transcribeWithUploadFallback(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        uploadFile: PluginAudioUploadFile
    ) async throws -> PluginTranscriptionResult {
        try await transcribeWithUploadFallback(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: requestTimeout,
            responseFormat: responseFormat,
            uploadFile: uploadFile,
            apiVersion: nil
        )
    }

    public func transcribeWithUploadFallback(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        uploadFile: PluginAudioUploadFile,
        apiVersion: String?
    ) async throws -> PluginTranscriptionResult {
        try await performTranscribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout,
            uploadFile: uploadFile,
            apiVersion: apiVersion,
            allowsWavFallback: true
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        uploadFile: PluginAudioUploadFile
    ) async throws -> PluginTranscriptionResult {
        try await transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            requestTimeout: requestTimeout,
            responseFormat: responseFormat,
            uploadFile: uploadFile,
            apiVersion: nil
        )
    }

    public func transcribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        requestTimeout: TimeInterval,
        responseFormat: String? = nil,
        uploadFile: PluginAudioUploadFile,
        apiVersion: String?
    ) async throws -> PluginTranscriptionResult {
        try await performTranscribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelName,
            language: language,
            translate: translate,
            prompt: prompt,
            responseFormat: responseFormat,
            requestTimeout: requestTimeout,
            uploadFile: uploadFile,
            apiVersion: apiVersion
        )
    }

    private func performTranscribe(
        audio: AudioData,
        apiKey: String,
        modelName: String,
        language: String?,
        translate: Bool,
        prompt: String?,
        responseFormat: String?,
        requestTimeout: TimeInterval,
        uploadFile: PluginAudioUploadFile? = nil,
        apiVersion: String? = nil,
        allowsWavFallback: Bool = false
    ) async throws -> PluginTranscriptionResult {
        let path = translate ? "/v1/audio/translations" : "/v1/audio/transcriptions"
        guard let url = requestURL(path: path, apiVersion: apiVersion) else {
            throw PluginTranscriptionError.apiError("Invalid URL: \(baseURL)\(path)")
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        let uploadAudio = uploadFile == nil ? normalizedAudioForUpload(audio) : audio
        let uploadFile = uploadFile ?? PluginAudioUploadEncoder.wavUpload(from: uploadAudio)
        var body = Data()

        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(uploadFile.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(uploadFile.contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(uploadFile.data)
        body.append("\r\n".data(using: .utf8)!)

        // model field
        body.appendFormField(boundary: boundary, name: "model", value: modelName)

        // response_format field
        let format = responseFormat ?? self.responseFormat
        body.appendFormField(boundary: boundary, name: "response_format", value: format)

        // language field (only for transcription)
        if !translate, let language, !language.isEmpty {
            body.appendFormField(boundary: boundary, name: "language", value: language)
        }

        // prompt field
        if let prompt, !prompt.isEmpty {
            body.appendFormField(boundary: boundary, name: "prompt", value: prompt)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (responseData, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginTranscriptionError.networkError("Invalid response")
        }

        if allowsWavFallback,
           uploadFile.format != "wav",
           PluginAudioUploadEncoder.shouldRetryWithWavUpload(
            statusCode: httpResponse.statusCode,
            responseData: responseData
           ) {
            return try await performTranscribe(
                audio: audio,
                apiKey: apiKey,
                modelName: modelName,
                language: language,
                translate: translate,
                prompt: prompt,
                responseFormat: responseFormat,
                requestTimeout: requestTimeout,
                uploadFile: PluginAudioUploadEncoder.wavUpload(from: normalizedAudioForUpload(audio)),
                apiVersion: apiVersion
            )
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginTranscriptionError.invalidApiKey
        case 429:
            throw PluginTranscriptionError.rateLimited
        case 413:
            throw PluginTranscriptionError.fileTooLarge
        default:
            let errorMessage = PluginHTTPErrorBodyFormatter.summary(
                from: responseData,
                response: httpResponse
            )
            throw PluginTranscriptionError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        return try parseResponse(responseData, response: httpResponse)
    }

    public func validateApiKey(_ apiKey: String) async -> Bool {
        await validateApiKey(apiKey, apiVersion: nil)
    }

    public func validateApiKey(_ apiKey: String, apiVersion: String?) async -> Bool {
        guard !apiKey.isEmpty else { return false }
        guard let url = requestURL(path: "/v1/models", apiVersion: apiVersion) else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (_, response) = try await PluginHTTPClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private func requestURL(path: String, apiVersion: String?) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, requestPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        let trimmedVersion = apiVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedVersion.isEmpty {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name.caseInsensitiveCompare("api-version") == .orderedSame }
            queryItems.append(URLQueryItem(name: "api-version", value: trimmedVersion))
            components.queryItems = queryItems
        }
        return components.url
    }

    private struct APISegment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    private struct APIResponse: Decodable {
        let text: String
        let language: String?
        let segments: [APISegment]?
    }

    private func parseResponse(
        _ data: Data,
        response: HTTPURLResponse
    ) throws -> PluginTranscriptionResult {
        if let htmlPageSummary = PluginHTTPErrorBodyFormatter.htmlPageSummary(
            from: data,
            response: response
        ) {
            throw PluginTranscriptionError.apiError(
                "Failed to parse response: \(htmlPageSummary)"
            )
        }

        do {
            let response = try JSONDecoder().decode(APIResponse.self, from: data)
            let segments = (response.segments ?? []).map {
                PluginTranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
            }
            return PluginTranscriptionResult(text: response.text, detectedLanguage: response.language, segments: segments)
        } catch {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                return PluginTranscriptionResult(text: text, detectedLanguage: json["language"] as? String)
            }
            throw PluginTranscriptionError.apiError("Failed to parse response: \(error.localizedDescription)")
        }
    }
}

// MARK: - OpenAI-Compatible Chat Completion Helper

public enum PluginChatError: LocalizedError, Sendable {
    case notConfigured
    case noModelSelected
    case invalidApiKey
    case rateLimited
    case apiError(String)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "LLM provider not configured. Please set an API key."
        case .noModelSelected:
            "No LLM model selected."
        case .invalidApiKey:
            "Invalid API key. Please check your API key and try again."
        case .rateLimited:
            "Rate limit exceeded. Please wait and try again."
        case .apiError(let message):
            "API error: \(message)"
        case .networkError(let message):
            "Network error: \(message)"
        }
    }
}

public struct PluginOpenAIChatHelper: Sendable {
    public let baseURL: String
    public let chatEndpoint: String

    public init(baseURL: String, chatEndpoint: String = "/v1/chat/completions") {
        self.baseURL = baseURL
        self.chatEndpoint = chatEndpoint
    }

    // Keep the pre-ac10ea9 symbol available so already-installed plugin bundles
    // continue to load after the helper grew token-parameter customization.
    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: 4096,
            maxOutputTokenParameter: "max_tokens"
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        reasoningEffort: String? = nil
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: 0.3
        )
    }

    // Keep the pre-requestTimeout symbols available so already-installed plugin
    // bundles continue to load after the helper grew the timeout parameter.
    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        reasoningEffort: String? = nil,
        temperature: Double?
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            requestTimeout: 30
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        reasoningEffort: String? = nil,
        temperature: Double?,
        requestTimeout: TimeInterval
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            requestTimeout: requestTimeout,
            thinkingEnabled: nil
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        reasoningEffort: String? = nil,
        temperature: Double?,
        requestTimeout: TimeInterval,
        thinkingEnabled: Bool?
    ) async throws -> String {
        let endpoint = "\(baseURL)\(chatEndpoint)"
        guard let url = URL(string: endpoint) else {
            throw PluginChatError.apiError("Invalid URL: \(endpoint)")
        }

        let requestBody = requestBody(
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            thinkingEnabled: thinkingEnabled
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request, resourceTimeout: requestTimeout)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            throw PluginChatError.apiError(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        return Self.chatMessageContent(from: message).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts assistant text from an OpenAI-compatible chat `message`.
    /// Reasoning-capable models (e.g. gpt-oss on Cerebras, some OpenRouter
    /// models) return `content: null` when the visible answer is empty - that
    /// is a valid empty response, not a malformed one. Some providers also
    /// return `content` as an array of typed parts. Reasoning text is never
    /// promoted to content.
    public static func chatMessageContent(from message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            // Only typed text parts contribute. A `reasoning` (or any other
            // typed) part may also carry a `text` field and must never be
            // promoted into the visible answer.
            return parts.compactMap { part -> String? in
                guard (part["type"] as? String) == "text" else { return nil }
                return (part["text"] as? String) ?? (part["content"] as? String)
            }.joined()
        }
        // null or absent content: an intentionally empty visible answer
        return ""
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens"
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: nil
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        temperature: Double?
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: nil,
            temperature: temperature,
            requestTimeout: 30
        )
    }

    public func process(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int? = 4096,
        maxOutputTokenParameter: String = "max_tokens",
        temperature: Double?,
        requestTimeout: TimeInterval
    ) async throws -> String {
        try await process(
            apiKey: apiKey,
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: nil,
            temperature: temperature,
            requestTimeout: requestTimeout
        )
    }

    /// Extracts a human-readable error message from an OpenAI-compatible error body,
    /// falling back to `HTTP <status>` when no message can be found.
    ///
    /// Most providers return `{"error": {"message": ...}}`, but some (notably
    /// Google's Gemini OpenAI-compat endpoint) wrap the error in a top-level JSON
    /// array: `[{"error": {"message": ...}}]`. Both shapes are handled here so the
    /// descriptive message survives instead of being collapsed to `HTTP 404`.
    static func errorMessage(from data: Data, statusCode: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: data)

        let object: [String: Any]?
        if let dictionary = json as? [String: Any] {
            object = dictionary
        } else if let array = json as? [Any],
                  let first = array.first as? [String: Any] {
            object = first
        } else {
            object = nil
        }

        if let object, let message = message(fromErrorObject: object) {
            return message
        }
        return "HTTP \(statusCode)"
    }

    /// Extracts a message from a single error object following the precedence used
    /// across providers: top-level `detail`, then nested `error.message`, then a
    /// top-level `message`.
    private static func message(fromErrorObject object: [String: Any]) -> String? {
        if let detail = object["detail"] as? String, !detail.isEmpty {
            return detail
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    func requestBody(
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int?,
        maxOutputTokenParameter: String,
        reasoningEffort: String?,
        temperature: Double?
    ) -> [String: Any] {
        requestBody(
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            maxOutputTokens: maxOutputTokens,
            maxOutputTokenParameter: maxOutputTokenParameter,
            reasoningEffort: reasoningEffort,
            temperature: temperature,
            thinkingEnabled: nil
        )
    }

    func requestBody(
        model: String,
        systemPrompt: String,
        userText: String,
        maxOutputTokens: Int?,
        maxOutputTokenParameter: String,
        reasoningEffort: String?,
        temperature: Double?,
        thinkingEnabled: Bool?
    ) -> [String: Any] {
        var requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ]
        ]

        if let temperature {
            requestBody["temperature"] = temperature
        }

        if let maxOutputTokens {
            requestBody[maxOutputTokenParameter] = maxOutputTokens
        }

        if let reasoningEffort, !reasoningEffort.isEmpty {
            requestBody["reasoning_effort"] = reasoningEffort
        }

        if let thinkingEnabled {
            requestBody["thinking"] = [
                "type": thinkingEnabled ? "enabled" : "disabled"
            ]
        }

        return requestBody
    }
}

private extension Data {
    mutating func appendFormField(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
