import Foundation
import os

typealias APIHandler = @Sendable (HTTPRequest) async -> HTTPResponse

final class APIRouter: Sendable {
    private typealias RouteEntry = (method: String, path: String, handler: APIHandler)

    private let routes = OSAllocatedUnfairLock<[RouteEntry]>(initialState: [])
    private let apiTokenProvider: @Sendable () -> String?

    init(apiTokenProvider: @escaping @Sendable () -> String? = { nil }) {
        self.apiTokenProvider = apiTokenProvider
    }

    func register(_ method: String, _ path: String, handler: @escaping APIHandler) {
        routes.withLock { routes in
            routes.append((method: method.uppercased(), path: path, handler: handler))
        }
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
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
              let expectedToken = apiTokenProvider(),
              !expectedToken.isEmpty else {
            return true
        }

        guard let providedToken = request.bearerToken ?? request.apiTokenHeader else {
            return false
        }

        return Self.constantTimeEquals(providedToken, expectedToken)
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
