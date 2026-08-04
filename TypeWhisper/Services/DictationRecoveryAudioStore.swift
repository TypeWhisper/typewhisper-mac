import Foundation

enum DictationRecoveryRetentionPolicy: Int, CaseIterable, Sendable {
    case immediately = -1
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case sixtyDays = 60
    case ninetyDays = 90
    case oneHundredEightyDays = 180
    case never = 0

    static let defaultPolicy: Self = .thirtyDays

    static func load(from defaults: UserDefaults) -> Self {
        guard let storedValue = defaults.object(forKey: UserDefaultsKeys.dictationRecoveryRetentionDays) as? NSNumber,
              let policy = Self(rawValue: storedValue.intValue)
        else {
            return defaultPolicy
        }
        return policy
    }

    var keepsRecoveryFiles: Bool {
        self != .immediately
    }

    var retentionDays: Int? {
        rawValue > 0 ? rawValue : nil
    }
}

/// Persists the active dictation as a temporary 16 kHz mono PCM WAV so the
/// audio can be recovered if transcription fails after recording has stopped.
final class DictationRecoveryAudioStore: @unchecked Sendable {
    private enum Constants {
        static let sampleRate: UInt32 = 16_000
        static let bitsPerSample: UInt16 = 16
        static let channelCount: UInt16 = 1
        static let bytesPerSample = 2
        static let wavHeaderByteCount = 44
        static let activeFileName = "active-dictation-recovery.wav"
        static let legacyLatestFileName = "last-dictation-recovery.wav"
        static let recoveryFilePrefix = "dictation-recovery-"
        static let recoveryFileExtension = "wav"
    }

    private let directory: URL
    private let activeFileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.typewhisper.dictation-recovery-audio", qos: .utility)

    private var activeHandle: FileHandle?
    private var activeSampleCount = 0
    private var hasActiveRecording = false
    private var recoverySerialNumber: UInt64 = 0
    private var retentionPolicy: DictationRecoveryRetentionPolicy

    init(
        directory: URL = AppConstants.appSupportDirectory
            .appendingPathComponent("dictation-recovery", isDirectory: true),
        fileManager: FileManager = .default,
        retentionPolicy: DictationRecoveryRetentionPolicy = .defaultPolicy,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let standardizedInput = directory.standardizedFileURL
        let standardizedDirectory: URL
        if fileManager.fileExists(atPath: standardizedInput.path) {
            standardizedDirectory = standardizedInput.resolvingSymlinksInPath().standardizedFileURL
        } else {
            let resolvedParent = standardizedInput
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
            standardizedDirectory = resolvedParent
                .appendingPathComponent(standardizedInput.lastPathComponent, isDirectory: true)
                .standardizedFileURL
        }
        self.directory = standardizedDirectory
        self.activeFileURL = standardizedDirectory.appendingPathComponent(Constants.activeFileName)
        self.fileManager = fileManager
        self.retentionPolicy = retentionPolicy
        self.now = now

        // An active file cannot be recovered safely because its WAV header is
        // finalized only after recording stops. Never leave crash residue on disk.
        removeItemIfExists(at: activeFileURL)
        applyRetentionPolicy()
    }

    var recoveryURLs: [URL] {
        queue.sync {
            applyRetentionPolicy()
            return storedRecoveryURLs()
        }
    }

    var latestRecoveryURL: URL? {
        queue.sync {
            applyRetentionPolicy()
            return storedRecoveryURLs().first
        }
    }

