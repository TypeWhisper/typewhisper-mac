import Foundation
import os

typealias APIHandler = @Sendable (HTTPRequest) async -> HTTPResponse

enum APIAuthenticationRequirement: Sendable, Equatable {
    case disabled
    /// A missing or empty token rejects every protected request.
    case required(token: String?)
}

final class APIRouter: Sendable {
    private typealias RouteEntry = (method: String, path: String, handler: APIHandler)

    private let routes = OSAllocatedUnfairLock<[RouteEntry]>(initialState: [])
    private let authenticationProvider: @Sendable () -> APIAuthenticationRequirement

    init(authenticationProvider: @escaping @Sendable () -> APIAuthenticationRequirement = { .disabled }) {
        self.authenticationProvider = authenticationProvider
    }

    func register(_ method: String, _ path: String, handler: @escaping APIHandler) {
        routes.withLock { routes in
            routes.append((method: method.uppercased(), path: path, handler: handler))
        }
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = Self.browserRequestRejection(request) {
            return .error(status: 403, message: rejection)
        }

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, contentType: "text/plain", body: Data())
        }

        let registeredRoutes = routes.withLock { $0 }

        for route in registeredRoutes {
            if route.method == request.method && route.path == request.path {
                guard isAuthorized(request) else {
                    return .error(
                        status: 401,
                        message: "Missing or invalid API token",
                        headers: ["WWW-Authenticate": "Bearer"]
                    )
                }
                return await route.handler(request)
            }
        }

        return .error(status: 404, message: "Not found: \(request.method) \(request.path)")
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard !isPublicRoute(request),
              case .required(let expectedToken) = authenticationProvider() else {
            return true
        }

        guard let expectedToken, !expectedToken.isEmpty,
              let providedToken = request.bearerToken ?? request.apiTokenHeader else {
            return false
        }

        return Self.constantTimeEquals(providedToken, expectedToken)
    }

    /// The API serves local tools, which either send no browser headers or
    /// talk to 127.0.0.1 directly. Web pages from other sites, including
    /// DNS-rebinding attempts that point a foreign host name at 127.0.0.1,
    /// are refused even when no API token is required.
    static func browserRequestRejection(_ request: HTTPRequest) -> String? {
        if let host = request.headers["host"], !isLoopbackHost(host) {
            return "Requests must be addressed to 127.0.0.1 or localhost"
        }

        let origin = request.headers["origin"]
        if let origin, !isAllowedOrigin(origin) {
            return "Requests from web pages on other sites are not allowed"
        }

        // Browsers treat localhost and 127.0.0.1 as different sites, so a
        // page on localhost also arrives as cross-site. Only a loopback
        // Origin vouches for it; navigations and embeds send none.
        if request.headers["sec-fetch-site"]?.lowercased() == "cross-site",
           !(origin.map(isLoopbackWebOrigin) ?? false) {
            return "Requests from web pages on other sites are not allowed"
        }

        return nil
    }

    private static func isLoopbackHost(_ hostHeader: String) -> Bool {
        let value = hostHeader.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("["), let closingBracket = value.firstIndex(of: "]") {
            return isLoopbackHostName(String(value[value.index(after: value.startIndex)..<closingBracket]))
        }
        let hostName = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return isLoopbackHostName(String(hostName))
    }

    private static func isLoopbackHostName(_ name: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(name.lowercased())
    }

    /// Pages served from this Mac and non-web origins such as browser
    /// extensions are allowed. Opaque "null" origins come from sandboxed
    /// frames and local files, which any site can create.
    private static func isAllowedOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased() else {
            return false
        }

        guard scheme == "http" || scheme == "https" else { return true }
        return isLoopbackWebOrigin(origin)
    }

    private static func isLoopbackWebOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host else {
            return false
        }
        return isLoopbackHostName(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    private func isPublicRoute(_ request: HTTPRequest) -> Bool {
        request.method == "GET" && request.path == "/v1/status"
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        let maxCount = max(lhsBytes.count, rhsBytes.count)

        for index in 0..<maxCount {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }

        return difference == 0
    }
}

private extension HTTPRequest {
    var bearerToken: String? {
        guard let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        let prefix = "Bearer "
        guard authorization.regionMatches(prefix, options: .caseInsensitive) else {
            return nil
        }

        let token = authorization.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    var apiTokenHeader: String? {
        let token = headers["x-typewhisper-api-token"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

private extension String {
    func regionMatches(_ prefix: String, options: String.CompareOptions) -> Bool {
        range(of: prefix, options: options, range: startIndex..<endIndex, locale: nil)?.lowerBound == startIndex
    }
}
