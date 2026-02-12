import Foundation

typealias APIHandler = (HTTPRequest) async -> HTTPResponse

final class APIRouter {
    private var routes: [(method: String, path: String, handler: APIHandler)] = []

    func register(_ method: String, _ path: String, handler: @escaping APIHandler) {
        routes.append((method: method.uppercased(), path: path, handler: handler))
    }

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "OPTIONS" {
            return HTTPResponse(status: 200, contentType: "text/plain", body: Data())
        }

        for route in routes {
            if route.method == request.method && route.path == request.path {
                return await route.handler(request)
            }
        }

        return .error(status: 404, message: "Not found: \(request.method) \(request.path)")
    }
}