    func startNewRecording() {
        queue.sync {
            closeActiveHandle()
            removeItemIfExists(at: activeFileURL)
            activeSampleCount = 0
            hasActiveRecording = false
            applyRetentionPolicy()

            guard retentionPolicy.keepsRecoveryFiles else { return }
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard !itemExists(at: activeFileURL) else { return }

            fileManager.createFile(
                atPath: activeFileURL.path,
                contents: Self.wavHeader(sampleCount: 0),
                attributes: nil
            )
            activeHandle = try? FileHandle(forWritingTo: activeFileURL)
            _ = try? activeHandle?.seekToEnd()
            activeSampleCount = 0
            hasActiveRecording = activeHandle != nil
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        queue.async { [weak self, samples] in
            guard let self, self.hasActiveRecording, let activeHandle = self.activeHandle else { return }
            let data = Self.pcm16Data(from: samples)
            do {
                try activeHandle.write(contentsOf: data)
                self.activeSampleCount += samples.count
            } catch {
                self.closeActiveHandle()
                self.removeItemIfExists(at: self.activeFileURL)
                self.hasActiveRecording = false
                self.activeSampleCount = 0
            }
        }
    }

    @discardableResult
    func preserveActiveRecording() -> URL? {
        queue.sync {
            guard retentionPolicy.keepsRecoveryFiles else {
                closeActiveHandle()
                activeSampleCount = 0
                hasActiveRecording = false
                removeItemIfExists(at: activeFileURL)
                removeStoredRecoveries()
                return nil
            }

            guard hasActiveRecording else {
                return storedRecoveryURLs().first
            }

            closeActiveHandle()
            hasActiveRecording = false

            guard activeSampleCount > 0 else {
                activeSampleCount = 0
                removeItemIfExists(at: activeFileURL)
                return storedRecoveryURLs().first
            }

            finalizeActiveWavHeader(sampleCount: activeSampleCount)
            let recoveryURL = makeUniqueRecoveryFileURL()

            do {
                try fileManager.moveItem(at: activeFileURL, to: recoveryURL)
                activeSampleCount = 0
                return canonicalFileURL(recoveryURL)
            } catch {
                activeSampleCount = 0
                removeItemIfExists(at: activeFileURL)
                return storedRecoveryURLs().first
            }
        }
    }

    @discardableResult
    func updateRetentionPolicy(_ policy: DictationRecoveryRetentionPolicy) -> [URL] {
        queue.sync {
            retentionPolicy = policy
            applyRetentionPolicy()
            return storedRecoveryURLs()
        }
    }

    @discardableResult
    func refreshRetention() -> [URL] {
        queue.sync {
            applyRetentionPolicy()
            return storedRecoveryURLs()
        }
    }

    func discardActiveRecording(keepingLatest: Bool = true) {
        queue.sync {
            closeActiveHandle()
            activeSampleCount = 0
            hasActiveRecording = false
            removeItemIfExists(at: activeFileURL)
            if !keepingLatest {
                removeStoredRecoveries()
            }
        }
    }

    func discardLatestRecovery() {
        queue.sync {
            guard let latestRecoveryURL = storedRecoveryURLs().first else { return }
            removeItemIfExists(at: latestRecoveryURL)
        }
    }

    func discardRecovery(at url: URL) {
        queue.sync {
            guard isStoredRecoveryFile(url) else { return }
            removeItemIfExists(at: url)
        }
    }

    func discardAllRecoveries() {
        queue.sync {
            removeStoredRecoveries()
        }
    }

    private func storedRecoveryURLs() -> [URL] {
        guard fileManager.fileExists(atPath: directory.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        return urls
            .filter(isStoredRecoveryFile)
            .map { directory.appendingPathComponent($0.lastPathComponent) }
            .sorted { lhs, rhs in
                let lhsDate = contentModificationDate(for: lhs)
                let rhsDate = contentModificationDate(for: rhs)
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
    }

    private func isStoredRecoveryFile(_ url: URL) -> Bool {
        let canonicalURL = canonicalFileURL(url)
        guard canonicalURL.deletingLastPathComponent() == directory else { return false }
        guard isRegularNonSymlinkFile(url) else { return false }
        let fileName = url.lastPathComponent
        return fileName == Constants.legacyLatestFileName || isGeneratedRecoveryFileName(fileName)
    }

    private func isGeneratedRecoveryFileName(_ fileName: String) -> Bool {
        let suffix = ".\(Constants.recoveryFileExtension)"
        guard fileName.hasPrefix(Constants.recoveryFilePrefix), fileName.hasSuffix(suffix) else { return false }

        let stemStart = fileName.index(fileName.startIndex, offsetBy: Constants.recoveryFilePrefix.count)
        let stemEnd = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        let components = fileName[stemStart..<stemEnd].split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 4 || components.count == 5 else { return false }
        guard hasASCIIDigits(components[0], count: 8),
              hasASCIIDigits(components[1], count: 6),
              hasASCIIDigits(components[2], count: 3),
              components[3].count >= 4,
              hasASCIIDigits(components[3])
        else {
            return false
        }

        return components.count == 4 || hasASCIIDigits(components[4])
    }

    private func hasASCIIDigits(_ value: Substring, count: Int? = nil) -> Bool {
        guard !value.isEmpty, count == nil || value.count == count else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func contentModificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func itemExists(at url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            return true
        }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func makeUniqueRecoveryFileURL() -> URL {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        recoverySerialNumber += 1
        let baseName = "\(Constants.recoveryFilePrefix)\(Self.recoveryTimestamp(from: now()))-\(String(format: "%04llu", recoverySerialNumber))"
        var candidate = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension(Constants.recoveryFileExtension)
        var collisionIndex = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)-\(collisionIndex)")
                .appendingPathExtension(Constants.recoveryFileExtension)
            collisionIndex += 1
        }

        return candidate
    }

    private func removeStoredRecoveries() {
        for url in storedRecoveryURLs() {
            removeItemIfExists(at: url)
        }
    }

    private func applyRetentionPolicy() {
        guard retentionPolicy.keepsRecoveryFiles else {
            closeActiveHandle()
            activeSampleCount = 0
            hasActiveRecording = false
            removeItemIfExists(at: activeFileURL)
            removeStoredRecoveries()
            return
        }

        guard let retentionDays = retentionPolicy.retentionDays else { return }
        let currentDate = now()
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: currentDate) ?? currentDate
        for url in storedRecoveryURLs() where contentModificationDate(for: url) < cutoff {
            removeItemIfExists(at: url)
        }
    }

    private func finalizeActiveWavHeader(sampleCount: Int) {
        guard let handle = try? FileHandle(forWritingTo: activeFileURL) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.wavHeader(sampleCount: sampleCount))
        } catch {
            removeItemIfExists(at: activeFileURL)
        }
    }

    private func closeActiveHandle() {
        try? activeHandle?.synchronize()
        try? activeHandle?.close()
        activeHandle = nil
    }

    private func removeItemIfExists(at url: URL) {
        guard fileManager.fileExists(atPath: url.path), isRegularNonSymlinkFile(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * Constants.bytesPerSample)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            var littleEndian = scaled.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }

    private static func wavHeader(sampleCount: Int) -> Data {
        let dataByteCount = UInt32(sampleCount * Constants.bytesPerSample)
        let fileByteCount = UInt32(Constants.wavHeaderByteCount - 8) + dataByteCount
        let byteRate = Constants.sampleRate * UInt32(Constants.channelCount) * UInt32(Constants.bytesPerSample)
        let blockAlign = Constants.channelCount * Constants.bitsPerSample / 8

        var data = Data()
        data.reserveCapacity(Constants.wavHeaderByteCount)
        data.appendASCII("RIFF")
        data.appendLittleEndian(fileByteCount)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(Constants.channelCount)
        data.appendLittleEndian(Constants.sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(Constants.bitsPerSample)
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        return data
    }

    private static func recoveryTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
