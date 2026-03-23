import Foundation
import os

typealias APIHandler = @Sendable (HTTPRequest) async -> HTTPResponse

final class APIRouter: Sendable {
    private typealias RouteEntry = (method: String, path: String, handler: APIHandler)

    private let routes = OSAllocatedUnfairLock<[RouteEntry]>(initialState: [])

    func register(_ method: String, _ path: String, handler: @escaping APIHandler) {
        routes.withLock { routes in
            routes.append((method: method.uppercased(), path: path, handler: handler))
        }
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 200, contentType: "text/plain", body: Data())
        }

        let registeredRoutes = routes.withLock { $0 }

        for route in registeredRoutes {
            if route.method == request.method && route.path == request.path {
                return await route.handler(request)
            }
        }

        return .error(status: 404, message: "Not found: \(request.method) \(request.path)")
    }
}
