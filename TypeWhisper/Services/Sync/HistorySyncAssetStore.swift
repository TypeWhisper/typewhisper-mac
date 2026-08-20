import CryptoKit
import Foundation

enum HistorySyncAssetStoreError: LocalizedError, Equatable {
    case invalidDescriptor
    case missingAsset
    case integrityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            String(localized: "The synchronized audio reference is invalid.")
        case .missingAsset:
            String(localized: "The synchronized audio is not available yet.")
        case .integrityMismatch:
            String(localized: "The synchronized audio could not be verified.")
        }
    }
}

enum HistorySyncAssetStore {
    static func publish(
        sourceURL: URL,
        packageURL: URL,
        generation: String,
        recordID: UUID,
        updatedAt: Date,
        durationSeconds: Double?
    ) throws -> UserDataSyncHistoryAudioV1 {
        let digest = try sha256AndSize(of: sourceURL)
        let relativePath = [
            "assets",
            "history",
            generation,
            recordID.uuidString.lowercased(),
            "\(digest.sha256).wav",
        ].joined(separator: "/")
        let destination = packageURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = destination
                .deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).partial")
            try FileManager.default.copyItem(at: sourceURL, to: temporary)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    throw error
                }
            }
        }

        let published = try sha256AndSize(of: destination)
        guard published == digest else {
            throw HistorySyncAssetStoreError.integrityMismatch
        }
        return UserDataSyncHistoryAudioV1(
            recordID: recordID,
            updatedAt: updatedAt,
            relativeAssetPath: relativePath,
            mediaType: "audio/wav",
            byteCount: digest.byteCount,
            sha256: digest.sha256,
            createdAt: updatedAt,
            durationSeconds: durationSeconds
        )
    }

    static func verifiedAssetURL(
        packageURL: URL,
        descriptor: UserDataSyncHistoryAudioV1
    ) async throws -> URL {
        guard descriptor.isValid else {
            throw HistorySyncAssetStoreError.invalidDescriptor
        }
        let resolvedPackageURL = packageURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let url = packageURL
            .appendingPathComponent(descriptor.relativeAssetPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let packagePath = resolvedPackageURL.path.hasSuffix("/")
            ? resolvedPackageURL.path
            : resolvedPackageURL.path + "/"
        guard url.path.hasPrefix(packagePath) else {
            throw HistorySyncAssetStoreError.invalidDescriptor
        }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        for attempt in 0..<40 {
            if FileManager.default.fileExists(atPath: url.path),
               let digest = try? sha256AndSize(of: url),
               digest.byteCount == descriptor.byteCount,
               digest.sha256 == descriptor.sha256 {
                return url
            }
            if attempt == 39 {
                if FileManager.default.fileExists(atPath: url.path) {
                    throw HistorySyncAssetStoreError.integrityMismatch
                }
                throw HistorySyncAssetStoreError.missingAsset
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw HistorySyncAssetStoreError.missingAsset
    }

    static func sha256AndSize(of url: URL) throws -> (sha256: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0

        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, byteCount)
    }
}
