import Foundation

enum CalendarMeetingRecordingFilename {
    static func preferredBaseName(title: String, date: Date = Date()) -> String {
        let timestamp = timestampString(for: date)
        let sanitizedTitle = sanitizeTitle(title)
        if sanitizedTitle.isEmpty {
            return "Recording \(timestamp)"
        }
        return "\(sanitizedTitle) — \(timestamp)"
    }

    static func sanitizedBaseName(_ value: String, fallbackDate: Date = Date()) -> String {
        let normalized = normalize(value)
        return normalized.isEmpty ? "Recording \(timestampString(for: fallbackDate))" : normalized
    }

    static func availableURL(
        in directory: URL,
        preferredBaseName: String,
        fileExtension: String,
        fallbackDate: Date = Date(),
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)
    ) -> URL {
        let baseName = sanitizedBaseName(preferredBaseName, fallbackDate: fallbackDate)
        var suffix = 1
        while true {
            let candidateName = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let candidate = directory
                .appendingPathComponent(candidateName)
                .appendingPathExtension(fileExtension)
            if !fileExists(candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func sanitizeTitle(_ title: String) -> String {
        String(normalize(title).prefix(120))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ value: String) -> String {
        let precomposed = value.precomposedStringWithCanonicalMapping
        let normalizedScalars = precomposed.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar == "/"
                || scalar == ":" {
                return UnicodeScalar(0x20)!
            }
            return scalar
        }
        let withoutInvalidScalars = String(String.UnicodeScalarView(normalizedScalars))
        let collapsed = withoutInvalidScalars
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.drop(while: { $0 == "." || $0.isWhitespace }).description
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
