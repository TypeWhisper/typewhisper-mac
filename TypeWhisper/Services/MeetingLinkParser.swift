import Foundation

struct MeetingLinkParser: Sendable {
    private static let candidateExpression = try? NSRegularExpression(
        pattern: #"(?i)(?:(?:https?|zoommtg|msteams|facetime):(?://)?[^\s<>\"']+|(?:[a-z0-9-]+\.)*(?:zoom\.us|zoomgov\.com|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|facetime\.apple\.com)/[^\s<>\"']+)"#
    )

    func parse(
        eventURL: URL?,
        location: String?,
        notes: String?
    ) -> [CalendarMeetingCanonicalLink] {
        var links = Set<CalendarMeetingCanonicalLink>()

        if let eventURL, let link = parse(url: eventURL) {
            links.insert(link)
        }
        for text in [location, notes].compactMap({ $0 }) {
            links.formUnion(parse(text: text))
        }

        return links.sorted {
            if $0.provider.rawValue != $1.provider.rawValue {
                return $0.provider.rawValue < $1.provider.rawValue
            }
            return $0.identity < $1.identity
        }
    }

    func parse(text: String) -> [CalendarMeetingCanonicalLink] {
        candidateStrings(in: text)
            .compactMap(parse(candidate:))
            .reduce(into: Set<CalendarMeetingCanonicalLink>()) { $0.insert($1) }
            .sorted { $0.id < $1.id }
    }

    func parse(url: URL) -> CalendarMeetingCanonicalLink? {
        parse(candidate: url.absoluteString)
    }

    private func candidateStrings(in text: String) -> [String] {
        guard let expression = Self.candidateExpression else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let prefix = text[..<swiftRange.lowerBound]
            if prefix.range(
                of: #"[a-z][a-z0-9+.-]*:$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                return nil
            }
            return String(text[swiftRange])
        }
    }

    private func parse(candidate rawCandidate: String) -> CalendarMeetingCanonicalLink? {
        let trimmed = trimTrailingPunctuation(rawCandidate)
        let withScheme: String
        if trimmed.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: [.regularExpression, .caseInsensitive]) != nil {
            withScheme = trimmed
        } else {
            withScheme = "https://\(trimmed)"
        }

        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https":
            return parseWebLink(components)
        case "zoommtg":
            return parseZoomDeepLink(components)
        case "msteams":
            return parseTeamsDeepLink(components)
        case "facetime":
            return parseFaceTimeDeepLink(components, original: withScheme)
        default:
            return nil
        }
    }

    private func parseWebLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        guard let host = components.host?.lowercased() else { return nil }
        if isZoomHost(host) {
            return parseZoomWebLink(components)
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return parseTeamsWebLink(components)
        }
        if host == "meet.google.com" {
            return parseGoogleMeetLink(components)
        }
        if host == "facetime.apple.com" {
            return parseFaceTimeWebLink(components)
        }
        return nil
    }

    private func parseZoomWebLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        let parts = decodedPathParts(components)
        let identity: String?
        switch parts.map({ $0.lowercased() }) {
        case let values where values.count >= 2 && ["j", "s"].contains(values[0]):
            identity = validatedZoomMeetingNumber(parts[1]).map { "j/\($0)" }
        case let values where values.count >= 2 && values[0] == "my":
            identity = "my/\(normalizedIdentifier(parts[1]))"
        case let values where values.count >= 3 && values[0] == "wc" && values[1] == "join":
            identity = validatedZoomMeetingNumber(parts[2]).map { "j/\($0)" }
        default:
            identity = nil
        }
        guard let identity, !identity.hasSuffix("/") else { return nil }
        return CalendarMeetingCanonicalLink(provider: .zoom, identity: identity)
    }

    private func parseZoomDeepLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        let query = queryDictionary(components)
        let candidate = query["confno"] ?? query["meetingid"] ?? decodedPathParts(components).last
        guard let candidate,
              let identifier = validatedZoomMeetingNumber(candidate) else { return nil }
        return CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/\(identifier)")
    }

    private func parseTeamsWebLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        guard let host = components.host?.lowercased() else { return nil }
        let path = normalizedDecodedPath(components)
        if host == "teams.microsoft.com",
           let canonicalPath = canonicalTeamsPath(path, routePrefix: "/l/meetup-join/") {
            return CalendarMeetingCanonicalLink(provider: .teams, identity: host + canonicalPath)
        }
        if host == "teams.live.com",
           let canonicalPath = canonicalTeamsPath(path, routePrefix: "/meet/") {
            return CalendarMeetingCanonicalLink(provider: .teams, identity: host + canonicalPath)
        }
        return nil
    }

    private func parseTeamsDeepLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        let path = normalizedDecodedPath(components)
        if let canonicalPath = canonicalTeamsPath(path, routePrefix: "/l/meetup-join/") {
            return CalendarMeetingCanonicalLink(
                provider: .teams,
                identity: "teams.microsoft.com" + canonicalPath
            )
        }
        if let canonicalPath = canonicalTeamsPath(path, routePrefix: "/meet/") {
            return CalendarMeetingCanonicalLink(
                provider: .teams,
                identity: "teams.live.com" + canonicalPath
            )
        }
        let query = queryDictionary(components)
        if let meetingID = query["meetingid"], !meetingID.isEmpty {
            return CalendarMeetingCanonicalLink(
                provider: .teams,
                identity: "meetingid/\(normalizedIdentifier(meetingID))"
            )
        }
        return nil
    }

    private func canonicalTeamsPath(
        _ path: String,
        routePrefix: String
    ) -> String? {
        guard path.lowercased().hasPrefix(routePrefix) else { return nil }
        let identityStart = path.index(path.startIndex, offsetBy: routePrefix.count)
        let identity = path[identityStart...]
        guard !identity.isEmpty else { return nil }
        return routePrefix + identity
    }

    private func parseGoogleMeetLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        let parts = decodedPathParts(components)
        guard !parts.isEmpty else { return nil }
        if parts.count >= 2, parts[0].lowercased() == "lookup" {
            let slug = normalizedIdentifier(parts[1])
            guard !slug.isEmpty else { return nil }
            return CalendarMeetingCanonicalLink(provider: .googleMeet, identity: "lookup/\(slug)")
        }
        let code = normalizedIdentifier(parts[0])
        guard code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return CalendarMeetingCanonicalLink(provider: .googleMeet, identity: code)
    }

    private func parseFaceTimeWebLink(_ components: URLComponents) -> CalendarMeetingCanonicalLink? {
        guard normalizedDecodedPath(components).lowercased() == "/join" else { return nil }
        let payload = normalizedFaceTimePayload(components)
        guard !payload.isEmpty else { return nil }
        return CalendarMeetingCanonicalLink(provider: .faceTime, identity: "join/\(payload)")
    }

    private func parseFaceTimeDeepLink(_ components: URLComponents, original: String) -> CalendarMeetingCanonicalLink? {
        let prefix = "facetime:"
        let rawTarget = String(original.dropFirst(prefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding ?? ""
        let normalized = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return CalendarMeetingCanonicalLink(provider: .faceTime, identity: "target/\(normalized)")
    }

    private func normalizedFaceTimePayload(_ components: URLComponents) -> String {
        var pairs = components.queryItems ?? []
        if let fragment = components.fragment,
           let fragmentComponents = URLComponents(string: "https://facetime.invalid/?\(fragment)") {
            pairs.append(contentsOf: fragmentComponents.queryItems ?? [])
        }
        return pairs
            .filter { !$0.name.lowercased().hasPrefix("utm_") }
            .compactMap { item -> String? in
                guard let value = item.value?.removingPercentEncoding, !value.isEmpty else { return nil }
                return "\(item.name.lowercased())=\(value)"
            }
            .sorted()
            .joined(separator: "&")
    }

    private func queryDictionary(_ components: URLComponents) -> [String: String] {
        (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            let key = item.name.lowercased()
            guard result[key] == nil,
                  let value = item.value?.removingPercentEncoding else { return }
            result[key] = value
        }
    }

    private func decodedPathParts(_ components: URLComponents) -> [String] {
        normalizedDecodedPath(components)
            .split(separator: "/")
            .map(String.init)
    }

    private func normalizedDecodedPath(_ components: URLComponents) -> String {
        let decoded = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let collapsed = decoded.replacingOccurrences(of: #"/{2,}"#, with: "/", options: .regularExpression)
        if collapsed.count > 1, collapsed.hasSuffix("/") {
            return String(collapsed.dropLast())
        }
        return collapsed
    }

    private func normalizedIdentifier(_ value: String) -> String {
        (value.removingPercentEncoding ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func normalizedZoomIdentifier(_ value: String) -> String {
        let normalized = normalizedIdentifier(value)
        let compact = normalized.filter { !$0.isWhitespace && $0 != "-" }
        return compact.allSatisfy(\.isNumber) ? compact : normalized
    }

    private func validatedZoomMeetingNumber(_ value: String) -> String? {
        let normalized = normalizedZoomIdentifier(value)
        guard !normalized.isEmpty, normalized.allSatisfy(\.isNumber) else { return nil }
        return normalized
    }

    private func isZoomHost(_ host: String) -> Bool {
        host == "zoom.us" || host.hasSuffix(".zoom.us")
            || host == "zoomgov.com" || host.hasSuffix(".zoomgov.com")
    }

    private func trimTrailingPunctuation(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet(charactersIn: ".,;!?)]}>")
        while let scalar = result.unicodeScalars.last, punctuation.contains(scalar) {
            result.removeLast()
        }
        return result
    }
}
